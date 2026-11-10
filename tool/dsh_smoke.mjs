#!/usr/bin/env node
// BaoCode's manual smoke for the DSH kernel.
//
// It starts the dsh on this machine on its ACP profile, with the profile patch
// BaoCode's adapter writes - mirrored by hand from `DshPatch.content` in
// `lib/kernel/dsh/dsh_patch.dart`, in a temporary folder under an absolute
// path - and runs one prompt through it: initialize, session/new,
// session/prompt. Approvals dsh asks for are allowed once, automatically, so
// the turn is not left waiting.
//
// This spends one model call on the user's account, and it starts a real
// process. It is NOT part of CI, and no test runs it:
//
//   node tool/dsh_smoke.mjs --help
//   node tool/dsh_smoke.mjs
//   node tool/dsh_smoke.mjs --cwd /path/to/project --prompt "List the tasks"
//
// What it writes: the patch below, in a fresh temporary folder, removed on the
// way out. It never writes to ~/.dsh (dsh itself creates the session there, as
// it does for dsh web), and never reads a credential value: the patch names
// the ref with `apiKeyEnv`, and dsh reads its own store.
//
// Exit code 0 when the prompt came back with a stopReason, 1 otherwise.

import {execFileSync, spawn} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import readline from 'node:readline';

const packagePath = path.join(
  'node_modules',
  '@deepseek-ai',
  'dsh',
  'lib',
  'bin.js',
);

const usage = `Usage: node tool/dsh_smoke.mjs [--cwd <dir>] [--prompt <text>]

Starts the dsh found on this machine on its ACP profile, with the patch
BaoCode's adapter writes (mirrored below, in a temporary folder under an
absolute path), and runs one prompt: initialize, session/new, session/prompt.
Approvals are allowed once by itself.

  --cwd <dir>      the project folder the session works in (default: this one)
  --prompt <text>  what to ask (default: "Reply with the single word: ok.")
  --help           print this, exit 0, and start nothing

Environment:
  BAOCODE_DSH_PATH  the dsh's lib/bin.js (or its package folder) to use,
                    instead of the one found on the PATH or under npm's
                    global root

It spends one model call on the user's account. It is not run in CI.`;

// --- Arguments --------------------------------------------------------------

function parseArgs(argv) {
  const options = {cwd: process.cwd(), prompt: 'Reply with the single word: ok.'};
  for (let i = 0; i < argv.length; i++) {
    const argument = argv[i];
    if (argument === '--help' || argument === '-h') {
      return {help: true};
    }
    if (argument === '--cwd' || argument === '--prompt') {
      const value = argv[++i];
      if (value === undefined || value === '') {
        throw new Error(`${argument} needs a value`);
      }
      if (argument === '--cwd') {
        options.cwd = value;
      } else {
        options.prompt = value;
      }
      continue;
    }
    throw new Error(`unknown argument: ${argument}`);
  }
  return options;
}

function usageError(error) {
  console.error(`dsh_smoke: ${error.message}\n`);
  console.error(usage);
  process.exit(1);
}

// --- Locating dsh -----------------------------------------------------------

function unquoted(entry) {
  const trimmed = entry.trim();
  return trimmed.length > 1 && trimmed.startsWith('"') && trimmed.endsWith('"')
    ? trimmed.slice(1, -1)
    : trimmed;
}

function pathDirectories() {
  return (process.env.PATH ?? process.env.Path ?? '')
    .split(path.delimiter)
    .map(unquoted)
    .filter((entry) => entry !== '');
}

/** The `bin.js` an npm shim's text runs, or null for another program. */
function binJsFromShim(text, directory) {
  for (const raw of text.split(/\s+/)) {
    const token = raw.replaceAll('"', '').replaceAll("'", '');
    if (!token.includes('bin.js')) continue;
    let found = token
      .replaceAll('\\', '/')
      .replace(/%dp0%/gi, directory)
      .replace(/\$\{?basedir\}?/g, directory);
    if (!found.endsWith(packagePath.replaceAll('\\', '/'))) continue;
    if (!path.isAbsolute(found)) found = path.join(directory, found);
    return path.normalize(found);
  }
  return null;
}

/** The dsh an earlier `dsh`/`dsh.cmd`/`dsh.ps1` on the PATH runs. */
function fromShims(directories) {
  for (const directory of directories) {
    for (const name of ['dsh', 'dsh.cmd', 'dsh.ps1']) {
      try {
        const binJs = binJsFromShim(
          readFileSync(path.join(directory, name), 'utf8'),
          directory,
        );
        if (binJs && existsSync(binJs)) return binJs;
      } catch {
        // Not this one: another names it, or it is not a shim.
      }
    }
  }
  return null;
}

/** npm's global root, as `npm root -g` says it; null where npm cannot say. */
function npmGlobalRoot() {
  try {
    const root = execFileSync('npm', ['root', '-g'], {
      encoding: 'utf8',
      shell: process.platform === 'win32',
      timeout: 20000,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return root === '' ? null : root;
  } catch {
    return null;
  }
}

/** Where an npm global dsh may be, PATH or no PATH. */
function globalRoots(directories) {
  const roots = [];
  if (process.platform === 'win32') {
    // %APPDATA%\npm\node_modules
    for (const directory of directories) {
      roots.push(path.join(directory, 'node_modules'));
    }
    if (process.env.APPDATA) {
      roots.push(path.join(process.env.APPDATA, 'npm', 'node_modules'));
    }
    return roots;
  }
  const prefixOfBin = [];
  for (const directory of directories) {
    if (path.basename(directory) !== 'bin') continue;
    if (
      !existsSync(path.join(directory, 'node')) &&
      !existsSync(path.join(directory, 'dsh'))
    ) {
      continue;
    }
    prefixOfBin.push(path.dirname(directory));
  }
  const home = process.env.HOME ?? '';
  if (home !== '') {
    const nvm = path.join(home, '.nvm', 'versions', 'node');
    if (existsSync(nvm)) {
      for (const name of nvmChildren(nvm)) {
        roots.push(path.join(nvm, name, 'lib', 'node_modules'));
      }
    }
    roots.push(path.join(home, '.npm-global', 'lib', 'node_modules'));
  }
  roots.push(path.join('/usr/local', 'lib', 'node_modules'));
  for (const prefix of prefixOfBin) {
    roots.push(path.join(prefix, 'lib', 'node_modules'));
  }
  return roots;
}

/** The Node versions under nvm's folder. */
function nvmChildren(directory) {
  try {
    return readdirSync(directory, {withFileTypes: true})
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name);
  } catch {
    return [];
  }
}

/** The first dsh found: BAOCODE_DSH_PATH, npm's root, a shim, a global root. */
function locate() {
  const named = (process.env.BAOCODE_DSH_PATH ?? '').trim();
  if (named !== '') {
    const candidate = named.endsWith('.js') ? named : path.join(named, 'lib', 'bin.js');
    return candidate;
  }
  const directories = pathDirectories();
  const root = npmGlobalRoot();
  if (root) {
    const candidate = path.join(root, packagePath);
    if (existsSync(candidate)) return candidate;
  }
  const shim = fromShims(directories);
  if (shim) return shim;
  for (const modules of globalRoots(directories)) {
    const candidate = path.join(modules, packagePath);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/** The version of the package [binJs] belongs to; `unknown` if unreadable. */
function versionOf(binJs) {
  const packageDir = path.dirname(path.dirname(binJs));
  try {
    const manifest = JSON.parse(
      readFileSync(path.join(packageDir, 'package.json'), 'utf8'),
    );
    return typeof manifest.version === 'string' ? manifest.version : 'unknown';
  } catch {
    return 'unknown';
  }
}

// --- The patch --------------------------------------------------------------

/**
 * What the patch says, in one place: the values `DshPatch` writes. It is
 * mirrored by hand rather than read from the app - a change to
 * `dsh_patch.dart`, or a dsh upgrade that changes the patch's shape, has to be
 * made here as well.
 *
 * There is no `bashPath` here: the adapter adds the `bash-sandbox`/`tool-bash`
 * pair when it finds this machine's Git Bash *and* `dsh-gitbash-shell` is
 * installed for the ACP profile (`DshPatch.ensure`). This script looks for
 * neither, so its patch never carries that pair.
 */
const patch = {
  header: (version) => `# Generated by BaoCode for dsh ${version}. Do not edit.`,
  credentialRef: 'STEPCODEV2_API_KEY',
  contextWindow: 512000,
  provider: 'stepcodev2',
  model: 'deepseek-v4.1-flash',
  baseURL: 'https://i-ai-gw.stepx.com/v1',
};

/** The patch's text, from [patch] and the dsh [version] it names. */
function patchText(version) {
  const lines = [
    patch.header(version),
    '',
    '- id: llm-pi-ai',
    "  name: '@deepseek-ai/dsh-llm-pi-ai'",
    '  config:',
    '    providers:',
    `      ${patch.provider}:`,
    `        displayName: ${patch.provider}`,
    `        apiKeyEnv: ${patch.credentialRef}`,
    '        api: openai-completions',
    `        baseURL: ${patch.baseURL}`,
    '        models:',
    `          - id: ${patch.model}`,
    `            name: ${patch.model}`,
    `            contextWindow: ${patch.contextWindow}`,
    '            input: [text, image]',
    '- id: acp',
    "  name: '@deepseek-ai/dsh-acp'",
    '  inject: [acpAppStartup]',
    '  config:',
    `    provider: ${patch.provider}`,
    `    model: ${patch.model}`,
  ];
  return `${lines.join('\n')}\n`;
}

function writePatch(version) {
  const directory = mkdtempSync(path.join(tmpdir(), 'baocode-dsh-smoke-'));
  mkdirSync(directory, {recursive: true});
  const file = path.join(directory, 'acp.patch.yml');
  writeFileSync(file, patchText(version), {mode: 0o600});
  if (process.platform !== 'win32') {
    // As dsh's own config is: the user's alone.
    execFileSync('chmod', ['700', directory]);
    execFileSync('chmod', ['600', file]);
  }
  return {directory, file};
}

// --- The conversation -------------------------------------------------------

const updates = [];
const stderrTail = [];
const pending = new Map();
let nextId = 1;
let exited = false;
let stopping = false;

function remember(line) {
  stderrTail.push(line);
  if (stderrTail.length > 30) stderrTail.shift();
}

function send(child, message) {
  if (exited) return;
  try {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  } catch {
    // Gone under us: its exit is reported on its own.
  }
}

function request(child, method, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method}: no answer within ${timeoutMs} ms`));
    }, timeoutMs);
    pending.set(id, {
      resolve: (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timer);
        reject(error);
      },
    });
    send(child, {jsonrpc: '2.0', id, method, params});
  });
}

function errorFrom(message, fallback) {
  const error = message.error;
  if (!error || typeof error !== 'object') return new Error(fallback);
  const details = error.data && error.data.details;
  const text = typeof details === 'string' && details.trim() !== ''
    ? details
    : String(error.message ?? fallback);
  const wrapped = new Error(`${text}${error.code ? ` (code ${error.code})` : ''}`);
  wrapped.code = error.code;
  return wrapped;
}

function handleLine(child, line) {
  const trimmed = line.trim();
  if (trimmed === '') return;
  let message;
  try {
    message = JSON.parse(trimmed);
  } catch {
    // Not protocol (a warning on stdout): keep it for a failure's report.
    remember(trimmed);
    return;
  }
  if (message.method === 'session/update') {
    const update = message.params?.update;
    const kind = update?.sessionUpdate;
    if (!kind) return;
    updates.push(kind);
    const title = typeof update.title === 'string' && update.title !== ''
      ? `: ${update.title}`
      : '';
    console.log(`update: ${kind}${title}`);
    return;
  }
  if (message.method === 'session/request_permission') {
    // dsh asks leave to step outside its sandbox: allowed once, so that the
    // prompt is not left waiting.
    const toolCallId = message.params?.toolCall?.toolCallId ?? '';
    console.log(`approval: allow-once (${toolCallId})`);
    send(child, {
      jsonrpc: '2.0',
      id: message.id,
      result: {outcome: {outcome: 'selected', optionId: 'allow-once'}},
    });
    return;
  }
  if (message.method) {
    // Anything else dsh asks: turned down rather than left waiting.
    send(child, {
      jsonrpc: '2.0',
      id: message.id,
      result: {outcome: {outcome: 'cancelled'}},
    });
    return;
  }
  const waiter = pending.get(message.id);
  if (!waiter) return;
  pending.delete(message.id);
  if (message.error) {
    waiter.reject(errorFrom(message, 'dsh answered an error'));
    return;
  }
  waiter.resolve(message.result ?? {});
}

/** Ends the child, its stdin closed first so dsh flushes what it has. */
function shutdown(child) {
  if (stopping) return Promise.resolve();
  stopping = true;
  if (exited) {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const done = () => {
      exited = true;
      resolve();
    };
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        // Already gone.
      }
      done();
    }, 10000);
    child.once('exit', () => {
      clearTimeout(timer);
      done();
    });
    try {
      child.stdin.end();
    } catch {
      done();
    }
  });
}

function rejectPending(error) {
  for (const waiter of pending.values()) waiter.reject(error);
  pending.clear();
}

async function run(options) {
  const cwd = path.resolve(options.cwd);
  if (!existsSync(cwd) || !statSync(cwd).isDirectory()) {
    throw new Error(`--cwd is not a folder: ${cwd}`);
  }
  const binJs = locate();
  if (!binJs || !existsSync(binJs)) {
    throw new Error(
      'dsh was not found: run `npm i -g @deepseek-ai/dsh`, or set ' +
        'BAOCODE_DSH_PATH to its lib/bin.js',
    );
  }
  const version = versionOf(binJs);
  const patch = writePatch(version);
  console.log(`dsh: ${version} (${binJs})`);
  console.log(`node: ${process.execPath}`);
  console.log(`patch: ${patch.file}`);
  console.log(`cwd: ${cwd}`);
  console.log(`prompt: ${options.prompt}`);

  // The tier BaoCode starts a new conversation in by default, passed the way
  // the kernel passes it: the sandbox mode, and so what may ask for approval.
  const child = spawn(
    process.execPath,
    [binJs, '--profile', 'acp', '--patch', patch.file],
    {
      cwd,
      env: {...process.env, DSH_PERMISSION_MODE: 'workspace-write'},
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    },
  );

  child.on('error', (error) => {
    remember(`spawn: ${error.message}`);
    rejectPending(new Error(`dsh did not start: ${error.message}`));
  });
  child.on('exit', (code, signal) => {
    if (!exited) remember(`dsh exited (code ${code}, signal ${signal})`);
    exited = true;
    rejectPending(new Error(`dsh exited (code ${code}, signal ${signal})`));
  });
  readline
    .createInterface({input: child.stdout})
    .on('line', (line) => handleLine(child, line));
  readline
    .createInterface({input: child.stderr})
    .on('line', remember);

  try {
    const initialized = await request(
      child,
      'initialize',
      {protocolVersion: 1},
      30000,
    );
    const info = initialized?.agentInfo ?? {};
    console.log(`agent: ${info.name ?? '?'} ${info.version ?? ''}`.trim());

    const session = await request(
      child,
      'session/new',
      // Required, and really started when not empty (F4).
      {cwd, mcpServers: []},
      60000,
    );
    console.log(`session: ${session.sessionId ?? '(none)'}`);

    const result = await request(
      child,
      'session/prompt',
      {
        sessionId: session.sessionId,
        prompt: [{type: 'text', text: options.prompt}],
      },
      180000,
    );
    const stopReason = result?.stopReason;
    console.log(`updates: ${updates.length === 0 ? '(none)' : updates.join(' -> ')}`);
    console.log(`stopReason: ${stopReason ?? '(none)'}`);
    await shutdown(child);
    rmSync(patch.directory, {recursive: true, force: true});
    if (typeof stopReason !== 'string') {
      throw new Error('the turn ended without a stopReason');
    }
    return 0;
  } catch (error) {
    console.error(`smoke failed: ${error.message}`);
    if (stderrTail.length > 0) {
      console.error('dsh stderr (last lines):');
      for (const line of stderrTail) console.error(`  ${line}`);
    }
    await shutdown(child);
    rmSync(patch.directory, {recursive: true, force: true});
    return 1;
  }
}

let options;
try {
  options = parseArgs(process.argv.slice(2));
} catch (error) {
  usageError(error);
}
if (options.help) {
  console.log(usage);
  process.exit(0);
}
process.exitCode = 1;
run(options)
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error) => {
    console.error(`smoke failed: ${error.message}`);
    process.exitCode = 1;
  });

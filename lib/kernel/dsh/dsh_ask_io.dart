import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart' show writeFileAtomically;
import 'dsh_ask.dart';
import 'dsh_locate.dart';
import 'dsh_notices.dart' show DshCredentials;
import 'dsh_patch.dart';
import 'dsh_path_setting.dart';
import 'dsh_transport.dart' show DshLaunch;
import 'dsh_transport_io.dart' show DshRedact;

/// What a failed search for dsh says: the install it names.
const _missing =
    'DSH is not installed: run `npm i -g @deepseek-ai/dsh`, then try again.';

/// Where dsh is looked for, to say where it is not.
const _where =
    'The path can be set in Settings → General → DSH, or dsh put on the PATH.';

/// The last lines dsh printed on stderr, to say why it gave no answer.
const _stderrLines = 30;

/// How many questions have been asked this run: each in a folder of its own,
/// so that two at once cannot clean up after one another.
int _asked = 0;

/// Asks the dsh on this machine one question, in one run of its `headless`
/// profile (see `dsh_ask.dart`): the answer it printed last, or why it gave
/// none.
///
/// It runs where dsh's own files are not touched: its own folder under the
/// system's temporary one, which dsh is given as its working directory and as
/// where its sessions for the answer go (`DshPatch.askContent`). The folder is
/// removed once the process is gone — with the session, so nothing of the
/// question is left in `~/.dsh` or anywhere else.
///
/// The run is `read-only`: a question is answered, nothing is written, and
/// what would need approval is refused, there being no one to ask.
Future<String> askDsh(
  String system,
  String prompt, {
  Future<void>? cancel,
  DshInstall? install,
  DshAskCredentials? credentials,
  Duration timeout = dshAskTimeout,
}) async {
  final environment = await ClaudeEnvironment.of();
  final DshInstall? dsh;
  try {
    dsh =
        install ??
        await locateDsh(
          setting: DshPathSetting.current(),
          environment: environment,
        );
  } on Object catch (error) {
    throw DshAskException('DSH could not be found', detail: '$error');
  }
  if (dsh == null) {
    throw const DshAskException(_missing, detail: _where);
  }
  await _checkCredential(credentials, environment);
  final run = Directory(
    p.join(Directory.systemTemp.path, 'baocode-dsh-ask-$pid-${_asked++}'),
  );
  try {
    await run.create(recursive: true);
    final patch = File(p.join(run.path, DshPatch.askFileName));
    await writeFileAtomically(
      patch,
      DshPatch.askContent(
        version: dsh.version,
        sessionRoot: p.join(run.path, 'sessions'),
      ),
    );
    final Process process;
    try {
      process = await Process.start(
        dsh.node,
        [dsh.binJs, ...dshAskArguments(patch.path)],
        workingDirectory: run.path,
        environment: {
          ...Platform.environment,
          ...environment,
          DshLaunch.permissionModeVariable: 'read-only',
        },
        // The parent environment beside the app's own on Windows, for what
        // `cmd.exe` itself runs on, as the ACP profile's is started.
        includeParentEnvironment: Platform.isWindows,
        // `node <bin.js>`, never the npm shim: a `.cmd` only a shell can run.
        runInShell: false,
      );
    } on ProcessException catch (error) {
      throw DshAskException(
        'DSH could not start',
        detail: '${dsh.node}\n${error.message}',
      );
    }
    var cancelled = false;
    final stopping = cancel?.then((_) {
      cancelled = true;
      unawaited(_kill(process));
    });
    // What it printed, read to the end as it goes.
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final noise = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      process.stdin.write('${_task(system, prompt)}\n');
    } on StateError {
      // Closed under us: the exit that follows says why.
    }
    unawaited(process.stdin.close().catchError((Object _) {}));
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        unawaited(_kill(process));
        throw DshAskException(
          'dsh did not answer within ${timeout.inMinutes} minutes.',
        );
      },
    );
    unawaited(stopping);
    final answer = await output;
    if (cancelled) throw const DshAskCancelled();
    return dshAskAnswer(answer, _tail(await noise), code);
  } finally {
    try {
      await run.delete(recursive: true);
    } on FileSystemException {
      // Left in the system's temporary folder: nothing of it is in `~/.dsh`.
    }
  }
}

/// [system] and [prompt] as the task dsh reads on stdin: the system's words
/// first, when there are any, then the question.
String _task(String system, String prompt) {
  final words = system.trim();
  return words.isEmpty ? prompt : '$words\n\n$prompt';
}

/// The last [_stderrLines] of [stderr], with what a credential would be by,
/// taken out (`DshRedact`), so that it can be shown as why dsh failed.
String _tail(String stderr) {
  final lines = [
    for (final line in const LineSplitter().convert(stderr))
      if (line.trim().isNotEmpty) DshRedact.line(line),
  ];
  final kept = lines.length > _stderrLines
      ? lines.sublist(lines.length - _stderrLines)
      : lines;
  return kept.join('\n');
}

/// Says so when dsh's route has no key for the ref it reads (F24): every
/// question would fail over it, and a word about the key is worth more than
/// dsh's own refusal to answer.
///
/// The refs are the given ones where a test gave them, and this machine's own
/// otherwise — its store's key names, never a value. A check that cannot be
/// made is not dsh that cannot answer: dsh says so itself.
Future<void> _checkCredential(
  DshAskCredentials? credentials,
  Map<String, String> environment,
) async {
  final Set<String> refs;
  try {
    refs =
        await (credentials ?? DshCredentials.refs(environment: environment))();
  } on Object {
    return;
  }
  if (refs.contains(DshPatch.credentialRef)) return;
  throw const DshAskException(
    'dsh has no credential for ${DshPatch.credentialRef}; add it in dsh web '
    '(Models), or set the environment variable.',
  );
}

/// Ends [process] and what it started: `taskkill` on Windows, which knows a
/// tree of grandchildren, the process itself elsewhere.
Future<void> _kill(Process process) async {
  if (Platform.isWindows) {
    try {
      await Process.run('taskkill', ['/pid', '${process.pid}', '/T', '/F']);
      return;
    } on ProcessException {
      // Falls back to the process itself.
    }
  }
  process.kill();
}

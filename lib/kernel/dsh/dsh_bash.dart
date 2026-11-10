import 'dart:io';

import 'package:path/path.dart' as p;

/// The Git for Windows bash to run dsh's shell commands with, where one is
/// installed; null when none is.
///
/// dsh on Windows serves its shell commands with PowerShell unless the
/// `dsh-gitbash-shell` plugin is installed for the ACP profile. That plugin
/// resolves the bash itself (its own bundle patch, F28); what this answers is
/// only whether there is a Git Bash to serve, which turns the `bash` tool on in
/// the patch `dsh_patch.dart` writes — found here, before dsh is started.
///
/// The first of these that is there is the one:
///
/// 1. `BAOCODE_GIT_BASH`, an absolute path given for the purpose;
/// 2. the `bash.exe` on the login shell's PATH, but not Windows' own: the one
///    in `System32` (or its `WindowsApps` alias) is a WSL Linux shell, and dsh
///    running it would read every path as a Linux one;
/// 3. the one of the Git that `git --exec-path` belongs to
///    (`<Git>/bin/bash.exe`), where that PATH has a git at all;
/// 4. a Git in either Program Files.
///
/// POSIX needs none of it — bash is the shell itself — so null comes back.
///
/// [environment] is the login shell's where it is given, else this machine's;
/// [exists] says whether a candidate path is there, and [gitExecPath] answers
/// what git prints for `--exec-path` — asked only where that PATH names a git.
/// A test gives its own for both, rather than reading the machine or running
/// git. [windows] is [Platform.isWindows] where it is not given, so that a test
/// can ask for the other platform.
Future<String?> findGitBash({
  Map<String, String>? environment,
  bool Function(String path)? exists,
  Future<String?> Function(Map<String, String> environment)? gitExecPath,
  bool? windows,
}) async {
  if (!(windows ?? Platform.isWindows)) return null;
  final env = environment ?? Platform.environment;
  final there = exists ?? (path) => File(path).existsSync();
  final named = env['BAOCODE_GIT_BASH']?.trim() ?? '';
  if (named.isNotEmpty && there(named)) return p.normalize(named);
  for (final dir in _pathDirectories(env)) {
    final onPath = p.normalize(p.join(dir, 'bash.exe'));
    if (_isWslBash(onPath) || !there(onPath)) continue;
    return onPath;
  }
  // A git is asked about only where that PATH has one: git in no folder of it
  // is not one `--exec-path` could answer for, and asking is a process of its
  // own — one a caller that cannot wait on a process, a widget test on its own
  // fake clock, would wait on for ever. No answer is fine: finding a bash is
  // best effort, and null is a dsh that keeps its own shell.
  final execPath = !_namesGit(env, there)
      ? null
      : await (gitExecPath ?? _gitExecPath)(env);
  if (execPath != null && execPath.trim().isNotEmpty) {
    final beside = _bashAboveGit(execPath.trim(), there);
    if (beside != null) return beside;
  }
  for (final path in const [
    'C:/Program Files/Git/bin/bash.exe',
    'C:/Program Files (x86)/Git/bin/bash.exe',
  ]) {
    final installed = p.normalize(path);
    if (there(installed)) return installed;
  }
  return null;
}

/// The folders the PATH of [environment] searches, in order: Windows allows
/// quotes around an entry with a space in it.
List<String> _pathDirectories(Map<String, String> environment) {
  final path = environment['PATH'] ?? environment['Path'] ?? '';
  return [
    for (final dir in path.split(';'))
      if (dir.trim().isNotEmpty) _unquoted(dir.trim()),
  ];
}

/// [dir] without the quotes Windows allows around a PATH entry.
String _unquoted(String dir) =>
    dir.length > 1 && dir.startsWith('"') && dir.endsWith('"')
    ? dir.substring(1, dir.length - 1)
    : dir;

/// Whether [path] is a bash Windows itself ships rather than Git for
/// Windows': `C:\Windows\System32\bash.exe` is `bash` on Windows 10, a
/// WSL distribution's Linux shell, and `…\WindowsApps\bash.exe` is its
/// alias in the Microsoft Store's folder.
///
/// dsh's shell tool would hand either of them a Windows path, and its Linux
/// side reads it as a Linux one (`/c/...` is not `C:\...`): the next
/// candidate is looked for instead.
bool _isWslBash(String path) {
  final parts = p.split(p.normalize(path));
  if (parts.length < 2) return false;
  return switch (parts[parts.length - 2].toLowerCase()) {
    'system32' || 'windowsapps' => true,
    _ => false,
  };
}

/// Whether [environment]'s PATH has a git in it: one of the folders it lists
/// with `git.exe` or `git.cmd` in it, the names Windows resolves `git` to.
bool _namesGit(Map<String, String> environment, bool Function(String) exists) {
  for (final dir in _pathDirectories(environment)) {
    for (final name in const ['git.exe', 'git.cmd']) {
      if (exists(p.normalize(p.join(dir, name)))) return true;
    }
  }
  return false;
}

/// The `bin/bash.exe` of the Git that [execPath] belongs to; null when none
/// above it says yes.
///
/// `git --exec-path` prints a folder inside the install
/// (`…/Git/mingw64/libexec/git-core`), so each folder above it is tried until
/// one has a `bin/bash.exe`: that one is the Git root.
String? _bashAboveGit(String execPath, bool Function(String path) exists) {
  var dir = execPath;
  while (dir.isNotEmpty) {
    final bash = p.normalize(p.join(dir, 'bin', 'bash.exe'));
    if (exists(bash)) return bash;
    final above = p.dirname(dir);
    if (above == dir) return null;
    dir = above;
  }
  return null;
}

/// What `git --exec-path` prints when git is run with [environment]; null when
/// git is not there, or answers nothing.
///
/// Only [findGitBash] calls it, and only where that PATH names a git: it is the
/// one place a process is started, and a widget test's fake clock never lets
/// `Process.run` finish — the reason the guard sits at that call site rather
/// than here alone.
Future<String?> _gitExecPath(Map<String, String> environment) async {
  try {
    final result = await Process.run('git', const [
      '--exec-path',
    ], environment: environment);
    if (result.exitCode != 0) return null;
    final path = '${result.stdout}'.trim();
    return path.isEmpty ? null : path;
  } on Object {
    // Not installed, or not runnable: the Git in Program Files is looked for.
    return null;
  }
}

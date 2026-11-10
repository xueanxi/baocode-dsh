import 'dart:io';

import 'package:bao_remote/local.dart' show AppPaths, ClaudeEnvironment;
import 'package:path/path.dart' as p;

import 'dsh_locate.dart';

/// dsh found on this machine, the way npm leaves one: the `|` form in
/// Settings first, then the shim the PATH has, then npm's own global folder.
///
/// [environment] is the user's shell's where it is not given (an app opened
/// from the Finder gets a bare PATH), so that nvm's Node and a
/// `~/.npm-global` are found as the user's terminal finds them.
Future<DshInstall?> locateDsh({
  String? setting,
  Map<String, String>? environment,
}) async {
  final env = environment ?? await ClaudeEnvironment.of();
  final dirs = _pathDirectories(env);
  final named = setting?.trim() ?? '';
  if (named.isNotEmpty) {
    final parts = DshLocate.splitSetting(named);
    if (parts == null) return null;
    final node = parts.node != null
        ? _namedNode(_homeExpanded(parts.node!, env), dirs)
        : _onPath(dirs, 'node');
    return _install(node, _homeExpanded(parts.binJs, env));
  }
  // What npm wrote as the `dsh` command first: its text says where the
  // package is, which also covers an install the PATH does not bind.
  for (final dir in dirs) {
    final binJs = await _shimBinJs(dir);
    if (binJs == null) continue;
    final install = await _install(
      _onPath(dirs, 'node') ?? _nodeBeside(binJs),
      binJs,
    );
    if (install != null) return install;
  }
  for (final binJs in _packageBinJs(env, dirs)) {
    final install = await _install(
      _onPath(dirs, 'node') ?? _nodeBeside(binJs),
      binJs,
    );
    if (install != null) return install;
  }
  return null;
}

/// [path] with a leading `~` spelled out from the home of [environment] — the
/// login shell's, which is the environment dsh is started with.
///
/// Only a path that *starts* at the home is a home: `~/lib/bin.js`, or `~`
/// alone, and `~\lib\bin.js` where Windows' separator was used. A `~` any
/// other place, or after another character (`~user/x`), is part of a name and
/// is left as it is.
String _homeExpanded(String path, Map<String, String> environment) {
  final atHome = path == '~' || path.startsWith('~/') || path.startsWith(r'~\');
  if (!atHome) return path;
  final home = AppPaths.home(environment);
  if (home.isEmpty) return path;
  // Spelled out with this platform's separators, whatever the setting used:
  // it is a path dsh is started by.
  return p.normalize(path == '~' ? home : p.join(home, path.substring(2)));
}

/// [install] where [node] runs [binJs], and both are there; null when one
/// is not (a stale setting, a shim of an uninstalled package).
Future<DshInstall?> _install(String? node, String binJs) async {
  if (node == null) return null;
  if (!await File(binJs).exists()) return null;
  final packageDir = p.dirname(p.dirname(binJs));
  return DshInstall(
    node: node,
    binJs: binJs,
    version: await _versionOf(packageDir),
    packageDir: packageDir,
  );
}

/// The `version` of the dsh package in [packageDir]; `unknown` when its
/// `package.json` is missing or unreadable (F3: the ACP bridge reports
/// another version, so none blocks the run).
Future<String> _versionOf(String packageDir) async {
  try {
    final text = await File(p.join(packageDir, 'package.json')).readAsString();
    return DshLocate.versionIn(text);
  } on FileSystemException {
    return 'unknown';
  }
}

/// The folders the PATH of [environment] searches, in order.
List<String> _pathDirectories(Map<String, String> environment) {
  final path = environment['PATH'] ?? environment['Path'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  return [
    for (final dir in path.split(separator))
      if (dir.trim().isNotEmpty) _unquoted(dir.trim()),
  ];
}

/// [dir] without the quotes Windows allows around a PATH entry with a space
/// in it.
String _unquoted(String dir) =>
    dir.length > 1 && dir.startsWith('"') && dir.endsWith('"')
    ? dir.substring(1, dir.length - 1)
    : dir;

/// The `node` a setting names, or the one of that name on the PATH.
String? _namedNode(String name, List<String> dirs) {
  if (p.isAbsolute(name) || name.contains('/') || name.contains(r'\')) {
    return File(name).existsSync() ? name : null;
  }
  return _onPath(dirs, name);
}

/// The executable called [name] in the first of [dirs] that has it.
String? _onPath(List<String> dirs, String name) {
  for (final dir in dirs) {
    for (final candidate in Platform.isWindows ? ['$name.exe', name] : [name]) {
      final path = p.join(dir, candidate);
      if (File(path).existsSync()) return path;
    }
  }
  return null;
}

/// The `node` npm keeps beside the packages of its global folder, where a
/// PATH does not have one.
String? _nodeBeside(String binJs) {
  // <modules>/@deepseek-ai/dsh/lib/bin.js
  final modules = p.dirname(p.dirname(p.dirname(p.dirname(binJs))));
  for (final name in Platform.isWindows ? ['node.exe', 'node'] : ['node']) {
    final path = p.join(modules, '.bin', name);
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// The `bin.js` the npm shim of [dir] runs; null when there is no shim
/// there, or it runs another program.
Future<String?> _shimBinJs(String dir) async {
  for (final name in const ['dsh', 'dsh.cmd', 'dsh.ps1']) {
    try {
      final text = await File(p.join(dir, name)).readAsString();
      final binJs = DshLocate.binJsFromShim(text, dir);
      if (binJs != null && await File(binJs).exists()) return binJs;
    } on FileSystemException {
      // Not this one: another names it, or the package sits beside it.
    }
  }
  return null;
}

/// Where npm's global dsh may be, no PATH entry needed: Windows keeps it in
/// the `npm` folder of `%APPDATA%` (and beside the PATH's own `dsh.cmd`);
/// POSIX keeps packages under `<prefix>/lib/node_modules`, the `bin` beside
/// them being what the PATH names.
Iterable<String> _packageBinJs(
  Map<String, String> environment,
  List<String> dirs,
) sync* {
  final packagePath = p.join('@deepseek-ai', 'dsh', 'lib', 'bin.js');
  if (Platform.isWindows) {
    for (final dir in dirs) {
      yield p.join(dir, 'node_modules', packagePath);
    }
    final appData = environment['APPDATA']?.trim() ?? '';
    if (appData.isNotEmpty) {
      yield p.join(appData, 'npm', 'node_modules', packagePath);
    }
    return;
  }
  for (final prefix in _posixPrefixes(environment, dirs)) {
    yield p.join(prefix, 'lib', 'node_modules', packagePath);
  }
}

/// The npm global prefixes on POSIX: the folder above a PATH `bin` that
/// holds `node` or `dsh`, `/usr/local`, `~/.npm-global`, and every Node of
/// `~/.nvm`.
Iterable<String> _posixPrefixes(
  Map<String, String> environment,
  List<String> dirs,
) sync* {
  for (final dir in dirs) {
    if (p.basename(dir) != 'bin') continue;
    if (!_hasNodeOrDsh(dir)) continue;
    yield p.dirname(dir);
  }
  yield '/usr/local';
  final home = AppPaths.home(environment);
  if (home.isEmpty) return;
  yield p.join(home, '.npm-global');
  try {
    for (final entity in Directory(
      p.join(home, '.nvm', 'versions', 'node'),
    ).listSync(followLinks: false)) {
      if (entity is Directory) yield entity.path;
    }
  } on FileSystemException {
    // No nvm here: nothing under it to look in.
  }
}

/// Whether [dir] holds the `node` or `dsh` a POSIX PATH entry names.
bool _hasNodeOrDsh(String dir) =>
    File(p.join(dir, 'node')).existsSync() ||
    File(p.join(dir, 'dsh')).existsSync();

import 'dart:convert';

import 'package:path/path.dart' as p;

import 'dsh_locate_stub.dart'
    if (dart.library.io) 'dsh_locate_io.dart'
    as platform;

/// A dsh on this machine: the `node` that runs it, the `lib/bin.js` it
/// runs, and the version of the package holding them.
class DshInstall {
  const DshInstall({
    required this.node,
    required this.binJs,
    required this.version,
    required this.packageDir,
  });

  /// The `node` executable [binJs] is run with.
  final String node;

  /// `<dsh>/lib/bin.js`, run rather than the npm shim: a `.cmd` cannot be
  /// started without a shell, and with one there is a shell in between
  /// (F20).
  final String binJs;

  /// The `version` in `<dsh>/package.json`, or `unknown` when it cannot be
  /// read. It is dsh's own version: the ACP bridge reports another (F3).
  final String version;

  /// The package folder [binJs] and `package.json` belong to.
  final String packageDir;
}

/// The dsh to run on this machine: the one [setting] names, else the one an
/// npm shim on the PATH runs, else the package beside a PATH folder; null
/// when there is none.
///
/// A [setting] starting at `~` is read from [environment]'s home, as the shell
/// would read it: the folder is typed by hand, and a hand types the home.
Future<DshInstall?> locateDsh({
  String? setting,
  Map<String, String>? environment,
}) => platform.locateDsh(setting: setting, environment: environment);

/// What [locateDsh] reads, apart from the files it finds: how a setting and
/// an npm shim are written (F20).
abstract final class DshLocate {
  /// [setting] apart: the `bin.js` it names, and the `node` to run it with
  /// where it names one as well (`node|bin.js`, both trimmed); null when it
  /// names neither.
  static ({String? node, String binJs})? splitSetting(String setting) {
    final parts = setting.split('|');
    if (parts.length > 2) return null;
    final binJs = parts.last.trim();
    if (binJs.isEmpty) return null;
    if (parts.length == 1) return (node: null, binJs: binJs);
    final node = parts.first.trim();
    if (node.isEmpty) return null;
    return (node: node, binJs: binJs);
  }

  /// The `…/node_modules/@deepseek-ai/dsh/lib/bin.js` a shim's [text] runs,
  /// resolved from the folder [dir] the shim is in (what `%dp0%` stands for
  /// in a `.cmd`, `$basedir` in a shell's); null when it runs another
  /// program.
  static String? binJsFromShim(String text, String dir) {
    for (final raw in text.split(RegExp(r'\s+'))) {
      final token = raw.replaceAll('"', '').replaceAll("'", '');
      if (!token.contains('bin.js')) continue;
      var path = token
          .replaceAll(r'\', '/')
          .replaceAll(RegExp(r'%dp0%', caseSensitive: false), dir)
          .replaceAll(RegExp(r'\$\{?basedir\}?'), dir);
      if (!path.endsWith(_packageBinJs)) continue;
      if (!p.isAbsolute(path)) path = p.join(dir, path);
      return p.normalize(path);
    }
    return null;
  }

  /// Where the `bin.js` of the package dsh is installed as sits.
  static const _packageBinJs = 'node_modules/@deepseek-ai/dsh/lib/bin.js';

  /// The `version` a `package.json` [text] gives; `unknown` when it gives
  /// none (or is not JSON at all).
  static String versionIn(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final version = decoded['version'];
        if (version is String && version.trim().isNotEmpty) {
          return version.trim();
        }
      }
    } on FormatException {
      // Not JSON (or cut short): no version to read.
    }
    return 'unknown';
  }
}

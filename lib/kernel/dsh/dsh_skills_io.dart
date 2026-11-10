import 'dart:io';

import 'package:path/path.dart' as p;

/// This machine's environment, as dsh would be started with it (the app's
/// own; a test passes its own instead).
Map<String, String> dshEnvironment() => Platform.environment;

/// Where the project [cwd] is: the nearest ancestor holding `.git`, as dsh
/// resolves the project's skill roots; [cwd] itself where there is none.
String dshProjectRoot(String cwd) {
  final start = p.normalize(p.absolute(cwd));
  var current = start;
  while (true) {
    final type = FileSystemEntity.typeSync(
      p.join(current, '.git'),
      followLinks: true,
    );
    if (type != FileSystemEntityType.notFound) return current;
    final parent = p.dirname(current);
    if (parent == current) return start;
    current = parent;
  }
}

/// The skill files under [root], their text as written: a folder's
/// `SKILL.md`, or a flat `<name>.md`.
Future<List<({String path, String text})>> dshSkillFiles(
  String root, {
  required bool skipSystem,
}) async {
  final directory = Directory(root);
  final List<FileSystemEntity> entries;
  try {
    entries = await directory.list(followLinks: true).toList();
  } on FileSystemException {
    // No root yet: no skills from it, not a failure of the others.
    return const [];
  }
  final files = <({String path, String text})>[];
  for (final entry in entries) {
    final name = p.basename(entry.path);
    if (skipSystem && name == '.system') continue;
    final String? path;
    if (entry is Directory) {
      path = p.join(entry.path, 'SKILL.md');
    } else if (entry is File && name.endsWith('.md')) {
      path = entry.path;
    } else {
      continue;
    }
    try {
      files.add((path: path, text: await File(path).readAsString()));
    } on FileSystemException {
      // Gone between the listing and the read, or no SKILL.md in it.
    } on FormatException {
      // Not UTF-8: dsh skips it too.
    }
  }
  return files;
}

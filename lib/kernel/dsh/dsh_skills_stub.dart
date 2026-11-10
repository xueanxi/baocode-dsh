/// The browser has no filesystem and no dsh: no skills are read there.
Map<String, String> dshEnvironment() => const {};

/// Without files, a project is only what it was named.
String dshProjectRoot(String cwd) => cwd;

/// No files to read.
Future<List<({String path, String text})>> dshSkillFiles(
  String root, {
  required bool skipSystem,
}) async => const [];

import 'package:bao_remote/local.dart' show AppPaths;
import 'package:path/path.dart' as p;

import 'dsh_skills_stub.dart'
    if (dart.library.io) 'dsh_skills_io.dart'
    as platform;

/// A skill dsh would load for `/name`: what the composer lists, and the file
/// it opens (the skill's `SKILL.md`).
typedef DshSkill = ({String name, String description, String path});

/// The skills dsh itself would offer under `/` in [cwd].
///
/// ACP has no command surface (see `docs/spec/dsh-kernel.md`, F30): dsh never
/// tells a client which skills it has, and the `/name` a message carries is
/// loaded on dsh's side from the files dsh would scan anyway. This reads the
/// same roots, in the same rank order, so the menu offers what dsh would
/// load — and nothing it would not.
///
/// Only the default roots are read: the project's (`.dsh/skills`,
/// `.agents/skills`), the user's (`$DSH_HOME/skills`, `$DSH_AGENTS_HOME/skills`,
/// else `~/.dsh/skills` and `~/.agents/skills`), and `$DSH_BUNDLED_SKILL_DIR`
/// where that names one. A `customSkillDirs` in the user's own profile patch
/// is not read: that would be dsh's composed config, not a file format of
/// ours.
abstract final class DshSkills {
  /// The skills for [cwd], by name, first in dsh's rank order winning a
  /// duplicate, and none of a project's or a user's when neither is there.
  static Future<List<DshSkill>> discover({
    required String cwd,
    Map<String, String>? environment,
  }) async {
    final env = environment ?? platform.dshEnvironment();
    final project = platform.dshProjectRoot(cwd);
    final skills = <String, DshSkill>{};
    for (final root in _roots(project, env)) {
      final files = [
        ...await platform.dshSkillFiles(root.path, skipSystem: root.skipSystem),
      ];
      // dsh reads a root's entries by name; a folder and a flat file of one
      // name are then told apart the same way.
      files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final file in files) {
        final skill = parse(file.text, path: file.path);
        if (skill != null) skills.putIfAbsent(skill.name, () => skill);
      }
    }
    return skills.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// The folder dsh keeps its own files in: `$DSH_HOME`, else `~/.dsh`; null
  /// where [environment] names no home.
  static String? home(Map<String, String> environment) {
    final named = environment['DSH_HOME']?.trim() ?? '';
    if (named.isNotEmpty) return named;
    final home = AppPaths.home(environment);
    return home.isEmpty ? null : p.join(home, '.dsh');
  }

  /// The user's skills: [home]'s `skills`; null where there is no home.
  static String? userSkillsRoot(Map<String, String> environment) =>
      switch (home(environment)) {
        final home? => p.join(home, 'skills'),
        null => null,
      };

  /// A project's skills: its nearest ancestor with `.git`'s `.dsh/skills`,
  /// as dsh resolves the project's skill roots; [cwd]'s where there is none.
  static String projectSkillsRoot(String cwd) =>
      p.join(platform.dshProjectRoot(cwd), '.dsh', 'skills');

  /// The default roots, lowest rank first (dsh's own order), each with
  /// whether its `.system` child is skipped.
  static List<({String path, bool skipSystem})> _roots(
    String project,
    Map<String, String> environment,
  ) {
    final home = AppPaths.home(environment);
    String named(String name, String fallback) {
      final value = environment[name]?.trim() ?? '';
      return value.isNotEmpty ? value : fallback;
    }

    final dshHome = DshSkills.home(environment);
    final agentsHome = named(
      'DSH_AGENTS_HOME',
      home.isEmpty ? '' : p.join(home, '.agents'),
    );
    final bundled = environment['DSH_BUNDLED_SKILL_DIR']?.trim() ?? '';
    return [
      (path: p.join(project, '.dsh', 'skills'), skipSystem: false),
      (path: p.join(project, '.agents', 'skills'), skipSystem: false),
      if (dshHome != null) (path: p.join(dshHome, 'skills'), skipSystem: true),
      if (agentsHome.isNotEmpty)
        (path: p.join(agentsHome, 'skills'), skipSystem: false),
      if (bundled.isNotEmpty) (path: bundled, skipSystem: false),
    ];
  }

  /// The skill [text] holds, of the file at [path]; null for one dsh would
  /// ignore (no frontmatter, a key it rejects, an invalid name, or a
  /// `user-invocable: false` that keeps it out of human-facing menus).
  static DshSkill? parse(String text, {required String path}) {
    final lines = [
      for (final line in text.split('\n'))
        line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    ];
    if (lines.isEmpty || lines.first.trim() != '---') return null;
    var end = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        end = i;
        break;
      }
    }
    if (end < 0) return null;
    final fields = _frontmatter(lines.sublist(1, end));
    // Keys dsh rejects outright, rather than reading as a default.
    if (fields.containsKey('disableModelInvocation') ||
        fields.containsKey('modelInvocable') ||
        fields.containsKey('userInvocable')) {
      return null;
    }
    final name = fields['name'] ?? '';
    final description = fields['description'] ?? '';
    if (name.isEmpty || description.isEmpty) return null;
    if (!_name.hasMatch(name)) return null;
    final bool? userInvocable;
    try {
      userInvocable = _boolean(fields['user-invocable']);
      _boolean(fields['disable-model-invocation']);
    } on FormatException {
      return null;
    }
    if (userInvocable == false) return null;
    return (name: name, description: description, path: path);
  }

  static final _name = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

  /// The top-level `key: value` pairs of [lines], with a block scalar folded
  /// or kept as lines. Nested mappings are not read: no key this reads is
  /// one.
  static Map<String, String> _frontmatter(List<String> lines) {
    final fields = <String, String>{};
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isEmpty ||
          line.startsWith(' ') ||
          line.startsWith('\t')) {
        i++;
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) {
        i++;
        continue;
      }
      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      i++;
      if (value.isEmpty) {
        final block = _indented(lines, i);
        i = block.next;
        if (block.lines.isNotEmpty) fields[key] = block.lines.join('\n').trim();
        continue;
      }
      if (_blockMark.hasMatch(value)) {
        final block = _indented(lines, i);
        i = block.next;
        fields[key] = value.startsWith('>')
            ? _fold(block.lines)
            : block.lines.join('\n').trim();
        continue;
      }
      fields[key] = _scalar(value);
    }
    return fields;
  }

  /// The `|`/`>` of a block scalar, with its chomping and indentation
  /// indicators.
  static final _blockMark = RegExp(r'^[|>][+-]?[0-9]?$');

  /// The indented [lines] from [start], each without their common
  /// indentation, and where the block after them starts.
  static ({List<String> lines, int next}) _indented(
    List<String> lines,
    int start,
  ) {
    final block = <String>[];
    var i = start;
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isNotEmpty &&
          !line.startsWith(' ') &&
          !line.startsWith('\t')) {
        break;
      }
      block.add(line);
      i++;
    }
    while (block.isNotEmpty && block.last.trim().isEmpty) {
      block.removeLast();
    }
    var indent = -1;
    for (final line in block) {
      if (line.trim().isEmpty) continue;
      final leading = line.length - line.trimLeft().length;
      if (indent < 0 || leading < indent) indent = leading;
    }
    if (indent <= 0) return (lines: block, next: i);
    return (
      lines: [
        for (final line in block)
          line.length <= indent ? line.trim() : line.substring(indent),
      ],
      next: i,
    );
  }

  /// [lines] as a folded scalar: one line, its line breaks becoming spaces,
  /// a blank line kept as a break.
  static String _fold(List<String> lines) {
    final text = StringBuffer();
    var blank = false;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        blank = true;
        continue;
      }
      if (text.isNotEmpty) text.write(blank ? '\n' : ' ');
      text.write(trimmed);
      blank = false;
    }
    return text.toString();
  }

  /// A YAML scalar: a quoted string, or a plain one (its comment trimmed
  /// where a space starts one).
  static String _scalar(String value) {
    if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
      return value.substring(1, value.length - 1).replaceAll("''", "'");
    }
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return _doubleQuoted(value.substring(1, value.length - 1));
    }
    final comment = value.indexOf(' #');
    return comment < 0 ? value : value.substring(0, comment).trimRight();
  }

  static String _doubleQuoted(String value) {
    final text = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (char != r'\' || i + 1 == value.length) {
        text.write(char);
        continue;
      }
      final next = value[++i];
      text.write(switch (next) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        _ => next,
      });
    }
    return text.toString();
  }

  /// dsh's strict boolean: null where the key is absent, a throw where it is
  /// there but not a boolean.
  static bool? _boolean(String? value) {
    if (value == null) return null;
    return switch (value.toLowerCase()) {
      'true' || 'yes' || 'on' || '1' => true,
      'false' || 'no' || 'off' || '0' => false,
      _ => throw const FormatException('not a boolean'),
    };
  }
}

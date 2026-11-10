// The skills dsh would load for `/name` (#DSH): read from the files dsh
// scans, since ACP names no commands.

import 'dart:io';

import 'package:baocode/kernel/dsh/dsh_skills.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void _write(String path, String text) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

String _skill(String name, String description, {String extra = ''}) =>
    '---\n'
    'name: $name\n'
    'description: $description\n'
    '$extra'
    '---\n'
    'The body.\n';

Map<String, String> _environment(String home, {String? dshHome}) => {
  'HOME': home,
  'USERPROFILE': home,
  'DSH_HOME': ?dshHome,
};

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('dsh_skills'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('a skill file', () {
    test('is one when its frontmatter names it and says what it is for', () {
      final skill = DshSkills.parse(
        '---\n'
        'name: code-review\n'
        'description: "Review the changes since a fixed point."\n'
        '---\n',
        path: '/skills/code-review/SKILL.md',
      );
      expect(skill, (
        name: 'code-review',
        description: 'Review the changes since a fixed point.',
        path: '/skills/code-review/SKILL.md',
      ));
    });

    test('keeps a folded description on one line', () {
      final skill = DshSkills.parse(
        '---\n'
        'name: tdd\n'
        'description: >-\n'
        '  Build features test-first.\n'
        '  Red, then green.\n'
        '---\n',
        path: '/skills/tdd/SKILL.md',
      );
      expect(skill?.description, 'Build features test-first. Red, then green.');
    });

    test('is not one dsh would ignore', () {
      String text(String frontmatter) => '---\n$frontmatter---\n';
      final cases = {
        'no frontmatter': 'Just a body.\n',
        'no description': text('name: tdd\n'),
        'not a kebab-case name': text(
          'name: TDD Work\n'
          'description: Test first.\n',
        ),
        'a user-only skill is still one': text(
          'name: grill-me\n'
          'description: Grill me.\n'
          'disable-model-invocation: true\n',
        ),
      };
      expect(DshSkills.parse(cases['no frontmatter']!, path: 'a'), isNull);
      expect(DshSkills.parse(cases['no description']!, path: 'a'), isNull);
      expect(
        DshSkills.parse(cases['not a kebab-case name']!, path: 'a'),
        isNull,
      );
      expect(
        DshSkills.parse(
          cases['a user-only skill is still one']!,
          path: 'a',
        )?.name,
        'grill-me',
      );
    });

    test('is dropped when dsh would drop it', () {
      for (final frontmatter in [
        'name: tdd\n'
            'description: Test first.\n'
            'user-invocable: false\n',
        'name: tdd\n'
            'description: Test first.\n'
            'user-invocable: maybe\n',
        'name: tdd\n'
            'description: Test first.\n'
            'userInvocable: true\n',
      ]) {
        expect(
          DshSkills.parse('---\n$frontmatter---\n', path: 'a'),
          isNull,
          reason: frontmatter,
        );
      }
    });
  });

  test('reads the user roots, in dsh rank order, by name', () async {
    final home = p.join(temp.path, 'home');
    final skills = p.join(home, '.dsh', 'skills');
    _write(
      p.join(skills, 'alpha', 'SKILL.md'),
      _skill('alpha', 'From the user.'),
    );
    _write(p.join(skills, 'beta.md'), _skill('beta', 'Flat.'));
    _write(
      p.join(skills, 'gamma', 'SKILL.md'),
      _skill('gamma', 'User only.', extra: 'user-invocable: false\n'),
    );
    _write(
      p.join(skills, '.system', 'SKILL.md'),
      _skill('system', 'Not offered.'),
    );
    // The shared root under ~/.agents is read too, after ~/.dsh.
    _write(
      p.join(home, '.agents', 'skills', 'delta', 'SKILL.md'),
      _skill('delta', 'Shared.'),
    );

    final found = await DshSkills.discover(
      cwd: p.join(temp.path, 'project'),
      environment: _environment(home),
    );
    expect([for (final skill in found) skill.name], ['alpha', 'beta', 'delta']);
    expect(found.first.description, 'From the user.');
    expect(found.first.path, p.join(skills, 'alpha', 'SKILL.md'));
  });

  test('a project root wins a name the user also has', () async {
    final home = p.join(temp.path, 'home');
    _write(
      p.join(home, '.dsh', 'skills', 'alpha', 'SKILL.md'),
      _skill('alpha', 'The user one.'),
    );
    final project = p.join(temp.path, 'project');
    Directory(p.join(project, '.git')).createSync(recursive: true);
    Directory(p.join(project, 'src')).createSync();
    _write(
      p.join(project, '.dsh', 'skills', 'alpha', 'SKILL.md'),
      _skill('alpha', 'The project one.'),
    );

    final found = await DshSkills.discover(
      // From below the project: the root is the nearest ancestor with .git.
      cwd: p.join(project, 'src'),
      environment: _environment(home),
    );
    expect(found.single.description, 'The project one.');
  });

  test('DSH_HOME names the root, not the home', () async {
    final home = p.join(temp.path, 'home');
    _write(
      p.join(home, '.dsh', 'skills', 'alpha', 'SKILL.md'),
      _skill('alpha', 'Where the user is not looking.'),
    );
    final elsewhere = p.join(temp.path, 'elsewhere');
    _write(
      p.join(elsewhere, 'skills', 'beta', 'SKILL.md'),
      _skill('beta', 'Where DSH_HOME points.'),
    );

    final found = await DshSkills.discover(
      cwd: p.join(temp.path, 'project'),
      environment: _environment(home, dshHome: elsewhere),
    );
    expect([for (final skill in found) skill.name], ['beta']);
  });

  test('a folder without a SKILL.md is not a skill', () async {
    final home = p.join(temp.path, 'home');
    Directory(p.join(home, '.dsh', 'skills', 'empty'))
        .createSync(recursive: true);
    final found = await DshSkills.discover(
      cwd: p.join(temp.path, 'project'),
      environment: _environment(home),
    );
    expect(found, isEmpty);
  });
}

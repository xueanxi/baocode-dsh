import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/files.dart' show IdeFileExistsException;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';

void main() {
  late Directory temp;
  late String config;
  late String project;
  late CustomizationStore store;

  void write(String path, String text) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('customize');
    config = p.join(temp.path, 'home', '.claude');
    project = p.join(temp.path, 'app');
    store = CustomizationStore(
      configDir: config,
      homeDir: p.join(temp.path, 'home'),
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('reads front matter, block scalars and quotes included', () {
    const text =
        '---\n'
        'name: "pdf"\n'
        'description: >-\n'
        '  Reads PDFs\n'
        '  and fills forms.\n'
        'tools: Read\n'
        '---\n'
        '\n'
        '# PDF\n';
    expect(parseFrontMatter(text), {
      'name': 'pdf',
      'description': 'Reads PDFs and fills forms.',
      'tools': 'Read',
    });
    expect(describeMarkdown('# Title\n\nFirst line.\n'), 'First line.');
    expect(bodyOf(text), '\n# PDF\n');
  });

  test('finds a /command\'s file: a skill\'s, a command\'s, a plugin\'s '
      '(#220)', () async {
    final skill = p.join(config, 'skills', 'pdf-tools', 'SKILL.md');
    write(skill, '---\nname: pdf\ndescription: Reads PDFs\n---\n');
    final command = p.join(project, '.claude', 'commands', 'ship.md');
    write(command, 'Ship it.\n');
    final root = p.join(config, 'plugins', 'cache', 'cf');
    final pluginSkill = p.join(root, 'skills', 'wrangler', 'SKILL.md');
    write(pluginSkill, '---\nname: wrangler\n---\n');
    write(
      p.join(config, 'plugins', 'installed_plugins.json'),
      jsonEncode({
        'version': 2,
        'plugins': {
          'cloudflare@market': [
            {'installPath': root},
          ],
        },
      }),
    );
    expect(await store.commandFile('pdf', project: project), skill);
    expect(await store.commandFile('pdf-tools', project: project), skill);
    expect(await store.commandFile('ship', project: project), command);
    expect(await store.commandFile('ship'), isNull);
    expect(await store.commandFile('cloudflare:wrangler'), pluginSkill);
    expect(await store.commandFile('cloudflare:nope'), isNull);
    expect(await store.commandFile('compact', project: project), isNull);
    // A folder's file is SKILL.md, not a name to match a command on.
    expect(await store.commandFile('SKILL', project: project), isNull);
  });

  test('lists the user\'s and the project\'s skills, agents, commands '
      'and rules', () async {
    write(
      p.join(config, 'skills', 'pdf', 'SKILL.md'),
      '---\nname: pdf\ndescription: Reads PDFs\n---\n',
    );
    write(p.join(config, 'skills', 'empty', 'notes.txt'), 'no SKILL.md');
    // Synced from claude.ai, under a bucket: shown, not edited.
    write(
      p.join(config, 'skills', 'synced', 'bucket-1', 'docx', 'SKILL.md'),
      '---\nname: docx\ndescription: Word files\n---\n',
    );
    write(
      p.join(config, 'skills', 'synced', '.bucket-1', 'stale', 'SKILL.md'),
      '---\nname: stale\n---\n',
    );
    write(
      p.join(project, '.claude', 'skills', 'deploy', 'SKILL.md'),
      '# Deploy\n\nShips it.\n',
    );
    write(
      p.join(config, 'agents', 'reviewer.md'),
      '---\nname: code-reviewer\ndescription: Reviews diffs\n---\n',
    );
    write(
      p.join(project, '.claude', 'commands', 'git', 'ship.md'),
      '---\ndescription: Commit and push\n---\n',
    );
    write(p.join(config, 'CLAUDE.md'), '# Me\n\nBe brief.\n');
    write(p.join(project, 'CLAUDE.md'), 'Use Dart.\n');
    write(p.join(project, '.claude', 'rules', 'tests.md'), 'Test it.\n');

    final skills = await store.list(CustomizationKind.skills, project: project);
    expect(
      [for (final s in skills) (s.scope, s.name, s.description)],
      [
        (CustomizationScope.user, 'pdf', 'Reads PDFs'),
        (CustomizationScope.synced, 'docx', 'Word files'),
        (CustomizationScope.project, 'deploy', 'Ships it.'),
      ],
    );
    expect(skills.first.removePath, p.join(config, 'skills', 'pdf'));
    expect(skills[1].editable, isFalse);
    expect(skills[1].removePath, isNull);

    final agents = await store.list(CustomizationKind.subagents);
    expect(agents.single.name, 'code-reviewer');

    final commands = await store.list(
      CustomizationKind.commands,
      project: project,
    );
    expect(commands.single.name, '/ship');
    expect(commands.single.description, 'Commit and push');

    final rules = await store.list(CustomizationKind.rules, project: project);
    expect(
      [for (final r in rules) (r.scope, r.name, r.removePath != null)],
      [
        (CustomizationScope.user, 'CLAUDE.md', false),
        (
          CustomizationScope.project,
          p.join('.claude', 'rules', 'tests.md'),
          true,
        ),
        (CustomizationScope.project, 'CLAUDE.md', false),
      ],
    );
  });

  test('lists servers, hooks and plugins from their JSON files', () async {
    write(
      p.join(temp.path, 'home', '.claude.json'),
      jsonEncode({
        'mcpServers': {
          'github': {'type': 'http', 'url': 'https://example.com/mcp'},
        },
        'claudeAiMcpEverConnected': ['claude.ai Docs'],
        'projects': {
          project: {
            'mcpServers': {
              'db': {
                'command': 'npx',
                'args': ['db-mcp', '--ro'],
              },
            },
          },
        },
      }),
    );
    write(
      p.join(project, '.mcp.json'),
      jsonEncode({
        'mcpServers': {
          'docs': {'command': 'docs-mcp'},
        },
      }),
    );
    write(
      p.join(config, 'settings.json'),
      jsonEncode({
        'hooks': {
          'PostToolUse': [
            {
              'matcher': 'Edit',
              'hooks': [
                {'type': 'command', 'command': 'dart format .'},
              ],
            },
          ],
        },
        'enabledPlugins': {'review@market': true},
      }),
    );
    final installRoot = p.join(config, 'plugins', 'cache', 'review');
    write(
      p.join(config, 'plugins', 'installed_plugins.json'),
      jsonEncode({
        'version': 2,
        'plugins': {
          'review@market': [
            {'scope': 'user', 'installPath': installRoot, 'version': '1.2.0'},
          ],
          'other@market': [
            {'scope': 'user', 'installPath': '/nowhere', 'version': '0.1.0'},
          ],
        },
      }),
    );
    write(
      p.join(installRoot, '.claude-plugin', 'plugin.json'),
      jsonEncode({'name': 'review', 'description': 'Reviews code'}),
    );

    final servers = await store.list(CustomizationKind.mcps, project: project);
    expect(
      [for (final s in servers) (s.scope, s.name, s.description, s.editable)],
      [
        (
          CustomizationScope.user,
          'github',
          'http · https://example.com/mcp',
          false,
        ),
        (CustomizationScope.synced, 'claude.ai Docs', 'claude.ai', false),
        (CustomizationScope.project, 'docs', 'docs-mcp', true),
        (CustomizationScope.local, 'db', 'npx db-mcp --ro', false),
      ],
    );
    expect(servers.first.detail, contains('"url"'));

    final hooks = await store.list(CustomizationKind.hooks);
    expect(hooks.single.name, 'PostToolUse · Edit');
    expect(hooks.single.description, 'dart format .');
    expect(hooks.single.path, p.join(config, 'settings.json'));

    final plugins = await store.list(CustomizationKind.plugins);
    expect(
      [for (final x in plugins) (x.name, x.description, x.enabled)],
      [('other', 'market · 0.1.0', false), ('review', 'Reviews code', true)],
    );
  });

  test('finds the file servers and hooks are kept in, by scope', () async {
    Future<String?> file(CustomizationKind kind, CustomizationScope scope) =>
        store.configFile(kind, scope, project: project);
    expect(
      await file(CustomizationKind.mcps, CustomizationScope.project),
      p.join(project, '.mcp.json'),
    );
    expect(await file(CustomizationKind.mcps, CustomizationScope.user), isNull);
    expect(
      await file(CustomizationKind.hooks, CustomizationScope.user),
      p.join(config, 'settings.json'),
    );
    expect(
      await file(CustomizationKind.hooks, CustomizationScope.local),
      p.join(project, '.claude', 'settings.local.json'),
    );
    expect(
      await store.configFile(
        CustomizationKind.hooks,
        CustomizationScope.project,
      ),
      isNull,
    );
    expect(
      await file(CustomizationKind.skills, CustomizationScope.user),
      isNull,
    );
  });

  test('lists none of each where there are none', () async {
    for (final kind in CustomizationKind.values) {
      expect(await store.list(kind, project: project), isEmpty);
    }
  });

  test('takes any name a file can have, Chinese included', () {
    for (final name in ['style', 'Release_notes-2', '代码风格', '发布v2', 'a' * 64]) {
      expect(isCustomizationName(name), isTrue, reason: name);
    }
    for (final name in [
      '',
      '../escape',
      'a/b',
      'a b',
      'what?',
      'a:b',
      '.hidden',
      '-dash',
      'ends.',
      'a' * 65,
    ]) {
      expect(isCustomizationName(name), isFalse, reason: name);
    }

    expect(
      followsOfficialNaming(CustomizationKind.skills, 'pdf-tools'),
      isTrue,
    );
    expect(followsOfficialNaming(CustomizationKind.skills, '代码风格'), isFalse);
    expect(
      followsOfficialNaming(CustomizationKind.subagents, 'Reviewer'),
      isFalse,
    );
    expect(followsOfficialNaming(CustomizationKind.rules, '代码风格'), isTrue);
    expect(followsOfficialNaming(CustomizationKind.commands, '发布'), isTrue);
  });

  test('makes new ones from templates, edits and deletes them', () async {
    final skill = await store.create(
      CustomizationKind.skills,
      CustomizationScope.user,
      'release-notes',
    );
    expect(skill, p.join(config, 'skills', 'release-notes', 'SKILL.md'));
    expect(parseFrontMatter(await store.read(skill))['name'], 'release-notes');
    await expectLater(
      store.create(
        CustomizationKind.skills,
        CustomizationScope.user,
        'release-notes',
      ),
      throwsA(isA<IdeFileExistsException>()),
    );
    expect(
      () => store.create(
        CustomizationKind.skills,
        CustomizationScope.user,
        '../escape',
      ),
      throwsArgumentError,
    );

    final rule = await store.create(
      CustomizationKind.rules,
      CustomizationScope.project,
      'style',
      project: project,
    );
    expect(rule, p.join(project, '.claude', 'rules', 'style.md'));

    final chinese = await store.create(
      CustomizationKind.commands,
      CustomizationScope.project,
      '发布说明',
      project: project,
    );
    expect(chinese, p.join(project, '.claude', 'commands', '发布说明.md'));
    expect(File(chinese).existsSync(), isTrue);

    await store.write(skill, '---\nname: notes\ndescription: Edited\n---\n');
    final listed = await store.list(CustomizationKind.skills);
    expect(listed.single.description, 'Edited');

    await store.delete(listed.single);
    expect(Directory(p.dirname(skill)).existsSync(), isFalse);
    expect(await store.list(CustomizationKind.skills), isEmpty);
  });

  group('dsh', () {
    late CustomizationStore dsh;
    late String home;

    setUp(() {
      home = p.join(temp.path, 'home');
      dsh = CustomizationStore(
        homeDir: home,
        agent: CustomizationAgent.dsh,
        environment: const {},
      );
    });

    test(
      'reads the user\'s and a project\'s .dsh skills, flat ones too',
      () async {
        final user = p.join(home, '.dsh', 'skills');
        write(
          p.join(user, 'pdf', 'SKILL.md'),
          '---\nname: pdf\ndescription: Reads PDFs\n---\n',
        );
        write(
          p.join(user, 'flat.md'),
          '---\nname: flat\ndescription: A flat skill\n---\n',
        );
        // dsh skips `.system`; Claude Code's skills are not its own.
        write(
          p.join(user, '.system', 'builtin', 'SKILL.md'),
          '---\nname: builtin\ndescription: System\n---\n',
        );
        write(
          p.join(home, '.claude', 'skills', 'claude-only', 'SKILL.md'),
          '---\nname: claude-only\ndescription: Claude\n---\n',
        );
        // A project's, at the nearest ancestor with .git.
        final repo = p.join(temp.path, 'repo');
        write(p.join(repo, '.git', 'HEAD'), 'ref: refs/heads/main\n');
        final folder = p.join(repo, 'packages', 'app');
        Directory(folder).createSync(recursive: true);
        write(
          p.join(repo, '.dsh', 'skills', 'deploy', 'SKILL.md'),
          '# Deploy\n\nShips it.\n',
        );

        final skills = await dsh.list(
          CustomizationKind.skills,
          project: folder,
        );
        expect(
          [for (final s in skills) (s.scope, s.name, s.description)],
          [
            (CustomizationScope.user, 'flat', 'A flat skill'),
            (CustomizationScope.user, 'pdf', 'Reads PDFs'),
            (CustomizationScope.project, 'deploy', 'Ships it.'),
          ],
        );
        expect(skills.first.path, p.join(user, 'flat.md'));
        expect(skills.first.removePath, skills.first.path);
        expect(skills[1].removePath, p.join(user, 'pdf'));
        expect(
          skills.last.path,
          p.join(repo, '.dsh', 'skills', 'deploy', 'SKILL.md'),
        );
        expect(
          skills.last.removePath,
          p.join(repo, '.dsh', 'skills', 'deploy'),
        );

        // The other kinds are Claude Code's alone.
        for (final kind in CustomizationKind.values) {
          if (kind == CustomizationKind.skills) continue;
          expect(
            await dsh.list(kind, project: folder),
            isEmpty,
            reason: '$kind',
          );
        }
      },
    );

    test('makes, lists and deletes skills under dsh\'s own folders', () async {
      final skill = await dsh.create(
        CustomizationKind.skills,
        CustomizationScope.user,
        'release-notes',
      );
      expect(
        skill,
        p.join(home, '.dsh', 'skills', 'release-notes', 'SKILL.md'),
      );
      expect(parseFrontMatter(await dsh.read(skill))['name'], 'release-notes');
      await expectLater(
        dsh.create(
          CustomizationKind.skills,
          CustomizationScope.user,
          'release-notes',
        ),
        throwsA(isA<IdeFileExistsException>()),
      );

      final deploy = await dsh.create(
        CustomizationKind.skills,
        CustomizationScope.project,
        'deploy',
        project: project,
      );
      expect(deploy, p.join(project, '.dsh', 'skills', 'deploy', 'SKILL.md'));

      // A kind dsh does not keep is not made.
      expect(
        () => dsh.create(
          CustomizationKind.subagents,
          CustomizationScope.user,
          'reviewer',
        ),
        throwsArgumentError,
      );

      final listed = await dsh.list(CustomizationKind.skills, project: project);
      expect(
        [for (final s in listed) (s.scope, s.name)],
        [
          (CustomizationScope.user, 'release-notes'),
          (CustomizationScope.project, 'deploy'),
        ],
      );
      await dsh.delete(listed.first);
      expect(
        Directory(p.join(home, '.dsh', 'skills', 'release-notes')).existsSync(),
        isFalse,
      );

      // A flat skill is deleted as the file it is.
      final flat = p.join(home, '.dsh', 'skills', 'flat.md');
      write(flat, '---\nname: flat\ndescription: Flat\n---\n');
      final flatItem = (await dsh.list(CustomizationKind.skills))
          .singleWhere((s) => s.name == 'flat');
      await dsh.delete(flatItem);
      expect(File(flat).existsSync(), isFalse);
    });

    test('reads DSH_HOME, and finds a /command\'s skill there', () async {
      final moved = p.join(temp.path, 'moved-dsh');
      final movedStore = CustomizationStore(
        homeDir: home,
        agent: CustomizationAgent.dsh,
        environment: {'DSH_HOME': moved},
      );
      final path = p.join(moved, 'skills', 'pdf', 'SKILL.md');
      write(path, '---\nname: pdf\ndescription: Reads PDFs\n---\n');
      expect(await movedStore.commandFile('pdf'), path);
      expect(await movedStore.commandFile('pdf-tools'), isNull);

      final flat = p.join(moved, 'skills', 'notes.md');
      write(flat, '---\nname: notes\ndescription: Notes\n---\n');
      expect(await movedStore.commandFile('notes'), flat);
    });

    test('the same store as another agent keeps its files', () async {
      final claude = CustomizationStore(configDir: config, homeDir: home);
      final asDsh = claude.forAgent(CustomizationAgent.dsh);
      expect(asDsh.agent, CustomizationAgent.dsh);
      expect(asDsh.configDir, config);
      expect(asDsh.homeDir, home);
      expect(identical(claude.forAgent(CustomizationAgent.dsh), asDsh), isTrue);
      expect(
        identical(claude.forAgent(CustomizationAgent.claudeCode), claude),
        isTrue,
      );
    });
  });
}

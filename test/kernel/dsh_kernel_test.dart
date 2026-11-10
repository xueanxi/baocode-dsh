import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_ask_bridge.dart';
import 'package:baocode/kernel/dsh/dsh_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_locate.dart';
import 'package:baocode/kernel/dsh/dsh_notices.dart';
import 'package:baocode/kernel/dsh/dsh_patch.dart';
import 'package:baocode/kernel/dsh/dsh_sessions.dart';
import 'package:baocode/kernel/dsh/dsh_transport.dart';
import 'package:baocode/kernel/dsh/mock_dsh_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The kernel's handshake with dsh, the session it makes on the first
/// message, what it offers once that session is there, and how it lets the
/// process go again. Nothing is started: the transport is
/// [MockDshTransport].
void main() {
  // The test binding fakes HttpClient (every request a 400). The question
  // endpoint is a real loopback server, so these tests use the real client.
  setUp(() => HttpOverrides.global = null);

  test(
    'shakes hands: the image capability, the project, and no session yet',
    () async {
      final dsh = _FakeDsh();
      // The route's key, given rather than looked for: no test reads the
      // user's own ~/.dsh.
      final kernel = dsh.kernel(
        credentials: () async => {DshPatch.credentialRef},
      );
      final events = _listen(kernel);

      expect(kernel.health.status, KernelHealthStatus.idle);
      expect(kernel.supportsImages, isFalse);

      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);

      expect(kernel.supportsImages, isTrue);
      expect(dsh.transport.requests('initialize').single['params'], {
        'protocolVersion': 1,
      });
      // Nothing is created before the first message: an empty session would be
      // left in ~/.dsh for every conversation opened.
      expect(dsh.transport.requests('session/new'), isEmpty);
      expect(kernel.sessionId, isNull);
      // A version this adapter was written against says nothing.
      expect(events.whereType<ItemUpserted>(), isEmpty);

      final launch = dsh.launches.single;
      expect(launch.cwd, '/project');
      expect(launch.permissionMode, 'workspace-write');
      expect(launch.patchFile, endsWith(DshPatch.fileName));
      expect(File(launch.patchFile).existsSync(), isTrue);
      // The login shell's environment, without which dsh finds no `node` or
      // `git` when the app was started from Finder; beside it, where the
      // answerer plugin asks (the bridge, see `dsh_ask_bridge.dart`).
      expect(launch.environment!['PATH'], '/usr/bin');
      final askUrl = Uri.parse(launch.environment![DshAskBridge.urlVariable]!);
      expect(askUrl.scheme, 'http');
      expect(askUrl.host, '127.0.0.1');
      expect(launch.environment![DshAskBridge.tokenVariable], isNotEmpty);
      final patch = File(launch.patchFile).readAsStringSync();
      expect(patch, contains('- id: baocode-ask'));
      expect(patch, contains("name: '@deepseek-ai/dsh-tool-ask-user'"));
      expect(patch, contains(DshAskBridge.fileName));
    },
  );

  test(
    'the skills dsh would load are the / menu, and a later one joins it',
    () async {
      final home = Directory.systemTemp.createTempSync('dsh_skills');
      addTearDown(() => home.deleteSync(recursive: true));
      final skill = File(
        p.join(home.path, '.dsh', 'skills', 'dsh-test-skill', 'SKILL.md'),
      );
      skill.parent.createSync(recursive: true);
      skill.writeAsStringSync(
        '---\n'
        'name: dsh-test-skill\n'
        'description: A skill from the user roots.\n'
        '---\n',
      );
      final dsh = _FakeDsh();
      // ACP names no commands, so the kernel reads the files dsh would.
      final kernel = dsh.kernel(
        environment: {
          'PATH': '/usr/bin',
          'HOME': home.path,
          'USERPROFILE': home.path,
        },
      );
      expect(kernel.commands, isEmpty);

      kernel.prepare();
      await settled(() => kernel.commands.isNotEmpty);
      final command = kernel.commands.single;
      expect(command.name, 'dsh-test-skill');
      expect(command.description, 'A skill from the user roots.');
      expect(command.path, skill.path);

      File(p.join(home.path, '.dsh', 'skills', 'later.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '---\nname: later\ndescription: Added later.\n---\n',
        );
      kernel.prepare();
      await settled(() => kernel.commands.length == 2);
      expect(
        [for (final command in kernel.commands) command.name],
        ['dsh-test-skill', 'later'],
      );
    },
  );

  test(
    'the Git Bash plugin, and a bash found: the patch turns bash on',
    () async {
      final machine = _bashMachine(withPlugin: true);
      final dsh = _FakeDsh();
      final kernel = dsh.kernel(environment: machine);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);

      // What installing the plugin does: its own bundle patch mounts the Git
      // Bash executor. The patch only turns the tool that executor serves on.
      final patch = File(dsh.launches.single.patchFile).readAsStringSync();
      expect(patch, contains('- id: tool-bash'));
      expect(patch, contains('  disabled: false'));
      expect(patch, isNot(contains('dsh-gitbash-shell/shell')));
      expect(patch, isNot(contains('bashPath')));
    },
    skip: Platform.isWindows ? false : 'the plugin is a Windows one',
  );

  test(
    'no Git Bash plugin: no bash in the patch, though the machine has one',
    () async {
      final machine = _bashMachine(withPlugin: false);
      final dsh = _FakeDsh();
      final kernel = dsh.kernel(environment: machine);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);

      // The bash was there to turn on, and dsh would silently ignore the tool:
      // only the plugin's bundle patch mounts the executor it runs on.
      final patch = File(dsh.launches.single.patchFile).readAsStringSync();
      expect(patch, isNot(contains('tool-bash')));
    },
    skip: Platform.isWindows ? false : 'the plugin is a Windows one',
  );

  test(
    'no key for the route: said once, and dsh is started all the same',
    () async {
      final dsh = _FakeDsh();
      final kernel = dsh.kernel(credentials: () async => <String>{});
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);

      final notice =
          _item(events, 'notice:credential:${DshPatch.credentialRef}').item
              as NoticeItem;
      expect(notice.kind, NoticeKind.error);
      // The key's absence is what the turns fail on, not what the start does.
      expect(dsh.launches, hasLength(1));
      expect(
        events.whereType<ItemUpserted>().where(
          (event) => event.id.startsWith('notice:credential:'),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'a dsh that takes no pictures: they are left out, and said so',
    () async {
      final dsh = _FakeDsh(image: false);
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      expect(kernel.supportsImages, isFalse);

      kernel.send(
        KernelTurn(
          id: 'turn-1',
          text: 'What is this?',
          images: [
            ImageAttachment(
              bytes: Uint8List.fromList([1, 2, 3]),
              mediaType: 'image/png',
            ),
          ],
        ),
      );
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);

      final notice = _item(events, 'notice:images:turn-1');
      expect((notice.item as NoticeItem).kind, NoticeKind.warning);
      final message = _item(events, 'turn-1').item as UserMessageItem;
      expect(message.images, isEmpty);
      final prompt = dsh.transport.lastPrompt!['prompt'] as List;
      expect([for (final block in prompt) (block as Map)['type']], ['text']);
    },
  );

  test('the pictures dsh takes go with the message', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);

    kernel.send(
      KernelTurn(
        id: 'turn-1',
        text: 'What is this?',
        images: [
          ImageAttachment(
            bytes: Uint8List.fromList([1, 2, 3]),
            mediaType: 'image/png',
          ),
        ],
      ),
    );
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);

    final prompt = dsh.transport.lastPrompt!['prompt'] as List;
    expect(prompt.first, {
      'type': 'image',
      'data': base64Encode([1, 2, 3]),
      'mimeType': 'image/png',
    });
    expect(prompt.last, {'type': 'text', 'text': 'What is this?'});
    expect(
      (_item(events, 'turn-1').item as UserMessageItem).images,
      hasLength(1),
    );
  });

  test('an older dsh: named in a warning, and still used', () async {
    final dsh = _FakeDsh(version: '0.1.9');
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);

    final notice = _item(events, 'notice:version');
    expect((notice.item as NoticeItem).kind, NoticeKind.warning);
    expect((notice.item as NoticeItem).text, contains('0.1.9'));
    expect((notice.item as NoticeItem).text, contains('0.2.0-rc.2'));
    expect(kernel.health.status, KernelHealthStatus.ready);
  });

  test(
    'the first message makes the session: the project, and no MCP servers',
    () async {
      final dsh = _FakeDsh();
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);

      kernel.send(KernelTurn(id: 'turn-1', text: 'Change the composer'));
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);

      expect(dsh.transport.requests('session/new').single['params'], {
        'cwd': '/project',
        'mcpServers': <Object?>[],
      });
      expect(kernel.sessionId, 'session-mock');
      expect(dsh.transport.requests('session/prompt').single['params'], {
        'sessionId': 'session-mock',
        'prompt': [
          {'type': 'text', 'text': 'Change the composer'},
        ],
      });
    },
  );

  test(
    'the models dsh lists, grouped by provider, values as dsh writes them',
    () async {
      final dsh = _FakeDsh(
        models: const {
          'stepcodev2': ['deepseek-v4.1-flash'],
          'acme': ['m-1', 'm-2'],
        },
      );
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      // dsh says what it offers with the session (F6): nothing before it.
      expect(kernel.model.options, isEmpty);

      kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);

      final options = kernel.model.options;
      expect(
        [for (final option in options) option.id],
        [
          '["stepcodev2","deepseek-v4.1-flash"]',
          '["acme","m-1"]',
          '["acme","m-2"]',
        ],
      );
      expect(options.first.group?.id, 'stepcodev2');
      expect(options[1].group?.label, 'acme');
      expect(options[1].label, 'm-1');
      expect(kernel.model.selected, '["stepcodev2","deepseek-v4.1-flash"]');
    },
  );

  test(
    'a model picked is set on the session, and dsh is not restarted',
    () async {
      final dsh = _FakeDsh(
        models: const {
          'stepcodev2': ['deepseek-v4.1-flash', 'deepseek-v4-pro'],
        },
      );
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);

      const other = '["stepcodev2","deepseek-v4-pro"]';
      kernel.model.select(other);
      await settled(() => kernel.model.selected == other);

      expect(
        dsh.transport.requests('session/set_config_option').single['params'],
        {'sessionId': 'session-mock', 'configId': 'model', 'value': other},
      );
      expect(dsh.launches, hasLength(1));
    },
  );

  test('a model another kernel kept is dropped, and none is set', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel(settings: {'model': 'claude-opus-4'});
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);

    expect(kernel.model.selected, '["stepcodev2","deepseek-v4.1-flash"]');
    expect(dsh.transport.requests('session/set_config_option'), isEmpty);
  });

  test(
    'a model picked before the session existed is set when it is made',
    () async {
      final dsh = _FakeDsh(
        models: const {
          'stepcodev2': ['deepseek-v4.1-flash', 'deepseek-v4-pro'],
        },
      );
      const other = '["stepcodev2","deepseek-v4-pro"]';
      final kernel = dsh.kernel(settings: {'model': other});
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);

      expect(
        dsh.transport.requests('session/set_config_option').single['params'],
        {'sessionId': 'session-mock', 'configId': 'model', 'value': other},
      );
      expect(kernel.model.selected, other);
    },
  );

  test('a model without reasoning levels offers none', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);

    expect(kernel.effort.optionsFor(kernel.model.selected!), isEmpty);
    expect(kernel.effort.selected, isNull);
  });

  test('the reasoning levels come with the model, and are set on it', () async {
    final dsh = _FakeDsh(reasoningEffort: true);
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);

    final model = kernel.model.selected!;
    expect(
      [for (final option in kernel.effort.optionsFor(model)) option.id],
      ['low', 'medium', 'high'],
    );
    expect(kernel.effort.selected, 'medium');

    kernel.effort.select(model, 'high');
    await settled(() => kernel.effort.selected == 'high');
    expect(
      dsh.transport.requests('session/set_config_option').single['params'],
      {
        'sessionId': 'session-mock',
        'configId': 'reasoning_effort',
        'value': 'high',
      },
    );
  });

  test('the context window: the patch\'s until dsh reports its own', () async {
    final dsh = _FakeDsh()
      ..configure = ((transport) => transport.contextSize = 200000);
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    expect(kernel.contextWindow, 512000);

    kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);

    expect(kernel.contextWindow, 200000);
    expect(events.whereType<UsageReported>().single.usage.window, 200000);
  });

  test('no dsh on this machine: failed, saying how to install it', () async {
    final dsh = _FakeDsh(installed: false);
    final kernel = dsh.kernel();
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.failed);

    expect(kernel.health.message, contains('npm i -g @deepseek-ai/dsh'));
    expect(kernel.health.detail, contains('Settings → General → DSH'));
    expect(dsh.launches, isEmpty);
  });

  test('a process that will not start: failed, with what it printed', () async {
    final dsh = _FakeDsh()
      ..startFailure = const DshUnavailable(
        'DSH could not start',
        detail: 'node: not found',
      );
    final kernel = dsh.kernel();
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.failed);

    expect(kernel.health.message, 'DSH could not start');
    expect(kernel.health.detail, 'node: not found');
  });

  test(
    'a handshake that never is: failed, with the tail of what it printed',
    () async {
      final dsh = _FakeDsh()
        ..configure = ((transport) {
          transport
            ..diesOnInitialize = true
            ..dieWith = 'Error: 3 entries did not activate';
        });
      final kernel = dsh.kernel();
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.failed);

      expect(kernel.health.message, 'DSH did not start');
      expect(kernel.health.detail, contains('3 entries did not activate'));
    },
  );

  test('a turn sent while that failed ends too', () async {
    final dsh = _FakeDsh(installed: false);
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);

    expect((events.last as TurnEnded).interrupted, isTrue);
    expect(
      (_item(events, 'error:turn-1').item as NoticeItem).kind,
      NoticeKind.error,
    );
  });

  test(
    'the process ending by itself while ready: idle, and started again',
    () async {
      final dsh = _FakeDsh();
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);

      dsh.transport.exit();
      await settled(() => kernel.health.status == KernelHealthStatus.idle);
      expect(kernel.health.status, KernelHealthStatus.idle);

      final ended = events.whereType<TurnEnded>();
      expect(ended, isEmpty);
    },
  );

  test('released and used again: the session is resumed, the process before it '
      'gone first', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);
    final first = dsh.transport;

    kernel.release();
    await first.exited;
    expect(kernel.health.status, KernelHealthStatus.idle);

    final beforeRestart = events.last.seq;
    kernel.send(KernelTurn(id: 'turn-2', text: 'Go on'));
    await settled(() => events.whereType<TurnEnded>().length == 2);

    // Numbered on past the restart, never from zero again.
    expect(events.last.seq, greaterThan(beforeRestart));
    expect(dsh.transports, hasLength(2));
    expect(dsh.transport.requests('session/new'), isEmpty);
    expect(dsh.transport.requests('session/resume').single['params'], {
      'sessionId': 'session-mock',
      'cwd': '/project',
    });
    // Started only once the process that held the session was gone (F15).
    expect(dsh.restartedAfterExit, [true]);
  });

  test('a session another process still holds: resumed once more', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);

    kernel.release();
    await dsh.transport.exited;
    dsh.configure = (transport) => transport.busyResumes = 1;

    kernel.send(KernelTurn(id: 'turn-2', text: 'Go on'));
    await settled(() => events.whereType<TurnEnded>().length == 2);

    expect(dsh.transport.requests('session/resume'), hasLength(2));
    expect(kernel.health.status, KernelHealthStatus.ready);
  });

  test(
    'the permission tier: picked before the first message, locked after it',
    () async {
      final dsh = _FakeDsh();
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      expect(
        [for (final option in kernel.permission.options) option.id],
        ['read-only', 'workspace-write', 'danger-full-access'],
      );
      expect(kernel.permission.selected, 'workspace-write');
      expect(kernel.permission.options.last.caution, isTrue);

      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      expect(dsh.launches.single.permissionMode, 'workspace-write');

      // Picked after the process is up: it is started again for it, so the
      // session is made under the tier picked and shown.
      kernel.permission.select('danger-full-access');
      expect(kernel.permission.selected, 'danger-full-access');
      kernel.send(KernelTurn(id: 'turn-1', text: 'Go'));
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);
      expect(
        [for (final launch in dsh.launches) launch.permissionMode],
        ['workspace-write', 'danger-full-access'],
      );

      // Locked: dsh wrote the tier into the session, and resuming does not
      // change it (F16).
      expect(kernel.permission.options, hasLength(1));
      expect(kernel.permission.options.single.id, 'danger-full-access');
      kernel.permission.select('read-only');
      expect(kernel.permission.selected, 'danger-full-access');
    },
  );

  test('the tier last picked is the one a conversation starts in', () {
    expect(
      _FakeDsh()
          .kernel(settings: {'permission': 'read-only'})
          .permission
          .selected,
      'read-only',
    );
    // Not a tier of dsh's: it would silently fall back (F22), so the kernel
    // picks one it knows.
    expect(
      _FakeDsh().kernel(settings: {'permission': 'yolo'}).permission.selected,
      'workspace-write',
    );
  });

  test(
    'failed, restarted once dsh is there: it starts, and only then',
    () async {
      final dsh = _FakeDsh(installed: false);
      final kernel = dsh.kernel();
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.failed);

      // Ready it is not, so there is nothing to retry.
      dsh.installed = true;
      kernel.restart();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      expect(dsh.launches, hasLength(1));
      expect(kernel.health.status, KernelHealthStatus.ready);
      // And a retry it is not in need of: nothing starts again.
      kernel.restart();
      expect(dsh.launches, hasLength(1));
    },
  );

  test(
    'released while a turn runs: the process goes once it is over',
    () async {
      final dsh = _FakeDsh();
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      dsh.transport.holds = true;
      kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
      await settled(
        () => events.any(
          (event) => event is ItemUpserted && event.id == 'thought:1',
        ),
      );

      kernel.release();
      expect(kernel.health.status, KernelHealthStatus.ready);
      kernel.cancel();
      await settled(() => kernel.health.status == KernelHealthStatus.idle);
      expect(dsh.transport.gone, isTrue);
    },
  );

  test(
    'what the process took is forgotten with it: release, then resume',
    () async {
      final dsh = _FakeDsh();
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      expect(kernel.supportsImages, isTrue);
      kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);

      kernel.release();
      await settled(() => kernel.health.status == KernelHealthStatus.idle);
      // The answer was that process's: the next one answers for itself.
      expect(kernel.supportsImages, isFalse);

      // Another dsh takes no pictures, and the same session is resumed onto
      // it: the pictures of the next turn are left out, and said so inside
      // the turn.
      dsh.image = false;
      kernel.send(
        KernelTurn(id: 'turn-2', text: 'And this?', images: [_picture()]),
      );
      await settled(() => events.whereType<TurnEnded>().length == 2);

      final user = _item(events, 'turn-2').item as UserMessageItem;
      expect(user.images, isEmpty);
      final prompt = dsh.transport.lastPrompt!['prompt'] as List;
      expect([for (final block in prompt) (block as Map)['type']], ['text']);
      expect(_item(events, 'notice:images:turn-2').item, isA<NoticeItem>());
    },
  );

  test('disposed: let go, and `stopped` completes once it is gone', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel();
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    final transport = dsh.transport;

    kernel.dispose();
    await kernel.stopped;
    expect(transport.gone, isTrue);
  });

  test('the registry offers Claude Code first, then DSH', () {
    expect(
      [for (final kernel in KernelRegistry.builtIn) kernel.id],
      ['claude-code', 'dsh'],
    );
    expect(KernelRegistry.dsh.id, 'dsh');
    expect(KernelRegistry.dsh.label, 'DSH');
    expect(KernelRegistry.dsh.description, 'DeepSeek Harness');
  });

  test(
    'a question from the bridge: the panel shows its options, and the answer '
    'goes back in dsh\'s shape',
    () async {
      final dsh = _FakeDsh();
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      final environment = dsh.launches.single.environment!;
      final url = _askUrl(environment);

      final created = await _post(url, environment, 'questions', {
        'questions': [
          {
            'id': 'fruit',
            'question': 'Which fruit do you want?',
            'header': 'Fruit',
            'options': [
              {'label': 'Apple', 'description': 'A red one'},
              {'label': 'Banana', 'description': 'A yellow one'},
            ],
          },
        ],
      });
      await settled(() => events.whereType<InteractionRequested>().isNotEmpty);

      final request =
          events.whereType<InteractionRequested>().single.request
              as QuestionRequest;
      expect(request.title, 'DSH has a question');
      expect(request.questions.single.prompt, 'Which fruit do you want?');
      expect(request.questions.single.header, 'Fruit');
      expect(
        [for (final option in request.questions.single.options) option.label],
        ['Apple', 'Banana'],
      );
      expect(request.questions.single.allowMultiple, isFalse);
      expect(request.questions.single.allowOther, isTrue);

      kernel.answer(
        request.id,
        QuestionAnswer([
          ['Apple'],
        ]),
      );
      final answered = await _settledPoll(
        url,
        environment,
        id: created['id'] as String,
      );
      expect(answered['state'], 'answered');
      expect(answered['answers'], [
        {
          'id': 'fruit',
          'selected': ['Apple'],
        },
      ]);
      // The panel is told it is over.
      await settled(
        () => events.whereType<InteractionResolved>().any(
          (event) => event.requestId == request.id,
        ),
      );
    },
  );

  test(
    'a multi-select question stays multiple: dsh\'s `multiSelect` reaches the '
    'panel, and every pick comes back',
    () async {
      final dsh = _FakeDsh();
      final kernel = dsh.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      final environment = dsh.launches.single.environment!;
      final url = _askUrl(environment);

      // The service normalizes the tool's `multi_select` to `multiSelect`
      // before the waterfall: this is what the bridge posts.
      final created = await _post(url, environment, 'questions', {
        'questions': [
          {
            'id': 'weekend',
            'question': 'Which days?',
            'multiSelect': true,
            'options': [
              {'label': 'Saturday'},
              {'label': 'Sunday'},
            ],
          },
        ],
      });
      await settled(() => events.whereType<InteractionRequested>().isNotEmpty);
      final request =
          events.whereType<InteractionRequested>().single.request
              as QuestionRequest;
      expect(request.questions.single.allowMultiple, isTrue);

      kernel.answer(
        request.id,
        QuestionAnswer([
          ['Saturday', 'Sunday'],
        ]),
      );
      final answered = await _settledPoll(
        url,
        environment,
        id: created['id'] as String,
      );
      expect(answered['answers'], [
        {
          'id': 'weekend',
          'selected': ['Saturday', 'Sunday'],
        },
      ]);
    },
  );

  test('an answer of the user\'s own is dsh\'s custom, and a skip is empty '
      'selections', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    final environment = dsh.launches.single.environment!;
    final url = _askUrl(environment);

    final created = await _post(url, environment, 'questions', {
      'questions': [
        {
          'id': 'fruit',
          'question': 'Which fruit?',
          'options': [
            {'label': 'Apple'},
          ],
        },
      ],
    });
    await settled(() => events.whereType<InteractionRequested>().isNotEmpty);
    final first =
        events.whereType<InteractionRequested>().single.request
            as QuestionRequest;
    kernel.answer(
      first.id,
      QuestionAnswer([
        ['Peach'],
      ]),
    );
    final answered = await _settledPoll(
      url,
      environment,
      id: created['id'] as String,
    );
    expect(answered['answers'], [
      {'id': 'fruit', 'selected': <String>[], 'custom': 'Peach'},
    ]);

    // A second question, dismissed: answered with nothing picked, which dsh's
    // own tool reads as skipped (not as cancelled).
    final skipped = await _post(url, environment, 'questions', {
      'questions': [
        {'id': 'size', 'question': 'How big?'},
      ],
    });
    await settled(() => events.whereType<InteractionRequested>().length == 2);
    final second = events.whereType<InteractionRequested>().last.request;
    kernel.answer(second.id, QuestionAnswer([<String>[]], skipped: true));
    expect(
      (await _settledPoll(
        url,
        environment,
        id: skipped['id'] as String,
      ))['answers'],
      [
        {'id': 'size', 'selected': <String>[]},
      ],
    );
  });

  test('the conversation lets go while a question waits: the bridge is told '
      'cancelled', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    final environment = dsh.launches.single.environment!;
    final url = _askUrl(environment);

    final created = await _post(url, environment, 'questions', {
      'questions': [
        {'id': 'fruit', 'question': 'Which fruit?'},
      ],
    });
    await settled(() => events.whereType<InteractionRequested>().isNotEmpty);

    kernel.release();
    final state = await _poll(url, environment, created['id'] as String);
    expect(state['state'], 'cancelled');
    kernel.dispose();
  });

  test('no one at the computer: no answerer in the patch, and none in the '
      'environment', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel(
      workspace: const KernelWorkspace(folders: [], approvesAll: true),
    );
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);

    final launch = dsh.launches.single;
    expect(launch.environment, {'PATH': '/usr/bin'});
    expect(
      File(launch.patchFile).readAsStringSync(),
      isNot(contains('baocode-ask')),
    );
  });
}

/// The endpoint the kernel's bridge asks on.
Uri _askUrl(Map<String, String> environment) =>
    Uri.parse(environment[DshAskBridge.urlVariable]!);

/// Posts [body] to [path] on the question endpoint, as the bridge does.
Future<Map<String, Object?>> _post(
  Uri url,
  Map<String, String> environment,
  String path,
  Map<String, Object?> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(url.resolve('/$path'));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${environment[DshAskBridge.tokenVariable]}',
    );
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    expect(response.statusCode, inInclusiveRange(200, 299), reason: text);
    return (jsonDecode(text) as Map).cast<String, Object?>();
  } finally {
    client.close(force: true);
  }
}

/// One poll of the question endpoint, as the bridge does.
Future<Map<String, Object?>> _poll(
  Uri url,
  Map<String, String> environment,
  String id,
) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url.resolve('/questions/$id'));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${environment[DshAskBridge.tokenVariable]}',
    );
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (jsonDecode(text) as Map).cast<String, Object?>();
  } finally {
    client.close(force: true);
  }
}

/// Polls until the question is no longer open, as the bridge would; the
/// kernel keeps running while it does.
Future<Map<String, Object?>> _settledPoll(
  Uri url,
  Map<String, String> environment, {
  required String id,
}) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    final state = await _poll(url, environment, id);
    if (state['state'] != 'open') return state;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('the question was never answered');
}

/// A machine's Git Bash and dsh home, for the patch that turns bash on: a
/// `bash.exe` on the login shell's PATH, and a `DSH_HOME` whose ACP profile has
/// the Git Bash plugin installed — or, with [withPlugin] false, has not.
///
/// Both are this test's own, made under the temp folder and taken away with it:
/// no test reads the machine's `~/.dsh`, nor a Git installed on it.
Map<String, String> _bashMachine({required bool withPlugin}) {
  final root = Directory.systemTemp.createTempSync('baocode-dsh-bash');
  addTearDown(() => root.deleteSync(recursive: true));
  final bin = Directory(p.join(root.path, 'git', 'bin'))
    ..createSync(recursive: true);
  File(p.join(bin.path, 'bash.exe')).writeAsStringSync('');
  final home = Directory(p.join(root.path, 'dsh-home'))
    ..createSync(recursive: true);
  if (withPlugin) {
    Directory(
      p.join(home.path, 'profiles', 'acp', 'node_modules', 'dsh-gitbash-shell'),
    ).createSync(recursive: true);
  }
  return {'PATH': bin.path, 'DSH_HOME': home.path};
}

/// dsh on this machine, as much of it as a kernel needs: where it is, what
/// it is started with, and the process each start gets. No dsh runs.
class _FakeDsh {
  _FakeDsh({
    this.version = '0.2.0-rc.2',
    this.installed = true,
    this.image = true,
    this.reasoningEffort = false,
    this.models,
  });

  final String version;
  bool installed;

  /// Whether the process started next says it takes pictures: a dsh replaced
  /// by another between two starts, as its upgrade would replace it.
  bool image;
  final bool reasoningEffort;
  final Map<String, List<String>>? models;

  /// Every start, in order.
  final List<DshLaunch> launches = [];

  /// The process each start got, in order.
  final List<MockDshTransport> transports = [];

  /// What a start throws instead of making a process.
  Object? startFailure;

  /// Set on each process as it is made.
  void Function(MockDshTransport transport)? configure;

  /// Each start after the first, and whether the process before it was
  /// already gone.
  final List<bool> restartedAfterExit = [];

  MockDshTransport get transport => transports.last;

  Future<DshInstall?> locate() async => installed
      ? DshInstall(
          node: 'node',
          binJs: '/opt/dsh/lib/bin.js',
          version: version,
          packageDir: '/opt/dsh',
        )
      : null;

  Future<DshTransport> start(DshLaunch launch) async {
    launches.add(launch);
    if (transports.isNotEmpty) {
      restartedAfterExit.add(transports.last.gone);
    }
    if (startFailure case final failure?) throw failure;
    final transport = MockDshTransport(
      image: image,
      reasoningEffort: reasoningEffort,
      models: models,
    );
    configure?.call(transport);
    transports.add(transport);
    return transport;
  }

  /// A kernel over this fake dsh. The refs its route can resolve are given
  /// here rather than read from the machine's `~/.dsh`: no test reads the
  /// user's own store, and the machine that runs it decides nothing.
  DshKernel kernel({
    String cwd = '/project',
    Map<String, String> settings = const {},
    Map<String, String> environment = const {'PATH': '/usr/bin'},
    KernelWorkspace? workspace,
    DshCredentialRefs? credentials,
  }) => DshKernel(
    KernelRegistry.dsh,
    KernelContext(
      cwd: cwd,
      settings: settings,
      workspace: workspace == null ? null : () => workspace,
    ),
    start: start,
    locate: locate,
    environment: () async => environment,
    sessions: MemoryDshSessionStore(),
    credentials: credentials ?? () async => {DshPatch.credentialRef},
  );
}

/// Everything [kernel] reports, as it reports it.
List<KernelEvent> _listen(AgentKernel kernel) {
  final events = <KernelEvent>[];
  kernel.events.listen(events.add);
  return events;
}

/// A picture to send: the bytes mean nothing to the mock.
ImageAttachment _picture() => ImageAttachment(
  bytes: Uint8List.fromList([1, 2, 3]),
  mediaType: 'image/png',
);

/// The item [id] was put under.
ItemUpserted _item(List<KernelEvent> events, String id) =>
    events.whereType<ItemUpserted>().firstWhere((event) => event.id == id);

/// Runs the event loop until [done] holds, giving up after a while: what the
/// kernel does off the wire is asynchronous, and the patch it writes is a
/// file on disk, which needs more than a turn of the loop.
Future<void> settled(bool Function() done) async {
  for (var turns = 0; turns < 500 && !done(); turns++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue, reason: 'the kernel never got there');
}

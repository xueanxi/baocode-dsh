import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_locate.dart';
import 'package:baocode/kernel/dsh/dsh_sessions.dart';
import 'package:baocode/kernel/dsh/mock_dsh_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_route_fixture.dart';

/// A DSH conversation kept between two runs: the session of the first is
/// listed by the catalog of the second, resumed rather than made anew, and
/// what was said in it is read back.
void main() {
  test('a kept session is resumed, not made anew', () async {
    final mock = MockDshTransport();
    final kernel = _kernel(
      mock,
      resume: SessionRecord(
        id: 'session-mock',
        title: 'Change the composer',
        updatedAt: DateTime(2026, 11, 9),
        cwd: '/project',
      ),
    );
    addTearDown(kernel.dispose);

    kernel.prepare();
    await settled(
      () => kernel.health.status == KernelHealthStatus.ready,
      'the handshake',
    );
    kernel.send(KernelTurn(id: 'turn-2', text: 'One more thing'));

    await settled(
      () => mock.requests('session/prompt').isNotEmpty,
      'the turn to go out',
    );
    expect(
      mock.requests('session/new'),
      isEmpty,
      reason: 'a session kept from before is continued, not started over',
    );
    expect(mock.requests('session/resume'), hasLength(1));
  });

  test(
    'what was said is kept, and read back when the session is resumed',
    () async {
      final sessions = MemoryDshSessionStore();

      // The first run: a turn, kept once it ends.
      final firstMock = MockDshTransport();
      final first = _kernel(firstMock, sessions: sessions);
      final firstEvents = _listen(first);
      first.prepare();
      await settled(
        () => first.health.status == KernelHealthStatus.ready,
        'the handshake',
      );
      first.send(KernelTurn(id: 'turn-1', text: 'Change the composer'));
      await settled(
        () => firstEvents.whereType<TurnEnded>().isNotEmpty,
        'the first turn to end',
      );
      first.dispose();
      await first.stopped;

      final kept = (await DshCatalog(
        sessions: sessions,
      ).projects()).single.sessions.single;
      expect(kept.id, 'session-mock');
      expect(kept.title, 'Change the composer');
      final said = await sessions.history(kept.id);
      expect(said.first.$1, 'turn-1');
      expect(
        said.map((item) => item.$1),
        containsAll(['message:1', 'message:2']),
      );

      // The next run: the same conversation, told so before it says anything.
      final secondMock = MockDshTransport();
      final second = _kernel(secondMock, resume: kept, sessions: sessions);
      addTearDown(second.dispose);
      final events = _listen(second);
      second.prepare();
      await settled(
        () => events.whereType<HistoryPrepended>().isNotEmpty,
        'what was said before',
      );
      final readBack = events.whereType<HistoryPrepended>().single.items;
      expect(readBack.map((item) => item.$1), said.map((item) => item.$1));

      second.send(KernelTurn(id: 'turn-2', text: 'One more thing'));
      await settled(
        () => events.whereType<TurnEnded>().isNotEmpty,
        'the second turn to end',
      );
      // Its message ids count on from the history's: a message:1 again would
      // replace the one read back.
      final written = [
        for (final event in events.whereType<ItemUpserted>())
          if (event.item is! UserMessageItem) event.id,
      ];
      expect(written, contains('message:3'));
      expect(written, isNot(contains('message:1')));
    },
  );

  test(
    'a session made in one run is listed, and read back, in the next',
    () async {
      final sessions = MemoryDshSessionStore();
      final preferences = MemoryPreferenceStore();
      final first = Workspace(
        projects: const [Project('baocode', '/p/baocode')],
        kernels: [MockKernels.dshOn(MockDshTransport(), sessions: sessions)],
        preferences: preferences,
      );
      addTearDown(first.dispose);
      await first.load();
      final made = first.threads.single;
      made.session.send(const ComposerMessage(text: 'Change the composer'));
      await settled(
        () => !made.session.isStreaming && made.session.itemCount > 0,
        'the first turn',
      );
      expect(made.session.sessionId, 'session-mock');

      // The next run: listed in its project, with what it was first asked.
      final second = Workspace(
        projects: const [Project('baocode', '/p/baocode')],
        kernels: [MockKernels.dshOn(MockDshTransport(), sessions: sessions)],
        preferences: preferences,
      );
      addTearDown(second.dispose);
      await second.load();
      final kept = second.threads.where(
        (thread) => thread.id == 'session-mock',
      );
      expect(kept, hasLength(1));
      expect(kept.single.title, 'Change the composer');
      // Still the agent shown: not a new, empty one in its place.
      expect(second.threads, hasLength(1));
      expect(second.current, same(kept.single));

      // Opened: what was said before is read, before anything new is sent.
      kept.single.session.attach();
      await settled(
        () => kept.single.session.itemCount > 0,
        'the conversation read back',
      );
      expect(kept.single.session.itemAt(0), isA<UserMessageItem>());
    },
  );

  test('the file store keeps a session and what was said in it', () async {
    final directory = await Directory.systemTemp.createTemp('dsh-sessions');
    addTearDown(() => directory.delete(recursive: true));
    final store = DshSessionStore.file(directory.path);
    // Not a UUID, as a newer dsh may give: its slashes are not a path.
    const id = 'a/b?';
    await store.keep(
      DshSession(
        id: id,
        cwd: '/p/baocode',
        title: 'Change the composer',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
    );
    await store.keepHistory(id, [
      ('turn-1', const UserMessageItem(text: 'Change the composer')),
      ('message:1', const AssistantTextItem('Done.')),
    ]);

    final record = (await DshCatalog(
      sessions: store,
    ).projects()).single.sessions.single;
    expect(record.id, id);
    expect(record.title, 'Change the composer');
    expect(record.updatedAt, DateTime.fromMillisecondsSinceEpoch(1000));
    final said = await store.history(id);
    expect(said.map((item) => item.$1), ['turn-1', 'message:1']);
    expect((said.last.$2 as AssistantTextItem).text, 'Done.');

    await DshCatalog(sessions: store).delete(id);
    expect(await store.sessions(), isEmpty);
    expect(await store.history(id), isEmpty);
  });
}

/// Everything [kernel] reports, as it reports it.
List<KernelEvent> _listen(DshKernel kernel) {
  final events = <KernelEvent>[];
  kernel.events.listen((event) {
    if (event is! KernelInfoChanged) events.add(event);
  });
  return events;
}

DshKernel _kernel(
  MockDshTransport mock, {
  SessionRecord? resume,
  DshSessionStore? sessions,
}) => DshKernel(
  KernelRegistry.dsh,
  KernelContext(cwd: '/project', resume: resume),
  start: (_) async => mock,
  locate: () async => const DshInstall(
    node: 'node',
    binJs: '/opt/dsh/lib/bin.js',
    version: '0.2.0-rc.2',
    packageDir: '/opt/dsh',
  ),
  environment: () async => const {'PATH': '/usr/bin'},
  sessions: sessions,
  route: testDshRoute,
  credentials: (_) async => true,
  titleAsker: (_, {route, cancel}) async => null,
);

/// Runs the event loop until [done] holds, giving up after a while: what the
/// kernel does off the wire is asynchronous, and the patch it writes is a file
/// on disk, which needs more than a turn of the loop.
Future<void> settled(bool Function() done, [String? what]) async {
  for (var turns = 0; turns < 500 && !done(); turns++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue, reason: 'the kernel never got there: ${what ?? ''}');
}

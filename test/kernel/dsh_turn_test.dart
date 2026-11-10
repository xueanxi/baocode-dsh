import 'dart:typed_data';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_locate.dart';
import 'package:baocode/kernel/dsh/dsh_sessions.dart';
import 'package:baocode/kernel/dsh/dsh_transport.dart';
import 'package:baocode/kernel/dsh/mock_dsh_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_route_fixture.dart';

/// One turn as dsh reports it, translated: the order of what the history
/// shows, the ids the client makes for it, and the ways a turn can end —
/// every one of them with a `TurnEnded`, or the conversation waits for ever.
void main() {
  test(
    'a turn: started, the user\'s message, what the agent did, and ended',
    () async {
      final rig = _Rig();
      await rig.ready();

      rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Change the composer'));
      await rig.ended();

      // The sequence the history renders: nothing before the start, the user's
      // message right after it, and the end last.
      final first = rig.events.first;
      expect(first, isA<TurnStarted>());
      expect((first as TurnStarted).turnId, 'turn-1');
      final user = rig.events[1] as ItemUpserted;
      expect(user.id, 'turn-1');
      final message = user.item as UserMessageItem;
      expect(message.text, 'Change the composer');
      expect(message.images, isEmpty);

      final last = rig.events.last;
      expect(last, isA<TurnEnded>());
      expect((last as TurnEnded).turnId, 'turn-1');
      expect(last.interrupted, isFalse);
      expect(last.worked, isNotNull);

      expect(
        [for (final event in rig.items()) event.id],
        ['turn-1', 'thought:1', 'call_1', 'call_1', 'message:1', 'message:2'],
      );
    },
  );

  test('the events are numbered on, and never twice', () async {
    final rig = _Rig();
    await rig.ready();
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await rig.ended();

    final seqs = [for (final event in rig.events) event.seq];
    expect(seqs, orderedEquals([...seqs]..sort()));
    expect(seqs.toSet(), hasLength(seqs.length));
  });

  test('a message lands whole, under an id of ours: no streaming', () async {
    final rig = _Rig();
    await rig.ready();
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await rig.ended();

    final messages = [
      for (final event in rig.items())
        if (event.item is AssistantTextItem) event,
    ];
    expect(
      [for (final event in messages) event.id],
      ['message:1', 'message:2'],
    );
    expect(
      [for (final event in messages) (event.item as AssistantTextItem).text],
      ['I read lib/main.dart.', 'It starts the app and the window.'],
    );
    expect([for (final event in messages) event.streaming], [false, false]);
    // dsh commits whole messages: there is nothing to stream, and nothing to
    // complete a second time.
    expect(rig.events.whereType<TextDelta>(), isEmpty);
    expect(rig.events.whereType<ItemCompleted>(), isEmpty);
  });

  test('message ids count on across turns', () async {
    final rig = _Rig();
    await rig.ready();
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'One'));
    await rig.ended();
    rig.kernel.send(KernelTurn(id: 'turn-2', text: 'Two'));
    await rig.ended(turns: 2);

    expect(
      [
        for (final event in rig.items())
          if (event.item is AssistantTextItem) event.id,
      ],
      ['message:1', 'message:2', 'message:3', 'message:4'],
    );
  });

  test('a thought: its own item, not left streaming', () async {
    final rig = _Rig();
    await rig.ready();
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await rig.ended();

    final thought = rig.items().firstWhere((event) => event.id == 'thought:1');
    final item = thought.item as ThinkingItem;
    expect(item.text, 'Reading the file before changing it.');
    expect(item.streaming, isFalse);
    expect(item.seconds, isNotNull);
  });

  test('a tool call: running, then what it returned', () async {
    final rig = _Rig();
    await rig.ready();
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await rig.ended();

    final calls = [
      for (final event in rig.items())
        if (event.id == 'call_1') event.item as ToolCallItem,
    ];
    expect(calls, hasLength(2));
    expect(calls.first.status, ToolStatus.running);
    expect(calls.first.kind, ToolKind.command);
    expect(calls.first.target, 'read lib/main.dart');
    expect(calls.first.label, 'read lib/main.dart');
    expect(calls.first.detail, 'path: lib/main.dart, limit: 40');
    expect(calls.last.status, ToolStatus.succeeded);
    expect(calls.last.output, "import 'package:flutter/material.dart';");
  });

  test('a tool call that failed says so', () async {
    final rig = _Rig();
    await rig.ready();
    rig.transport.toolFails = true;
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await rig.ended();

    final calls = [
      for (final event in rig.items())
        if (event.id == 'call_1') event.item as ToolCallItem,
    ];
    expect(calls.last.status, ToolStatus.failed);
  });

  test('what the turn filled of the context', () async {
    final rig = _Rig();
    await rig.ready();
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await rig.ended();

    final usage = rig.events.whereType<UsageReported>().single.usage;
    expect(usage.window, 512000);
    expect(usage.used, 18240);
  });

  test('a failed turn ends all the same, and the kernel stays ready', () async {
    final rig = _Rig();
    await rig.ready();
    rig.transport.failure = {
      'code': -32603,
      'message': 'Internal error',
      'data': {
        'details': 'turn failed: MISSING_CREDENTIAL: STEPCODEV2_API_KEY',
      },
    };

    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await rig.ended();

    final notice = rig.items().firstWhere(
      (event) => event.id == 'error:turn-1',
    );
    expect((notice.item as NoticeItem).kind, NoticeKind.error);
    // dsh's own reason, without the lead-in it wraps it in.
    expect(
      (notice.item as NoticeItem).text,
      'MISSING_CREDENTIAL: STEPCODEV2_API_KEY',
    );
    expect((rig.events.last as TurnEnded).interrupted, isTrue);
    // A missing key is this turn's failure, not the kernel's.
    expect(rig.kernel.health.status, KernelHealthStatus.ready);
  });

  test('a failure told in the message alone is read too', () async {
    final rig = _Rig();
    await rig.ready();
    rig.transport.failure = {
      'code': -32603,
      'message': 'Internal error: turn failed: the model is unavailable',
    };

    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await rig.ended();

    final notice = rig.items().firstWhere(
      (event) => event.id == 'error:turn-1',
    );
    expect((notice.item as NoticeItem).text, 'the model is unavailable');
  });

  test('stopped by the user: cancelled at dsh, and the turn ended', () async {
    final rig = _Rig();
    await rig.ready();
    rig.transport.holds = true;
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    // At dsh with a call under way when it is stopped.
    await settled(() => rig.items().any((event) => event.id == 'call_1'));

    rig.kernel.cancel();
    await rig.ended();

    expect(rig.transport.requests('session/cancel').single['params'], {
      'sessionId': 'session-mock',
    });
    expect((rig.events.last as TurnEnded).interrupted, isTrue);
    // A call of the turn it was stopped in does not spin for ever: dsh
    // reports no result for it.
    final call = rig.items().lastWhere((event) => event.id == 'call_1');
    expect((call.item as ToolCallItem).status, ToolStatus.failed);
    expect(rig.items().where((event) => event.id == 'message:1'), isEmpty);
  });

  test(
    'pictures sent before the handshake wait for it, and go with the message',
    () async {
      final rig = _Rig();
      // Nothing is known about what this dsh takes until it shakes hands.
      expect(rig.kernel.supportsImages, isFalse);

      rig.kernel.send(
        KernelTurn(id: 'turn-1', text: 'What is this?', images: [_picture()]),
      );
      await rig.ended();

      // The turn starts first, then the message it carries — pictures and
      // all, since the handshake said they can go.
      expect(rig.events.first, isA<TurnStarted>());
      final user = rig.events[1] as ItemUpserted;
      expect(user.id, 'turn-1');
      expect((user.item as UserMessageItem).images, hasLength(1));
      expect(rig.events.last, isA<TurnEnded>());
      expect((rig.events.last as TurnEnded).turnId, 'turn-1');
      expect(rig.transport.requests('session/prompt'), hasLength(1));
      final prompt = rig.transport.lastPrompt!['prompt'] as List;
      expect(
        [for (final block in prompt) (block as Map)['type']],
        ['image', 'text'],
      );
      // Nothing was dropped, so nothing was said about it.
      expect(
        rig.items().where((event) => event.id.startsWith('notice:images:')),
        isEmpty,
      );
    },
  );

  test('a notice about pictures is inside the turn, after it starts', () async {
    final rig = _Rig(image: false);
    await rig.ready();

    rig.kernel.send(
      KernelTurn(id: 'turn-1', text: 'What is this?', images: [_picture()]),
    );
    await rig.ended();

    // TurnStarted, the message, and only then the word about the pictures
    // the route cannot take: never before the turn it is about.
    expect(rig.events.first, isA<TurnStarted>());
    final user = rig.events[1] as ItemUpserted;
    expect(user.id, 'turn-1');
    // What the thread shows is what was sent: no pictures.
    expect((user.item as UserMessageItem).images, isEmpty);
    final notice = rig.events.indexWhere(
      (event) => event is ItemUpserted && event.id == 'notice:images:turn-1',
    );
    expect(notice, greaterThan(1));
    expect(rig.events.last, isA<TurnEnded>());
  });

  test(
    'stopped before dsh has the message: ended here, nothing sent',
    () async {
      final rig = _Rig();
      await rig.ready();

      rig.kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
      rig.kernel.cancel();
      await rig.ended();

      expect((rig.events.last as TurnEnded).interrupted, isTrue);
      expect(rig.transport.requests('session/prompt'), isEmpty);
    },
  );

  test('a message sent while a turn runs waits for it, then runs', () async {
    final rig = _Rig();
    await rig.ready();
    rig.transport.paused = true;

    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'One'));
    await settled(() => rig.items().any((event) => event.id == 'call_1'));
    rig.kernel.send(KernelTurn(id: 'turn-2', text: 'Two'));

    // Apart from the conversation until its turn, and not given dsh while
    // the one before it is in flight (F12).
    expect(rig.transcript.activeTurn, 'turn-1');
    expect(rig.transcript.indexOf('turn-2'), isNull);
    expect([for (final (id, _) in rig.transcript.queued) id], ['turn-2']);
    expect(rig.transport.requests('session/prompt'), hasLength(1));

    rig.transport.resume();
    await settled(() => rig.transcript.activeTurn == 'turn-2');
    // Taken up after what the turn before it said.
    expect(rig.transcript.queued, isEmpty);
    expect(rig.transcript.indexOf('turn-2'), isNotNull);
    expect(
      [for (final start in rig.events.whereType<TurnStarted>()) start.turnId],
      ['turn-1', 'turn-2'],
    );
    final prompts = rig.transport.requests('session/prompt');
    expect(prompts, hasLength(2));
    expect(((prompts.last['params'] as Map)['prompt'] as List).single, {
      'type': 'text',
      'text': 'Two',
    });

    rig.transport.resume();
    await rig.ended(turns: 2);
    expect(rig.transcript.queued, isEmpty);
  });

  test(
    'a queued message can be taken back or moved before those ahead',
    () async {
      final rig = _Rig();
      await rig.ready();
      rig.transport.paused = true;
      rig.kernel.send(KernelTurn(id: 'turn-1', text: 'One'));
      await settled(() => rig.items().any((event) => event.id == 'call_1'));
      rig.kernel
        ..send(KernelTurn(id: 'turn-2', text: 'Two'))
        ..send(KernelTurn(id: 'turn-3', text: 'Three'))
        ..send(KernelTurn(id: 'turn-4', text: 'Four'));

      List<String> queued() => [
        for (final (id, _) in rig.transcript.queued) id,
      ];
      expect(queued(), ['turn-2', 'turn-3', 'turn-4']);

      expect(await rig.kernel.cancelQueued('turn-3'), isTrue);
      expect(queued(), ['turn-2', 'turn-4']);
      // One already running is not queued to take back.
      expect(await rig.kernel.cancelQueued('turn-1'), isFalse);

      rig.kernel.moveQueued('turn-4', 0);
      expect(queued(), ['turn-4', 'turn-2']);

      // The order moved is the order dsh is given, once the turn before ends.
      rig.transport.resume();
      await settled(() => rig.transcript.activeTurn == 'turn-4');
      rig.transport.resume();
      await settled(() => rig.transcript.activeTurn == 'turn-2');
      rig.transport.resume();
      await rig.ended(turns: 3);
      expect(_prompts(rig), ['One', 'Four', 'Two']);
    },
  );

  test(
    'a message sent now while the session is being made waits for it',
    () async {
      final rig = _Rig();
      await rig.ready();

      rig.kernel
        ..send(KernelTurn(id: 'turn-1', text: 'One'))
        ..send(KernelTurn(id: 'turn-2', text: 'Two'))
        // The first prompt is not at dsh yet: its session is still being made.
        ..sendQueuedNow('turn-2');

      await rig.ended(turns: 2);

      // One session for both, and the first turn never reached dsh.
      expect(rig.transport.requests('session/new'), hasLength(1));
      expect(_prompts(rig), ['Two']);
    },
  );

  test('a queued message sent now stops the turn running for it', () async {
    final rig = _Rig();
    await rig.ready();
    rig.transport.paused = true;
    rig.kernel.send(KernelTurn(id: 'turn-1', text: 'One'));
    await settled(() => rig.items().any((event) => event.id == 'call_1'));
    rig.kernel
      ..send(KernelTurn(id: 'turn-2', text: 'Two'))
      ..send(KernelTurn(id: 'turn-3', text: 'Three'));

    rig.kernel.sendQueuedNow('turn-3');
    expect(rig.transport.requests('session/cancel'), hasLength(1));

    await settled(() => rig.transcript.activeTurn == 'turn-3');
    // The one stopped ended there; those behind it keep their order.
    expect(rig.events.whereType<TurnEnded>().single.interrupted, isTrue);
    expect([for (final (id, _) in rig.transcript.queued) id], ['turn-2']);

    rig.transport.resume();
    await settled(() => rig.transcript.activeTurn == 'turn-2');
    rig.transport.resume();
    await rig.ended(turns: 3);
    expect(_prompts(rig), ['One', 'Three', 'Two']);
  });
}

/// The texts of the prompts dsh was given, in order.
List<String> _prompts(_Rig rig) => [
  for (final request in rig.transport.requests('session/prompt'))
    for (final block in ((request['params'] as Map)['prompt'] as List))
      '${(block as Map)['text']}',
];

/// A kernel on a mock process, and what it reported: the conversation's
/// events, without the changers of its own state.
class _Rig {
  /// [image]: whether the route the mock plays takes pictures.
  _Rig({this.image = true});

  final bool image;

  late final DshKernel kernel = DshKernel(
    KernelRegistry.dsh,
    const KernelContext(cwd: '/project'),
    start: _start,
    locate: () async => const DshInstall(
      node: 'node',
      binJs: '/opt/dsh/lib/bin.js',
      version: '0.2.0-rc.2',
      packageDir: '/opt/dsh',
    ),
    environment: () async => const {'PATH': '/usr/bin'},
    sessions: MemoryDshSessionStore(),
    // The route and its credential, served rather than looked for: nothing
    // here reads this machine's `~/.dsh`, and no `notice:credential:*` opens
    // the conversation ahead of the turn.
    route: testDshRoute,
    credentials: (_) async => true,
  )..events.listen(_receive);

  final List<KernelEvent> events = [];
  final Transcript transcript = Transcript();
  late MockDshTransport transport;

  void _receive(KernelEvent event) {
    transcript.apply(event);
    if (event is! KernelInfoChanged) events.add(event);
  }

  Future<DshTransport> _start(DshLaunch launch) async {
    return transport = MockDshTransport(image: image);
  }

  /// Its handshake done.
  Future<void> ready() async {
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
  }

  /// The items it put, in the order it put them.
  List<ItemUpserted> items() => events.whereType<ItemUpserted>().toList();

  /// Waits for the [turns] turns sent to have ended.
  Future<void> ended({int turns = 1}) =>
      settled(() => events.whereType<TurnEnded>().length == turns);
}

/// A picture to send: the bytes mean nothing to the mock.
ImageAttachment _picture() => ImageAttachment(
  bytes: Uint8List.fromList([1, 2, 3]),
  mediaType: 'image/png',
);

/// Runs the event loop until [done] holds, giving up after a while: what the
/// kernel does off the wire is asynchronous, and the patch it writes is a
/// file on disk, which needs more than a turn of the loop.
Future<void> settled(bool Function() done) async {
  for (var turns = 0; turns < 500 && !done(); turns++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue, reason: 'the kernel never got there');
}

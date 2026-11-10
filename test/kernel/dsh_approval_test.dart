import 'dart:async';
import 'dart:typed_data';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_locate.dart';
import 'package:baocode/kernel/dsh/dsh_notices.dart';
import 'package:baocode/kernel/dsh/dsh_sessions.dart';
import 'package:baocode/kernel/dsh/dsh_transport.dart';
import 'package:baocode/kernel/dsh/mock_dsh_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_route_fixture.dart';

/// What dsh asks the user for, and what the conversation says of its own: an
/// approval held as a question and answered in dsh's own words, the dsh older
/// than the one probed, a route without its key, and pictures left out.
/// Nothing is started: the transport is [_ScriptedDsh] or
/// [MockDshTransport].
void main() {
  test(
    'the approval dsh asks for: a pending question, the tool, its reason',
    () async {
      final dsh = _ScriptedDsh();
      final rig = _Rig(transport: () => dsh);
      final kernel = rig.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);

      kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
      await settled(() => events.whereType<InteractionRequested>().isNotEmpty);

      final request =
          events.whereType<InteractionRequested>().single.request
              as ApprovalRequest;
      // Named after the request, numbered: dsh may ask about one tool twice.
      expect(request.id, 'approval:call_1:1');
      // The title is what the panel draws: `toolName` goes nowhere (§5.6).
      expect(request.title, 'run npm test');
      expect(request.reason, 'Runs the project tests');
      // dsh offers `allow-once` only: a third button would have nothing behind
      // it.
      expect(request.alwaysAllowLabel, isNull);
      // Still dsh's to answer: the turn waits for the user, not for the kernel.
      expect(dsh.answers, isEmpty);
      expect(events.whereType<TurnEnded>(), isEmpty);
    },
  );

  test(
    'allowed once: dsh is told allow-once, and the question is resolved',
    () async {
      final dsh = _ScriptedDsh();
      final rig = _Rig(transport: () => dsh);
      final kernel = rig.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
      await settled(() => events.whereType<InteractionRequested>().isNotEmpty);
      final id = events.whereType<InteractionRequested>().single.request.id;

      kernel.answer(id, const ApprovalAnswer(ApprovalDecision.allowOnce));

      // The shape dsh reads, word for word (§5.6).
      expect(dsh.answers.single, {
        'jsonrpc': '2.0',
        'id': 'perm-1',
        'result': {
          'outcome': {'outcome': 'selected', 'optionId': 'allow-once'},
        },
      });
      expect(
        [
          for (final event in events.whereType<InteractionResolved>())
            event.requestId,
        ],
        [id],
      );
      // And the turn ends by itself once dsh was answered.
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);
      expect((events.last as TurnEnded).interrupted, isFalse);
    },
  );

  test(
    'refused: dsh is told reject-once, and what was written is dropped',
    () async {
      final dsh = _ScriptedDsh();
      final rig = _Rig(transport: () => dsh);
      final kernel = rig.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
      await settled(() => events.whereType<InteractionRequested>().isNotEmpty);
      final id = events.whereType<InteractionRequested>().single.request.id;

      kernel.answer(
        id,
        const ApprovalAnswer(
          ApprovalDecision.deny,
          message: 'Use npm ci instead',
        ),
      );

      expect(dsh.answers.single['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'reject-once'},
      });
      // dsh has nowhere to put the words, so they are not sent.
      expect('${dsh.answers.single}', isNot(contains('npm ci')));
      expect(events.whereType<InteractionResolved>(), hasLength(1));
    },
  );

  test('a tool call with no justification: dsh gave no reason', () async {
    final dsh = _ScriptedDsh(reason: false);
    final rig = _Rig(transport: () => dsh);
    final kernel = rig.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
    await settled(() => events.whereType<InteractionRequested>().isNotEmpty);

    final request =
        events.whereType<InteractionRequested>().single.request
            as ApprovalRequest;
    expect(request.title, 'run npm test');
    expect(request.reason, 'dsh did not give a reason');
  });

  test('an approval before its tool call: plain words, and no crash', () async {
    final dsh = _ScriptedDsh(ask: _Ask.beforeToolCall);
    final rig = _Rig(transport: () => dsh);
    final kernel = rig.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
    await settled(() => events.whereType<InteractionRequested>().isNotEmpty);

    final request =
        events.whereType<InteractionRequested>().single.request
            as ApprovalRequest;
    expect(request.title, 'Approval needed');
    expect(request.reason, 'dsh did not give a reason');
  });

  test(
    'stopped by the user: the question is answered cancelled, and resolved',
    () async {
      final dsh = _ScriptedDsh();
      final rig = _Rig(transport: () => dsh);
      final kernel = rig.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
      await settled(() => events.whereType<InteractionRequested>().isNotEmpty);
      final id = events.whereType<InteractionRequested>().single.request.id;

      kernel.cancel();
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);

      expect(dsh.answers.single, {
        'jsonrpc': '2.0',
        'id': 'perm-1',
        'result': {
          'outcome': {'outcome': 'cancelled'},
        },
      });
      expect(
        [
          for (final event in events.whereType<InteractionResolved>())
            event.requestId,
        ],
        [id],
      );
      // The question resolved last: the turn ends first, then what it was
      // waiting on is let go.
      expect(events.whereType<TurnEnded>().single.interrupted, isTrue);
      expect(events.last, isA<InteractionResolved>());
    },
  );

  test('an answer after the turn stopped is ignored', () async {
    final dsh = _ScriptedDsh();
    final rig = _Rig(transport: () => dsh);
    final kernel = rig.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
    await settled(() => events.whereType<InteractionRequested>().isNotEmpty);
    final id = events.whereType<InteractionRequested>().single.request.id;
    kernel.cancel();
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);
    final written = dsh.answers.length;

    // Late by a moment: dsh has the cancelled answer, and the panel is gone.
    kernel.answer(id, const ApprovalAnswer(ApprovalDecision.allowOnce));

    expect(dsh.answers, hasLength(written));
    expect(dsh.answers.single['result'], {
      'outcome': {'outcome': 'cancelled'},
    });
    expect(events.whereType<InteractionResolved>(), hasLength(1));
  });

  test('an answer for a request never asked is ignored', () async {
    final dsh = _ScriptedDsh();
    final rig = _Rig(transport: () => dsh);
    final kernel = rig.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
    await settled(() => events.whereType<InteractionRequested>().isNotEmpty);

    kernel.answer(
      'approval:nothing:99',
      const ApprovalAnswer(ApprovalDecision.allowOnce),
    );

    expect(dsh.answers, isEmpty);
    expect(events.whereType<InteractionResolved>(), isEmpty);
  });

  test(
    'disposed with a question open: answered cancelled, then let go',
    () async {
      final dsh = _ScriptedDsh();
      final rig = _Rig(transport: () => dsh);
      final kernel = rig.kernel();
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);
      kernel.send(KernelTurn(id: 'turn-1', text: 'Run the tests'));
      await settled(() => events.whereType<InteractionRequested>().isNotEmpty);
      final id = events.whereType<InteractionRequested>().single.request.id;

      kernel.dispose();
      await kernel.stopped;

      expect(dsh.answers.single['result'], {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(dsh.answers.single['id'], 'perm-1');
      expect(
        [
          for (final event in events.whereType<InteractionResolved>())
            event.requestId,
        ],
        [id],
      );
      expect(dsh.gone, isTrue);
    },
  );

  test('a dsh older than the one probed: said once, and still run', () async {
    final rig = _Rig(version: '0.1.9');
    final kernel = rig.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);

    final notice = _item(events, 'notice:version').item as NoticeItem;
    expect(notice.kind, NoticeKind.warning);
    expect(
      notice.text,
      'dsh 0.1.9 is older than the version BaoCode was tested with '
      '(0.2.0-rc.2); some behaviour may differ.',
    );
    expect(kernel.health.status, KernelHealthStatus.ready);

    // Started again: the warning is not said a second time.
    kernel.release();
    await rig.transports.single.exited;
    kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);
    expect(rig.transports, hasLength(2));
    expect(
      events.whereType<ItemUpserted>().where((e) => e.id == 'notice:version'),
      hasLength(1),
    );
  });

  test('the version probed, and a key for it: nothing is said', () async {
    final rig = _Rig();
    final kernel = rig.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);

    expect(events.whereType<ItemUpserted>(), isEmpty);
  });

  test(
    'a route without its credential: said once, and the process still starts',
    () async {
      final rig = _Rig();
      // dsh on this machine is not the dsh of the test: the refs the route can
      // resolve are given, so that no preflight reads the real store.
      final kernel = rig.kernel(credentials: (_) async => false);
      final events = _listen(kernel);
      kernel.prepare();
      await settled(() => kernel.health.status == KernelHealthStatus.ready);

      final notice =
          _item(events, 'notice:credential:STEPCODEV2_API_KEY').item
              as NoticeItem;
      expect(notice.kind, NoticeKind.error);
      expect(
        notice.text,
        'dsh has no credential for STEPCODEV2_API_KEY; add it in dsh web '
        '(Models) or set the environment variable.',
      );
      // Starting is not what a missing key stops: the turns are what fails.
      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(rig.launches, hasLength(1));

      // Started again: still one word about it.
      kernel.release();
      await rig.transports.single.exited;
      kernel.send(KernelTurn(id: 'turn-1', text: 'Hello'));
      await settled(() => events.whereType<TurnEnded>().isNotEmpty);
      expect(
        events.whereType<ItemUpserted>().where(
          (event) => event.id.startsWith('notice:credential:'),
        ),
        hasLength(1),
      );
    },
  );

  test('pictures the route cannot take are left out, and said once', () async {
    final rig = _Rig(image: false);
    final kernel = rig.kernel();
    final events = _listen(kernel);
    kernel.prepare();
    await settled(() => kernel.health.status == KernelHealthStatus.ready);
    expect(kernel.supportsImages, isFalse);

    final images = [
      ImageAttachment(
        bytes: Uint8List.fromList([1, 2, 3]),
        mediaType: 'image/png',
      ),
    ];
    kernel.send(
      KernelTurn(id: 'turn-1', text: 'What is this?', images: images),
    );
    await settled(() => events.whereType<TurnEnded>().isNotEmpty);

    final notice = _item(events, 'notice:images:turn-1').item as NoticeItem;
    expect(notice.kind, NoticeKind.warning);
    expect(
      notice.text,
      'This dsh route cannot take images; they were left out.',
    );
    // Not sent to a model that never saw them.
    final mock = rig.transports.single as MockDshTransport;
    expect(mock.lastPrompt!['prompt'], [
      {'type': 'text', 'text': 'What is this?'},
    ]);
    // The next turn is its own: said again there, once.
    kernel.send(KernelTurn(id: 'turn-2', text: 'And this?', images: images));
    await settled(() => events.whereType<TurnEnded>().length == 2);
    expect(
      events.whereType<ItemUpserted>().where(
        (event) => event.id.startsWith('notice:images:'),
      ),
      hasLength(2),
    );
  });

  test('a missing key is read from the store by its name, never its value', () {
    const store = '''
version: 1
refs:
  STEPCODE_API_KEY: sk-one
  "STEPCODEV2_API_KEY": sk-two
records:
  STEPCODEV2_API_KEY: 2026-11-09
''';
    expect(DshCredentials.names(store, 'STEPCODEV2_API_KEY'), isTrue);
    expect(DshCredentials.names(store, 'OPENROUTER_API_KEY'), isFalse);
    // A name only under `records` is not a key.
    expect(
      DshCredentials.names(
        'refs: {}\nrecords:\n  STEPCODEV2_API_KEY: 1\n',
        'STEPCODEV2_API_KEY',
      ),
      isFalse,
    );
  });
}

/// dsh as far as an approval needs it: the handshake, a session, and a turn
/// that stops at the tool call it asks about — held until the kernel answers,
/// or the turn is stopped.
class _ScriptedDsh implements DshTransport {
  _ScriptedDsh({this.ask = _Ask.afterToolCall, this.reason = true});

  /// When the question is asked: after the tool call it is about, or before
  /// it (which is what the fallback words are for).
  final _Ask ask;

  /// Whether the tool call says why it asks.
  final bool reason;

  final StreamController<Map<String, Object?>> _out =
      StreamController<Map<String, Object?>>.broadcast();
  final Completer<void> _exit = Completer<void>();

  /// Answered when the kernel answered the question, or stopped the turn.
  final Completer<void> _settled = Completer<void>();

  /// Every message the kernel wrote, in order.
  final List<Map<String, Object?>> written = [];

  static const _sessionId = 'session-mock';

  Object? _promptId;

  /// The letters the answers the kernel gave, as dsh reads them: a response
  /// has an id and no method.
  List<Map<String, Object?>> get answers => [
    for (final message in written)
      if (message.containsKey('id') && !message.containsKey('method')) message,
  ];

  /// What the next `session/prompt` asked: its params.
  Map<String, Object?>? get lastPrompt {
    for (final message in written.reversed) {
      if (message['method'] == 'session/prompt') {
        return (message['params'] as Map?)?.cast<String, Object?>();
      }
    }
    return null;
  }

  /// Whether the process is gone already.
  bool get gone => _exit.isCompleted;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  Future<void> get exited => _exit.future;

  @override
  String? get executable => 'node';

  void _emit(Map<String, Object?> message) {
    if (!_out.isClosed) _out.add(message);
  }

  void _respond(Object? id, Map<String, Object?> result) =>
      _emit({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _notify(String kind, Map<String, Object?> update) => _emit({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {
      'sessionId': _sessionId,
      'update': {'sessionUpdate': kind, ...update},
    },
  });

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    switch (message['method']) {
      case 'initialize':
        _respond(message['id'], {
          'protocolVersion': 1,
          'agentInfo': {'name': 'deepseek-harness-acp', 'version': '0.0.1'},
          'agentCapabilities': {
            'promptCapabilities': {'image': false},
          },
        });
      case 'session/new':
        _respond(message['id'], {
          'sessionId': _sessionId,
          'configOptions': <Object?>[],
        });
      case 'session/prompt':
        unawaited(_prompt(message['id']));
      case 'session/cancel':
        _cancel();
      case null:
        // The answer to the question it asked: it may go on.
        if (!_settled.isCompleted) _settled.complete();
    }
  }

  Future<void> _prompt(Object? id) async {
    _promptId = id;
    if (ask == _Ask.beforeToolCall) _askLeave();
    _notify('tool_call', {
      'toolCallId': 'call_1',
      'title': 'run npm test',
      'kind': 'other',
      'status': 'in_progress',
      'rawInput': {
        if (reason) 'justification': 'Runs the project tests',
        'command': 'npm test',
      },
    });
    if (ask == _Ask.afterToolCall) _askLeave();
    await _settled.future;
    // Stopped meanwhile: the cancel answered the prompt already.
    if (_promptId != id) return;
    _promptId = null;
    _respond(id, {'stopReason': 'end_turn'});
  }

  /// dsh asking leave to step outside its sandbox: the tool call, and nothing
  /// more (F10).
  void _askLeave() {
    _emit({
      'jsonrpc': '2.0',
      'id': 'perm-1',
      'method': 'session/request_permission',
      'params': {
        'sessionId': _sessionId,
        'toolCall': {'toolCallId': 'call_1'},
        'options': [
          {'optionId': 'allow-once', 'kind': 'allow_once'},
          {'optionId': 'reject-once', 'kind': 'reject_once'},
        ],
      },
    });
  }

  void _cancel() {
    final id = _promptId;
    _promptId = null;
    if (!_settled.isCompleted) _settled.complete();
    if (id != null) _respond(id, {'stopReason': 'cancelled'});
  }

  /// The process ending (or being closed): what the transport says last.
  void exit({int code = 0, String stderr = ''}) {
    if (_exit.isCompleted) return;
    _emit(DshExit.message(code, stderr));
    unawaited(_out.close());
    scheduleMicrotask(() {
      if (!_exit.isCompleted) _exit.complete();
    });
  }

  @override
  void close() => exit();
}

/// Where the question is asked, against the tool call it is about.
enum _Ask { afterToolCall, beforeToolCall }

/// dsh on this machine, as much of it as a kernel needs: where it is, what it
/// is started with, and the process each start gets. No dsh runs.
class _Rig {
  _Rig({
    this.version = '0.2.0-rc.2',
    bool image = true,
    DshTransport Function()? transport,
  }) : _make = transport ?? (() => MockDshTransport(image: image));

  final String version;
  final DshTransport Function() _make;

  /// Every start, in order.
  final List<DshLaunch> launches = [];

  /// The process each start got, in order.
  final List<DshTransport> transports = [];

  Future<DshInstall?> locate() async => DshInstall(
    node: 'node',
    binJs: '/opt/dsh/lib/bin.js',
    version: version,
    packageDir: '/opt/dsh',
  );

  Future<DshTransport> start(DshLaunch launch) async {
    launches.add(launch);
    final transport = _make();
    transports.add(transport);
    return transport;
  }

  /// A kernel over this fake dsh. The refs its route can resolve are given
  /// here rather than read from the machine's `~/.dsh`: no test reads the
  /// user's own store.
  DshKernel kernel({DshCredentialCheck? credentials}) => DshKernel(
    KernelRegistry.dsh,
    const KernelContext(cwd: '/project'),
    start: start,
    locate: locate,
    environment: () async => const {'PATH': '/usr/bin'},
    sessions: MemoryDshSessionStore(),
    route: testDshRoute,
    credentials: credentials ?? (_) async => true,
  );
}

/// Everything [kernel] reports, as it reports it.
List<KernelEvent> _listen(AgentKernel kernel) {
  final events = <KernelEvent>[];
  kernel.events.listen(events.add);
  return events;
}

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

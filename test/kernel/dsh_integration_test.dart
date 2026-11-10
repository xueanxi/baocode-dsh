import 'dart:async';

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
import 'package:flutter_test/flutter_test.dart';

/// One conversation across the tickets that built the DSH kernel: prepare and
/// its handshake (T2), the first message making the session (T2), a turn with
/// a tool call and an approval answered (T3), a later turn (T2), a failed turn
/// (T3), letting the process go, resuming the session (T2), and dispose (T2).
///
/// Everything on the wire comes from [MockDshTransport]; the one thing it does
/// not play — dsh's `session/request_permission` — is added by [_ApprovalDsh],
/// which forwards the mock for everything else. No dsh runs, no token is
/// spent, and the credentials the preflight would look for are given here, so
/// no test reads the user's own `~/.dsh`.
void main() {
  test('a conversation, from prepare to dispose, in the order it happens', () async {
    final dsh = _FakeDsh();
    final kernel = dsh.kernel();
    final events = _listen(kernel);

    // --- Prepare: a handshake, and no session yet ---------------------------
    kernel.prepare();
    await settled(
      () => kernel.health.status == KernelHealthStatus.ready,
      'the handshake',
    );

    expect(dsh.transports.single.mock.requests('initialize').single['params'], {
      'protocolVersion': 1,
    });
    // An empty session would be left in ~/.dsh for every conversation opened.
    expect(dsh.transport.mock.requests('session/new'), isEmpty);
    expect(kernel.sessionId, isNull);
    expect(events, isEmpty);
    final launch = dsh.launches.single;
    expect(launch.cwd, '/project');
    expect(launch.permissionMode, 'workspace-write');
    // Before the first message all three tiers are on offer; dsh runs the one
    // picked when the session is made (F22).
    expect(
      [for (final option in kernel.permission.options) option.id],
      ['read-only', 'workspace-write', 'danger-full-access'],
    );

    // --- The first message makes the session, in the project ----------------
    kernel.send(KernelTurn(id: 'turn-1', text: 'Change the composer'));
    await settled(
      () => dsh.transport.mock.requests('session/prompt').isNotEmpty,
      'the first prompt to go out',
    );
    await settled(
      () =>
          events.any((event) => event is ItemUpserted && event.id == 'call_1'),
      'the tool call card',
    );
    // The tool call went before the question, as dsh sends them (F10).
    dsh.transport.askPermission('call_1');
    await settled(
      () => events.whereType<InteractionRequested>().isNotEmpty,
      'the approval dsh asked for',
    );

    expect(dsh.transport.mock.requests('session/new').single['params'], {
      'cwd': '/project',
      // Required, and really started when not empty (F4).
      'mcpServers': <Object?>[],
    });
    expect(kernel.sessionId, 'session-mock');
    expect(kernel.health.status, KernelHealthStatus.ready);
    // Locked by the session: dsh writes the tier into it, and resuming does
    // not change it (F16).
    expect(
      [for (final option in kernel.permission.options) option.id],
      ['workspace-write'],
    );

    // A turn starts with its own message, under the turn's id, before anything
    // the agent did (§5.5).
    expect(events.first, isA<TurnStarted>());
    expect((events.first as TurnStarted).turnId, 'turn-1');
    final user = events[1] as ItemUpserted;
    expect(user.id, 'turn-1');
    expect((user.item as UserMessageItem).text, 'Change the composer');

    // --- The approval dsh asked for, in the turn's own words ----------------
    final request =
        events.whereType<InteractionRequested>().single.request
            as ApprovalRequest;
    // The request names no tool and no reason (F10): both are read from the
    // tool call it went with. The mock's call gives no justification, so the
    // fallback is said.
    expect(request.id, 'approval:call_1:1');
    expect(request.title, 'read lib/main.dart');
    expect(request.toolName, 'read lib/main.dart');
    expect(request.reason, 'dsh did not give a reason');
    // dsh offers allow-once only: no third button with nothing behind it.
    expect(request.alwaysAllowLabel, isNull);
    // The turn waits for the user, not for the kernel.
    expect(events.whereType<TurnEnded>(), isEmpty);

    kernel.answer(request.id, const ApprovalAnswer(ApprovalDecision.allowOnce));

    // The shape dsh reads, word for word (§5.6).
    expect(
      dsh.transport.mock.written.singleWhere(
        (message) =>
            message['id'] == 'perm-1' && !message.containsKey('method'),
      ),
      {
        'jsonrpc': '2.0',
        'id': 'perm-1',
        'result': {
          'outcome': {'outcome': 'selected', 'optionId': 'allow-once'},
        },
      },
    );
    expect(
      [
        for (final event in events.whereType<InteractionResolved>())
          event.requestId,
      ],
      [request.id],
    );

    // --- The turn ends once, and its tool call did complete -----------------
    await settled(
      () => events.whereType<TurnEnded>().isNotEmpty,
      'the first turn to end',
    );
    final firstEnd = events.whereType<TurnEnded>().single;
    expect(firstEnd.turnId, 'turn-1');
    expect(firstEnd.interrupted, isFalse);
    expect(events.last, same(firstEnd));
    // Resolved before the answer let the turn finish.
    expect(
      events.indexOf(events.whereType<InteractionResolved>().single),
      lessThan(events.indexOf(firstEnd)),
    );
    expect(
      [
        for (final event in events.whereType<ItemUpserted>())
          if (event.item is ToolCallItem) (event.item as ToolCallItem).status,
      ],
      [ToolStatus.running, ToolStatus.succeeded],
    );

    // --- A later turn, plain text, the same session -------------------------
    kernel.send(KernelTurn(id: 'turn-2', text: 'And the window?'));
    await settled(
      () => events.whereType<TurnEnded>().length == 2,
      'the second turn to end',
    );

    final secondStart = events.whereType<TurnStarted>().firstWhere(
      (event) => event.turnId == 'turn-2',
    );
    expect(events[events.indexOf(secondStart) + 1], isA<ItemUpserted>());
    expect(
      (events[events.indexOf(secondStart) + 1] as ItemUpserted).id,
      'turn-2',
    );
    expect(events.whereType<InteractionRequested>(), hasLength(1));
    expect(events.whereType<InteractionResolved>(), hasLength(1));
    final secondEnd = events.whereType<TurnEnded>().last;
    expect(secondEnd.turnId, 'turn-2');
    expect(secondEnd.interrupted, isFalse);
    expect(dsh.transport.mock.requests('session/prompt'), hasLength(2));
    expect(dsh.transport.mock.requests('session/new'), hasLength(1));
    // One TurnEnded per turn started: the conversation never stays busy.
    expect(
      events.whereType<TurnStarted>().length,
      events.whereType<TurnEnded>().length,
    );

    // --- A failed turn still ends, and the kernel stays ready --------------
    dsh.transport.mock.failure = {
      'code': -32603,
      'message': 'Internal error',
      'data': {
        'details': 'turn failed: MISSING_CREDENTIAL: STEPCODEV2_API_KEY',
      },
    };
    kernel.send(KernelTurn(id: 'turn-3', text: 'Try again'));
    await settled(
      () => events.whereType<TurnEnded>().length == 3,
      'the failed turn to end',
    );

    final error = events.whereType<ItemUpserted>().firstWhere(
      (event) => event.id == 'error:turn-3',
    );
    expect((error.item as NoticeItem).kind, NoticeKind.error);
    // dsh's own words, without its `turn failed:` lead-in.
    expect(
      (error.item as NoticeItem).text,
      'MISSING_CREDENTIAL: STEPCODEV2_API_KEY',
    );
    final thirdEnd = events.whereType<TurnEnded>().last;
    expect(thirdEnd.turnId, 'turn-3');
    expect(thirdEnd.interrupted, isTrue);
    expect(events.last, same(thirdEnd));
    // A missing key is this turn's failure, not the kernel's (§5.9).
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(
      events.whereType<TurnStarted>().length,
      events.whereType<TurnEnded>().length,
    );

    // --- Released: the process goes, the session stays ----------------------
    final first = dsh.transport;
    final beforeRestart = events.last.seq;
    kernel.release();
    await first.exited;
    expect(kernel.health.status, KernelHealthStatus.idle);
    // dsh keeps the session on disk: the next process resumes it (F25).
    expect(kernel.sessionId, 'session-mock');

    // --- Prepared again, then resumed on the next message -------------------
    kernel.prepare();
    await settled(
      () => kernel.health.status == KernelHealthStatus.ready,
      'the next handshake',
    );
    expect(dsh.transports, hasLength(2));
    // Preparing is a handshake only: no session is made or resumed yet.
    expect(dsh.transport.mock.requests('session/new'), isEmpty);
    expect(dsh.transport.mock.requests('session/resume'), isEmpty);
    expect(kernel.permission.options, hasLength(1));

    kernel.send(KernelTurn(id: 'turn-4', text: 'Go on'));
    await settled(
      () => events.whereType<TurnEnded>().length == 4,
      'the resumed turn to end',
    );

    expect(dsh.transport.mock.requests('session/new'), isEmpty);
    expect(dsh.transport.mock.requests('session/resume').single['params'], {
      'sessionId': 'session-mock',
      'cwd': '/project',
    });
    expect((events.whereType<TurnEnded>().last).turnId, 'turn-4');
    expect((events.whereType<TurnEnded>().last).interrupted, isFalse);
    // Numbered on past the restart, never from zero again.
    expect(events.last.seq, greaterThan(beforeRestart));
    expect(kernel.health.status, KernelHealthStatus.ready);
    // Every event after the first is numbered after the one before it.
    final seqs = [for (final event in events) event.seq];
    expect(seqs, orderedEquals([...seqs]..sort()));
    expect(seqs.toSet(), hasLength(seqs.length));

    // --- Disposed: the process is gone, and nothing is left running ---------
    kernel.dispose();
    await kernel.stopped;
    expect(dsh.transport.mock.gone, isTrue);
  });
}

/// dsh on this machine, as much of it as the conversation needs: where it is,
/// what each process is started with, and the process itself. No dsh runs.
class _FakeDsh {
  /// Every start, in order.
  final List<DshLaunch> launches = [];

  /// The process each start got, in order.
  final List<_ApprovalDsh> transports = [];

  _ApprovalDsh get transport => transports.last;

  Future<DshInstall?> locate() async => const DshInstall(
    node: 'node',
    binJs: '/opt/dsh/lib/bin.js',
    version: '0.2.0-rc.2',
    packageDir: '/opt/dsh',
  );

  Future<DshTransport> start(DshLaunch launch) async {
    launches.add(launch);
    final transport = _ApprovalDsh(
      MockDshTransport(),
      // The approval turn is the first process's.
      holdsAnswer: transports.isEmpty,
    );
    transports.add(transport);
    return transport;
  }

  DshKernel kernel() => DshKernel(
    KernelRegistry.dsh,
    const KernelContext(cwd: '/project'),
    start: start,
    locate: locate,
    environment: () async => const {'PATH': '/usr/bin'},
    sessions: MemoryDshSessionStore(),
    // Named rather than looked for: no test reads the user's own ~/.dsh.
    credentials: () async => {'STEPCODEV2_API_KEY'},
  );
}

/// [MockDshTransport], plus the one server request it does not play: dsh
/// asking leave to run a tool call. It forwards the mock for everything else,
/// and keeps the prompt's answer back until the approval is answered — the
/// turn would otherwise end before the user could.
class _ApprovalDsh implements DshTransport {
  _ApprovalDsh(this.mock, {this.holdsAnswer = false})
    : _holdAnswer = holdsAnswer {
    _mockSubscription = mock.messages.listen(_forward);
  }

  final MockDshTransport mock;

  /// Whether the process is one a question is asked in, and so has its
  /// prompt's answer kept back until it is answered. Only the process the
  /// approval turn runs in: a later one would wait for ever for a question
  /// no one asks.
  final bool holdsAnswer;

  /// What the kernel gets: the mock's messages, and dsh's question.
  final StreamController<Map<String, Object?>> _out =
      StreamController<Map<String, Object?>>.broadcast();

  /// The stream of the process it forwards, cancelled with it.
  late final StreamSubscription<Map<String, Object?>> _mockSubscription;

  /// The prompt's answer, held until the approval asked in the turn is
  /// answered: dsh asks before the turn is done, not after.
  final List<Map<String, Object?>> _held = [];
  Object? _promptId;
  bool _holdAnswer;
  int _asked = 0;

  void _forward(Map<String, Object?> message) {
    if (_holdAnswer &&
        message['method'] == null &&
        message['id'] != null &&
        message['id'] == _promptId) {
      _held.add(message);
      return;
    }
    if (!_out.isClosed) _out.add(message);
  }

  /// dsh asking leave to run [toolCallId]: the shape the bridge sends (F10).
  void askPermission(String toolCallId) {
    if (_out.isClosed) return;
    _out.add({
      'jsonrpc': '2.0',
      'id': 'perm-${++_asked}',
      'method': 'session/request_permission',
      'params': {
        'sessionId': 'session-mock',
        'toolCall': {'toolCallId': toolCallId},
        'options': [
          {'optionId': 'allow-once', 'kind': 'allow_once'},
          {'optionId': 'reject-once', 'kind': 'reject_once'},
        ],
      },
    });
  }

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  void write(Map<String, Object?> message) {
    mock.write(message);
    if (message['method'] == 'session/prompt') {
      _promptId = message['id'];
    }
    if (message['method'] == null && message.containsKey('result')) {
      // The answer to the approval: the turn may be over now.
      _holdAnswer = false;
      for (final held in [..._held]) {
        if (!_out.isClosed) _out.add(held);
      }
      _held.clear();
    }
  }

  @override
  Future<void> get exited => mock.exited;

  @override
  String? get executable => mock.executable;

  @override
  void close() {
    unawaited(_mockSubscription.cancel());
    if (!_out.isClosed) unawaited(_out.close());
    mock.close();
  }
}

/// Everything [kernel] reports, as it reports it: the conversation's events,
/// without the changers of its own state.
List<KernelEvent> _listen(AgentKernel kernel) {
  final events = <KernelEvent>[];
  kernel.events.listen((event) {
    if (event is! KernelInfoChanged) events.add(event);
  });
  return events;
}

/// Runs the event loop until [done] holds, giving up after a while: what the
/// kernel does off the wire is asynchronous, and the patch it writes is a file
/// on disk, which needs more than a turn of the loop.
Future<void> settled(bool Function() done, [String? what]) async {
  for (var turns = 0; turns < 500 && !done(); turns++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue, reason: 'the kernel never got there: ${what ?? ''}');
}

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_edit_bridge.dart';
import 'package:baocode/kernel/dsh/mock_dsh_transport.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/workspace/agent_title.dart' show askedText;
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the UI seams rest on now that two kernels are offered: where the
/// dsh one is offered at all, what a picker leaves, which pictures a
/// conversation takes, and what its titles are summed from.
void main() {
  group('DSH is offered only where it can work', () {
    bool available(KernelContext context) =>
        KernelRegistry.dsh.available!(context);

    test('in one project folder of this machine', () {
      expect(available(const KernelContext(cwd: '/p/baocode')), isTrue);
    });

    test('not in a multi-folder workspace', () {
      expect(
        available(
          KernelContext(
            cwd: '/data/workspaces/w1',
            workspace: () => const KernelWorkspace(folders: ['/a', '/b']),
          ),
        ),
        isFalse,
      );
    });

    test('not in a project of another machine', () {
      expect(
        available(const KernelContext(cwd: 'ssh://mac-mini/Users/me/app')),
        isFalse,
      );
    });

    test('Claude Code is offered everywhere: no predicate', () {
      expect(KernelRegistry.claudeCode.available, isNull);
    });
  });

  group('the kernel picker', () {
    test('offers the kernels that can work here, Claude Code first', () {
      final session = ChatSession(
        kernels: [MockKernels.claudeCode, MockKernels.dsh],
        historyCount: 0,
      );
      addTearDown(session.dispose);
      expect(session.kernel, MockKernels.claudeCode);
      expect(
        [for (final option in session.kernelChoice!.options) option.id],
        ['claude-code', 'dsh'],
      );
    });

    test('is gone with one kernel left to pick from', () {
      final session = ChatSession(
        kernels: [MockKernels.claudeCode, _away(MockKernels.dsh)],
        historyCount: 0,
      );
      addTearDown(session.dispose);
      expect(session.kernelChoice, isNull);
    });

    test('falls back to the first that works when the kept one cannot', () {
      // A thread restored in a project its kernel no longer runs in: dsh's,
      // in a multi-folder workspace, say.
      final away = _away(MockKernels.dsh);
      final session = ChatSession(
        kernel: away,
        kernels: [away, MockKernels.claudeCode],
        historyCount: 0,
      );
      addTearDown(session.dispose);
      expect(session.kernel, MockKernels.claudeCode);
    });

    test('stays on one that can when it is picked', () {
      final session = ChatSession(
        kernel: MockKernels.dsh,
        kernels: [MockKernels.claudeCode, MockKernels.dsh],
        historyCount: 0,
      );
      addTearDown(session.dispose);
      expect(session.kernel, MockKernels.dsh);
      expect(session.kernelChoice!.selected, MockKernels.dsh.option);
    });
  });

  group('messages sent while the agent works', () {
    test('wait for the turn running, then run in order', () async {
      final transport = MockDshTransport()..paused = true;
      final session = ChatSession(
        kernel: MockKernels.dshOn(transport),
        historyCount: 0,
      );
      addTearDown(session.dispose);
      session.attach();

      session.send(const ComposerMessage(text: 'first'));
      await _awaitWhere(() => session.isStreaming, 'the first turn');
      await _awaitWhere(() => transport.isPaused, 'the first turn held');
      // What Claude Code has: the composer sends while the agent works,
      // the message waiting over it until its turn.
      expect(session.canQueue, isTrue);
      expect(session.canSend, isTrue);
      session.send(const ComposerMessage(text: 'second'));
      expect([for (final (_, item) in session.queued) item.text], ['second']);
      expect(session.isStreaming, isTrue);

      transport.resume();
      await _awaitWhere(
        () => session.queued.isEmpty,
        'the queued message started',
      );
      await _awaitWhere(() => transport.isPaused, 'the second turn held');
      expect(session.isStreaming, isTrue);

      transport.resume();
      await _awaitWhere(() => !session.isStreaming, 'the second turn ended');
      expect([for (final (_, item) in session.queued) item.text], isEmpty);
    });
  });

  group('editing a message', () {
    test('counts only the turns dsh was sent, not one still queued', () async {
      final transport = MockDshTransport();
      final session = ChatSession(
        kernel: MockKernels.dshOn(transport),
        historyCount: 0,
      );
      addTearDown(session.dispose);
      session.attach();
      expect(session.canEditMessages, isTrue);

      for (final text in ['first', 'second']) {
        session.send(ComposerMessage(text: text));
        await _awaitWhere(() => session.isStreaming, 'the $text turn');
        await _awaitWhere(() => !session.isStreaming, 'the $text turn to end');
      }
      // A turn under way, and a message waiting over it: that one is not in
      // dsh's conversation yet, so the edit must not drop it as a turn.
      transport.paused = true;
      session.send(const ComposerMessage(text: 'third'));
      await _awaitWhere(() => transport.isPaused, 'the third turn held');
      session.send(const ComposerMessage(text: 'fourth'));
      expect(session.queued, hasLength(1));

      session.editMessage(0, const ComposerMessage(text: 'FIRST'));
      await _awaitWhere(
        () => _promptText(transport).startsWith(DshEditBridge.marker),
        'the edit sent',
      );

      // first, second and third were dsh's; fourth was only the app's.
      expect(_promptText(transport), '${DshEditBridge.marker * 3}FIRST');
      // What dsh is sent is the edit; what the thread shows is the user's
      // words, with no markers and none of the turns after it.
      expect(
        [
          for (var i = 0; i < session.itemCount; i++)
            if (session.itemAt(i) case UserMessageItem(:final text)) text,
        ],
        ['FIRST'],
      );
    });
  });

  group('pictures', () {
    test('are taken by the kernels that take them on every route', () {
      final claude = ChatSession(
        kernel: MockKernels.claudeCode,
        historyCount: 0,
      );
      final codex = ChatSession(kernel: MockKernels.codex, historyCount: 0);
      addTearDown(claude.dispose);
      addTearDown(codex.dispose);
      expect(claude.acceptsImages, isTrue);
      expect(codex.acceptsImages, isTrue);
    });

    test('are not taken before dsh said it takes them', () {
      final session = ChatSession(kernel: MockKernels.dsh, historyCount: 0);
      addTearDown(session.dispose);
      expect(session.acceptsImages, isFalse);
    });
  });

  group('a title summed up by hand', () {
    test('is not asked of a kernel that keeps none', () async {
      final asked = <String>[];
      final workspace = _workspace(MockKernels.dsh, asked);
      addTearDown(workspace.dispose);
      final thread = workspace.startAgent(workspace.projects.single);
      expect(thread.session.canRename, isFalse);

      thread.session.send(const ComposerMessage(text: '把输入框改得随内容增高'));
      await _settled(thread.session);
      expect(askedText(thread.session), isNotEmpty);
      // Its kernel keeps no title: not even the automatic one asked.
      expect(asked, isEmpty);

      expect(await workspace.summarizeTitle(thread), isNull);
      expect(asked, isEmpty);
    });

    test('goes to the titler for a kernel that keeps one', () async {
      final asked = <String>[];
      final workspace = _workspace(MockKernels.claudeCode, asked);
      addTearDown(workspace.dispose);
      final thread = workspace.startAgent(workspace.projects.single);
      expect(thread.session.canRename, isTrue);

      thread.session.send(const ComposerMessage(text: '把输入框改得随内容增高'));
      await _settled(thread.session);

      final before = asked.length;
      expect(await workspace.summarizeTitle(thread), 'A new title');
      expect(asked, hasLength(before + 1));
      expect(asked.last, '把输入框改得随内容增高');
    });
  });
}

/// Runs the event loop until [done] holds, giving up after a while.
Future<void> _awaitWhere(bool Function() done, [String? reason]) async {
  for (var turns = 0; turns < 500 && !done(); turns++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue, reason: reason ?? 'the session never got there');
}

/// [kernel], offered nowhere: a kernel another project runs on, or this
/// workspace cannot (see [KernelDescriptor.available]).
KernelDescriptor _away(KernelDescriptor kernel) => KernelDescriptor(
  id: kernel.id,
  label: kernel.label,
  icon: kernel.icon,
  description: kernel.description,
  create: kernel.create,
  customizations: kernel.customizations,
  catalog: kernel.catalog,
  available: (_) => false,
);

/// A workspace whose agents run on [kernel], titled by a titler that keeps
/// what it was asked.
Workspace _workspace(KernelDescriptor kernel, List<String> asked) => Workspace(
  projects: const [Project('baocode', '/p/baocode')],
  kernels: [kernel],
  titler: (text, {model, location, session}) async {
    asked.add(text);
    return 'A new title';
  },
);

/// The text of the last prompt [transport] was sent, markers and all.
String _promptText(MockDshTransport transport) {
  final prompt = transport.lastPrompt?['prompt'];
  if (prompt is! List) return '';
  for (final block in prompt) {
    if (block is Map && block['type'] == 'text' && block['text'] is String) {
      return block['text'] as String;
    }
  }
  return '';
}

/// Waits for [session]'s kernel to have started and its turn to be over: the
/// one message it was sent, answered by a mock process at once.
Future<void> _settled(ChatSession session) async {
  for (var i = 0; i < 300 && session.isStreaming; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

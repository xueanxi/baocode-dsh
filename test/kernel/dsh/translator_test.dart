import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/dsh/dsh_translator.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the translator makes of dsh's updates, with a clock we move.
void main() {
  test('a thought is timed from the step before it, not from the turn', () {
    var now = DateTime(2026, 1, 1, 12);
    final events = <KernelEvent>[];
    final translator = DshTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      options: (_) {},
      clock: () => now,
    );

    translator.begin('turn-1', text: 'Go', images: const []);
    now = now.add(const Duration(seconds: 10));
    translator.update({
      'sessionUpdate': 'agent_thought_chunk',
      'content': {'type': 'text', 'text': 'Read it first.'},
    });
    now = now.add(const Duration(seconds: 2));
    translator.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'call-1',
      'title': 'read lib/main.dart',
      'status': 'in_progress',
    });
    // A long command: not time the model spent thinking.
    now = now.add(const Duration(minutes: 5));
    translator.update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'call-1',
      'status': 'completed',
    });
    now = now.add(const Duration(seconds: 7));
    translator.update({
      'sessionUpdate': 'agent_thought_chunk',
      'content': {'type': 'text', 'text': 'Now change it.'},
    });

    final thoughts = [
      for (final event in events)
        if (event is ItemUpserted && event.item is ThinkingItem)
          event.item as ThinkingItem,
    ];
    expect([for (final thought in thoughts) thought.seconds], [10, 7]);
  });

  test("dsh's todo_write is a todo step: its input the list, the one in "
      'progress its line', () {
    final events = <KernelEvent>[];
    final translator = DshTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      options: (_) {},
    );

    translator.begin('turn-1', text: 'Go', images: const []);
    translator.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'call-1',
      'title': 'todo_write',
      'kind': 'other',
      'status': 'in_progress',
      'rawInput': {
        'todos': [
          {'content': 'Read it', 'status': 'completed'},
          {'content': 'Fix it', 'status': 'in_progress'},
          {'content': 'Test it', 'status': 'pending'},
        ],
      },
    });
    translator.update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'call-1',
      'status': 'completed',
      'content': [
        {
          'type': 'content',
          'content': {
            'type': 'text',
            'text':
                'Updated todo list: 1 pending, 1 in progress, '
                '1 completed.',
          },
        },
      ],
    });

    final items = [
      for (final event in events)
        if (event is ItemUpserted) event.item,
    ].whereType<ToolCallItem>().toList();
    expect(items, hasLength(2));
    // Running, the list is already there: it is what the call wrote.
    expect(
      (
        items.first.kind,
        items.first.tool,
        items.first.target,
        items.first.label,
        items.first.status,
        (items.first.input['todos'] as List?)?.length,
      ),
      (ToolKind.todo, 'todo_write', 'Fix it', null, ToolStatus.running, 3),
    );
    // Ended: the same step, with what dsh said it did.
    expect(
      (items.last.kind, items.last.tool, items.last.target, items.last.status),
      (ToolKind.todo, 'todo_write', 'Fix it', ToolStatus.succeeded),
    );
    expect(items.last.output, startsWith('Updated todo list:'));
  });

  test('a todo call whose input is the list itself reads the same', () {
    // The ACP bridge hands the call's arguments ({todos: …}); the tool's
    // own presentation hands the list.
    final events = <KernelEvent>[];
    final translator = DshTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      options: (_) {},
    );

    translator.begin('turn-1', text: 'Go', images: const []);
    translator.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'call-1',
      'title': 'todo_write',
      'rawInput': [
        {'content': 'Read it', 'status': 'completed'},
        {'content': 'Fix it', 'status': 'in_progress'},
      ],
    });

    final item = [
      for (final event in events)
        if (event is ItemUpserted) event.item,
    ].whereType<ToolCallItem>().single;
    expect((item.kind, item.target), (ToolKind.todo, 'Fix it'));
    expect(item.input['todos'], hasLength(2));
  });

  test('a shell call is the command card: its description the line, the '
      'whole command a tap away', () {
    final events = <KernelEvent>[];
    final translator = DshTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      options: (_) {},
    );

    translator.begin('turn-1', text: 'Go', images: const []);
    translator.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'call-1',
      'title': 'bash',
      'status': 'in_progress',
      'rawInput': {
        'command': 'flutter test test/kernel/dsh',
        'description': 'Run the dsh tests',
      },
    });
    translator.update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'call-1',
      'status': 'completed',
      'content': [
        {
          'type': 'content',
          'content': {'type': 'text', 'text': 'All tests passed!'},
        },
      ],
    });

    final items = [
      for (final event in events)
        if (event is ItemUpserted && event.id == 'call-1')
          event.item as TerminalItem,
    ];
    expect(items, hasLength(2));
    expect(
      (
        items.first.command,
        items.first.description,
        items.first.status,
        items.first.background,
        items.first.output,
      ),
      (
        'flutter test test/kernel/dsh',
        'Run the dsh tests',
        CommandStatus.running,
        false,
        '',
      ),
    );
    expect(
      (items.last.status, items.last.output),
      (CommandStatus.succeeded, 'All tests passed!'),
    );
  });

  test('a background shell call keeps its mark, and a failed one says so', () {
    final events = <KernelEvent>[];
    final translator = DshTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      options: (_) {},
    );

    translator.begin('turn-1', text: 'Go', images: const []);
    translator.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'call-1',
      'title': 'pwsh',
      'status': 'in_progress',
      'rawInput': {
        'command': 'Start-Sleep 9',
        'description': 'Wait',
        'run_in_background': true,
      },
    });
    translator.update({
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'call-1',
      'status': 'failed',
      'content': [
        {
          'type': 'content',
          'content': {'type': 'text', 'text': 'no'},
        },
      ],
    });

    final items = [
      for (final event in events)
        if (event is ItemUpserted && event.id == 'call-1')
          event.item as TerminalItem,
    ];
    expect(
      (items.first.background, items.first.status),
      (true, CommandStatus.running),
    );
    expect(
      (items.last.background, items.last.status),
      (true, CommandStatus.failed),
    );
  });

  test('another tool still reads as a command, its name its line', () {
    final events = <KernelEvent>[];
    final translator = DshTranslator(
      emit: events.add,
      nextSeq: () => events.length,
      options: (_) {},
    );

    translator.begin('turn-1', text: 'Go', images: const []);
    translator.update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'call-1',
      'title': 'read',
      'status': 'in_progress',
      'rawInput': {'path': 'lib/main.dart'},
    });

    final item = [
      for (final event in events)
        if (event is ItemUpserted) event.item,
    ].whereType<ToolCallItem>().single;
    expect(
      (item.kind, item.tool, item.target, item.label, item.detail),
      (ToolKind.command, null, 'read', 'read', 'path: lib/main.dart'),
    );
  });
}

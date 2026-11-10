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
}

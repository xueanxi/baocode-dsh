import 'package:baocode/kernel/dsh/dsh_ask.dart';
import 'package:flutter_test/flutter_test.dart';

/// One question asked of dsh's `headless` profile: the run's arguments, and
/// the answer read out of what it printed.
void main() {
  test('the run: the headless profile, the patch, the task on stdin', () {
    expect(dshAskArguments('/tmp/ask/ask.patch.yml'), [
      '--profile',
      'headless',
      '--patch',
      '/tmp/ask/ask.patch.yml',
      '--json',
      // The task: what is written to stdin.
      '-',
    ]);
  });

  group('the answer', () {
    Matcher says(String message) => throwsA(
      isA<DshAskException>().having(
        (error) => error.message,
        'message',
        message,
      ),
    );

    test('is the final event, its thinking and its steps left out', () {
      final output = [
        '{"type":"session","sessionId":"session-1"}',
        '{"type":"status","phase":"turn_start","turn":1}',
        '{"type":"thinking","text":"The user wants a commit message."}',
        '{"type":"text","text":"Add a"}',
        '{"type":"final","text":"Add a\\n\\nAdd b to it."}',
        '',
      ].join('\n');

      expect(dshAskAnswer(output, '', 0), 'Add a\n\nAdd b to it.');
    });

    test('is nothing: the turn says why it ended, in its words', () {
      final output = [
        '{"type":"status","phase":"turn_end","reason":{"kind":"error",'
            '"error":{"message":"503: no channel for the model"}}}',
        '{"type":"final","text":""}',
      ].join('\n');

      expect(
        () => dshAskAnswer(output, 'dsh: SERVER: 503', 1),
        says('503: no channel for the model'),
      );
    });

    test('is nothing, without a reason: what dsh printed on stderr', () {
      expect(() => dshAskAnswer('', 'dsh: boom', 1), says('dsh: boom'));
    });

    test('a final event with nothing in it is no answer', () {
      expect(
        () => dshAskAnswer('{"type":"final","text":"  \\n"}', '', 1),
        says('dsh gave no answer (exit 1).'),
      );
    });

    test('is nothing at all: how it exited', () {
      expect(
        () => dshAskAnswer('', '', 3),
        says('dsh gave no answer (exit 3).'),
      );
    });

    test('passes over what is not an event', () {
      final output = [
        'not json at all',
        '[1,2,3]',
        '{"type":"final","text":"Fix the parse"}',
      ].join('\n');

      expect(dshAskAnswer(output, '', 0), 'Fix the parse');
    });
  });
}

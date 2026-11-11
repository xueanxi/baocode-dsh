import 'package:baocode/kernel/dsh/dsh_ask.dart';
import 'package:baocode/kernel/dsh/dsh_title.dart';
import 'package:baocode/kernel/title_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

/// A title asked of dsh's headless one-shot: what is asked, and what comes
/// back cleaned. The ask is stood in for: no test starts a process (or
/// spends a model call).
void main() {
  tearDown(() => dshTitleAsk = null);

  test('the title is the reply cleaned, the message cut to fit', () async {
    String? system;
    String? prompt;
    dshTitleAsk = (askedSystem, askedPrompt, {cancel, route}) async {
      system = askedSystem;
      prompt = askedPrompt;
      return '"Fix the wheel."';
    };

    expect(await askDshTitle('  ${'a' * 3000}'), 'Fix the wheel');
    expect(system, agentTitleSystem);
    expect(prompt, startsWith('<message>\n'));
    expect(prompt, endsWith('…\n</message>'));
    expect(prompt, contains('a' * 100));
  });

  test(
    'no title when the ask is cancelled, fails, or has no message',
    () async {
      dshTitleAsk = (system, prompt, {cancel, route}) async =>
          throw const DshAskCancelled();
      expect(await askDshTitle('hi'), isNull);

      dshTitleAsk = (system, prompt, {cancel, route}) async =>
          throw const DshAskException('boom');
      expect(await askDshTitle('hi'), isNull);

      expect(await askDshTitle('   '), isNull);
    },
  );
}

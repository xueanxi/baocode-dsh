import 'dart:io';

import 'package:baocode/kernel/dsh/dsh_edit_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rewind plugin BaoCode writes into dsh's patch: the file dsh loads, and
/// the prompt marker the kernel puts in front of an edit.
void main() {
  test(
    'the rewind plugin is written once, and its URL names the file',
    () async {
      final root = Directory.systemTemp.createTempSync('baocode-edit-bridge');
      addTearDown(() => root.deleteSync(recursive: true));

      final url = await DshEditBridge.ensure(root.path);
      final file = File('${root.path}/${DshEditBridge.fileName}');
      expect(file.existsSync(), isTrue);
      expect(url, file.uri.toString());
      expect(Uri.parse(url).isScheme('file'), isTrue);
      expect(await file.readAsString(), DshEditBridge.source);

      final kept = await file.lastModified();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await DshEditBridge.ensure(root.path), url);
      expect(await file.lastModified(), kept);
    },
  );

  test('the plugin strips the markers before the step is built', () {
    const source = DshEditBridge.source;
    // It works from the agent loop's own hooks: the claimed prompt first,
    // then the request, with the step already open. Never from a session
    // event listener, where dsh refuses an append made while publishing.
    expect(source, contains("ctx.on('agent/pre-step'"));
    expect(source, contains("ctx.on('agent/request'"));
    expect(source, isNot(contains("ctx.on('session/event'")));
    expect(source, contains('decision.messages'));
    expect(source, contains('withoutMarkers'));
    // The rewind itself: an empty developer message replacing the old tail,
    // which projects no model message.
    expect(source, contains("'developer/message'"));
    expect(source, contains('surfaceOp:'));
    expect(source, contains("op: 'replace'"));
    expect(source, contains('sourceEventSeqs'));
    // User prompts only: injected context is not a turn to drop.
    expect(source, contains("event.data?.source?.kind !== 'user'"));
    // Plain JavaScript, resolved by dsh's own loader: no imports of its own.
    expect(source, isNot(contains('import ')));
    // The markers the kernel writes, and the plugin counts, are the same.
    expect(source, contains(r"'\u200B\u200C'"));
    expect(DshEditBridge.marker, '\u200B\u200C');
  });
}

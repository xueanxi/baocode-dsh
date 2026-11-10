import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/dsh/dsh_ask_bridge.dart';
import 'package:baocode/kernel/dsh/dsh_question_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plugin BaoCode writes into dsh's patch, and the loopback endpoint it
/// asks: no dsh runs here, only the two halves it joins.
void main() {
  // The test binding fakes HttpClient; these tests speak to a real loopback
  // server of the app's own.
  setUp(() => HttpOverrides.global = null);

  test('the answerer is written once, and its URL names the file', () async {
    final root = Directory.systemTemp.createTempSync('baocode-ask-bridge');
    addTearDown(() => root.deleteSync(recursive: true));

    final url = await DshAskBridge.ensure(root.path);
    final file = File('${root.path}/${DshAskBridge.fileName}');
    expect(file.existsSync(), isTrue);
    expect(url, file.uri.toString());
    expect(Uri.parse(url).isScheme('file'), isTrue);
    expect(await file.readAsString(), DshAskBridge.source);

    final kept = await file.lastModified();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await DshAskBridge.ensure(root.path), url);
    expect(await file.lastModified(), kept);
  });

  test('the plugin waits on the app, and names neither a dsh version nor a '
      'secret', () {
    const source = DshAskBridge.source;
    expect(source, contains("ctx.on('user-questions/request'"));
    expect(source, contains('BAOCODE_ASK_URL'));
    expect(source, contains('BAOCODE_ASK_TOKEN'));
    expect(source, contains('/questions/'));
    // Plain JavaScript, resolved by dsh's own loader: no imports of its own.
    expect(source, isNot(contains('import ')));
  });

  test(
    'the endpoint wants the token, and says gone for an unknown question',
    () async {
      final server = await startDshQuestionServer((questions) async => null);
      addTearDown(server.close);

      expect(server.url.host, '127.0.0.1');
      expect(server.token, isNotEmpty);

      expect(await _status(server, '/questions', token: 'wrong'), 401);
      expect(
        await _status(server, '/questions', token: server.token, method: 'GET'),
        405,
      );
      expect(
        await _status(
          server,
          '/questions/nope',
          token: server.token,
          method: 'GET',
        ),
        404,
      );
    },
  );
}

Future<int> _status(
  DshQuestionServer server,
  String path, {
  required String token,
  String method = 'POST',
}) async {
  final client = HttpClient();
  try {
    final url = server.url.resolve(path);
    final request = switch (method) {
      'GET' => await client.getUrl(url),
      _ => await client.postUrl(url),
    };
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.contentType = ContentType.json;
    if (method != 'GET') request.write(jsonEncode({'questions': []}));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

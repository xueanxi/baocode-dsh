import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/dsh/dsh_usage_bridge.dart';
import 'package:baocode/kernel/dsh/dsh_usage_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plugin BaoCode writes into dsh's patch and the loopback endpoint it
/// posts on: no dsh runs here, only the two halves it joins.
void main() {
  // The test binding fakes HttpClient; these tests speak to a real loopback
  // server of the app's own.
  setUp(() => HttpOverrides.global = null);

  test(
    'the token accountant is written once, and its URL names the file',
    () async {
      final root = Directory.systemTemp.createTempSync('baocode-usage-bridge');
      addTearDown(() => root.deleteSync(recursive: true));

      final url = await DshUsageBridge.ensure(root.path);
      final file = File('${root.path}/${DshUsageBridge.fileName}');
      expect(file.existsSync(), isTrue);
      expect(url, file.uri.toString());
      expect(Uri.parse(url).isScheme('file'), isTrue);
      expect(await file.readAsString(), DshUsageBridge.source);

      final kept = await file.lastModified();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await DshUsageBridge.ensure(root.path), url);
      expect(await file.lastModified(), kept);
    },
  );

  test('the plugin reads the provider usage dsh commits, and nothing else', () {
    const source = DshUsageBridge.source;
    expect(source, contains("ctx.on('session/event'"));
    expect(source, contains("'assistant/message'"));
    expect(source, contains('inputTokens'));
    expect(source, contains('outputTokens'));
    expect(source, contains('cacheReadTokens'));
    expect(source, contains('cacheWriteTokens'));
    expect(source, contains('reasoningTokens'));
    expect(source, contains('BAOCODE_USAGE_URL'));
    expect(source, contains('BAOCODE_USAGE_TOKEN'));
    // Plain JavaScript, resolved by dsh's own loader: no imports of its own.
    expect(source, isNot(contains('import ')));
  });

  test(
    'the endpoint wants the token, and hands each report over once',
    () async {
      final reports = <Map<String, Object?>>[];
      final server = await startDshUsageServer(reports.add);
      addTearDown(server.close);

      expect(server.url.host, '127.0.0.1');
      expect(server.token, isNotEmpty);

      expect(await _status(server, '/usage', token: 'wrong'), 401);
      expect(
        await _status(server, '/usage', token: server.token, method: 'GET'),
        405,
      );
      expect(await _status(server, '/nope', token: server.token), 404);
      expect(
        await _status(
          server,
          '/usage',
          token: server.token,
          body: {
            'session': 'session-1',
            'time': 1794290000000,
            'usage': {'input': 10, 'output': 2},
          },
        ),
        204,
      );
      expect(reports, hasLength(1));
      expect(reports.single['session'], 'session-1');
      expect((reports.single['usage'] as Map)['input'], 10);
    },
  );
}

Future<int> _status(
  DshUsageServer server,
  String path, {
  required String token,
  String method = 'POST',
  Map<String, Object?>? body,
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
    if (method != 'GET') request.write(jsonEncode(body ?? const {}));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

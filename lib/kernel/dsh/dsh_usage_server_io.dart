import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'dsh_usage_server.dart';

/// Starts a loopback server handing each report to [onUsage].
Future<DshUsageServer> start(DshUsageHandler onUsage) async {
  final server = _UsageServer(onUsage);
  await server.start();
  return server;
}

class _UsageServer implements DshUsageServer {
  _UsageServer(this._onUsage);

  final DshUsageHandler _onUsage;
  final String _token = _newToken();
  HttpServer? _server;
  Uri? _url;
  bool _closed = false;

  @override
  Uri get url =>
      _url ?? (throw StateError('the usage endpoint was not started'));

  @override
  String get token => _token;

  @override
  Future<void> start() async {
    if (_server != null || _closed) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _url = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen(
      _handle,
      onError: (Object error) {
        // One broken report is not the endpoint: the next one is served as
        // usual, and the bridge sees its own failure.
        debugPrint('DSH usage endpoint: $error');
      },
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $_token') {
        await _json(request, HttpStatus.unauthorized, {
          'error': 'unauthorized',
        });
        return;
      }
      final path = request.uri.pathSegments;
      if (path.length != 1 || path.first != 'usage') {
        await _json(request, HttpStatus.notFound, {'error': 'not found'});
        return;
      }
      if (request.method != 'POST') {
        request.response.headers.set(HttpHeaders.allowHeader, 'POST');
        await _json(request, HttpStatus.methodNotAllowed, {
          'error': 'method not allowed',
        });
        return;
      }
      const limit = 64 * 1024;
      final body = BytesBuilder(copy: false);
      await for (final chunk in request) {
        body.add(chunk);
        if (body.length > limit) {
          await _json(request, HttpStatus.requestEntityTooLarge, {
            'error': 'too large',
          });
          return;
        }
      }
      final decoded = jsonDecode(utf8.decode(body.takeBytes()));
      if (decoded is! Map) {
        await _json(request, HttpStatus.badRequest, {'error': 'not a report'});
        return;
      }
      _onUsage(decoded.cast<String, Object?>());
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    } on Object catch (error) {
      debugPrint('DSH usage endpoint: $error');
      try {
        await _json(request, HttpStatus.badRequest, {'error': '$error'});
      } on Object {
        // The response went already: nothing left to say.
      }
    }
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  static String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'dsh_question_server.dart';

/// Starts a loopback server answering with [ask].
Future<DshQuestionServer> start(DshAskHandler ask) async {
  final server = _QuestionServer(ask);
  await server.start();
  return server;
}

/// One question the bridge posted: open until the panel answers it or the
/// conversation lets it go.
class _Question {
  _Question(this.questions);

  /// dsh's questions, as its tool sent them (`id`, `question`, `options`…).
  final List<Map<String, Object?>> questions;

  /// What the user picked, per question; null until answered.
  List<Map<String, Object?>>? answers;

  /// Given up: the turn stopped, dsh went, or the bridge's request was
  /// aborted. The plugin is told to stop waiting.
  bool cancelled = false;
}

class _QuestionServer implements DshQuestionServer {
  _QuestionServer(this._ask);

  final DshAskHandler _ask;
  final Map<String, _Question> _questions = {};
  final String _token = _newToken();
  HttpServer? _server;
  int _asked = 0;
  bool _closed = false;

  @override
  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}');

  @override
  String get token => _token;

  @override
  Future<void> start() async {
    if (_server != null || _closed) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(
      _handle,
      onError: (Object error) {
        // One broken request is not the endpoint: the next one is served as
        // usual, and the bridge sees its own failure.
        debugPrint('DSH question endpoint: $error');
      },
    );
  }

  @override
  void cancelAll() {
    for (final question in _questions.values) {
      if (question.answers == null) question.cancelled = true;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    cancelAll();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  // --- Requests ---------------------------------------------------------------

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
      if (path.length == 1 && path.first == 'questions') {
        if (request.method != 'POST') {
          await _methodNotAllowed(request, 'POST');
          return;
        }
        await _create(request);
        return;
      }
      if (path.length == 2 && path.first == 'questions') {
        if (request.method != 'GET') {
          await _methodNotAllowed(request, 'GET');
          return;
        }
        await _poll(request, path[1]);
        return;
      }
      if (path.length == 3 &&
          path.first == 'questions' &&
          path[2] == 'cancel') {
        if (request.method != 'POST') {
          await _methodNotAllowed(request, 'POST');
          return;
        }
        await _cancel(request, path[1]);
        return;
      }
      await _json(request, HttpStatus.notFound, {'error': 'not found'});
    } on Object catch (error) {
      debugPrint('DSH question endpoint: $error');
      try {
        await _json(request, HttpStatus.badRequest, {'error': '$error'});
      } on Object {
        // The response went already: nothing left to say.
      }
    }
  }

  Future<void> _create(HttpRequest request) async {
    const limit = 256 * 1024;
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
    final questions = switch (decoded) {
      {'questions': final List<Object?> raw} => [
        for (final question in raw)
          if (question is Map) question.cast<String, Object?>(),
      ],
      _ => const <Map<String, Object?>>[],
    };
    if (questions.isEmpty) {
      await _json(request, HttpStatus.badRequest, {'error': 'no questions'});
      return;
    }
    final id = 'q${++_asked}';
    _questions[id] = _Question(questions);
    unawaited(_askFor(id));
    await _json(request, HttpStatus.created, {'id': id});
  }

  /// Answers [id] with the panel's picks, once the user is done: the bridge
  /// polls [poll] meanwhile.
  Future<void> _askFor(String id) async {
    final question = _questions[id];
    if (question == null) return;
    List<List<String>>? picks;
    try {
      picks = await _ask(question.questions);
    } on Object catch (error) {
      debugPrint('DSH question not asked: $error');
    }
    if (question.cancelled || question.answers != null) return;
    final answers = picks == null ? null : _answers(question.questions, picks);
    if (answers == null) {
      question.cancelled = true;
    } else {
      question.answers = answers;
    }
  }

  Future<void> _poll(HttpRequest request, String id) async {
    final question = _questions[id];
    if (question == null) {
      await _json(request, HttpStatus.notFound, {'state': 'gone'});
      return;
    }
    if (question.answers case final answers?) {
      await _json(request, HttpStatus.ok, {
        'state': 'answered',
        'answers': answers,
      });
      return;
    }
    await _json(request, HttpStatus.ok, {
      'state': question.cancelled ? 'cancelled' : 'open',
    });
  }

  Future<void> _cancel(HttpRequest request, String id) async {
    if (_questions[id] case final question?) {
      question.cancelled = true;
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  /// dsh's answers for [questions], from the labels the panel picked: those
  /// that name an option are `selected`, anything else the user wrote is
  /// `custom` (dsh's own shape for an answer of the user's own).
  static List<Map<String, Object?>> _answers(
    List<Map<String, Object?>> questions,
    List<List<String>> picks,
  ) => [
    for (final (i, question) in questions.indexed)
      () {
        final labels = {
          for (final option in question['options'] as List? ?? const [])
            if (option is Map && option['label'] is String) option['label'],
        };
        final selected = <String>[];
        final custom = <String>[];
        for (final pick in i < picks.length ? picks[i] : const <String>[]) {
          if (labels.contains(pick)) {
            selected.add(pick);
          } else {
            custom.add(pick);
          }
        }
        return <String, Object?>{
          'id': '${question['id'] ?? ''}',
          'selected': selected,
          if (custom.isNotEmpty) 'custom': custom.join('\n'),
        };
      }(),
  ];

  // --- Responses --------------------------------------------------------------

  Future<void> _methodNotAllowed(HttpRequest request, String allowed) async {
    request.response.headers.set(HttpHeaders.allowHeader, allowed);
    await _json(request, HttpStatus.methodNotAllowed, {
      'error': 'method not allowed',
    });
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

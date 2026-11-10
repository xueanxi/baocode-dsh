import 'dart:async';
import 'dart:convert';

import 'dsh_transport.dart';

/// Plays dsh's ACP bridge as the kernel drives it: one session, a turn of a
/// thought, a tool call and two messages, and the JSON-RPC shapes dsh
/// answers with. Not dsh: the shapes follow the protocol closely enough to
/// drive the adapter, and nothing is timed, so a test runs at once.
///
/// What the kernel wrote is kept in [written], to check what it sent.
class MockDshTransport implements DshTransport {
  MockDshTransport({
    this.image = true,
    this.reasoningEffort = false,
    Map<String, List<String>>? models,
  }) : _models = models ?? _patched,
       _current = _firstValue(models ?? _patched);

  /// The one provider the patch in `dsh_patch.dart` mounts.
  static const _patched = {
    'stepcodev2': ['deepseek-v4.1-flash'],
  };

  static String _firstValue(Map<String, List<String>> models) {
    final provider = models.entries.first;
    return _valueOf(provider.key, provider.value.first);
  }

  /// Whether `initialize` says pictures can be sent (`promptCapabilities`).
  final bool image;

  /// Whether the model offers reasoning levels; the patch's does not (F6).
  final bool reasoningEffort;

  /// The models dsh lists, by provider: its options are grouped by them.
  final Map<String, List<String>> _models;

  /// What a prompt is answered with instead of a turn: dsh's error, as JSON-
  /// RPC carries it. A failed prompt's reason is in `data.details`.
  Map<String, Object?>? failure;

  /// How much the model holds, as `usage_update` reports it: the patch's
  /// until a test says otherwise.
  int contextSize = 512000;

  /// Holds a prompt at its tool call until the kernel cancels it (F14),
  /// rather than playing the turn on: the call is left running.
  bool holds = false;

  /// Whether the process dies as it is shaken hands with: a dsh that cannot
  /// start.
  bool diesOnInitialize = false;

  /// What it printed on stderr as it died.
  String dieWith = '';

  /// Whether the tool call played with a turn ends in failure.
  bool toolFails = false;

  /// How many `session/resume` requests are refused as `session is already
  /// active` before one is answered: what dsh says while the process before
  /// still holds the session (F15).
  int busyResumes = 0;

  /// Every message the kernel wrote, in order.
  final List<Map<String, Object?>> written = [];

  /// The requests the kernel wrote [method] for, in order.
  List<Map<String, Object?>> requests(String method) => [
    for (final message in written)
      if (message['method'] == method) message,
  ];

  /// What the next `session/prompt` asks: its params.
  Map<String, Object?>? get lastPrompt {
    final prompts = requests('session/prompt');
    if (prompts.isEmpty) return null;
    return (prompts.last['params'] as Map?)?.cast<String, Object?>();
  }

  static const String _sessionId = 'session-mock';
  String _current;
  String _effort = 'medium';

  /// Asynchronous, as the transport over a process is: a message is
  /// delivered a turn later, and answering it may end the process.
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast();
  final Completer<void> _exit = Completer<void>();
  final Completer<void> _cancelled = Completer<void>();

  Object? _promptId;

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  @override
  Future<void> get exited => _exit.future;

  /// Whether the process is gone already.
  bool get gone => _exit.isCompleted;

  @override
  String? get executable => 'node';

  void _emit(Map<String, Object?> message) {
    if (!_out.isClosed) _out.add(message);
  }

  void _respond(Object? id, Map<String, Object?> result) =>
      _emit({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _notify(String kind, Map<String, Object?> update) => _emit({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {
      'sessionId': _sessionId,
      'update': {'sessionUpdate': kind, ...update},
    },
  });

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    final method = message['method'] as String?;
    if (method == null) return;
    final id = message['id'];
    final params =
        (message['params'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (method) {
      case 'initialize':
        if (diesOnInitialize) {
          exit(code: 1, stderr: dieWith);
          return;
        }
        _respond(id, {
          'protocolVersion': 1,
          'agentInfo': {'name': 'deepseek-harness-acp', 'version': '0.0.1'},
          'agentCapabilities': {
            'promptCapabilities': {
              'image': image,
              'audio': false,
              'embeddedContext': false,
            },
            'sessionCapabilities': {
              'close': <String, Object?>{},
              'list': <String, Object?>{},
              'resume': <String, Object?>{},
            },
          },
        });
      case 'session/new':
        _respond(id, {'sessionId': _sessionId, 'configOptions': _options()});
      case 'session/resume':
        if (busyResumes > 0) {
          busyResumes--;
          _emit({
            'jsonrpc': '2.0',
            'id': id,
            'error': {
              'code': -32602,
              'message':
                  'Invalid params: session is already active: $_sessionId',
            },
          });
        } else {
          _respond(id, {'configOptions': _options()});
        }
      case 'session/set_config_option':
        _choose('${params['configId']}', '${params['value']}');
        _respond(id, {'configOptions': _options()});
      case 'session/cancel':
        _cancel();
      case 'session/prompt':
        unawaited(_prompt(id));
    }
  }

  /// The turn a prompt asks for: a thought, a tool call and its result, two
  /// messages, the usage — then the answer.
  Future<void> _prompt(Object? id) async {
    _promptId = id;
    if (failure case final error?) {
      _promptId = null;
      _emit({'jsonrpc': '2.0', 'id': id, 'error': error});
      return;
    }
    _notify('agent_thought_chunk', {
      'messageId': 'msg_1',
      'content': {
        'type': 'text',
        'text': 'Reading the file before changing it.',
      },
    });
    _notify('tool_call', {
      'toolCallId': 'call_1',
      'title': 'read lib/main.dart',
      'kind': 'other',
      'status': 'in_progress',
      'rawInput': {'path': 'lib/main.dart', 'limit': 40},
    });
    if (holds) {
      // Nothing more until the kernel cancels it, which answers the prompt:
      // the tool call is left running.
      await _cancelled.future;
      return;
    }
    _notify('tool_call_update', {
      'toolCallId': 'call_1',
      'status': toolFails ? 'failed' : 'completed',
      'content': [
        {
          'type': 'content',
          'content': {
            'type': 'text',
            'text': "import 'package:flutter/material.dart';",
          },
        },
      ],
    });
    _notify('agent_message_chunk', {
      'messageId': 'msg_2',
      'content': {'type': 'text', 'text': 'I read lib/main.dart.'},
    });
    _notify('agent_message_chunk', {
      'messageId': 'msg_3',
      'content': {'type': 'text', 'text': 'It starts the app and the window.'},
    });
    _notify('usage_update', {'used': 18240, 'size': contextSize});
    _promptId = null;
    _respond(id, {'stopReason': 'end_turn'});
  }

  void _cancel() {
    final id = _promptId;
    _promptId = null;
    if (id == null) return;
    if (!_cancelled.isCompleted) _cancelled.complete();
    _respond(id, {'stopReason': 'cancelled'});
  }

  /// Picks [value] for the option [configId], if it offers it.
  void _choose(String configId, String value) {
    switch (configId) {
      case 'model':
        if (_values().contains(value)) _current = value;
      case 'reasoning_effort':
        _effort = value;
    }
  }

  /// Every model value offered, opaque as dsh writes them.
  List<String> _values() => [
    for (final MapEntry(key: provider, value: models) in _models.entries)
      for (final model in models) _valueOf(provider, model),
  ];

  /// What dsh answers with: the model by provider, and the reasoning levels
  /// where the model has them.
  List<Map<String, Object?>> _options() => [
    {
      'id': 'model',
      'name': 'Model',
      'category': 'model',
      'type': 'select',
      'currentValue': _current,
      'options': [
        for (final MapEntry(key: provider, value: models) in _models.entries)
          {
            'group': provider,
            'name': provider,
            'options': [
              for (final model in models)
                {'value': _valueOf(provider, model), 'name': model},
            ],
          },
      ],
    },
    if (reasoningEffort)
      {
        'id': 'reasoning_effort',
        'name': 'Reasoning effort',
        'category': 'thought_level',
        'type': 'select',
        'currentValue': _effort,
        'options': [
          {'value': 'low', 'name': 'Low', 'description': 'Answers at once'},
          {
            'value': 'medium',
            'name': 'Medium',
            'description': 'Thinks a little',
          },
          {'value': 'high', 'name': 'High', 'description': 'Thinks more'},
        ],
      },
  ];

  /// One model's opaque value: `JSON.stringify([provider, model])` (F6).
  static String _valueOf(String provider, String model) =>
      jsonEncode([provider, model]);

  /// The process ending by itself (a crash, a kill): what the transport says
  /// when its last message is read.
  void exit({int code = 0, String stderr = ''}) {
    if (_exit.isCompleted) return;
    _emit(DshExit.message(code, stderr));
    unawaited(_out.close());
    // Gone a moment later, as a process is: what waits for it to end waits.
    scheduleMicrotask(() {
      if (!_exit.isCompleted) _exit.complete();
    });
  }

  @override
  void close() => exit();
}

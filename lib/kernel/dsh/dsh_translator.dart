import 'dart:math' as math;

import '../../chat/chat_models.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'dsh_patch.dart';

/// A JSON-RPC error dsh answered a request with.
class DshRpcError implements Exception {
  const DshRpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;

  /// dsh's own data with it: a failed turn puts its reason in `details`.
  final Map<String, Object?>? data;

  /// The error a message carries, or null when it carries none.
  static DshRpcError? from(Object? raw) {
    if (raw is! Map) return null;
    return DshRpcError(
      _number(raw['code']) ?? -32603,
      '${raw['message'] ?? ''}',
      (raw['data'] as Map?)?.cast<String, Object?>(),
    );
  }

  /// Whether dsh refused because another process still holds the session
  /// (`-32603 already owned by an active write handle`, `-32602 session is
  /// already active`): that one gone, the session resumes (F15).
  bool get heldByAnother =>
      (code == -32603 || code == -32602) &&
      (message.contains('already owned') || message.contains('already active'));

  /// What to show the user: the reason dsh put in `data.details`, dsh's
  /// `turn failed: ` lead-in (and the protocol's `Internal error: ` before
  /// it) dropped, else its own message.
  String get text {
    final detail = data?['details'];
    final said = detail is String && detail.trim().isNotEmpty
        ? detail
        : message;
    final text = said.replaceFirst(RegExp(r'^.*?turn failed:\s*'), '').trim();
    return text.isEmpty ? 'DSH failed' : text;
  }

  @override
  String toString() => text;
}

/// Translates dsh's side of ACP into the kernel's events: the six kinds of
/// `session/update`, the answer to a prompt and a failed turn, and the turn's
/// own start and end. The protocol detail lives here, so that a dsh upgrade
/// changes one file.
///
/// A turn is always the same, and without all of it the conversation waits
/// for ever (see `docs/spec/dsh-kernel.md` §5.5):
///
/// ```text
/// TurnStarted(turnId)
/// ItemUpserted(turnId, UserMessageItem(text, images))   // id == turnId
/// … items …
/// TurnEnded(turnId, interrupted:, worked:)
/// ```
class DshTranslator {
  DshTranslator({
    required this.emit,
    required this.nextSeq,
    required this.options,
  });

  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;

  /// Called with the `configOptions` dsh sends: with a new session, a
  /// resumed one, a pick of the user's, or a change of dsh's own.
  final void Function(List<Map<String, Object?>> options) options;

  /// How much of the model the context holds, as last reported; the
  /// patch's while dsh has said nothing (one number, in `dsh_patch.dart`).
  int contextWindow = DshPatch.contextWindow;

  String? _turn;
  DateTime? _startedAt;

  /// Message and thought ids count on across turns, and across a restart of
  /// the process: dsh names neither (F8), and an id used twice would replace
  /// the item before.
  int _messages = 0;
  int _thoughts = 0;

  /// Counts on from the ids of what a kept session already said: a new
  /// process starts at one again, and one of its messages would replace the
  /// same-numbered one read back.
  void continueFrom(Iterable<String> ids) {
    for (final id in ids) {
      if (id.startsWith('message:')) {
        _messages = math.max(
          _messages,
          int.tryParse(id.substring('message:'.length)) ?? 0,
        );
      } else if (id.startsWith('thought:')) {
        _thoughts = math.max(
          _thoughts,
          int.tryParse(id.substring('thought:'.length)) ?? 0,
        );
      }
    }
  }

  /// Each tool call's title and detail, to show again when it ends: its
  /// update names only its id (F9).
  final Map<String, ({String title, String? detail})> _tools = {};

  /// The calls under way: one the turn is stopped in would stay running for
  /// ever, dsh sending no result for it.
  final Set<String> _running = {};

  /// The turn under way; null between turns.
  String? get turnId => _turn;

  /// Whether a turn is under way.
  bool get inFlight => _turn != null;

  /// Starts turn [turnId] with the message sent: the user's own item first,
  /// which dsh never echoes back (§5.5).
  void begin(
    String turnId, {
    required String text,
    required List<ImageAttachment> images,
  }) {
    _turn = turnId;
    _startedAt = DateTime.now();
    emit(TurnStarted(nextSeq(), turnId));
    // Its id is the turn's: the time it took and what it spent are kept on
    // this item.
    emit(
      ItemUpserted(
        nextSeq(),
        turnId,
        UserMessageItem(text: text, images: images),
      ),
    );
  }

  /// Applies one `session/update`: what it carries under `update`.
  void update(Map<String, Object?> update) {
    switch (update['sessionUpdate']) {
      case 'agent_message_chunk':
        final text = _text(update['content']);
        if (text == null || text.isEmpty) return;
        // The whole message at once: dsh commits it, and streams no tokens
        // (F8).
        emit(
          ItemUpserted(
            nextSeq(),
            'message:${++_messages}',
            AssistantTextItem(text),
          ),
        );
      case 'agent_thought_chunk':
        final text = _text(update['content']);
        if (text == null || text.isEmpty) return;
        // dsh times nothing: the thought is taken as the time the turn had
        // run when it came.
        final run = switch (_startedAt) {
          final started? => DateTime.now().difference(started),
          null => Duration.zero,
        };
        emit(
          ItemUpserted(
            nextSeq(),
            'thought:${++_thoughts}',
            ThinkingItem(
              text: text,
              tokens: text.length,
              seconds: math.max(1, run.inSeconds),
            ),
          ),
        );
      case 'tool_call':
        final id = '${update['toolCallId'] ?? ''}';
        if (id.isEmpty) return;
        final title = '${update['title'] ?? ''}';
        final detail = _oneLine(update['rawInput']);
        _tools[id] = (title: title, detail: detail.isEmpty ? null : detail);
        _running.add(id);
        emit(
          ItemUpserted(
            nextSeq(),
            id,
            ToolCallItem(
              // dsh's kind is always `other`, which the history has no
              // member for: its calls show as commands (F9).
              kind: ToolKind.command,
              target: title,
              label: title,
              detail: detail.isEmpty ? null : detail,
              status: ToolStatus.running,
            ),
          ),
        );
      case 'tool_call_update':
        final id = '${update['toolCallId'] ?? ''}';
        final status = switch (update['status']) {
          'completed' => ToolStatus.succeeded,
          'failed' => ToolStatus.failed,
          _ => null,
        };
        // Still running: there is no progress to show, only the end (F9).
        if (id.isEmpty || status == null) return;
        _running.remove(id);
        final call = _tools[id];
        emit(
          ItemUpserted(
            nextSeq(),
            id,
            ToolCallItem(
              kind: ToolKind.command,
              target: call?.title ?? '',
              label: call?.title,
              detail: call?.detail,
              status: status,
              output: _output(update['content']),
            ),
          ),
        );
      case 'usage_update':
        final window = _number(update['size']);
        final used = _number(update['used']);
        if (window == null || used == null) return;
        final resized = window != contextWindow;
        contextWindow = window;
        emit(
          UsageReported(nextSeq(), ContextUsage(window: window, used: used)),
        );
        // The toolbar shows the window: it is told when it changes.
        if (resized) emit(KernelInfoChanged(nextSeq()));
      case 'config_option_update':
        options(_optionList(update['configOptions']));
    }
  }

  /// Ends the turn under way: a failure said as an error notice, then
  /// [TurnEnded] — without it the conversation stays busy for ever.
  void end({bool interrupted = false, String? error}) {
    final turn = _turn;
    if (turn == null) return;
    final worked = switch (_startedAt) {
      final started? => DateTime.now().difference(started),
      null => null,
    };
    _turn = null;
    _startedAt = null;
    if (interrupted) _settleTools();
    if (error != null) {
      emit(
        ItemUpserted(
          nextSeq(),
          'error:$turn',
          NoticeItem(NoticeKind.error, error),
        ),
      );
    }
    emit(TurnEnded(nextSeq(), turn, interrupted: interrupted, worked: worked));
  }

  /// Shows the calls the turn was stopped in as failed: dsh reports no
  /// result for them, and a card left running would spin for ever.
  void _settleTools() {
    for (final id in _running) {
      final call = _tools[id];
      emit(
        ItemUpserted(
          nextSeq(),
          id,
          ToolCallItem(
            kind: ToolKind.command,
            target: call?.title ?? '',
            label: call?.title,
            detail: call?.detail,
            status: ToolStatus.failed,
          ),
        ),
      );
    }
    _running.clear();
  }

  /// The text of a content block, if it is one.
  static String? _text(Object? content) {
    if (content is! Map) return null;
    final text = content['text'];
    return text is String ? text : null;
  }

  /// What a tool returned: its text blocks, in order.
  static String? _output(Object? content) {
    final blocks = content is List ? content : const [];
    final lines = <String>[];
    for (final block in blocks) {
      if (block is! Map) continue;
      final body = block['content'];
      final text = switch (body) {
        final Map map => map['text'],
        _ => block['text'],
      };
      if (text is String && text.trim().isNotEmpty) lines.add(text);
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// [value] on one line, for a tool's detail.
  static String _oneLine(Object? value) => switch (value) {
    null => '',
    final String text => text.replaceAll(RegExp(r'\s+'), ' ').trim(),
    final Map map => [
      for (final MapEntry(:key, :value) in map.entries)
        '$key: ${_oneLine(value)}',
    ].join(', '),
    final List list => [for (final item in list) _oneLine(item)].join(', '),
    _ => '$value',
  };

  static List<Map<String, Object?>> _optionList(Object? raw) {
    final options = <Map<String, Object?>>[];
    if (raw is! List) return options;
    for (final option in raw) {
      if (option is Map) options.add(option.cast<String, Object?>());
    }
    return options;
  }
}

/// [value] as a whole number: dsh's JSON numbers arrive as either kind.
int? _number(Object? value) => switch (value) {
  final int number => number,
  final double number => number.round(),
  _ => null,
};

import 'dart:math' as math;

import '../../chat/chat_models.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'dsh_route.dart';

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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;

  /// Now, for the one time dsh leaves us to work out: a thought's.
  final DateTime Function() _clock;

  /// Called with the `configOptions` dsh sends: with a new session, a
  /// resumed one, a pick of the user's, or a change of dsh's own.
  final void Function(List<Map<String, Object?>> options) options;

  /// How much of the model the context holds, as last reported; the route's
  /// while dsh has said nothing (`dsh_route.dart`).
  int contextWindow = DshRoute.defaultContextWindow;

  String? _turn;
  DateTime? _startedAt;

  /// When the step before a thought arrived: the wait since it is how long
  /// the model thought, dsh timing nothing itself. Reset by every step, not
  /// only by the turn, or each thought would carry the whole turn so far and
  /// their sum (a fold's "thought 37m 44s") would be nonsense.
  DateTime? _stepAt;

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

  /// Each tool call as first seen, to show again when it ends: its update
  /// names only its id (F9).
  final Map<String, _ToolCall> _tools = {};

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
    _startedAt = _clock();
    _stepAt = _startedAt;
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
        _stepAt = _clock();
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
        // dsh times nothing: a thought's time is the wait since the step
        // before it, in which the model was thinking. The turn's own start
        // stands for the first.
        final now = _clock();
        final since = _stepAt ?? _startedAt ?? now;
        _stepAt = now;
        final text = _text(update['content']);
        if (text == null || text.isEmpty) return;
        emit(
          ItemUpserted(
            nextSeq(),
            'thought:${++_thoughts}',
            ThinkingItem(
              text: text,
              tokens: text.length,
              seconds: math.max(
                1,
                (now.difference(since).inMilliseconds / 1000).round(),
              ),
            ),
          ),
        );
      case 'tool_call':
        _stepAt = _clock();
        final id = '${update['toolCallId'] ?? ''}';
        if (id.isEmpty) return;
        final title = '${update['title'] ?? ''}';
        final raw = update['rawInput'];
        // A call's arguments as an object; the todo tool's presentation
        // hands the list itself, so that counts as its `todos` too.
        final input = switch (raw) {
          final Map map => map.cast<String, Object?>(),
          final List todos => {'todos': todos},
          _ => const <String, Object?>{},
        };
        // dsh writes the whole todo list in the call itself (`todo_write`):
        // the items are what the step shows, its line the one in progress
        // (see todoStep). A shell call (`bash`, `pwsh`) is the command card
        // Claude Code's Bash gets: its description on the line, the whole
        // command one tap away. A `read` call is Claude Code's Read: the
        // file's name on the line, the whole path one tap away, the lines it
        // read as its detail. A `send_message` call is Claude Code's
        // SendMessage: what it says on the line, all of it one tap away.
        // Every other call is a command (F9).
        final todo = title.trim().toLowerCase() == 'todo_write';
        final command = _isShell(title) ? _string(input['command']) : null;
        final shell = command == null || command.trim().isEmpty
            ? null
            : command;
        final file = _isRead(title) ? _string(input['file_path']) : null;
        final reading = file == null || file.trim().isEmpty ? null : file;
        final text = _isMessage(title) ? _string(input['message']) : null;
        final message = text == null || text.trim().isEmpty ? null : text;
        final detail = _oneLine(raw);
        final call = shell != null
            ? _ToolCall.shell(
                command: shell,
                description: _string(input['description']),
                background: input['run_in_background'] == true,
              )
            : reading != null
            ? _ToolCall.read(
                path: reading,
                detail: _lineRange(input['offset'], input['limit']),
              )
            : message != null
            ? _ToolCall.message(message: message)
            : _ToolCall(
                kind: todo ? ToolKind.todo : ToolKind.command,
                tool: todo ? 'todo_write' : null,
                input: todo ? input : const {},
                target: todo ? _todoNow(input['todos']) : title,
                label: todo ? null : title,
                detail: todo || detail.isEmpty ? null : detail,
              );
        _tools[id] = call;
        _running.add(id);
        emit(ItemUpserted(nextSeq(), id, call.item(ToolStatus.running)));
      case 'tool_call_update':
        final id = '${update['toolCallId'] ?? ''}';
        final status = switch (update['status']) {
          'completed' => ToolStatus.succeeded,
          'failed' => ToolStatus.failed,
          _ => null,
        };
        // Still running: there is no progress to show, only the end (F9).
        if (id.isEmpty || status == null) return;
        _stepAt = _clock();
        _running.remove(id);
        final output = _output(update['content']);
        final call = _tools[id];
        emit(
          ItemUpserted(
            nextSeq(),
            id,
            call?.item(status, output: output) ??
                ToolCallItem(
                  kind: ToolKind.command,
                  target: '',
                  status: status,
                  output: output,
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
      final started? => _clock().difference(started),
      null => null,
    };
    _turn = null;
    _startedAt = null;
    _stepAt = null;
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
      if (_tools[id] case final call?) {
        emit(ItemUpserted(nextSeq(), id, call.item(ToolStatus.failed)));
      }
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

  /// Whether [title] names a shell tool: dsh calls its tools `bash` and
  /// `pwsh`, the persistent pair keeping the same names.
  static bool _isShell(String title) => switch (title.trim().toLowerCase()) {
    'bash' || 'pwsh' => true,
    _ => false,
  };

  /// Whether [title] names the read tool: dsh calls it `read`.
  static bool _isRead(String title) => title.trim().toLowerCase() == 'read';

  /// The lines a read asked for (`L10-19`), from its 1-based [offset] and
  /// [limit]; null unless both are given, as Claude Code's Read shows it.
  static String? _lineRange(Object? offset, Object? limit) {
    final first = _number(offset);
    final count = _number(limit);
    if (first == null || count == null) return null;
    return 'L$first-${first + count - 1}';
  }

  /// [path]'s last part: the file's name, its directory left to the row's
  /// tooltip and file link.
  static String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

  /// Whether [title] names the tool that messages another agent: dsh calls
  /// it `send_message`.
  static bool _isMessage(String title) =>
      title.trim().toLowerCase() == 'send_message';

  /// [value] as text, when it is.
  static String? _string(Object? value) => value is String ? value : null;

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

  /// The item in progress in the todo list a call wrote, which the step's
  /// line shows; empty when none is.
  static String _todoNow(Object? todos) {
    if (todos is! List) return '';
    for (final todo in todos) {
      if (todo is Map && todo['status'] == 'in_progress') {
        return '${todo['content'] ?? ''}';
      }
    }
    return '';
  }

  static List<Map<String, Object?>> _optionList(Object? raw) {
    final options = <Map<String, Object?>>[];
    if (raw is! List) return options;
    for (final option in raw) {
      if (option is Map) options.add(option.cast<String, Object?>());
    }
    return options;
  }
}

/// A tool call as first seen, kept to show it again when its update arrives:
/// that one names only its id (F9), and what a shell, read, message or todo
/// step shows is in the call's own input.
class _ToolCall {
  const _ToolCall({
    required this.kind,
    required this.target,
    this.tool,
    this.input = const {},
    this.label,
    this.detail,
  }) : command = null,
       description = null,
       background = false,
       path = null,
       message = null;

  /// A shell call, shown as a command card ([TerminalItem]) rather than a
  /// step: its [description] on the line, the whole [command] in the body.
  const _ToolCall.shell({
    required this.command,
    this.description,
    this.background = false,
  }) : kind = ToolKind.command,
       target = '',
       tool = null,
       input = const {},
       label = null,
       detail = null,
       path = null,
       message = null;

  /// A read call, shown as the read step Claude Code's Read gets: the file's
  /// name on the line, the whole [path] one tap away, [detail] the lines it
  /// read.
  const _ToolCall.read({required this.path, this.detail})
    : kind = ToolKind.read,
      target = '',
      tool = null,
      input = const {},
      label = null,
      command = null,
      description = null,
      background = false,
      message = null;

  /// A message to another agent, shown as Claude Code's SendMessage is: what
  /// it says on the line, all of it one tap away.
  const _ToolCall.message({required this.message})
    : kind = ToolKind.message,
      target = '',
      tool = null,
      input = const {},
      label = null,
      detail = null,
      command = null,
      description = null,
      background = false,
      path = null;

  final ToolKind kind;
  final String target;

  /// The tool's own name, for a kind each of whose tools says its own way
  /// (see `todoStep`).
  final String? tool;

  /// What it was called with, for those.
  final Map<String, Object?> input;

  final String? label;
  final String? detail;

  /// A read call's file, whole: the row opens it and shows only its name.
  final String? path;

  /// A message call's text, whole: the line takes one line of it, the body
  /// all of it.
  final String? message;

  /// A shell call's command; null for another call.
  final String? command;

  /// What the command is for, in the agent's words.
  final String? description;

  /// Whether it was left running on its own.
  final bool background;

  /// The item to show for it, [status] as it now stands and [output] what
  /// it returned.
  ChatItem item(ToolStatus status, {String? output}) {
    final command = this.command;
    if (command != null) {
      return TerminalItem(
        command: command,
        description: description,
        output: output ?? '',
        status: switch (status) {
          ToolStatus.running => CommandStatus.running,
          ToolStatus.succeeded => CommandStatus.succeeded,
          ToolStatus.failed || ToolStatus.denied => CommandStatus.failed,
        },
        background: background,
      );
    }
    final path = this.path;
    if (path != null) {
      return ToolCallItem(
        kind: ToolKind.read,
        target: DshTranslator._baseName(path),
        path: path,
        detail: detail,
        status: status,
        // The file itself opens from the row: what it returned is kept only
        // when it failed, as the reason.
        output: status == ToolStatus.succeeded ? null : output,
      );
    }
    final message = this.message;
    if (message != null) {
      return ToolCallItem(
        kind: ToolKind.message,
        target: DshTranslator._oneLine(message),
        status: status,
        // Delivered, all of it opens from the line; a failure keeps dsh's
        // reason instead.
        output: status == ToolStatus.failed ? output : message,
      );
    }
    return ToolCallItem(
      kind: kind,
      tool: tool,
      input: input,
      target: target,
      label: label,
      detail: detail,
      status: status,
      output: output,
    );
  }
}

/// [value] as a whole number: dsh's JSON numbers arrive as either kind.
int? _number(Object? value) => switch (value) {
  final int number => number,
  final double number => number.round(),
  _ => null,
};

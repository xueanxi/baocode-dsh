import '../kernel_event.dart';
import '../kernel_types.dart';

/// The approvals dsh asks for: leave to run a command that steps outside its
/// sandbox — the one thing it ever asks about (F11).
///
/// Its request names the tool call and nothing else (F10): the tool's name
/// and its reason are taken from the `tool_call` that went before it, by its
/// id, and said in plain words when that call did not come. What it offers is
/// one of two options, `allow-once` and `reject-once`: no "always allow",
/// which the panel would show as a third button dsh has nothing to do with.
class DshApprovals {
  DshApprovals({
    required this.emit,
    required this.nextSeq,
    required this.write,
  });

  /// What the conversation is told.
  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;

  /// The answer, as JSON-RPC over dsh's stdin; false when it is gone.
  final bool Function(Map<String, Object?> message) write;

  /// What each tool call was called, and why it asked, by its id: the
  /// approval carries neither (F10).
  final Map<String, ({String title, String? reason})> _calls = {};

  /// The requests dsh has open: this adapter's id → the JSON-RPC id the
  /// answer goes back under.
  final Map<String, Object?> _open = {};

  /// The requests asked so far, to number them: the same tool may be asked
  /// about twice, and each question is its own.
  int _asked = 0;

  /// What the panel is told when the tool call the approval answers for never
  /// came.
  static const noTool = 'Approval needed';

  /// What the panel is told when the tool call gave no justification.
  static const noReason = 'dsh did not give a reason';

  /// dsh's `tool_call`, kept for the approval it may ask about: the update
  /// that ends it names the call by id only.
  void toolCall(Map<String, Object?> update) {
    if (update['sessionUpdate'] != 'tool_call') return;
    final id = '${update['toolCallId'] ?? ''}';
    if (id.isEmpty) return;
    _calls[id] = (
      title: '${update['title'] ?? ''}',
      reason: _justification(update['rawInput']),
    );
  }

  /// dsh asking leave: held as the conversation's pending question, open
  /// until the user answers it or the turn ends.
  void requested(Object? rpcId, Map<String, Object?> params) {
    final toolCallId = _toolCallId(params);
    final call = _calls[toolCallId];
    final title = switch (call?.title) {
      final name? when name.trim().isNotEmpty => name,
      _ => noTool,
    };
    final reason = switch (call?.reason) {
      final said? when said.trim().isNotEmpty => said,
      _ => noReason,
    };
    final id = toolCallId.isEmpty
        ? 'approval:${++_asked}'
        : 'approval:$toolCallId:${++_asked}';
    _open[id] = rpcId;
    emit(
      InteractionRequested(
        nextSeq(),
        ApprovalRequest(
          id: id,
          // The tool's name goes in the title: it is the title the panel
          // draws, and `toolName` it draws nowhere (§5.6).
          title: title,
          toolName: title,
          reason: reason,
          // dsh has `allow-once`, so the panel must not offer more.
          alwaysAllowLabel: null,
        ),
      ),
    );
  }

  /// The user's answer to [requestId]: dsh is told, and the question is
  /// resolved. One already answered, cancelled or gone is ignored — the user
  /// may have answered a question the turn then stopped.
  void answer(String requestId, InteractionAnswer answer) {
    if (!_open.containsKey(requestId)) return;
    final rpcId = _open.remove(requestId);
    final optionId = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'allow-once',
      // dsh offers no "always": allowing it once is all it can be told.
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) => 'allow-once',
      // What the user wrote with a refusal is dropped: dsh has nowhere to
      // put it (§5.6).
      _ => 'reject-once',
    };
    write({
      'id': rpcId,
      'result': {
        'outcome': {'outcome': 'selected', 'optionId': optionId},
      },
    });
    emit(InteractionResolved(nextSeq(), requestId));
  }

  /// The turn stopped, or dsh is going: every request still open is answered
  /// `cancelled`, so that dsh is not left waiting for an answer that is never
  /// coming, and the panel is not left asking.
  void cancelOpen() {
    if (_open.isEmpty) return;
    final open = Map.of(_open);
    _open.clear();
    for (final MapEntry(key: id, value: rpcId) in open.entries) {
      write({
        'id': rpcId,
        'result': {
          'outcome': {'outcome': 'cancelled'},
        },
      });
      emit(InteractionResolved(nextSeq(), id));
    }
  }

  /// The tool call an approval is about.
  static String _toolCallId(Map<String, Object?> params) =>
      switch (params['toolCall']) {
        final Map call => '${call['toolCallId'] ?? ''}',
        _ => '',
      };

  /// Why dsh says it asks, from the tool call's input: its `justification`,
  /// where it gave one.
  static String? _justification(Object? rawInput) => switch (rawInput) {
    final Map input => switch (input['justification']) {
      final String said => said,
      _ => null,
    },
    _ => null,
  };
}

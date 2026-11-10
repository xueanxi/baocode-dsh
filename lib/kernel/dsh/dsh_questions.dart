import 'dart:async';

import '../kernel_event.dart';
import '../kernel_types.dart';

/// dsh's `ask_user_question`, put to the user as the conversation's question
/// (`QuestionRequest`) and answered by the panel.
///
/// dsh's own tool asks through `ctx.userQuestions`, which the ACP profile has
/// no answerer for (see `dsh_ask_bridge.dart`): the bridge plugin takes that
/// waterfall and puts the question here, over the app's local HTTP endpoint.
/// The answer is the labels picked per question; null where it was given up
/// (the turn stopped or the process went), while a panel dismissed without
/// picking comes back as empty lists, which dsh's tool reads as skipped.
class DshQuestions {
  DshQuestions({required this.emit, required this.nextSeq});

  /// What the conversation is told.
  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;

  /// The questions open, by the id the panel answers: this adapter's id → the
  /// answer it waits on.
  final Map<String, Completer<List<List<String>>?>> _open = {};

  /// The questions asked so far, to number them: two of them may be open at
  /// once, and each is its own.
  int _asked = 0;

  /// Puts [questions] (dsh's tool input) to the user, and completes with the
  /// labels picked for each — one list per question, in the order asked.
  Future<List<List<String>>?> ask(List<Map<String, Object?>> questions) {
    final id = 'ask:${++_asked}';
    final answer = Completer<List<List<String>>?>();
    _open[id] = answer;
    emit(
      InteractionRequested(
        nextSeq(),
        QuestionRequest(
          id: id,
          title: 'DSH has a question',
          questions: [
            for (final question in questions)
              Question(
                prompt: '${question['question'] ?? ''}',
                header: '${question['header'] ?? ''}',
                // dsh's question service normalizes the tool's
                // `multi_select` to `multiSelect` before the waterfall hands
                // it over; the tool's own spelling is accepted too, since a
                // question may come either way.
                allowMultiple:
                    question['multiSelect'] == true ||
                    question['multi_select'] == true,
                options: [
                  for (final option in question['options'] as List? ?? const [])
                    if (option is Map)
                      QuestionOption(
                        '${option['label'] ?? ''}',
                        description: '${option['description'] ?? ''}',
                      ),
                ],
              ),
          ],
        ),
      ),
    );
    return answer.future;
  }

  /// The user's answer to [requestId]: what they picked for each question, or
  /// nothing where they dismissed it without picking. One already answered,
  /// cancelled or gone is ignored — the turn may have stopped since.
  void answer(String requestId, InteractionAnswer answer) {
    final open = _open.remove(requestId);
    if (open == null || open.isCompleted) return;
    emit(InteractionResolved(nextSeq(), requestId));
    open.complete(switch (answer) {
      QuestionAnswer(:final picks) => picks,
      _ => null,
    });
  }

  /// Answers every open question with nothing (the turn stopped, or dsh is
  /// going), so that the panel is not left asking about a turn that is done
  /// and the bridge does not wait for an answer that cannot come.
  void cancelOpen() {
    for (final MapEntry(key: id, value: open) in [..._open.entries]) {
      if (open.isCompleted) continue;
      _open.remove(id);
      emit(InteractionResolved(nextSeq(), id));
      open.complete(null);
    }
  }
}

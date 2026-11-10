import '../../usage/usage_record.dart';

/// What dsh's usage bridge reports of one model call (`dsh_usage_bridge.dart`)
/// as a [UsageCall] for the app's ledger.
///
/// The tokens are the provider's own, as dsh committed them: input not read
/// from its cache, the cache read and written, the output, and the reasoning
/// within it. Nothing is estimated here; a call whose report has no tokens
/// at all (an adapter that reported none) is left out rather than guessed.
///
/// A session dsh made for a subagent is still this conversation's: its calls
/// are kept on the conversation's id, marked [UsageClass.subagent] and
/// attributed to that session.
class DshUsageMeter {
  DshUsageMeter({
    required this.record,
    required this.session,
    this.provider = 'dsh',
    this.providerName = 'DSH',
  });

  /// Keeps [call] with the conversation's others.
  final void Function(UsageCall call) record;

  /// The conversation's dsh session, as it is now.
  final String? Function() session;
  final String provider;
  final String providerName;

  /// Takes one report, if it says tokens; reports without them change
  /// nothing.
  void receive(Map<String, Object?> report) {
    final usage = report['usage'];
    if (usage is! Map) return;
    final input = _int(usage['input']);
    final output = _int(usage['output']);
    final cacheRead = _int(usage['cacheRead']);
    final cacheWrite = _int(usage['cacheWrite']);
    final reasoning = _int(usage['reasoning']);
    if (input + output + cacheRead + cacheWrite == 0) return;
    final conversation = session() ?? _text(report['session']);
    if (conversation == null || conversation.isEmpty) return;
    final sessionId = _text(report['session']);
    final child = sessionId != null && sessionId != conversation;
    final at = _time(report['time']) ?? DateTime.now();
    final asked = _time(report['started']);
    record(
      UsageCall(
        at: at,
        duration: asked == null || at.isBefore(asked)
            ? Duration.zero
            : at.difference(asked),
        status: 200,
        provider: _text(report['provider']) ?? provider,
        providerName: providerName,
        protocol: 'openaiChat',
        model: _text(report['model']) ?? '',
        upstreamModel: _text(report['responseModel']),
        session: conversation,
        requestClass: child ? UsageClass.subagent : UsageClass.main,
        agentId: child ? sessionId : null,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        reasoning: reasoning,
        stopReason: _text(report['stopReason']),
      ),
    );
  }

  static int _int(Object? value) => switch (value) {
    final int value when value > 0 => value,
    final double value when value > 0 => value.truncate(),
    _ => 0,
  };

  static String? _text(Object? value) => switch (value) {
    final String value when value.trim().isNotEmpty => value.trim(),
    _ => null,
  };

  /// A millisecond epoch: dsh's event times, and the call's start.
  static DateTime? _time(Object? value) => switch (value) {
    final int value when value > 0 => DateTime.fromMillisecondsSinceEpoch(
      value,
    ),
    final double value when value > 0 => DateTime.fromMillisecondsSinceEpoch(
      value.truncate(),
    ),
    _ => null,
  };
}

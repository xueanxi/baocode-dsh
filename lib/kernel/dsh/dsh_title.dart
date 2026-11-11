// A conversation's title, asked of the dsh this machine runs in one run of
// its `headless` profile (see `dsh_ask.dart`): the same route as the
// conversation, not the app's Claude Haiku. The reply is cleaned as any
// title is (`kernel/title_prompt.dart`); null when dsh gives none or the
// ask is cancelled.

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../title_prompt.dart';
import 'dsh_ask.dart';
import 'dsh_route.dart';

/// Asks dsh [system] and [prompt], as [askDshTitle] does: the real one, or a
/// test's — which must not start a process.
@visibleForTesting
Future<String> Function(
  String system,
  String prompt, {
  Future<void>? cancel,
  DshRoute? route,
})?
dshTitleAsk;

/// Asks dsh on [route] for a title of [message] (the first thing a
/// conversation was asked); null when it gives none. Completing [cancel]
/// stops it.
typedef DshTitleAsker = Future<String?> Function(
  String message, {
  DshRoute? route,
  Future<void>? cancel,
});

/// The title dsh gives [message], by its own route; null when it cannot.
Future<String?> askDshTitle(
  String message, {
  DshRoute? route,
  Future<void>? cancel,
}) async {
  var text = message.trim();
  if (text.isEmpty) return null;
  if (text.length > agentTitleMessageBudget) {
    text = '${text.substring(0, agentTitleMessageBudget)}…';
  }
  final prompt = '<message>\n$text\n</message>';
  final ask = dshTitleAsk;
  try {
    return cleanAgentTitle(
      await (ask != null
          ? ask(agentTitleSystem, prompt, route: route, cancel: cancel)
          : askDsh(agentTitleSystem, prompt, route: route, cancel: cancel)),
    );
  } on DshAskCancelled {
    return null;
  } on Object catch (error) {
    debugPrint('DSH title not generated: $error');
    return null;
  }
}

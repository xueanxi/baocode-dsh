import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart' show writeFileAtomically;

/// dsh's own token accounting, sent to the app as each model call is
/// committed: a plugin of BaoCode's, written beside the patch
/// (`dsh_patch.dart`) and named by it.
///
/// dsh's ACP bridge publishes only the context's occupancy (`usage_update`),
/// not what a call spent. Its durable `assistant/message` event carries the
/// provider's exact tokens, though (`inputTokens`, `outputTokens`,
/// `cacheReadTokens`, `cacheWriteTokens`, `reasoningTokens`), so the plugin
/// listens for that event and posts it to the app's usage endpoint
/// (`dsh_usage_server.dart`). The app keeps it in the usage ledger as it
/// keeps a Claude Code call: the tokens are the provider's, not an estimate;
/// only the money is worked out from a price.
///
/// Where the plugin posts, and what it proves itself with, come from the
/// environment the conversation's dsh is started with ([urlVariable],
/// [tokenVariable]): neither goes in the patch, which holds no secret.
abstract final class DshUsageBridge {
  /// The plugin's file in the app's dsh folder.
  static const fileName = 'usage_bridge.mjs';

  /// Where the plugin posts each call (the usage endpoint's URL).
  static const urlVariable = 'BAOCODE_USAGE_URL';

  /// What it proves itself with (the usage endpoint's token).
  static const tokenVariable = 'BAOCODE_USAGE_TOKEN';

  /// The plugin as written: plain JavaScript, no imports, and nothing tied to
  /// a dsh version beyond the session event's name (`assistant/message`) and
  /// the provider usage fields it carries.
  static const source = r'''
// BaoCode's token accounting for dsh. Generated; do not edit.
export const name = 'baocode-usage-bridge';

export function apply(ctx) {
  const base = process.env.BAOCODE_USAGE_URL;
  const token = process.env.BAOCODE_USAGE_TOKEN;
  if (!base || !token) return;
  const headers = {
    'content-type': 'application/json',
    authorization: 'Bearer ' + token,
  };

  // When each step asked the model, so a call's time to answer is kept too.
  const started = new Map();
  const stepKey = (session, data) =>
    session.id + '|' + data.turn + '|' + data.step;

  const number = (value) => typeof value === 'number' && isFinite(value)
    ? Math.max(0, Math.trunc(value))
    : undefined;

  const report = (session, event) => {
    const data = event.data;
    const usage = data?.usage;
    if (!usage) return;
    const key = stepKey(session, data);
    const at = number(event.time) ?? Date.now();
    const asked = number(started.get(key));
    started.delete(key);
    const source = data.message?.source;
    const response = source?.replayState?.response;
    const body = {
      session: session.id,
      parent: session.header?.parentSession,
      turn: data.turn,
      step: data.step,
      time: at,
      started: asked,
      provider: source?.provider,
      model: source?.model,
      responseModel: response?.responseModel,
      stopReason: response?.stopReason,
      usage: {
        input: number(usage.inputTokens),
        output: number(usage.outputTokens),
        cacheRead: number(usage.cacheReadTokens),
        cacheWrite: number(usage.cacheWriteTokens),
        reasoning: number(usage.reasoningTokens),
        total: number(usage.totalTokens),
      },
    };
    fetch(base + '/usage', {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    }).catch(() => {});
  };

  ctx.on('session/event', (session, event) => {
    try {
      if (event?.type === 'step/start') {
        started.set(stepKey(session, event.data), number(event.time) ?? Date.now());
      } else if (event?.type === 'assistant/message') {
        report(session, event);
      } else if (event?.type === 'turn/end') {
        // The turn is over: no step of it can still be answered.
        const prefix = session.id + '|' + event.data.turn + '|';
        for (const key of started.keys()) {
          if (key.startsWith(prefix)) started.delete(key);
        }
      }
    } catch {
      // A malformed event is not the conversation's: keep listening.
    }
  });
}
''';

  /// Writes the plugin in [directory] and answers with its `file://` URL, as
  /// the patch names it; kept as it is when it already says exactly that.
  static Future<String> ensure(String directory) async {
    final file = File(p.join(directory, fileName));
    try {
      if (await file.readAsString() == source) return file.uri.toString();
    } on FileSystemException {
      // Not there yet (or unreadable): written below.
    }
    await Directory(directory).create(recursive: true);
    await writeFileAtomically(file, source);
    return file.uri.toString();
  }
}

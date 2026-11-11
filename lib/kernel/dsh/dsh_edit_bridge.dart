import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart' show writeFileAtomically;

/// Going back in a dsh conversation, which ACP has no call for: a plugin of
/// BaoCode's own, written beside the patch (`dsh_patch.dart`) and named by it.
///
/// dsh's session log is append-only, and its model-visible history is a
/// surface fold over it: a message event may replace a range of earlier
/// nodes (`{op: 'replace', startSeq, endSeq}`), which is how compaction
/// hides what it summarized. The plugin does the same for an edit, so the
/// next prompt is answered from the conversation as the user now sees it —
/// no fork, no restart, and the same session id.
///
/// ACP has no field for "this prompt is an edit", so the kernel says it in
/// the prompt itself: [DshEditBridge.marker] repeated as many times as turns
/// to drop, before the text ([DshKernel] adds it; the translator shows the
/// text without it). The plugin works in two steps of the agent loop, both
/// before the prompt's model request is built:
///
///  * `agent/pre-step` sees the claimed prompt. It counts the markers, takes
///    them out of the message (keeping its id, which ACP is waiting on), and
///    remembers how many old turns this step drops.
///  * `agent/request` runs once the step is open and before its system
///    prompt and prompt are admitted. It appends an empty `developer/message`
///    replacing the old tail — from the edited prompt through the turn
///    before this one. An empty developer message holds a surface position
///    but projects no model message, and being appended inside the open step
///    is what dsh's invariants allow.
///
/// The loop then appends this step's system prompt and the clean prompt; the
/// history is the old prefix, then the edit. Nothing is appended from a
/// `session/event` listener: dsh turns an append reentered while another is
/// publishing down, and the event names used here are the loop's own hooks.
abstract final class DshEditBridge {
  /// The plugin's file in the app's dsh folder.
  static const fileName = 'edit_bridge.mjs';

  /// The prompt prefix that means "drop this many turns": two zero-width
  /// characters per turn. Nothing a user types by accident; if the plugin is
  /// not there they reach the model as invisible formatting only.
  static const marker = '\u200B\u200C';

  /// The plugin as written: plain JavaScript, no imports, and nothing tied to
  /// a dsh version beyond agent hook names (`agent/pre-step`,
  /// `agent/request`) and the surface replacement shape.
  static const source = r'''
// BaoCode's rewind for dsh. Generated; do not edit.
export const name = 'baocode-edit-bridge';

const marker = '\u200B\u200C';

export function apply(ctx) {
  // One rewind waiting for its step, per session: the turn and step the
  // prompt was claimed in, and how many old turns it drops.
  const pending = new Map();

  const countMarkers = (text) => {
    let count = 0;
    let at = 0;
    while (text.startsWith(marker, at)) {
      count++;
      at += marker.length;
    }
    return count;
  };

  const textBlock = (message) => (message?.content ?? []).find(
    (block) => block?.type === 'text' && typeof block.text === 'string');

  const newId = () => {
    try {
      return globalThis.crypto.randomUUID();
    } catch {
      // A runtime without Web Crypto still names the message.
    }
    return 'rewind-' + Date.now().toString(36) + '-' +
      Math.random().toString(36).slice(2);
  };

  // [message] without the markers it starts with, its identity and source
  // kept: the prompt the loop admits is the one ACP is waiting on.
  const withoutMarkers = (message, turns) => {
    const length = marker.length * turns;
    const content = [];
    let stripped = false;
    for (const block of message.content ?? []) {
      if (!stripped && block?.type === 'text' &&
          typeof block.text === 'string' && block.text.startsWith(marker)) {
        stripped = true;
        const text = block.text.slice(length);
        if (text !== '') content.push({ ...block, text });
      } else {
        content.push(block);
      }
    }
    return { ...message, content };
  };

  // The user prompts dsh has on its surface, in order: injected context and
  // tool messages have other sources and do not count as turns, and a prompt
  // an earlier edit already hid is not on the surface any more.
  const userPrompts = (session) => {
    const prompts = [];
    const surface = new Set(session.surface.nodes);
    for (const event of session.snapshotEvents()) {
      if (!surface.has(event.seq)) continue;
      if (event.type !== 'user/message') continue;
      if (event.surfaceOp !== 'append') continue;
      if (event.data?.source?.kind !== 'user') continue;
      prompts.push(event);
    }
    return prompts;
  };

  const lastTurnStart = (session) => {
    let at = -1;
    for (const event of session.snapshotEvents()) {
      if (event.type === 'turn/start') at = event.seq;
    }
    return at;
  };

  // Hides [seqs] behind one empty developer message: a surface replacement
  // that projects no model message, appended inside the open step.
  const hide = (session, at, seqs) => {
    if (seqs.length === 0) return;
    session.append('developer/message', {
      turn: at.turn,
      step: at.step,
      message: {
        id: newId(),
        role: 'developer',
        content: [],
        source: { kind: 'user' },
      },
    }, {
      surfaceOp: {
        op: 'replace',
        startSeq: seqs[0],
        endSeq: seqs[seqs.length - 1],
      },
      sourceEventSeqs: seqs,
    });
  };

  ctx.on('agent/pre-step', async ({ agent, turn, step }, next) => {
    const decision = await next();
    if (decision.kind !== 'enter') return decision;
    let found = false;
    const cleaned = decision.messages.map((message) => {
      if (found || message?.source?.kind !== 'user') return message;
      const block = textBlock(message);
      const turns = block == null ? 0 : countMarkers(block.text);
      if (turns === 0) return message;
      found = true;
      pending.set(agent.session.id, { turn, step, turns });
      return withoutMarkers(message, turns);
    });
    if (!found) return decision;
    return { ...decision, messages: cleaned };
  });

  ctx.on('agent/request', async ({ agent, turn, step }, next) => {
    const rewind = pending.get(agent.session.id);
    if (rewind != null && rewind.turn === turn && rewind.step === step) {
      pending.delete(agent.session.id);
      try {
        const session = agent.session;
        const prompts = userPrompts(session);
        const target = prompts[prompts.length - rewind.turns];
        const nodes = [...session.surface.nodes];
        const start = target === undefined ? -1 : nodes.indexOf(target.seq);
        // The old tail ends where this turn began: nothing of the request
        // being assembled is on the surface yet, and a replacement must not
        // take it.
        const turnStart = lastTurnStart(session);
        let end = nodes.length - 1;
        if (turnStart >= 0) {
          end = -1;
          for (let i = 0; i < nodes.length; i++) {
            if (nodes[i] < turnStart) end = i;
          }
        }
        if (start >= 0 && end >= start) {
          hide(session, { turn, step }, nodes.slice(start, end + 1));
        }
      } catch {
        // An edit that cannot land leaves the conversation as it was: the
        // prompt is still sent.
      }
    }
    return next();
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

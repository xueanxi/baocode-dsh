import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart' show writeFileAtomically;

/// The answerer dsh's ACP profile has none of: a plugin of BaoCode's own,
/// written beside the patch (`dsh_patch.dart`) and named by it.
///
/// dsh's `ask_user_question` tool asks through `ctx.userQuestions`, and the
/// ACP profile mounts the service but no answerer (the web client is one). The
/// plugin takes that waterfall and asks the app instead: it posts the
/// questions to [DshQuestionServer] and polls until the panel's answer is
/// there, so it waits as long as the user does.
///
/// It learns where to ask from the environment the conversation's dsh is
/// started with ([urlVariable], [tokenVariable]): neither goes in the patch,
/// which holds no secret.
abstract final class DshAskBridge {
  /// The plugin's file in the app's dsh folder.
  static const fileName = 'ask_bridge.mjs';

  /// Where the plugin posts its questions (`DshQuestionServer.url`).
  static const urlVariable = 'BAOCODE_ASK_URL';

  /// What it proves itself with (`DshQuestionServer.token`).
  static const tokenVariable = 'BAOCODE_ASK_TOKEN';

  /// The plugin as written: plain JavaScript, no imports, and nothing that
  /// would tie it to a dsh version beyond the waterfall's name
  /// (`user-questions/request`) and the answer shape (`{answers: [...]}`).
  static const source = r'''
// BaoCode's answerer for dsh's ask_user_question. Generated; do not edit.
export const name = 'baocode-ask-bridge';

const pollMs = 300;

export function apply(ctx) {
  const base = process.env.BAOCODE_ASK_URL;
  const token = process.env.BAOCODE_ASK_TOKEN;
  if (!base || !token) return;
  const headers = {
    'content-type': 'application/json',
    authorization: 'Bearer ' + token,
  };
  const sleep = (ms, signal) => new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => {
      clearTimeout(timer);
      reject(new Error('aborted'));
    }, { once: true });
  });

  ctx.on('user-questions/request', async (request) => {
    const created = await fetch(base + '/questions', {
      method: 'POST',
      headers,
      body: JSON.stringify({ questions: request.questions }),
    });
    if (!created.ok) {
      throw new Error('BaoCode did not take the question (' + created.status + ')');
    }
    const { id } = await created.json();
    const cancel = () => {
      fetch(base + '/questions/' + id + '/cancel', {
        method: 'POST',
        headers,
      }).catch(() => {});
    };
    request.signal?.addEventListener('abort', cancel, { once: true });
    try {
      for (;;) {
        if (request.signal?.aborted) {
          throw new Error('ask_user_question was aborted before the user answered');
        }
        const polled = await fetch(base + '/questions/' + id, { headers });
        const state = await polled.json();
        if (state.state === 'answered') return { answers: state.answers };
        if (state.state !== 'open') {
          throw new Error('The user did not answer the question.');
        }
        await sleep(pollMs, request.signal);
      }
    } finally {
      request.signal?.removeEventListener('abort', cancel);
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

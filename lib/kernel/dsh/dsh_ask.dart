// One question for the app itself — a commit message, say — answered by the
// dsh on this machine in one run of its `headless` profile: no session of
// the conversation's, no turn of the user's, and nothing kept in `~/.dsh`.
//
// `dsh --profile headless --patch <patch> --json -` reads the task on stdin
// and answers it as it exits: the answer is the `final` event's text, its
// thinking (`thinking`) and its steps (`status`) left out.

import 'dart:convert';

import 'dsh_locate.dart';
import 'dsh_ask_stub.dart' if (dart.library.io) 'dsh_ask_io.dart' as platform;

/// How long a question is given: a one-line answer, with the process to
/// start and dsh's own setup before it.
const dshAskTimeout = Duration(minutes: 2);

/// The arguments dsh answers [patchFile]'s one question with: the `headless`
/// profile, the patch that gives it its provider and model, and the task on
/// stdin, its events printed as JSON.
List<String> dshAskArguments(String patchFile) => [
  '--profile',
  'headless',
  '--patch',
  patchFile,
  '--json',
  // The task: everything written to stdin.
  '-',
];

/// The refs dsh can resolve (see `DshCredentials.refs`): this machine's own,
/// or a test's, which must not read the user's own store.
typedef DshAskCredentials = Future<Set<String>> Function();

/// Asks the dsh on this machine [prompt], with [system] before it (an empty
/// one leaves it out), and completes with the answer.
///
/// Completing [cancel] stops it, and throws [DshAskCancelled]; a dsh that
/// cannot be found or started, or that answers nothing, throws
/// [DshAskException]. [install] is the dsh to ask (found as the kernel finds
/// one otherwise); [credentials] the refs it can resolve.
Future<String> askDsh(
  String system,
  String prompt, {
  Future<void>? cancel,
  DshInstall? install,
  DshAskCredentials? credentials,
  Duration timeout = dshAskTimeout,
}) => platform.askDsh(
  system,
  prompt,
  cancel: cancel,
  install: install,
  credentials: credentials,
  timeout: timeout,
);

/// The answer in what dsh printed on [output] (its `--json` events, a line
/// each), what it wrote on [stderr], and the [code] it exited with: the last
/// `final` event's text — its model's answer, not its thinking, nor what its
/// steps said. Throws [DshAskException] for none, saying why dsh gave none.
String dshAskAnswer(String output, String stderr, int code) {
  String? answer;
  String? failure;
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      // Not an event: a line dsh printed for something else.
      continue;
    }
    if (decoded is! Map) continue;
    if (decoded['type'] == 'final' && decoded['text'] is String) {
      answer = decoded['text'] as String;
    } else if (decoded['type'] == 'status' && decoded['phase'] == 'turn_end') {
      // What the turn ended on: `error` and its message, when it did.
      if (decoded['reason'] case {'error': {'message': final String message}}) {
        failure = message;
      }
    }
  }
  if (answer != null && answer.trim().isNotEmpty) return answer;
  final reason = failure?.trim() ?? '';
  final said = stderr.trim();
  final why = reason.isNotEmpty ? reason : said;
  throw DshAskException(why.isEmpty ? 'dsh gave no answer (exit $code).' : why);
}

class DshAskCancelled implements Exception {
  const DshAskCancelled();
}

class DshAskException implements Exception {
  const DshAskException(this.message, {this.detail});

  final String message;

  /// More of what dsh said, where it said a lot.
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}

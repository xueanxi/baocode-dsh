import 'dsh_question_server_stub.dart'
    if (dart.library.io) 'dsh_question_server_io.dart'
    as platform;

/// Puts one question from dsh's `ask_user_question` to the user.
typedef DshAskHandler = Future<List<List<String>>?> Function(
  List<Map<String, Object?>> questions,
);

/// Makes the endpoint one conversation asks on, e.g.
/// [startDshQuestionServer] (a test may give one that cannot bind, so that
/// no socket is opened under its feet).
typedef DshQuestionServerStarter = Future<DshQuestionServer> Function(
  DshAskHandler ask,
);

/// The endpoint BaoCode's bridge plugin in dsh asks questions on: a loopback
/// HTTP server of this app's own, for as long as the conversation is open.
///
/// dsh's ACP profile has no answerer for `ctx.userQuestions` (the web client
/// is one; ACP is not), so the patch mounts a small bridge plugin
/// (`dsh_ask_bridge.dart`). It posts a question here and polls for the answer,
/// which is the panel's: the plugin waits as long as the user does, with no
/// protocol timeout between them.
abstract interface class DshQuestionServer {
  /// Binds the endpoint, once; later calls do nothing.
  Future<void> start();

  /// Where the plugin posts questions, e.g. `http://127.0.0.1:51234`.
  Uri get url;

  /// What the plugin proves itself with (`Authorization: Bearer`).
  String get token;

  /// Drops every question still open: the turn stopped, or dsh is going.
  void cancelAll();

  /// Stops listening.
  Future<void> close();
}

/// Starts a server answering with [ask]; on the web, where there is no
/// loopback, one that fails to start (the bridge is then left out).
Future<DshQuestionServer> startDshQuestionServer(DshAskHandler ask) =>
    platform.start(ask);

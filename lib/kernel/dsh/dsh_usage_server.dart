import 'dsh_usage_server_stub.dart'
    if (dart.library.io) 'dsh_usage_server_io.dart'
    as platform;

/// Takes one report from dsh's usage bridge: the exact provider tokens of one
/// committed model call (`dsh_usage_bridge.dart`).
typedef DshUsageHandler = void Function(Map<String, Object?> report);

/// Makes the endpoint one conversation's usage bridge posts on, e.g.
/// [startDshUsageServer] (a test may give one that cannot bind).
typedef DshUsageServerStarter = Future<DshUsageServer> Function(
  DshUsageHandler onUsage,
);

/// The endpoint BaoCode's usage bridge plugin posts on: a loopback HTTP
/// server of this app's own, for as long as the conversation is open.
///
/// It is separate from the question endpoint ([DshQuestionServer]): usage is
/// kept even where no one is at the computer to answer a question.
abstract interface class DshUsageServer {
  /// Binds the endpoint, once; later calls do nothing.
  Future<void> start();

  /// Where the plugin posts, e.g. `http://127.0.0.1:51234`.
  Uri get url;

  /// What the plugin proves itself with (`Authorization: Bearer`).
  String get token;

  /// Stops listening.
  Future<void> close();
}

/// Starts a server handing each report to [onUsage]; on the web, where there
/// is no loopback, one that fails to start (the bridge is then left out).
Future<DshUsageServer> startDshUsageServer(DshUsageHandler onUsage) =>
    platform.start(onUsage);

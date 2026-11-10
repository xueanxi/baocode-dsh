import 'dsh_locate.dart';
import 'dsh_transport_stub.dart'
    if (dart.library.io) 'dsh_transport_io.dart'
    as platform;

/// dsh's side of the adapter (the Adaptee): JSON-RPC 2.0 over the stdin and
/// stdout of `node <dsh>/lib/bin.js --profile acp --patch <patch>`, one
/// message per line.
abstract interface class DshTransport {
  /// What it sends: responses (`id` + `result`), notifications (`method` +
  /// `params`) and server requests (`id` + `method` + `params`, e.g. the
  /// permission it asks for); last, when the process ends, [DshExit.type].
  Stream<Map<String, Object?>> get messages;

  /// Writes a request, or the response to a server request, to its stdin.
  void write(Map<String, Object?> message);

  /// Completes once the process is gone, closed or not.
  Future<void> get exited;

  /// Ends the process.
  void close();

  /// The `node` that runs it, to name in a report of its failing.
  String? get executable;
}

/// The message a transport ends with: the process is gone.
abstract final class DshExit {
  static const type = 'transport_exit';

  /// [stderr] is what it printed there, and what it printed on stdout that
  /// was not a message.
  static Map<String, Object?> message(int code, String stderr) => {
    'type': type,
    'code': code,
    'stderr': stderr,
  };
}

/// dsh could not be started for [message], [detail] saying why.
class DshUnavailable implements Exception {
  const DshUnavailable(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}

/// How to start dsh for one session.
class DshLaunch {
  const DshLaunch({
    required this.cwd,
    required this.install,
    required this.patchFile,
    required this.permissionMode,
    this.environment,
  });

  /// Where the process starts, and so the sandbox's workspace root (F22).
  final String cwd;

  final DshInstall install;

  /// The patch it runs with (`--patch`; `dsh_patch.dart` writes it).
  final String patchFile;

  /// `read-only`, `workspace-write` or `danger-full-access`: the sandbox
  /// mode, and so whether a sandbox upgrade is asked about (F18).
  final String permissionMode;

  /// Set beside the app's own environment, if any.
  final Map<String, String>? environment;

  /// The variable [permissionMode] goes in.
  static const permissionModeVariable = 'DSH_PERMISSION_MODE';

  /// What runs: [DshInstall.binJs] with the ACP profile and [patchFile],
  /// the npm shim never (F20).
  List<String> get arguments => [
    install.binJs,
    '--profile',
    'acp',
    '--patch',
    patchFile,
  ];
}

/// Starts dsh for one session; on the web, where there are no processes,
/// fails saying so.
Future<DshTransport> startDsh(DshLaunch launch) =>
    platform.DshProcessTransport.start(launch);

/// Ends every dsh process the app started, and waits for them: for when the
/// app quits.
Future<void> stopDshProcesses() => platform.DshProcessTransport.stopAll();

/// Ends the dsh processes an earlier run of the app left running (a crash, a
/// force quit, a hot restart); none on the web.
Future<void> reapDshProcesses() => platform.DshProcessTransport.reapLeftovers();

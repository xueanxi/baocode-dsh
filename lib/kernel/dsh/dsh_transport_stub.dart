import 'dsh_transport.dart';

/// No processes in the browser: starting dsh fails saying so, and there is
/// nothing to stop.
abstract final class DshProcessTransport {
  static Future<DshTransport> start(DshLaunch launch) async =>
      throw const DshUnavailable(
        'DSH runs in the desktop app',
        detail: 'The browser cannot start local processes.',
      );

  static Future<void> stopAll() async {}

  static Future<void> reapLeftovers() async {}
}

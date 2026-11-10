import 'dsh_usage_server.dart';

/// No loopback on the web: usage is not reported, and the conversation runs
/// as it did before.
Future<DshUsageServer> start(DshUsageHandler onUsage) async =>
    throw UnsupportedError('No loopback endpoint on the web');

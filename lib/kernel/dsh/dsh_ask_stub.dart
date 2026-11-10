import 'dsh_locate.dart';
import 'dsh_ask.dart';

/// No dsh runs here (the browser): a question has no one to answer it.
Future<String> askDsh(
  String system,
  String prompt, {
  Future<void>? cancel,
  DshInstall? install,
  DshAskCredentials? credentials,
  Duration timeout = dshAskTimeout,
}) async => throw const DshAskException(
  'DSH runs as a local process, which this app cannot start.',
);

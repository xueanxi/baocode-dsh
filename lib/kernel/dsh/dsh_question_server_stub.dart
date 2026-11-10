import 'dsh_question_server.dart';

/// No loopback on the web: the bridge is left out, and dsh starts without it.
Future<DshQuestionServer> start(DshAskHandler ask) async =>
    throw UnsupportedError('No question endpoint on the web');

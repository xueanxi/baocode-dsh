import '../../chat/chat_models.dart';
import 'dsh_sessions.dart';

/// Where the dsh conversations are kept where there is no file system (the
/// web): only while the app runs, as dsh itself does not run there.
class FileDshSessionStore implements DshSessionStore {
  FileDshSessionStore([this.directory]);

  final String? directory;

  final Map<String, DshSession> _sessions = {};
  final Map<String, List<(String, ChatItem)>> _history = {};

  @override
  Future<List<DshSession>> sessions() async => [..._sessions.values];

  @override
  Future<void> keep(DshSession session) async =>
      _sessions[session.id] = session;

  @override
  Future<List<(String, ChatItem)>> history(String id) async => [
    ...?_history[id],
  ];

  @override
  Future<void> keepHistory(String id, List<(String, ChatItem)> items) async =>
      _history[id] = [...items];

  @override
  Future<void> remove(String id) async {
    _sessions.remove(id);
    _history.remove(id);
  }
}

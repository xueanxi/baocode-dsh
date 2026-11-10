import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import 'dsh_sessions_stub.dart'
    if (dart.library.io) 'dsh_sessions_io.dart'
    as platform;

/// A conversation started with dsh, as BaoCode recorded it when it ran it.
///
/// dsh itself keeps the conversation, but its `session/list` names only an
/// id and a cwd, and `session/resume` replays nothing (F17, F15). So the
/// sidebar cannot list or show it from dsh's store: what BaoCode started
/// is kept here, beside its own data (never in `~/.dsh`).
class DshSession {
  const DshSession({
    required this.id,
    required this.cwd,
    required this.updatedAt,
    this.title = '',
  });

  final String id;

  /// The project folder it runs in: dsh's sandbox is one folder (F5).
  final String cwd;

  /// What it was first asked, its first line; empty for a first message of
  /// images only.
  final String title;

  /// When it was last talked in here.
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'cwd': cwd,
    'title': title,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  /// [json] as kept, or null when it is not one (an older or broken file).
  static DshSession? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final cwd = json['cwd'];
    final updatedAt = (json['updatedAt'] as num?)?.toInt();
    if (id is! String || cwd is! String || updatedAt == null) return null;
    return DshSession(
      id: id,
      cwd: cwd,
      title: json['title'] as String? ?? '',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt),
    );
  }
}

/// Where BaoCode keeps the dsh conversations it started: their projects and
/// titles for the sidebar, and what was said in each for reading it back.
abstract interface class DshSessionStore {
  /// `dsh/sessions/` in the app's data folder, or at [directory] instead
  /// (e.g. under test).
  factory DshSessionStore.file([String? directory]) =
      platform.FileDshSessionStore;

  /// Every conversation kept, newest first not required.
  Future<List<DshSession>> sessions();

  /// Records [session] (a new one, or one talked in since).
  Future<void> keep(DshSession session);

  /// What was said in the conversation [id], oldest first; empty when it
  /// was never kept.
  Future<List<(String, ChatItem)>> history(String id);

  /// Keeps what was said in the conversation [id], replacing what was.
  Future<void> keepHistory(String id, List<(String, ChatItem)> items);

  /// Forgets the conversation [id]: its record and what was said in it.
  /// (dsh's own session file is dsh's, and left alone.)
  Future<void> remove(String id);
}

/// The conversations kept while this store lives, e.g. under test.
class MemoryDshSessionStore implements DshSessionStore {
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

/// The dsh conversations BaoCode started, listed by project as the sidebar
/// does: kept in [DshSessionStore] because dsh names no titles (F17).
class DshCatalog implements SessionCatalog {
  const DshCatalog({this.sessions});

  /// Where they are kept: the app's data folder when not given.
  final DshSessionStore? sessions;

  DshSessionStore get _store => sessions ?? DshSessionStore.file();

  @override
  Future<List<ProjectRecord>> projects() async {
    final byProject = <String, List<DshSession>>{};
    for (final session in await _store.sessions()) {
      (byProject[session.cwd] ??= []).add(session);
    }
    return [
      for (final MapEntry(key: cwd, value: sessions) in byProject.entries)
        ProjectRecord(path: cwd, sessions: _records(cwd, sessions)),
    ]..sort(_newestProjectFirst);
  }

  /// As Claude Code's are listed: the most recently talked in first.
  static int _newestProjectFirst(ProjectRecord a, ProjectRecord b) =>
      (b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
        a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => _records(cwd, [
    for (final session in await _store.sessions())
      if (session.cwd == cwd) session,
  ]);

  /// [sessions] of [cwd] as the sidebar lists them: the most recently
  /// talked in first.
  static List<SessionRecord> _records(String cwd, List<DshSession> sessions) =>
      [
        for (final session in sessions..sort(_newestFirst))
          SessionRecord(
            id: session.id,
            title: session.title,
            updatedAt: session.updatedAt,
            cwd: cwd,
          ),
      ];

  static int _newestFirst(DshSession a, DshSession b) =>
      b.updatedAt.compareTo(a.updatedAt);

  @override
  Future<void> delete(String id) => _store.remove(id);
}

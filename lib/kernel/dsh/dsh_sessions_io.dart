import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../../link/chat_codec.dart';
import '../../platform/data_dir.dart' show DataDirectory, writeFileAtomically;
import 'dsh_sessions.dart';

/// What BaoCode keeps of the dsh conversations it started, as files in
/// [`dsh/sessions/`](DataDirectory.dshSessionsDir): one small record per
/// conversation under `index/`, and what was said under `history/`.
///
/// One file per conversation, not one list: several agents may run at once,
/// each with a store of its own, and none should have to read and rewrite
/// the others' records to add its own.
class FileDshSessionStore implements DshSessionStore {
  FileDshSessionStore([this.directory]);

  /// Where the files are kept; by default
  /// [`dsh/sessions/`](DataDirectory.dshSessionsDir) in the app's data
  /// folder.
  final String? directory;

  String get _root => directory ?? DataDirectory.current.dshSessionsDir;

  /// A file name for [id]: an id dsh gave is a UUID, but one read from a
  /// file (or a newer dsh) is not to become a path.
  String _name(String id) => Uri.encodeComponent(id);

  File _indexFile(String id) =>
      File(p.join(_root, 'index', '${_name(id)}.json'));

  File _historyFile(String id) =>
      File(p.join(_root, 'history', '${_name(id)}.json'));

  /// Writes one after another: the last one written is the last one made.
  Future<void> _writing = Future.value();

  Future<void> _write(Future<void> Function() write) {
    final result = _writing.then((_) => write());
    // The caller learns of a failure; the next write is tried still.
    _writing = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<List<DshSession>> sessions() async {
    try {
      final folder = Directory(p.join(_root, 'index'));
      if (!await folder.exists()) return const [];
      final sessions = <DshSession>[];
      for (final entity in await folder.list().toList()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        if (await _readSession(entity) case final session?) {
          sessions.add(session);
        }
      }
      return sessions;
    } on Object {
      // None the app can read: nothing listed, rather than no workspace.
      return const [];
    }
  }

  Future<DshSession?> _readSession(File file) async {
    try {
      return DshSession.fromJson(jsonDecode(await file.readAsString()));
    } on Object {
      return null;
    }
  }

  @override
  Future<void> keep(DshSession session) => _write(() async {
    final file = _indexFile(session.id);
    await file.parent.create(recursive: true);
    await writeFileAtomically(file, jsonEncode(session.toJson()));
  });

  @override
  Future<List<(String, ChatItem)>> history(String id) async {
    try {
      final file = _historyFile(id);
      if (!await file.exists()) return const [];
      final json = jsonDecode(await file.readAsString());
      return [
        for (final item in switch (json) {
          {'items': final List<Object?> items} => items,
          _ => const <Object?>[],
        })
          ?_decode(item),
      ];
    } on Object {
      // Kept by another version, or broken: read as a conversation with
      // nothing before what comes next.
      return const [];
    }
  }

  static (String, ChatItem)? _decode(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final item = ChatCodec.decode(json['item']);
    return switch ((id, item)) {
      (final String id, final item?) => (id, item),
      _ => null,
    };
  }

  @override
  Future<void> keepHistory(String id, List<(String, ChatItem)> items) =>
      _write(() async {
        final file = _historyFile(id);
        await file.parent.create(recursive: true);
        await writeFileAtomically(
          file,
          jsonEncode({
            'items': [
              for (final (id, item) in items)
                {'id': id, 'item': ChatCodec.encode(item)},
            ],
          }),
        );
      });

  @override
  Future<void> remove(String id) => _write(() async {
    for (final file in [_indexFile(id), _historyFile(id)]) {
      try {
        if (await file.exists()) await file.delete();
      } on Object {
        // Gone already, or not readable: nothing more to forget.
      }
    }
  });
}

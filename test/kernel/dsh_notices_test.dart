import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/dsh/dsh_notices.dart';
import 'package:baocode/kernel/dsh/dsh_patch.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// What the preflight makes of dsh's store, and what the conversation is told
/// of a dsh older than the one probed. The store read is a folder of this
/// test's own, never the user's `~/.dsh`.
void main() {
  group('the credential preflight', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('t7-dsh-home');
    });
    tearDown(() => home.delete(recursive: true));

    /// The environment a kernel starts dsh with here: a home of the test's
    /// own, so that the store read goes there and nowhere else.
    Map<String, String> environment() => {'DSH_HOME': home.path};

    Future<Set<String>> refs() =>
        DshCredentials.refs(environment: environment())();

    test(
      'a store listing the ref under `refs`: the route has its key',
      () async {
        await File(p.join(home.path, DshCredentials.fileName)).writeAsString('''
version: 1
refs:
  STEPCODE_API_KEY: sk-one
  "${DshPatch.credentialRef}": sk-two
records:
  ${DshPatch.credentialRef}: 2026-11-09
''');

        expect(await refs(), {DshPatch.credentialRef});
      },
    );

    test('a store listing another ref: the route has none', () async {
      await File(p.join(home.path, DshCredentials.fileName)).writeAsString('''
version: 1
refs:
  OPENROUTER_API_KEY: sk-one
records:
  ${DshPatch.credentialRef}: 2026-11-09
''');

      // A name only under `records` is a date, not a key.
      expect(await refs(), isEmpty);
    });

    test('a store that cannot be read: no refs, and no failure', () async {
      // A folder of that name: reading it fails, and a store that cannot be
      // read is not a start that cannot happen (§5.3).
      await Directory(p.join(home.path, DshCredentials.fileName)).create();

      expect(await refs(), isEmpty);
    });
  });

  group('the version comparison', () {
    late List<KernelEvent> events;
    late DshNotices notices;

    setUp(() {
      events = [];
      notices = DshNotices(emit: events.add, nextSeq: () => events.length);
    });

    /// The ids the conversation was given.
    List<String> ids() => [
      for (final event in events.whereType<ItemUpserted>()) event.id,
    ];

    test('the version probed: nothing is said', () {
      notices.versionIsOld('0.2.0-rc.2', verified: '0.2.0-rc.2');

      expect(ids(), isEmpty);
    });

    test('the rc before it: said once, though it is run all the same', () {
      notices.versionIsOld('0.2.0-rc.1', verified: '0.2.0-rc.2');

      expect(ids(), ['notice:version']);
      expect(
        ((events.single as ItemUpserted).item as NoticeItem).kind,
        NoticeKind.warning,
      );

      // Once per conversation: the next start says nothing again.
      notices.versionIsOld('0.2.0-rc.1', verified: '0.2.0-rc.2');
      expect(ids(), ['notice:version']);
    });

    test('a version that is not one: nothing is claimed about it', () {
      notices.versionIsOld('unknown', verified: '0.2.0-rc.2');

      expect(ids(), isEmpty);
    });
  });
}

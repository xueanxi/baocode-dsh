import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/dsh/dsh_path_setting.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:baocode/settings/pages/settings_widgets.dart' show SettingsRow;
import 'package:baocode/settings/user_settings.dart';

/// Settings → General's DSH group: the path kept in settings.json, read back
/// as main() reads it, and the row the app's settings page shows.
void main() {
  late Directory data;
  late SettingsFiles files;

  setUp(() async {
    data = await Directory.systemTemp.createTemp('baocode-dsh-page');
    files = SettingsFiles(DataDirectory(data.path));
    await files.load();
  });

  tearDown(() async {
    files.dispose();
    await data.delete(recursive: true);
  });

  /// The path set now, as main() hands it to the kernel.
  String? current() =>
      DshPathSetting.parse(files.settings[DshPathSetting.settingKey]);

  /// What settings.json holds: whether `dshCode.path` is there, and its
  /// value; empty before the first write.
  Map<String, Object?> onDisk() {
    final file = File(files.settings.path);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  test('the path is kept in settings.json and read back; cleared, the '
      'setting goes and the dsh on the PATH is the one', () async {
    // Either form dsh takes: `node` and the bin.js, apart by a `|`.
    const path = r'C:\Program Files\nodejs\node.exe|C:\npm\bin.js';
    await files.settings.update(DshPathSetting.settingKey, path);
    expect(current(), path);
    expect(onDisk()[DshPathSetting.settingKey], path);

    // Cleared, as emptying the row does: not set, so the locator looks on
    // the PATH.
    await files.settings.update(DshPathSetting.settingKey, null);
    expect(current(), isNull);
    expect(onDisk(), isNot(contains(DshPathSetting.settingKey)));
  });

  testWidgets('the settings page shows the DSH group, its path row, the dsh '
      'set in it', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GeneralSettingsPage(settings: files.settings)),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = englishLocalizations;
    expect(find.text(l10n.dshSettingsTitle), findsOneWidget);
    expect(find.text(l10n.dshPathSetting), findsOneWidget);
    // Where the path may point, that dsh keeps its own conversations, and
    // where DSH runs at all.
    final description = tester.widget<Text>(
      find.text(l10n.dshPathSettingDescription),
    );
    expect(description.data, contains('lib/bin.js'));
    expect(description.data, contains('dsh web'));
    expect(description.data, contains('single-folder local projects'));
    // The modes are chosen in the conversation; the page says when that
    // choice locks in.
    expect(find.text(l10n.dshPathSettingPermissions), findsOneWidget);
    // None set: the row says automatic.
    expect(find.text(l10n.dshPathSettingHint), findsOneWidget);

    /// The row's own field (the page keeps others: the explorer's).
    Finder field() => find.descendant(
      of: find.ancestor(
        of: find.text(l10n.dshPathSetting),
        matching: find.byType(SettingsRow),
      ),
      matching: find.byType(TextField),
    );
    String? shown() => tester.widget<TextField>(field()).controller?.text;

    const path = r'C:\npm\lib\bin.js';
    await tester.runAsync(
      () => files.settings.update(DshPathSetting.settingKey, path),
    );
    await tester.pump();
    expect(shown(), path);

    await tester.runAsync(
      () => files.settings.update(DshPathSetting.settingKey, null),
    );
    await tester.pump();
    expect(shown(), isEmpty);
    expect(find.text(l10n.dshPathSettingHint), findsOneWidget);
  });
}

/// Settings → General → DSH: the dsh to run on this machine
/// (`dshCode.path` in settings.json), either its `lib/bin.js` or the `node`
/// to run it with and that path apart by a `|`; none set, the one found on
/// the PATH (see `dsh_locate.dart`).
abstract final class DshPathSetting {
  static const settingKey = 'dshCode.path';

  /// The path a setting's [value] names; null for none.
  static String? parse(Object? value) => switch (value) {
    final String path when path.trim().isNotEmpty => path.trim(),
    _ => null,
  };

  /// The path set now: main.dart reads it from settings.json.
  static String? Function() current = () => null;
}

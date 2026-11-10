import 'dart:io';

import 'package:path/path.dart' as p;

/// A route file that is there but cannot be used: unreadable, or saying
/// something a patch cannot carry. Never a fallback to dsh's own route — a
/// route written down on purpose is not one to skip in silence.
class DshRouteException implements Exception {
  const DshRouteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The model dsh's route runs on, as this machine's own file names it.
///
/// The patch used to name a provider, an endpoint and a model in code: the
/// values of one particular setup, and of no use to anyone else's. They are
/// the machine's own now, and no route file means no route of BaoCode's: dsh
/// then runs on the model its own ACP profile is configured with, exactly as
/// it does from dsh web (`docs/dsh-kernel.md` §7).
///
/// The file has `.env`'s shape — one `KEY=value` a line, `#` starting a
/// comment, quotes around a value if they help:
///
/// ```text
/// # The model this machine's dsh runs on.
/// provider=stepcodev2
/// base_url=https://i-ai-gw.stepx.com/v1
/// api_key_env=STEPCODEV2_API_KEY
/// model=deepseek-v4.1-flash
/// context_window=512000
/// ```
///
/// It holds no key: `api_key_env` is the *name* dsh reads the key under, and
/// dsh still reads its own store (F24).
final class DshRoute {
  const DshRoute({
    required this.provider,
    required this.baseUrl,
    required this.apiKeyEnv,
    required this.model,
    this.contextWindow = defaultContextWindow,
  });

  /// The file a machine keeps its route in, under the data directory's `dsh/`
  /// (`DataDirectory.dshDir`), beside the patch it is written into. It is
  /// never in the repository, and the app neither writes nor deletes it.
  static const fileName = 'dsh.env';

  /// A file of another path to read instead, for a script or a test. Empty or
  /// unset reads [fileName]; a path that is not there throws rather than
  /// falling back, an explicit file being one that was meant.
  static const pathVariable = 'BAOCODE_DSH_ENV';

  /// How much of the model the context is taken to hold before dsh reports
  /// its own: the route's `context_window` where it names one, and this
  /// otherwise (dsh tells the real one on the first turn).
  static const defaultContextWindow = 200000;

  /// The provider the patch declares, and the model under it.
  final String provider;
  final String baseUrl;

  /// The credential ref dsh reads the key under — a name, never a key (F24).
  final String apiKeyEnv;
  final String model;

  /// What the patch declares the model holds, until dsh says otherwise.
  final int contextWindow;

  /// The route kept under [directory], or the one [pathVariable] names; null
  /// when neither is there, dsh's own configuration being the route then.
  ///
  /// [environment] is the one dsh is started with, which is where
  /// [pathVariable] is looked for.
  static Future<DshRoute?> load({
    required String directory,
    Map<String, String> environment = const {},
  }) async {
    final named = environment[pathVariable]?.trim() ?? '';
    final file = named.isEmpty
        ? File(p.join(directory, fileName))
        : File(named);
    final type = await FileSystemEntity.type(file.path);
    if (type == FileSystemEntityType.notFound) {
      if (named.isNotEmpty) {
        throw DshRouteException('$named (`$pathVariable`) is not there.');
      }
      return null;
    }
    if (type != FileSystemEntityType.file) {
      throw DshRouteException('${file.path}: not a file.');
    }
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (error) {
      throw DshRouteException('${file.path}: ${error.message}');
    }
    try {
      return parse(text);
    } on FormatException catch (error) {
      throw DshRouteException('${file.path}: ${error.message}');
    }
  }

  /// [text] as a route. Throws [FormatException] naming the line, so that a
  /// typo in a file the user edits is one they can find.
  static DshRoute parse(String text) {
    final values = <String, String>{};
    final lines = text.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final at = index + 1;
      final equals = line.indexOf('=');
      if (equals <= 0) {
        throw FormatException('line $at: expected KEY=value');
      }
      final key = line.substring(0, equals).trim();
      final value = _valueOf(line.substring(equals + 1), at, key);
      if (!_keys.contains(key)) {
        throw FormatException(
          'line $at: $key is not a key of this file '
          '(${_keys.join(', ')})',
        );
      }
      if (values.containsKey(key)) {
        throw FormatException('line $at: $key is set twice');
      }
      if (value.isEmpty) throw FormatException('line $at: $key is empty');
      values[key] = value;
    }

    String required(String key) {
      final value = values[key];
      if (value == null) throw FormatException('$key is required');
      if (!_safe.hasMatch(value)) {
        throw FormatException(
          '$key has characters a patch cannot carry: '
          '"$value"',
        );
      }
      return value;
    }

    final provider = required('provider');
    final baseUrl = required('base_url');
    final apiKeyEnv = required('api_key_env');
    final model = required('model');
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
      throw FormatException('base_url is not an http(s) URL: "$baseUrl"');
    }
    final window = values['context_window'];
    final contextWindow = window == null
        ? defaultContextWindow
        : _windowOf(window);
    return DshRoute(
      provider: provider,
      baseUrl: baseUrl,
      apiKeyEnv: apiKeyEnv,
      model: model,
      contextWindow: contextWindow,
    );
  }

  static int _windowOf(String value) {
    final tokens = int.tryParse(value);
    if (tokens == null || tokens <= 0) {
      throw FormatException(
        'context_window is not a positive number: '
        '"$value"',
      );
    }
    return tokens;
  }

  /// [raw], the text after `KEY=`, without the quotes a value may be written
  /// in. A quote that opens and does not close is a mistake in the file.
  static String _valueOf(String raw, int at, String key) {
    final value = raw.trim();
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      return value.substring(1, value.length - 1);
    }
    if (value.startsWith('"') || value.startsWith("'")) {
      throw FormatException('line $at: the quote around $key is not closed');
    }
    return value;
  }

  static const _keys = [
    'provider',
    'base_url',
    'api_key_env',
    'model',
    'context_window',
  ];

  /// What the patch can carry as a YAML scalar without quoting: the provider,
  /// the URL, the ref and the model id all are such.
  static final _safe = RegExp(r'^[A-Za-z0-9._~:/+@%-]+$');
}

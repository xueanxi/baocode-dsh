import 'package:bao_remote/local.dart' show ClaudeEnvironment;

/// The login shell's environment, as the dsh kernel starts its dsh with it.
Future<Map<String, String>> customizationEnvironment() =>
    ClaudeEnvironment.of();

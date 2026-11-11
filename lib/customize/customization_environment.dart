import 'customization_environment_stub.dart'
    if (dart.library.io) 'customization_environment_io.dart'
    as platform;

/// The environment dsh would be started with, where its skill folders are
/// looked for: `DSH_HOME`, and the home a bare `~/.dsh` starts at.
Future<Map<String, String>> customizationEnvironment() =>
    platform.customizationEnvironment();

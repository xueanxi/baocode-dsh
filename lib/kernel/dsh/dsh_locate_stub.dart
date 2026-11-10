import 'dsh_locate.dart';

/// Locating dsh reads the filesystem, which the browser has none of: none is
/// found there.
Future<DshInstall?> locateDsh({
  String? setting,
  Map<String, String>? environment,
}) async => null;

import 'dart:io';

import 'package:bao_remote/local.dart' show AppPaths;
import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../kernel_event.dart';

/// What dsh's route, and this adapter, have to tell the conversation that the
/// agent itself did not: a dsh older than the one probed, a credential that
/// route needs and does not have, and pictures left out of a message.
///
/// In English, as Claude Code's kernel notices are (§5.12): they are the
/// runtime's words rather than the app's, so they are in no l10n file. Each
/// is said once — a warning on every start would bury the conversation.
class DshNotices {
  DshNotices({required this.emit, required this.nextSeq});

  final void Function(KernelEvent event) emit;
  final int Function() nextSeq;

  /// What was said already, by what it was about: the version once per
  /// conversation, pictures once per turn.
  final Set<String> _said = {};

  /// dsh at [version] is older than [verified], the one this adapter was
  /// written and probed against: what it answers may differ, and it is run
  /// all the same, dsh being the user's own (§5.9).
  void versionIsOld(String version, {required String verified}) {
    if (!_olderThan(version, verified)) return;
    _say(
      'version',
      'notice:version',
      NoticeKind.warning,
      'dsh $version is older than the version BaoCode was tested with '
          '($verified); some behaviour may differ.',
    );
  }

  /// dsh has no key for [ref]: its route fails every turn until it has one,
  /// which is worth knowing before the first of them (§5.3). The process is
  /// started all the same — dsh may still find a key of its own.
  void credentialMissing(String ref) {
    _say(
      'credential:$ref',
      'notice:credential:$ref',
      NoticeKind.error,
      'dsh has no credential for $ref; add it in dsh web (Models) or set the '
          'environment variable.',
    );
  }

  /// A message of [turnId] carried pictures the route cannot take: they were
  /// left out rather than sent to a model that never saw them (§5.10).
  void imagesDropped(String turnId) {
    _say(
      'images:$turnId',
      'notice:images:$turnId',
      NoticeKind.warning,
      'This dsh route cannot take images; they were left out.',
    );
  }

  void _say(String about, String id, NoticeKind kind, String text) {
    if (!_said.add(about)) return;
    emit(ItemUpserted(nextSeq(), id, NoticeItem(kind, text)));
  }

  /// Whether [version] comes before [verified].
  static bool _olderThan(String version, String verified) {
    final left = _versionParts(version);
    final right = _versionParts(verified);
    if (left == null || right == null) return false;
    final (numbers, lead) = left;
    final (theirs, theirLead) = right;
    for (var i = 0; i < numbers.length || i < theirs.length; i++) {
      final mine = i < numbers.length ? numbers[i] : 0;
      final other = i < theirs.length ? theirs[i] : 0;
      if (mine != other) return mine < other;
    }
    // The same numbers: a pre-release comes before the release it leads to.
    if (lead == theirLead || lead.isEmpty) return false;
    if (theirLead.isEmpty) return true;
    return _preReleaseBefore(lead, theirLead);
  }

  /// Whether pre-release [lead] comes before [lead2], its numbers compared as
  /// numbers (`rc.10` after `rc.2`, not before it).
  static bool _preReleaseBefore(String lead, String lead2) {
    final mine = lead.split(RegExp(r'[.+-]'));
    final theirs = lead2.split(RegExp(r'[.+-]'));
    for (var i = 0; i < mine.length && i < theirs.length; i++) {
      final left = int.tryParse(mine[i]);
      final right = int.tryParse(theirs[i]);
      if (left != null && right != null) {
        if (left != right) return left < right;
      } else if (mine[i] != theirs[i]) {
        return mine[i].compareTo(theirs[i]) < 0;
      }
    }
    return mine.length < theirs.length;
  }

  /// [version]'s numbers and its pre-release part; null when it is not one
  /// (`unknown`, say), so that nothing is claimed about it.
  static (List<int>, String)? _versionParts(String version) {
    final withoutBuild = version.split('+').first.trim();
    final dash = withoutBuild.indexOf('-');
    final numbers = dash < 0 ? withoutBuild : withoutBuild.substring(0, dash);
    final parts = [
      for (final part in numbers.split('.')) int.tryParse(part.trim()),
    ];
    if (parts.isEmpty || parts.contains(null)) return null;
    return (
      [for (final part in parts) part!],
      dash < 0 ? '' : withoutBuild.substring(dash + 1),
    );
  }
}

/// Whether dsh can resolve one credential ref: its key in the environment
/// dsh is started with, or a key of that name in its own store. Given in a
/// test, which must not read the user's own.
typedef DshCredentialCheck = Future<bool> Function(String ref);

/// Whether dsh has a key for the ref its route reads, before a turn is left to
/// fail over it (§5.3): the variable itself, or a key of that name in dsh's
/// own store.
///
/// Only names are read there — no key is copied anywhere, and dsh still reads
/// its store itself (§5.11).
abstract final class DshCredentials {
  /// dsh's store: `$DSH_HOME/.credentials.yaml`, else `~/.dsh/.credentials.yaml`
  /// (F24).
  static const fileName = '.credentials.yaml';

  /// Whether dsh can resolve [ref], under [environment] — the one the process
  /// is started with —: the variable itself where it is set, else a key of that
  /// name in the store the environment points at. Only a name is read there,
  /// never a value (§5.3, §5.11).
  ///
  /// The preflight `DshKernel` makes when none is injected; a test injects its
  /// own — `DshKernel(credentials:)` is the only way in — since this one looks
  /// at the machine it runs on.
  static DshCredentialCheck check({
    Map<String, String> environment = const {},
  }) =>
      (ref) => _has(ref, environment: environment);

  /// Whether dsh has a key for [ref] in [environment] — the login shell's,
  /// which the process is started with — or in the store that environment
  /// points at.
  static Future<bool> _has(
    String ref, {
    Map<String, String> environment = const {},
  }) async {
    if (_set(environment, ref)) return true;
    final store = await _read(environment);
    return store != null && names(store, ref);
  }

  static bool _set(Map<String, String> environment, String ref) =>
      (environment[ref] ?? '').trim().isNotEmpty;

  /// Whether [text], a store's contents, names [ref] under `refs`: the keys
  /// there, and never a value (the entries are `KEY: value`, so a line is
  /// read up to its colon).
  static bool names(String text, String ref) {
    var underRefs = false;
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      final body = line.trim();
      if (body.isEmpty || body.startsWith('#')) continue;
      final indented = line.startsWith(' ') || line.startsWith('\t');
      if (!indented) {
        // A top-level key: `refs:` is the one the keys are listed under, and
        // any other (`version`, `records`) ends it.
        underRefs = body == 'refs:';
        continue;
      }
      if (!underRefs) continue;
      if (_keyIn(body) == ref) return true;
    }
    return false;
  }

  /// The key a YAML `key: value` line gives, its quotes taken off.
  static String? _keyIn(String line) {
    final colon = line.indexOf(':');
    if (colon <= 0) return null;
    return line
        .substring(0, colon)
        .trim()
        .replaceAll(RegExp(r'''^["']|["']$'''), '');
  }

  /// What dsh's store says; null when there is none to read (no dsh on this
  /// machine ever wrote one, or it cannot be read).
  static Future<String?> _read(Map<String, String> environment) async {
    final path = _path(environment);
    if (path == null) return null;
    try {
      return await File(path).readAsString();
    } on Object {
      return null;
    }
  }

  static String? _path(Map<String, String> environment) {
    final named = environment['DSH_HOME']?.trim() ?? '';
    if (named.isNotEmpty) return p.join(named, fileName);
    final home = AppPaths.home(environment);
    return home.isEmpty ? null : p.join(home, '.dsh', fileName);
  }
}

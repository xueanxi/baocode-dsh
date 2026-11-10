import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../platform/child_process_registry.dart';
import '../../platform/data_dir.dart';
import 'dsh_transport.dart';

/// dsh as a child process, over its stdin and stdout.
class DshProcessTransport implements DshTransport {
  DshProcessTransport._(this._process, {this.executable}) {
    _live.add(this);
    unawaited(registry.add(_process.pid));
    _process.stdout
        .transform(_decoder)
        .transform(const LineSplitter())
        .listen(_line, onError: _undecodable, onDone: _stdoutDone);
    _process.stderr
        .transform(_decoder)
        .transform(const LineSplitter())
        .listen(_stderrLine, onError: _undecodable);
    unawaited(_process.exitCode.then(_exited));
  }

  /// What both streams are read with, and not strict about it: a line that
  /// is not UTF-8 takes the replacement character and goes on to [_line],
  /// which drops it as it would any other line that is not protocol. Strict,
  /// the decode error would reach the subscription instead and end the
  /// stream there — and what dsh printed before it failed is exactly what
  /// says why.
  static const _decoder = Utf8Decoder(allowMalformed: true);

  /// A read error on either stream: kept as a stderr line, so that it is in
  /// the report when the process ends.
  void _undecodable(Object error) => _stderrLine('$error');

  /// A transport over [process], e.g. a stand-in process under test.
  @visibleForTesting
  factory DshProcessTransport.forProcess(Process process) =>
      DshProcessTransport._(process);

  /// Where the running processes are kept track of across runs.
  @visibleForTesting
  static DshProcessRegistry registry = DshProcessRegistry(
    file: File(DataDirectory.current.processRegistryFile('dsh')),
  );

  /// The processes this run of the app started and that still run.
  static final Set<DshProcessTransport> _live = {};

  /// Ends every dsh process this run started, and waits (up to [timeout]
  /// each) for them to go: done as the app quits, so a turn under way does
  /// not go on unseen, spending tokens, after the app is gone.
  static Future<void> stopAll({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    await Future.wait([
      for (final transport in [..._live]) transport._stop(timeout),
    ]);
    // Their entries gone from the list before the app is.
    await registry.flush();
  }

  /// Ends the processes an earlier run left behind; see
  /// [DshProcessRegistry].
  static Future<void> reapLeftovers() => registry.reaped;

  Future<void> _stop(Duration timeout) async {
    close();
    try {
      await _process.exitCode.timeout(timeout);
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
  }

  static Future<DshTransport> start(DshLaunch launch) async {
    // Left over from a run that ended without stopping them: gone first, so
    // two processes never go on with one session.
    await registry.reaped;
    try {
      final process = await Process.start(
        launch.install.node,
        launch.arguments,
        workingDirectory: launch.cwd,
        environment: {
          ...Platform.environment,
          ...?launch.environment,
          DshLaunch.permissionModeVariable: launch.permissionMode,
        },
        // The parent environment beside the app's own on Windows, for what
        // `cmd.exe` itself runs on (COMSPEC, PATHEXT, …), as Claude Code's
        // is.
        includeParentEnvironment: Platform.isWindows,
        // `node <bin.js>`, never the npm shim: a `.cmd` only a shell can run
        // (F20).
        runInShell: false,
      );
      return DshProcessTransport._(process, executable: launch.install.node);
    } on ProcessException catch (error) {
      // Which file: Windows' own words for it leave `%1` in its place.
      throw DshUnavailable(
        'DSH could not start',
        detail: '${launch.install.node}\n${error.message}',
      );
    }
  }

  final Process _process;

  /// The `node` run, to name in a report of its failing.
  @override
  final String? executable;

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();

  /// The last lines it printed on stderr, to say why it failed.
  final List<String> _stderr = [];
  static const _stderrLines = 30;

  int? _exitCode;
  bool _stdoutClosed = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  void _line(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, Object?>) _messages.add(decoded);
    } on FormatException {
      // Not protocol (e.g. a warning printed to stdout): keep it for the
      // failure report.
      _stderrLine(line);
    }
  }

  void _stderrLine(String line) {
    // Taken out before it is kept: this is the text a failure's detail is made
    // of, and a detail is pasted into reports (§5.11).
    _stderr.add(DshRedact.line(line));
    if (_stderr.length > _stderrLines) _stderr.removeAt(0);
  }

  void _stdoutDone() {
    _stdoutClosed = true;
    _finish();
  }

  void _exited(int code) {
    _exitCode = code;
    _live.remove(this);
    unawaited(registry.remove(_process.pid));
    _finish();
  }

  /// Ends the stream once both the output is read and the process gone,
  /// so its last messages come before the exit.
  void _finish() {
    final code = _exitCode;
    if (code == null || !_stdoutClosed || _messages.isClosed) return;
    _messages
      ..add(DshExit.message(code, _stderr.join('\n')))
      ..close();
  }

  @override
  void write(Map<String, Object?> message) {
    if (_exitCode != null) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on StateError {
      // Closed under us: the exit message follows.
    }
  }

  @override
  Future<void> get exited => _process.exitCode.then((_) {});

  /// How long it is given to end itself once its input is closed: dsh's
  /// dispose takes seconds, and hands back what it was granted on the
  /// workspace — ended at once, that is lost, and so is what it had not yet
  /// flushed.
  @visibleForTesting
  static Duration exitGrace = const Duration(seconds: 6);

  @override
  void close() {
    if (_exitCode != null) return;
    unawaited(_process.stdin.close().catchError((_) {}));
    unawaited(_endTree());
  }

  /// Its input closed: given [exitGrace] to end itself, then ended with all
  /// it started (Windows), or ended outright elsewhere.
  Future<void> _endTree() async {
    final ended = await _process.exitCode
        .timeout(exitGrace)
        .then((_) => true, onError: (Object _) => false);
    if (ended) return;
    if (!Platform.isWindows) {
      _process.kill();
      return;
    }
    try {
      await Process.run('taskkill', ['/pid', '${_process.pid}', '/T', '/F']);
    } on ProcessException {
      _process.kill();
    }
  }
}

/// What dsh prints with a credential in it, as it may be shown: the shape kept,
/// the secret gone (§5.11).
///
/// It is applied where a line is kept — the transport's stderr tail, and so
/// [DshExit]'s message and `KernelHealth.detail` — rather than where those are
/// shown: a detail's way to the UI and to a log is not one path.
abstract final class DshRedact {
  /// [text] with a `Bearer` token, an `Authorization` value, and a long opaque
  /// run taken out: `Bearer ***`, `Authorization: ***`, `***`.
  static String line(String text) {
    final bearer = text.replaceAll(_bearer, 'Bearer ***');
    final header = bearer.replaceAllMapped(_authorization, (match) {
      // The scheme is kept where it was one: `Bearer ***` says what was there
      // without saying what it was.
      final value = match[2]!.trim();
      final kept = value.toLowerCase().startsWith('bearer')
          ? 'Bearer ***'
          : '***';
      return '${match[1]}: $kept';
    });
    return header.replaceAll(_opaque, '***');
  }

  /// `Bearer <token>`, the token up to the next space or separator.
  static final _bearer = RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false);

  /// `Authorization: <value>`, or `Authorization=<value>`: everything after the
  /// name is the credential's.
  static final _authorization = RegExp(
    r'(\bAuthorization)\s*[:=]\s*([^\r\n]*)',
    caseSensitive: false,
  );

  /// A run long and mixed enough to be a key rather than a word: 32 characters
  /// of the alphabet keys are written in, with nothing around it.
  static final _opaque = RegExp(r'\b[A-Za-z0-9_\-]{32,}\b');
}

/// The dsh processes the app has running (`dsh-processes.json`); see
/// [ChildProcessRegistry]. An entry a run recorded without a command line is
/// ended only when it runs dsh's ACP profile, its whole command line read.
class DshProcessRegistry extends ChildProcessRegistry {
  DshProcessRegistry({
    required super.file,
    super.ownPid,
    super.lookup,
    super.signal,
  }) : super(recognizes: isDsh);

  /// Whether [command] runs dsh's ACP profile: `node` as the program, the
  /// package's own absolute `lib/bin.js` as an argument, and `--profile acp`
  /// as two more. Read as arguments, so that a `grep` for dsh, or another
  /// agent's profile, is never taken for one — a pid ended by mistake is a
  /// turn lost.
  static bool isDsh(String command) {
    final arguments = _arguments(command);
    if (arguments.isEmpty) return false;
    if (p.basenameWithoutExtension(arguments.first) != 'node') return false;
    var profile = false;
    var package = false;
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i].replaceAll(r'\', '/');
      if (argument == '--profile') {
        profile = i + 1 < arguments.length && arguments[i + 1] == 'acp';
      } else if (_isPackageBinJs(argument)) {
        package = true;
      }
    }
    return profile && package;
  }

  /// Whether [argument], as an absolute path, is the `lib/bin.js` of the
  /// package dsh is installed as.
  static bool _isPackageBinJs(String argument) {
    final absolute =
        argument.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(argument);
    return absolute &&
        argument.endsWith('/node_modules/@deepseek-ai/dsh/lib/bin.js');
  }

  /// [command] apart into its arguments, the quotes taken off: what `ps`
  /// prints as one line, spaces in a path included.
  static List<String> _arguments(String command) {
    final arguments = <String>[];
    final current = StringBuffer();
    var quoted = false;
    for (final unit in command.codeUnits) {
      final character = String.fromCharCode(unit);
      if (character == '"') {
        quoted = !quoted;
      } else if (!quoted && (character == ' ' || character == '\t')) {
        if (current.isNotEmpty) {
          arguments.add(current.toString());
          current.clear();
        }
      } else {
        current.write(character);
      }
    }
    if (current.isNotEmpty) arguments.add(current.toString());
    return arguments;
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../../platform/data_dir.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import '../transcript.dart';
import 'dsh_approval.dart';
import 'dsh_ask_bridge.dart';
import 'dsh_bash.dart';
import 'dsh_locate.dart';
import 'dsh_notices.dart';
import 'dsh_patch.dart';
import 'dsh_question_server.dart';
import 'dsh_questions.dart';
import 'dsh_sessions.dart';
import 'dsh_skills.dart';
import 'dsh_transport.dart';
import 'dsh_translator.dart';

/// Starts dsh for one session, e.g. [startDsh].
typedef DshStarter = Future<DshTransport> Function(DshLaunch launch);

/// The dsh on this machine, e.g. [locateDsh].
typedef DshLocator = Future<DshInstall?> Function();

/// The answerer dsh is started with: its plugin's `file://` URL (in the
/// patch), and what the plugin is told of the endpoint (`dsh_ask_bridge.dart`).
typedef _AskBridge = ({String plugin, Map<String, String> environment});

/// A value an option dsh offers, with the heading it is listed under.
typedef _Offer = ({
  Map<String, Object?> value,
  String? group,
  String? groupName,
});

/// Adapts DeepSeek Harness (`dsh`, its ACP profile) to [AgentKernel].
///
/// `prepare` finds dsh, writes the profile patch it runs with and shakes
/// hands, and only the first message creates a session: an empty one would
/// otherwise be left in `~/.dsh` for every conversation opened. What it does
/// not do, it does not declare: no usage bookkeeping (see
/// `docs/spec/dsh-kernel.md` §5.2). The conversations it starts are kept in
/// [DshSessionStore], as dsh names no titles and replays no history (F17,
/// F15).
class DshKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsEffort,
        SelectsPermission,
        ProvidesCommands,
        ReportsContext,
        AcceptsImages {
  DshKernel(
    this.descriptor,
    this._context, {
    required this._start,
    required this._locate,
    Future<Map<String, String>> Function()? environment,
    DshSessionStore? sessions,
    DshQuestionServerStarter? questionServer,
    this._credentials,
  }) : _environment = environment ?? ClaudeEnvironment.of,
       _sessions = sessions ?? DshSessionStore.file(),
       _questionServerStart = questionServer ?? startDshQuestionServer,
       _sessionId = _context.resume?.id,
       _title = _context.resume?.title ?? '' {
    _translator = DshTranslator(
      emit: emit,
      nextSeq: () => nextSeq,
      options: _applyOptions,
    );
    _approvals = DshApprovals(
      emit: emit,
      nextSeq: () => nextSeq,
      write: _write,
    );
    _notices = DshNotices(emit: emit, nextSeq: () => nextSeq);
    _questions = DshQuestions(emit: emit, nextSeq: () => nextSeq);
    final settings = _context.settings;
    _permission = _tierOf(settings[KernelChoiceKind.permission.name]);
    _wantedModel = settings[KernelChoiceKind.model.name];
    _wantedEffort = settings[KernelChoiceKind.effort.name];
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext _context;
  final DshStarter _start;
  final DshLocator _locate;

  /// The login shell's environment, put beside the app's own for the
  /// process: started from Finder on macOS, the app's PATH has neither
  /// `node` nor `git` (see `DshLaunch.environment`).
  final Future<Map<String, String>> Function() _environment;

  /// Where the bridge asks its questions (`dsh_question_server.dart`); a
  /// test gives one that cannot bind, so that no socket opens under it.
  final DshQuestionServerStarter _questionServerStart;

  /// The refs dsh can resolve, where a test gives its own: the preflight
  /// would otherwise look at the machine the test runs on. Null reads this
  /// machine's own store, by name only (`dsh_notices.dart`).
  final DshCredentialRefs? _credentials;

  /// Where the conversations this kernel starts are kept, for the sidebar
  /// and for reading back (see [DshCatalog]).
  final DshSessionStore _sessions;

  /// What was said in this conversation, as reported, to keep at each
  /// turn's end (see `docs/spec/dsh-kernel.md` §5.2).
  final Transcript _kept = Transcript();

  /// Whether what was said before this run was read: only the first start
  /// reads it, not every start after a release.
  bool _historyRead = false;

  /// What it was first asked, its first line: the title its session is
  /// kept under until dsh's own names anything.
  String _title;

  late final DshTranslator _translator;

  /// dsh's approvals, asked as the conversation's questions, and the notices
  /// the conversation carries that the agent did not write.
  late final DshApprovals _approvals;
  late final DshNotices _notices;

  /// `ask_user_question`, put to the same panel (see [DshQuestions]).
  late final DshQuestions _questions;

  /// Where the bridge plugin asks, once a conversation has needed it: one
  /// endpoint per conversation, kept across dsh restarts.
  DshQuestionServer? _questionServer;

  /// The three tiers dsh runs under (F22).
  static const _tiers = ['read-only', 'workspace-write', 'danger-full-access'];

  /// The dsh version this adapter was written and probed against: one
  /// before it is named in a warning, and still run (`dsh_patch.dart`).
  static const _verifiedVersion = '0.2.0-rc.2';

  DshTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _subscription;

  KernelHealth _health = KernelHealth.idle;

  /// The session this conversation runs in: the one it continues when
  /// started from a kept thread (see [DshSessionStore]), one dsh makes on
  /// the first message otherwise.
  String? _sessionId;

  /// Whether the running process has [_sessionId] open: after a release it
  /// has to be resumed.
  bool _sessionActive = false;

  /// What `initialize` said about pictures: false until the handshake.
  bool _imageCapable = false;

  /// The permission tier picked, and the one the process running was
  /// started on: dsh reads it at start, not per turn (F22), so a pick after
  /// that is taken up by the next start.
  late String _permission;
  String _launchedPermission = '';

  /// The previous process, awaited before another starts: two on one
  /// session are refused (F15).
  Future<void> _stopped = Future.value();
  Future<void>? _starting;
  bool _releaseWanted = false;
  bool _disposed = false;

  int _requests = 0;
  Object? _promptRequest;
  final Map<Object, Completer<Map<String, Object?>>> _responses = {};

  /// The turns sent, so that one sent twice runs once.
  final Set<String> _sentTurns = {};

  /// The last lines dsh printed on stderr, kept for a failure's detail.
  String _stderr = '';

  // What dsh offers (its `configOptions`), and what is in effect: the model
  // and, where the model has them, its reasoning levels (F6).
  Map<String, Object?>? _modelOption;
  Map<String, Object?>? _effortOption;
  String? _reportedModel;
  String? _reportedEffort;

  /// What the user picked and dsh was not told yet (or not told at all,
  /// before a session exists): shown as picked until dsh reports it.
  String? _wantedModel;
  String? _wantedEffort;

  // --- Lifecycle --------------------------------------------------------------

  @override
  KernelHealth get health => _health;

  @override
  String? get sessionId => _sessionId;

  @override
  Future<void> get stopped => _stopped;

  @override
  int get contextWindow => _translator.contextWindow;

  /// Whether a picture can be sent: dsh's `promptCapabilities.image`, false
  /// until the handshake (§5.2).
  @override
  bool get supportsImages => _imageCapable;

  String get _cwd => _context.cwd ?? '.';

  /// The skills dsh would load for `/name` here (see [DshSkills]), read from
  /// the files it would scan: ACP names no commands (F30), so the menu is
  /// built from them rather than from dsh.
  List<KernelCommand> _commands = const [];

  @override
  List<KernelCommand> get commands => _commands;

  /// Reads the skills for this conversation's project, saying so when they
  /// changed; a read that fails leaves the last list, as the menu had it.
  Future<void> _readCommands() async {
    if (_disposed) return;
    final Map<String, String> environment;
    try {
      // As dsh is started with: DSH_HOME and DSH_AGENTS_HOME may be the login
      // shell's, not the app's.
      environment = await _environment();
    } on Object catch (error) {
      debugPrint('DSH skills not read: $error');
      return;
    }
    final List<DshSkill> skills;
    try {
      skills = await DshSkills.discover(cwd: _cwd, environment: environment);
    } on Object catch (error) {
      debugPrint('DSH skills not read: $error');
      return;
    }
    if (_disposed) return;
    final commands = [
      for (final skill in skills)
        KernelCommand(
          skill.name,
          skill.description,
          Icons.auto_awesome_outlined,
          path: skill.path,
        ),
    ];
    if (_sameCommands(commands, _commands)) return;
    _commands = commands;
    emitInfoChanged();
  }

  static bool _sameCommands(List<KernelCommand> a, List<KernelCommand> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].name != b[i].name ||
          a[i].description != b[i].description ||
          a[i].path != b[i].path) {
        return false;
      }
    }
    return true;
  }

  /// The tier [id] names, or the one a new conversation starts in.
  static String _tierOf(String? id) =>
      _tiers.contains(id) ? id! : 'workspace-write';

  void _setHealth(KernelHealth health) {
    _health = health;
    emitInfoChanged();
  }

  /// Keeps what this conversation said while reporting it: the same events
  /// the session shows, so that what is kept and what is shown cannot come
  /// apart.
  @override
  void emit(KernelEvent event) {
    _kept.apply(event);
    super.emit(event);
    if (event is TurnEnded) unawaited(_keepSession());
  }

  /// The title a first message gives a session: its first line, as the
  /// sidebar names a new agent (see `Workspace._sync`).
  static String _titleOf(String text) => text.trim().split('\n').first.trim();

  /// Reads what was said before this run, where the conversation continues
  /// one kept from before, and shows it before anything new: dsh's
  /// `session/resume` replays nothing (F15).
  Future<void> _readHistory() async {
    if (_historyRead) return;
    _historyRead = true;
    final id = _sessionId;
    if (id == null || _disposed) return;
    final List<(String, ChatItem)> items;
    try {
      items = await _sessions.history(id);
    } on Object catch (error) {
      debugPrint('DSH conversation not read: $error');
      return;
    }
    if (items.isEmpty || _disposed) return;
    // The ids dsh gives are its own count, which a new process starts
    // again: on from the ones in the history, or a new message would
    // replace an old one.
    _translator.continueFrom(items.map((kept) => kept.$1));
    emit(HistoryPrepended(nextSeq, items));
  }

  /// Keeps the session's title and time, and what was said so far: at its
  /// creation (nothing said yet) and at each turn's end.
  Future<void> _keepSession() async {
    final id = _sessionId;
    if (id == null || _disposed) return;
    final items = [for (final kept in _kept.liveItems) kept];
    try {
      await _sessions.keepHistory(id, items);
      await _sessions.keep(
        DshSession(id: id, cwd: _cwd, title: _title, updatedAt: DateTime.now()),
      );
    } on Object catch (error) {
      // Not kept is not a turn that failed: dsh still has the conversation.
      debugPrint('DSH conversation not kept: $error');
    }
  }

  @override
  void prepare() {
    _releaseWanted = false;
    if (_health.status == KernelHealthStatus.failed) return;
    // With every start, so that a skill added since the last look is offered
    // the next time the conversation is opened.
    unawaited(_readCommands());
    unawaited(_ensureStarted().catchError((_) {}));
  }

  @override
  void restart() {
    if (_health.status != KernelHealthStatus.failed) return;
    _teardown();
    _setHealth(KernelHealth.idle);
    prepare();
  }

  /// Whether stopping the process now would cut work short.
  bool get _busy => _translator.inFlight || _starting != null;

  @override
  void release() {
    if (_busy) {
      _releaseWanted = true;
      return;
    }
    _free();
  }

  /// Lets the process go, whatever it was in the middle of: the callers know
  /// the turn is over.
  void _free() {
    _releaseWanted = false;
    if (_transport == null) return;
    _teardown();
    _setHealth(KernelHealth.idle);
  }

  /// Ends the process: its input closed, and dsh's own flush and teardown
  /// given their seconds by the transport, which ends the tree that is left
  /// (see `dsh_transport_io.dart`).
  void _teardown() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _failPending('DSH stopped');
    _promptRequest = null;
    // Answered while the process is still there to read it: a question left
    // open would be one the panel waits on for ever.
    _approvals.cancelOpen();
    _questions.cancelOpen();
    _questionServer?.cancelAll();
    if (_transport case final transport?) {
      _stopped = transport.exited.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      transport.close();
    }
    _transport = null;
    _sessionActive = false;
    _releaseWanted = false;
    // The handshake was this process's: the next one answers for itself, and
    // until it does nothing is known about what it takes (§5.2).
    _imageCapable = false;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _failPending('DSH stopped');
    _promptRequest = null;
    _approvals.cancelOpen();
    _questions.cancelOpen();
    final questions = _questionServer;
    if (questions != null) unawaited(questions.close());
    if (_transport case final transport?) {
      // Long enough for dsh to flush and hand back what it was granted.
      _stopped = transport.exited.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );
      transport.close();
    }
    _transport = null;
    _sessionActive = false;
    closeEvents();
  }

  /// The process is up and has shaken hands: the first message's start, and
  /// [prepare]'s.
  Future<void> _ensureStarted() {
    if (_transport != null &&
        (_sessionId != null || _launchedPermission == _permission)) {
      return Future.value();
    }
    return _starting ??= _launch().whenComplete(() => _starting = null);
  }

  Future<void> _launch() async {
    // The process before is gone before the next starts: dsh refuses a
    // session another process still holds (F15).
    if (_transport != null) _teardown();
    await _stopped;
    // Before anything of this run: what was said before, where the
    // conversation continues one kept from before.
    await _readHistory();
    _setHealth(const KernelHealth(KernelHealthStatus.starting));
    final DshInstall? install;
    try {
      install = await _locate();
    } on Object catch (error) {
      _fail('DSH could not be found', detail: '$error');
      throw DshUnavailable('DSH could not be found', detail: '$error');
    }
    if (install == null) {
      const detail =
          'The path can be set in Settings → General → DSH, or dsh put on '
          'the PATH.';
      _fail(_missingMessage, detail: detail);
      throw const DshUnavailable(_missingMessage, detail: detail);
    }
    _notices.versionIsOld(install.version, verified: _verifiedVersion);
    final String patchFile;
    final Map<String, String> environment;
    final DshTransport transport;
    try {
      // Read first: the environment is what dsh is started with, and it says
      // both whether there is a Git Bash to turn on and where DSH_HOME is,
      // which the patch checks the plugin against.
      environment = await _environment();
      final bridge = await _openAskBridge();
      patchFile = await DshPatch.ensure(
        install: install,
        directory: DataDirectory.current.dshDir,
        withBash: await findGitBash(environment: environment) != null,
        askBridge: bridge?.plugin,
        dshHome: _dshHomeOf(environment),
      );
      // Said before it starts, so that the first turn's failure is not the
      // first word about it (§5.3).
      await _checkCredential(environment);
      transport = await _start(
        DshLaunch(
          cwd: _cwd,
          install: install,
          patchFile: patchFile,
          permissionMode: _permission,
          environment: switch (bridge) {
            final bridge? => {...environment, ...bridge.environment},
            null => environment,
          },
        ),
      );
    } on DshUnavailable catch (error) {
      _fail(error.message, detail: error.detail ?? _stderrTail());
      rethrow;
    } on Object catch (error) {
      _fail('DSH did not start', detail: '$error');
      rethrow;
    }
    if (_disposed) {
      transport.close();
      return;
    }
    _launchedPermission = _permission;
    _transport = transport;
    _subscription = transport.messages.listen(
      (message) => _receive(transport, message),
    );
    try {
      final result = await _request('initialize', {'protocolVersion': 1});
      final capabilities = result['agentCapabilities'];
      final prompts = capabilities is Map
          ? capabilities['promptCapabilities']
          : null;
      _imageCapable = prompts is Map && prompts['image'] == true;
      _setHealth(KernelHealth.ready);
    } on Object catch (error) {
      if (_health.status != KernelHealthStatus.failed) {
        _fail(
          'DSH did not start',
          detail: error is DshRpcError
              ? error.text
              : _stderrTail(fallback: '$error'),
        );
      }
      _teardown();
      rethrow;
    }
    // Let go while it was starting (the view closed): freed now.
    if (_releaseWanted) _free();
  }

  /// The answerer dsh is started with, or null where there is none: no user
  /// at the computer (a bot's), or an endpoint that could not be made. Null
  /// only leaves `ask_user_question` out — the conversation runs as before.
  ///
  /// Started before the process, because both the patch (the plugin) and its
  /// environment (where to ask) name what it made.
  Future<_AskBridge?> _openAskBridge() async {
    if (_context.workspace?.call()?.approvesAll ?? false) return null;
    try {
      var server = _questionServer;
      if (server == null) {
        server = await _questionServerStart(_questions.ask);
        _questionServer = server;
      }
      await server.start();
      return (
        plugin: await DshAskBridge.ensure(DataDirectory.current.dshDir),
        environment: {
          DshAskBridge.urlVariable: server.url.toString(),
          DshAskBridge.tokenVariable: server.token,
        },
      );
    } on UnsupportedError {
      // Nowhere to listen (the web, or a kernel made without an endpoint):
      // not worth a line in the log.
      return null;
    } on Object catch (error) {
      // No endpoint, no tool: the agent asks in words, as Claude Code's does
      // where no one is there to answer.
      debugPrint('DSH questions: $error');
      return null;
    }
  }

  /// What a failed search for dsh says: the install it names.
  static const _missingMessage =
      'DSH is not installed: run `npm i -g @deepseek-ai/dsh`, then try '
      'again.';

  /// The `DSH_HOME` [environment] names, or null where it names none.
  ///
  /// dsh is started with that environment, so a `DSH_HOME` in it is where dsh
  /// reads its profiles from — and the patch has to be checked against the
  /// same folder, not against the app's own `~/.dsh`.
  static String? _dshHomeOf(Map<String, String> environment) {
    final named = environment['DSH_HOME']?.trim() ?? '';
    return named.isEmpty ? null : named;
  }

  /// Says so when dsh's route has no key of its own for the ref it reads
  /// (F24): every turn would fail over it, one by one, and it is a word in
  /// the conversation rather than a reason not to start (§5.3).
  ///
  /// The refs are the injected ones where a test gave them, and this machine's
  /// own otherwise — its store's key names, never a value.
  Future<void> _checkCredential(Map<String, String> environment) async {
    final Set<String> refs;
    try {
      refs =
          await (_credentials ??
              DshCredentials.refs(environment: environment))();
    } on Object {
      // A check that cannot be made is not a dsh that cannot start: dsh
      // answers for itself, turn by turn.
      return;
    }
    if (refs.contains(DshPatch.credentialRef)) return;
    _notices.credentialMissing(DshPatch.credentialRef);
  }

  void _fail(String message, {String? detail}) {
    _setHealth(
      KernelHealth(KernelHealthStatus.failed, message: message, detail: detail),
    );
  }

  /// dsh's last words on stderr — what a failure to start is explained by —
  /// or [fallback] when it printed nothing.
  String _stderrTail({String? fallback}) {
    final stderr = _stderr.trim();
    if (stderr.isNotEmpty) return stderr;
    return fallback ?? '';
  }

  // --- The conversation -------------------------------------------------------

  @override
  void send(KernelTurn turn) {
    // A prompt already in flight is refused by dsh (F12), and one sent twice
    // is run once. A turn waiting for the handshake is in flight too.
    if (_sentTurns.contains(turn.id) ||
        _translator.inFlight ||
        _awaiting != null) {
      return;
    }
    _sentTurns.add(turn.id);
    // Its first message names the session, as it names a new agent's in
    // the sidebar: kept for the next run, where dsh names no title (F17).
    if (_title.isEmpty) _title = _titleOf(turn.text);
    // Whether pictures can go is dsh's answer at the handshake: a turn
    // carrying them before it waits for that answer rather than guess, since
    // the thread shows what is sent (§5.5).
    if (turn.images.isNotEmpty && !_imageCapable) {
      _awaiting = turn.id;
      unawaited(_startTurn(turn));
      return;
    }
    unawaited(_startTurn(turn, begun: _begin(turn)));
  }

  /// The turn sent with pictures that is waiting for the handshake: it is in
  /// flight, and nothing of it is shown yet.
  String? _awaiting;

  /// Starts [turn] in the conversation — `TurnStarted`, its message with the
  /// pictures that can be sent, then, inside the turn, the word about those
  /// that cannot (§5.5, §5.10) — and answers those pictures, so that what the
  /// thread shows and what dsh is sent cannot come apart.
  List<ImageAttachment> _begin(KernelTurn turn) {
    _awaiting = null;
    final images = _imageCapable ? turn.images : const <ImageAttachment>[];
    _translator.begin(turn.id, text: turn.text, images: images);
    if (images.isEmpty && turn.images.isNotEmpty) {
      _notices.imagesDropped(turn.id);
    }
    return images;
  }

  /// Begins the turn if it is still wanted — it was not stopped while the
  /// handshake was awaited: then nothing of it was shown and nothing is to be
  /// sent, and no pictures answer it (null).
  List<ImageAttachment>? _beginIfWanted(KernelTurn turn) =>
      _awaiting == turn.id ? _begin(turn) : null;

  Future<void> _startTurn(
    KernelTurn turn, {
    List<ImageAttachment>? begun,
  }) async {
    List<ImageAttachment>? images = begun;
    try {
      await _ensureStarted();
    } on Object {
      // The handshake never came: the turn starts and ends here, so that what
      // was sent is not left without an end (§5.5).
      images = begun ?? _beginIfWanted(turn);
      if (images != null) {
        _translator.end(
          interrupted: true,
          error: _health.message ?? 'DSH did not start',
        );
      }
      _settleTurn();
      return;
    }
    // What the turn carries is the handshake's answer, when it had to wait
    // for it: its `TurnStarted` is that late only on this rare path — pictures
    // sent before dsh shook hands.
    images ??= _beginIfWanted(turn);
    if (images == null) {
      // Stopped while the handshake was awaited: nothing was shown, nothing
      // reached dsh, and there is nothing to end.
      _settleTurn();
      return;
    }
    try {
      await _openSession();
    } on DshRpcError catch (error) {
      _translator.end(interrupted: true, error: error.text);
      _settleTurn();
      return;
    } on Object catch (error) {
      _translator.end(interrupted: true, error: '$error');
      _settleTurn();
      return;
    }
    // Stopped while the session was being made: nothing is sent.
    if (_translator.turnId != turn.id) return;
    final sent = _prompt({
      'sessionId': _sessionId,
      'prompt': _promptContent(turn.text, images),
    });
    if (!sent) {
      // The process went as the message was to be sent: the turn ends here,
      // rather than waiting for an answer that cannot come.
      _translator.end(interrupted: true, error: 'DSH stopped.');
      _settleTurn();
    }
  }

  /// What the message is to dsh: its pictures, then its text. The turn's
  /// `notes` are not sent: dsh has no channel for them (§5.10).
  static List<Map<String, Object?>> _promptContent(
    String text,
    List<ImageAttachment> images,
  ) {
    final blocks = [
      for (final image in images)
        {
          'type': 'image',
          'data': base64Encode(image.bytes),
          'mimeType': image.mediaType,
        },
      if (text.isNotEmpty) {'type': 'text', 'text': text},
    ];
    return blocks.isEmpty
        ? [
            {'type': 'text', 'text': ''},
          ]
        : blocks;
  }

  /// Creates the session on the first message, and resumes it after a
  /// release: dsh keeps it on disk (F25).
  Future<void> _openSession() async {
    if (_sessionId case final session?) {
      if (!_sessionActive) {
        await _resume(session);
        _sessionActive = true;
      }
      await _pushPicks();
      return;
    }
    // dsh creates its session file as it is asked for one (F25), so this is
    // the first message and never [prepare].
    final result = await _request('session/new', {
      'cwd': _cwd,
      // Required, and really started when not empty (F4).
      'mcpServers': const <Object?>[],
    });
    _sessionId = switch (result['sessionId']) {
      final String id => id,
      _ => null,
    };
    _sessionActive = _sessionId != null;
    _applyOptions(result['configOptions']);
    emitInfoChanged();
    // Listed by the next run from the moment dsh makes it, even if nothing
    // in it is said yet (a failure before the first turn ends).
    unawaited(_keepSession());
    await _pushPicks();
  }

  Future<void> _resume(String session) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final result = await _request('session/resume', {
          'sessionId': session,
          'cwd': _cwd,
        });
        _applyOptions(result['configOptions']);
        return;
      } on DshRpcError catch (error) {
        // Another process still has it: gone now, so once more (F15).
        if (attempt > 0 || !error.heldByAnother) rethrow;
        await _stopped;
      }
    }
  }

  /// Asks dsh for the turn; false when the process is gone before it is.
  bool _prompt(Map<String, Object?> prompt) {
    final id = ++_requests;
    _promptRequest = id;
    if (_write({'id': id, 'method': 'session/prompt', 'params': prompt})) {
      return true;
    }
    _promptRequest = null;
    return false;
  }

  @override
  void cancel() {
    if (_awaiting != null) {
      // Waiting for the handshake, nothing shown and nothing at dsh yet:
      // dropped here, and the handshake that would have begun it finds no
      // turn to begin.
      _awaiting = null;
      _settleTurn();
      return;
    }
    if (!_translator.inFlight) return;
    // A notification, not a request: the prompt itself is answered, with
    // `cancelled` (F14).
    final cancelled =
        _promptRequest != null &&
        _sessionId != null &&
        _write({
          'method': 'session/cancel',
          'params': {'sessionId': _sessionId},
        });
    if (cancelled) return;
    // Nothing at dsh yet (the session is still being made): it ends here.
    _translator.end(interrupted: true);
    _settleTurn();
  }

  /// What the user answered to [requestId]: dsh's asks are approvals and its
  /// questions, and one already answered or cancelled is ignored rather than
  /// thrown over.
  @override
  void answer(String requestId, InteractionAnswer answer) {
    _questions.answer(requestId, answer);
    _approvals.answer(requestId, answer);
  }

  /// Frees the process once the turn is over, if it was asked for while
  /// busy — and answers what dsh asked in it: a question left open would
  /// leave the panel asking about a turn that is done.
  void _settleTurn() {
    _approvals.cancelOpen();
    _questions.cancelOpen();
    _questionServer?.cancelAll();
    if (_releaseWanted && !_translator.inFlight) release();
  }

  // --- Messages ---------------------------------------------------------------

  /// Writes [message] to the process; false when it is gone, and nothing
  /// would ever answer.
  bool _write(Map<String, Object?> message) {
    final transport = _transport;
    if (transport == null) return false;
    // Every message is a JSON-RPC 2.0 envelope: dsh reads nothing else
    // (`isJsonRpcEnvelope`).
    transport.write({'jsonrpc': '2.0', ...message});
    return true;
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = ++_requests;
    final response = Completer<Map<String, Object?>>();
    _responses[id] = response;
    if (!_write({'id': id, 'method': method, 'params': params})) {
      _responses.remove(id);
      return Future.error(const DshUnavailable('DSH is not running'));
    }
    return response.future;
  }

  void _receive(DshTransport transport, Map<String, Object?> message) {
    if (!identical(_transport, transport)) return;
    if (message['type'] == DshExit.type) {
      _exited(message);
      return;
    }
    if (message['method'] case final String method) {
      if (message.containsKey('id')) {
        _serverRequest(method, message);
      } else if (method == 'session/update') {
        final params = (message['params'] as Map?)?.cast<String, Object?>();
        final update = (params?['update'] as Map?)?.cast<String, Object?>();
        if (update != null) {
          // Kept for the approval dsh may ask about it: the request names no
          // tool and no reason (F10).
          _approvals.toolCall(update);
          _translator.update(update);
        }
      }
      return;
    }
    _response(message);
  }

  void _response(Map<String, Object?> message) {
    final id = message['id'];
    if (id == _promptRequest) {
      _promptRequest = null;
      final error = DshRpcError.from(message['error']);
      if (error != null) {
        // This turn's failure, not the kernel's: a missing key, a model the
        // route does not have (§5.9).
        _translator.end(interrupted: true, error: error.text);
      } else {
        final result = (message['result'] as Map?)?.cast<String, Object?>();
        _translator.end(interrupted: result?['stopReason'] == 'cancelled');
      }
      _settleTurn();
      return;
    }
    final response = _responses.remove(id);
    if (response == null) return;
    if (DshRpcError.from(message['error']) case final error?) {
      response.completeError(error);
      return;
    }
    response.complete(
      (message['result'] as Map?)?.cast<String, Object?>() ?? const {},
    );
  }

  /// dsh asking the client for something: leave to step outside its sandbox
  /// (F10), which becomes the conversation's pending question. Anything else
  /// it might ask is turned down rather than left waiting for ever, which
  /// would keep the turn from ending.
  void _serverRequest(String method, Map<String, Object?> message) {
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == 'session/request_permission') {
      _approvals.requested(message['id'], params ?? const {});
      return;
    }
    _write({
      'id': message['id'],
      'result': {
        'outcome': {'outcome': 'cancelled'},
      },
    });
  }

  /// The process is gone: what it was running ends here, and the next
  /// message starts it again.
  void _exited(Map<String, Object?> message) {
    _stderr = '${message['stderr'] ?? ''}';
    final failedToStart = _health.status == KernelHealthStatus.starting;
    _transport = null;
    _sessionActive = false;
    // Its answer was the process's: gone, the capability is unknown again.
    _imageCapable = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _failPending('DSH exited');
    _promptRequest = null;
    _approvals.cancelOpen();
    _questions.cancelOpen();
    _questionServer?.cancelAll();
    if (_translator.inFlight) {
      _translator.end(
        interrupted: true,
        error: 'DSH stopped${_exitCode(message)}.',
      );
    }
    if (failedToStart) {
      _fail('DSH did not start', detail: _stderrTail());
      _settleTurn();
      return;
    }
    // It ended by itself while ready: the next message starts it again
    // (§5.9). A turn it was running has been ended above.
    if (_health.status == KernelHealthStatus.ready) {
      _setHealth(KernelHealth.idle);
    }
    _settleTurn();
  }

  static String _exitCode(Map<String, Object?> message) =>
      switch (message['code']) {
        final int code when code != 0 => ' (exit $code)',
        _ => '',
      };

  void _failPending(String reason) {
    final pending = [..._responses.values];
    _responses.clear();
    for (final response in pending) {
      if (!response.isCompleted) {
        response.completeError(DshUnavailable(reason, detail: _stderrTail()));
      }
    }
  }

  // --- Options ----------------------------------------------------------------

  @override
  late final KernelChoiceSource model = _Choice(
    options: () => [
      for (final choice in _choicesOf(_modelOption))
        KernelOption(
          '${choice.value['value']}',
          '${choice.value['name'] ?? choice.value['value']}',
          Icons.hub_outlined,
          '${choice.value['description'] ?? ''}',
          group: choice.group == null
              ? null
              : KernelOptionGroup(choice.group!, choice.groupName ?? ''),
        ),
    ],
    selected: () => _wantedModel ?? _reportedModel,
    select: _selectModel,
  );

  @override
  late final ModelSetting effort = _ModelSetting(
    optionsFor: (_) => [
      for (final choice in _choicesOf(_effortOption))
        KernelOption(
          '${choice.value['value']}',
          '${choice.value['name'] ?? choice.value['value']}',
          Icons.speed_rounded,
          '${choice.value['description'] ?? ''}',
        ),
    ],
    selected: () => _wantedEffort ?? _reportedEffort,
    selectedFor: (model) => model == this.model.selected
        ? (_wantedEffort ?? _reportedEffort)
        : null,
    select: (_, id) => _selectEffort(id),
  );

  @override
  late final KernelChoiceSource permission = _Choice(
    // Locked once the first message went out: dsh writes the tier into the
    // session, and resuming does not change it (F16), so another shown
    // would not be the one running (§5.7).
    options: () => _permissionLocked
        ? [_tierOption(_permission)]
        : [for (final id in _tiers) _tierOption(id)],
    selected: () => _permission,
    select: _selectPermission,
  );

  /// Whether the tier can no longer be changed: a session exists, or the
  /// first message was sent.
  bool get _permissionLocked => _sessionId != null || _sentTurns.isNotEmpty;

  static const _tierOptions = [
    KernelOption(
      'read-only',
      'Read only',
      Icons.visibility_outlined,
      'Read and search: no file is changed and no command runs',
    ),
    KernelOption(
      'workspace-write',
      'Workspace write',
      Icons.edit_note_rounded,
      'Edit the project and run commands in it; dsh asks only when a '
          'command steps outside',
    ),
    KernelOption(
      'danger-full-access',
      'Full access',
      Icons.gpp_maybe_outlined,
      'Nothing is asked, and a request that needs approval is refused',
      caution: true,
    ),
  ];

  static KernelOption _tierOption(String id) => _tierOptions.firstWhere(
    (option) => option.id == id,
    orElse: () => _tierOptions[1],
  );

  void _selectModel(String id) {
    _wantedModel = id;
    emitInfoChanged();
    unawaited(_pushPicks());
  }

  void _selectEffort(String id) {
    _wantedEffort = id;
    emitInfoChanged();
    unawaited(_pushPicks());
  }

  void _selectPermission(String id) {
    if (_permissionLocked || id == _permission) return;
    _permission = _tierOf(id);
    emitInfoChanged();
  }

  /// Keeps what dsh says it offers and has in effect.
  void _applyOptions(Object? raw) {
    final options = _optionList(raw);
    _modelOption = _optionNamed(options, 'model');
    _effortOption = _optionNamed(options, 'reasoning_effort');
    _reportedModel = _currentOf(_modelOption);
    _reportedEffort = _currentOf(_effortOption);
    // A pick dsh does not offer is not its own: the last one used was
    // another kernel's, and is dropped (§5.2).
    if (_wantedModel != null && !_offers(_modelOption, _wantedModel!)) {
      _wantedModel = null;
    }
    if (_wantedEffort != null && !_offers(_effortOption, _wantedEffort!)) {
      _wantedEffort = null;
    }
    if (_wantedModel == _reportedModel) _wantedModel = null;
    if (_wantedEffort == _reportedEffort) _wantedEffort = null;
    emitInfoChanged();
  }

  /// Tells dsh the picks it does not have in effect: the options picked
  /// before a session existed, and those picked since.
  Future<void> _pushPicks() async {
    if (!_sessionActive) return;
    if (_wantedModel case final model? when model != _reportedModel) {
      await _setOption('model', model);
    }
    if (_wantedEffort case final effort? when effort != _reportedEffort) {
      await _setOption('reasoning_effort', effort);
    }
  }

  Future<void> _setOption(String configId, String value) async {
    try {
      final result = await _request('session/set_config_option', {
        'sessionId': _sessionId,
        'configId': configId,
        'value': value,
      });
      // dsh answers with the options as they now stand: one it refused
      // (another model, say) shows as the one still in effect.
      _applyOptions(result['configOptions']);
    } on Object {
      if (configId == 'model') {
        _wantedModel = null;
      } else {
        _wantedEffort = null;
      }
      emitInfoChanged();
    }
  }

  static Map<String, Object?>? _optionNamed(
    List<Map<String, Object?>> options,
    String id,
  ) {
    for (final option in options) {
      if (option['id'] == id) return option;
    }
    return null;
  }

  static String? _currentOf(Map<String, Object?>? option) =>
      switch (option?['currentValue']) {
        final String value => value,
        _ => null,
      };

  static bool _offers(Map<String, Object?>? option, String value) =>
      _choicesOf(option).any((choice) => '${choice.value['value']}' == value);

  /// The values [option] offers, each with the heading dsh lists it under:
  /// models are grouped by provider (F6).
  static List<_Offer> _choicesOf(Map<String, Object?>? option) {
    final raw = option?['options'];
    if (raw is! List) return const [];
    final choices = <_Offer>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      if (entry['group'] case final String group) {
        final name = '${entry['name'] ?? group}';
        for (final value in entry['options'] as List? ?? const []) {
          if (value is! Map) continue;
          choices.add((
            value: value.cast<String, Object?>(),
            group: group,
            groupName: name,
          ));
        }
        continue;
      }
      choices.add((
        value: entry.cast<String, Object?>(),
        group: null,
        groupName: null,
      ));
    }
    return choices;
  }

  static List<Map<String, Object?>> _optionList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final option in raw)
        if (option is Map) option.cast<String, Object?>(),
    ];
  }
}

/// A choice over what the kernel holds, read live: what a pick does is the
/// kernel's, not the list's — the permission tier, say, only holds until the
/// first message, and what dsh reports is what is in effect.
class _Choice implements KernelChoiceSource {
  _Choice({
    required this._options,
    required this._selected,
    required this._select,
  });

  final List<KernelOption> Function() _options;
  final String? Function() _selected;
  final void Function(String id) _select;
  List<KernelOption> _cache = const [];

  /// The same list while unchanged, so pickers keep their identity.
  @override
  List<KernelOption> get options {
    final fresh = _options();
    if (!listEquals(fresh, _cache)) _cache = fresh;
    return _cache;
  }

  @override
  String? get selected => _selected();

  @override
  void select(String id) {
    if (id != selected) _select(id);
  }
}

/// A setting that goes with the model, read live (the reasoning levels
/// dsh offers for the model in use, where it reports any).
class _ModelSetting implements ModelSetting {
  _ModelSetting({
    required this._optionsFor,
    required this._selected,
    required this._selectedFor,
    required this._select,
  });

  final List<KernelOption> Function(String model) _optionsFor;
  final String? Function() _selected;
  final String? Function(String model) _selectedFor;
  final void Function(String model, String id) _select;

  @override
  bool get toggle => false;

  @override
  List<KernelOption> optionsFor(String model) => _optionsFor(model);

  @override
  String? get selected => _selected();

  @override
  String? selectedFor(String model) => _selectedFor(model);

  @override
  void select(String model, String id) => _select(model, id);
}

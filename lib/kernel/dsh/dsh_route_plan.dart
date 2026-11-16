import 'package:flutter/foundation.dart' show debugPrint;

import '../../models/launch_environment.dart' show ProxyEndpoint;
import '../../models/model_provider.dart' show ModelProvider, ProviderModel;
import '../../models/model_providers.dart';
import '../../models/model_runtime.dart' show modelProxyEndpoint;
import 'dsh_route.dart';

/// The route dsh runs on, and the environment that carries what the route
/// needs: every upstream Settings → Models turned on, else this machine's
/// `dsh.env`, else dsh's own configuration.
///
/// A route the app builds is not a file's: every one of its upstreams names
/// the app's own model proxy as its endpoint, in Anthropic's Messages API,
/// and carries the proxy's token in the environment dsh is started with. The
/// upstreams' keys never leave the app, and the only secret dsh is given is
/// one that answers on loopback and is made anew each run.
///
/// What wins, in order:
///
/// 1. a file [DshRoute.pathVariable] names — a script's or a test's explicit
///    instruction, missing being an error rather than a fallback;
/// 2. DSH's own configuration, when Settings → Models says to follow it
///    (`ModelProviders.dshModelIsOwn`);
/// 3. the upstreams Settings → Models turned on, every conversation model of
///    each: the one picked as DSH's model starts the conversation, else the
///    default model, else the model this machine's `dsh.env` names while it
///    is one of them, else the first;
/// 4. `<data>/dsh/dsh.env`, the machine's own file, when no model is turned
///    on in Settings → Models;
/// 5. nothing: dsh runs on its own ACP profile's model and credentials.
final class DshRoutePlan {
  const DshRoutePlan({this.route, this.environment = const {}});

  /// The route to declare, or null for dsh's own.
  final DshRoute? route;

  /// What goes beside the login shell's environment into the dsh process —
  /// now only the proxy's token, under [proxyTokenVariable].
  final Map<String, String> environment;

  /// The variable the app's model proxy token is passed in. A ref of the
  /// route's `apiKeyEnv`, resolved from the environment dsh is started with,
  /// so that nothing is written to dsh's store.
  static const proxyTokenVariable = 'BAOCODE_DSH_PROXY_TOKEN';

  /// The plan for this machine, as the list above says. [providers] and
  /// [endpoint] are the app's, given by a test that must not read the
  /// machine's own settings or bind a socket.
  static Future<DshRoutePlan> load({
    required String directory,
    required Map<String, String> environment,
    ModelProviders? providers,
    Future<ProxyEndpoint> Function(String providerId)? endpoint,
  }) async {
    // A script's or a test's explicit instruction: it names a file, and that
    // file is the route, whatever Settings → Models says.
    if ((environment[DshRoute.pathVariable] ?? '').trim().isNotEmpty) {
      return DshRoutePlan(
        route: await DshRoute.load(
          directory: directory,
          environment: environment,
        ),
      );
    }
    final models = providers ?? ModelProviders.current;
    if (models.dshModelIsOwn) {
      return DshRoutePlan(
        route: await DshRoute.load(
          directory: directory,
          environment: environment,
        ),
      );
    }
    // The machine's own file is read as a hint for where a conversation
    // starts, but it no longer decides what Settings → Models offers. A file
    // that cannot be read is only fatal when there is nothing in Settings to
    // run on instead: the user may have stopped using it.
    DshRoute? own;
    DshRouteException? ownError;
    try {
      own = await DshRoute.load(directory: directory, environment: environment);
    } on DshRouteException catch (error) {
      ownError = error;
    }
    final picked = await _fromSettings(
      models,
      endpoint ?? modelProxyEndpoint,
      own,
    );
    if (picked != null) return picked;
    if (ownError != null) throw ownError;
    return DshRoutePlan(route: own);
  }

  /// The plan Settings → Models gives, or null when no conversation model is
  /// turned on there.
  ///
  /// [hint] is this machine's `dsh.env` route, if it has one: a model the
  /// user was already running on starts the conversation, so that offering
  /// the other models does not silently move it. It never decides the list.
  static Future<DshRoutePlan?> _fromSettings(
    ModelProviders providers,
    Future<ProxyEndpoint> Function(String providerId) endpoint,
    DshRoute? hint,
  ) async {
    final start = _startOf(providers, hint);
    if (start == null) return null;
    final (startProvider, startModel) = start;

    final endpoints = <String, ProxyEndpoint>{};
    Future<ProxyEndpoint> endpointOf(String providerId) async {
      if (endpoints[providerId] case final proxy?) return proxy;
      try {
        return endpoints[providerId] = await endpoint(providerId);
      } on Object catch (error) {
        throw DshRouteException(
          "BaoCode's model proxy could not be started: $error",
        );
      }
    }

    final ProxyEndpoint proxy = await endpointOf(startProvider.id);

    // One dsh provider for each upstream turned on: dsh groups its picker by
    // provider, and switching among them is one selection, no restart. All
    // of them answer at this one proxy, each at its own path and under the
    // same token.
    final keys = <String, String>{};
    final used = <String>{};
    String keyOf(String providerId) => keys.putIfAbsent(providerId, () {
      final base = _routeKey(providerId);
      var key = base;
      for (var n = 2; !used.add(key); n++) {
        key = '$base-$n';
      }
      return key;
    });

    final declared = <DshUpstream>[];
    for (final provider in providers.enabled) {
      final models = [
        for (final one in provider.enabledModels)
          if (!one.kind.generatesImages) _declared(provider, one),
      ];
      // The one picked is always offered, even where its own provider no
      // longer lists it as enabled (a role's model, say).
      if (provider.id == startProvider.id &&
          !models.any((one) => one.id == startModel.id)) {
        models.insert(0, _declared(provider, startModel));
      }
      if (models.isEmpty) continue;
      final at = await endpointOf(provider.id);
      declared.add(
        DshUpstream(
          provider: keyOf(provider.id),
          displayName: provider.name,
          baseUrl: at.baseUrl,
          apiKeyEnv: proxyTokenVariable,
          api: DshApi.anthropicMessages,
          models: models,
        ),
      );
    }
    final startKey = keyOf(startProvider.id);
    final startAt = await endpointOf(startProvider.id);
    return DshRoutePlan(
      route: DshRoute(
        provider: startKey,
        displayName: startProvider.name,
        baseUrl: startAt.baseUrl,
        apiKeyEnv: proxyTokenVariable,
        api: DshApi.anthropicMessages,
        model: startModel.id,
        contextWindow: startModel.initialContext,
        models: [
          for (final upstream in declared)
            if (upstream.provider == startKey) ...upstream.models,
        ],
        upstreams: declared,
        viaProxy: true,
      ),
      environment: {proxyTokenVariable: proxy.token},
    );
  }

  /// Where a conversation starts: DSH's own pick, else the default model,
  /// else the model [hint] names while Settings has it, else the first model
  /// turned on. Null when Settings has none to run on.
  static (ModelProvider, ProviderModel)? _startOf(
    ModelProviders providers,
    DshRoute? hint,
  ) {
    final picked = providers.dshModel;
    if (picked != null) {
      final resolved = providers.resolve(picked);
      if (resolved != null && resolved.$1.enabled) return resolved;
      debugPrint('DSH model "$picked" is gone; not using it');
    }
    final preferred = providers.defaultModel;
    if (preferred != null) {
      final resolved = providers.resolve(preferred);
      if (resolved != null && resolved.$1.enabled) return resolved;
    }
    if (hint != null) {
      final fromHint = _fromHint(providers, hint);
      if (fromHint != null) return fromHint;
    }
    return providers.resolve(providers.firstModel);
  }

  /// The upstream and model [hint], this machine's file, names, while
  /// Settings → Models has that upstream and that model turned on. Matched
  /// by the provider's name, then its endpoint, then the model alone.
  static (ModelProvider, ProviderModel)? _fromHint(
    ModelProviders providers,
    DshRoute hint,
  ) {
    final byKey = providers.providers.where(
      (provider) =>
          provider.enabled &&
          (provider.id == hint.provider ||
              _routeKey(provider.id) == hint.provider),
    );
    for (final provider in byKey) {
      final model = provider.enabledModels
          .where((one) => one.id == hint.model)
          .firstOrNull;
      if (model != null) return (provider, model);
    }
    final byUrl = providers.providers.where(
      (provider) =>
          provider.enabled && _sameEndpoint(provider.baseUrl, hint.baseUrl),
    );
    for (final provider in byUrl) {
      final model = provider.enabledModels
          .where((one) => one.id == hint.model)
          .firstOrNull;
      if (model != null) return (provider, model);
    }
    for (final provider in providers.providers) {
      if (!provider.enabled) continue;
      final model = provider.enabledModels
          .where((one) => one.id == hint.model)
          .firstOrNull;
      if (model != null) return (provider, model);
    }
    return null;
  }

  static DshModel _declared(ModelProvider provider, ProviderModel model) =>
      DshModel(
        id: model.id,
        name: provider.labelOf(model),
        contextWindow: model.initialContext,
        images: model.images,
      );

  /// Whether [a] and [b] name the same endpoint: the same scheme, host,
  /// port and path, a trailing slash aside.
  static bool _sameEndpoint(String a, String b) {
    final left = Uri.tryParse(a.trim());
    final right = Uri.tryParse(b.trim());
    if (left == null || right == null) return a.trim() == b.trim();
    String path(Uri uri) => uri.path.endsWith('/') && uri.path.length > 1
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return left.scheme == right.scheme &&
        left.host == right.host &&
        left.port == right.port &&
        path(left) == path(right);
  }

  /// [providerId] as the patch's route name: a YAML key of the provider
  /// dictionary, and dsh's own id for it.
  static String _routeKey(String providerId) {
    final key = providerId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    return key.isEmpty ? 'baocode' : key;
  }
}

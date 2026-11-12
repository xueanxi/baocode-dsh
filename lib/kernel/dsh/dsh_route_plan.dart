import 'package:flutter/foundation.dart' show debugPrint;

import '../../models/launch_environment.dart' show ProxyEndpoint;
import '../../models/model_providers.dart';
import '../../models/model_runtime.dart';
import 'dsh_route.dart';

/// The route dsh runs on, and the environment that carries what the route
/// needs: the model Settings → Models picks, else this machine's `dsh.env`,
/// else dsh's own configuration.
///
/// A route the app builds is not a file's: it names the app's own model proxy
/// as its endpoint, in Anthropic's Messages API, and carries the proxy's
/// token in the environment dsh is started with. The upstream's key never
/// leaves the app, and the only secret dsh is given is one that answers on
/// loopback and is made anew each run.
///
/// What wins, in order:
///
/// 1. a file [DshRoute.pathVariable] names — a script's or a test's explicit
///    instruction, missing being an error rather than a fallback;
/// 2. the model picked in Settings → Models, while it still resolves to an
///    upstream that is on;
/// 3. `<data>/dsh/dsh.env`, the machine's own file;
/// 4. nothing: dsh runs on its own ACP profile's model and credentials.
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
    if ((environment[DshRoute.pathVariable] ?? '').trim().isNotEmpty) {
      return DshRoutePlan(
        route: await DshRoute.load(
          directory: directory,
          environment: environment,
        ),
      );
    }
    final own = await _fromSettings(
      providers ?? ModelProviders.current,
      endpoint ?? modelProxyEndpoint,
    );
    if (own != null) return own;
    return DshRoutePlan(
      route: await DshRoute.load(
        directory: directory,
        environment: environment,
      ),
    );
  }

  /// The plan Settings → Models gives, or null when no model is picked there
  /// (or the one picked no longer resolves to an upstream that is on: a
  /// stale pick must not keep dsh from starting).
  static Future<DshRoutePlan?> _fromSettings(
    ModelProviders providers,
    Future<ProxyEndpoint> Function(String providerId) endpoint,
  ) async {
    final picked = providers.dshModel;
    if (picked == null) return null;
    final resolved = providers.resolve(picked);
    if (resolved == null || !resolved.$1.enabled) {
      debugPrint('DSH model "$picked" is gone; not using it');
      return null;
    }
    final (provider, model) = resolved;
    final ProxyEndpoint proxy;
    try {
      proxy = await endpoint(provider.id);
    } on Object catch (error) {
      throw DshRouteException(
        "BaoCode's model proxy could not be started: $error",
      );
    }
    final declared = <DshModel>[
      for (final one in provider.enabledModels)
        if (!one.kind.generatesImages)
          DshModel(
            id: one.id,
            name: one.displayName,
            contextWindow: one.initialContext,
            images: one.images,
          ),
    ];
    // The one picked is always offered, even where its own provider no
    // longer lists it as enabled (a role's model, say).
    if (!declared.any((one) => one.id == model.id)) {
      declared.insert(
        0,
        DshModel(
          id: model.id,
          name: model.displayName,
          contextWindow: model.initialContext,
          images: model.images,
        ),
      );
    }
    return DshRoutePlan(
      route: DshRoute(
        provider: _routeKey(provider.id),
        displayName: provider.name,
        baseUrl: proxy.baseUrl,
        apiKeyEnv: proxyTokenVariable,
        api: DshApi.anthropicMessages,
        model: model.id,
        contextWindow: model.initialContext,
        models: declared,
        viaProxy: true,
      ),
      environment: {proxyTokenVariable: proxy.token},
    );
  }

  /// [providerId] as the patch's route name: a YAML key of the provider
  /// dictionary, and dsh's own id for it.
  static String _routeKey(String providerId) {
    final key = providerId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    return key.isEmpty ? 'baocode' : key;
  }
}

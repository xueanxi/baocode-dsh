import 'dart:io';

import 'package:baocode/kernel/dsh/dsh_route.dart';
import 'package:baocode/kernel/dsh/dsh_route_plan.dart';
import 'package:baocode/models/launch_environment.dart' show ProxyEndpoint;
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A route Settings → Models picks: built from the model, through the app's
/// own proxy, its token passed in the environment — no upstream key, no file.
void main() {
  const gateway = ModelProvider(
    id: 'gw',
    name: 'Gateway',
    protocol: ProviderProtocol.openaiChat,
    baseUrl: 'https://gw.example.com/v1',
    models: [
      ProviderModel(id: 'gpt-5', label: 'GPT-5', contextWindow: 400000),
      ProviderModel(id: 'mini', contextWindow: 100000),
      ProviderModel(id: 'draw', kind: ModelKind.image),
    ],
  );

  Future<ProxyEndpoint> endpoint(String providerId) async =>
      (baseUrl: 'http://127.0.0.1:4321/p/$providerId', token: 'loopback-token');

  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('dsh_route_plan');
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('the model picked is the route: through the app\'s proxy, its token '
      'in the environment', () async {
    final providers = ModelProviders.memory(providers: [gateway]);
    await providers.setDshModel('@gw/gpt-5');

    final plan = await DshRoutePlan.load(
      directory: home.path,
      environment: const {'HOME': '/Users/someone'},
      providers: providers,
      endpoint: endpoint,
    );

    final route = plan.route!;
    expect(route.provider, 'gw');
    expect(route.displayName, 'Gateway');
    expect(route.baseUrl, 'http://127.0.0.1:4321/p/gw');
    expect(route.api, DshApi.anthropicMessages);
    expect(route.viaProxy, isTrue);
    expect(route.apiKeyEnv, DshRoutePlan.proxyTokenVariable);
    expect(route.model, 'gpt-5');
    expect(route.contextWindow, 400000);
    expect(plan.environment, {
      DshRoutePlan.proxyTokenVariable: 'loopback-token',
    });
    // Every conversation model the upstream offers, pictures left out:
    // the picker switches among them without a restart.
    expect([for (final model in route.declared) model.id], ['gpt-5', 'mini']);
    expect(route.declared[1].contextWindow, 100000);
  });

  test('nothing picked leaves the machine\'s own file in charge', () async {
    File(p.join(home.path, DshRoute.fileName)).writeAsStringSync('''
provider=stepcodev2
base_url=https://i-ai-gw.example/v1
api_key_env=STEPCODEV2_API_KEY
model=deepseek-v4.1-flash
''');
    final plan = await DshRoutePlan.load(
      directory: home.path,
      environment: const {},
      providers: ModelProviders.memory(providers: [gateway]),
      endpoint: endpoint,
    );

    expect(plan.route!.provider, 'stepcodev2');
    expect(plan.route!.api, DshApi.openaiCompletions);
    expect(plan.route!.viaProxy, isFalse);
    expect(plan.environment, isEmpty);
  });

  test('a file named out of band wins over the pick, a missing one is an '
      'error rather than a fallback', () async {
    final named = File(p.join(home.path, 'elsewhere.env'))
      ..writeAsStringSync('''
provider=local
base_url=http://127.0.0.1:8080/v1
api_key_env=LOCAL_API_KEY
model=local-model
''');
    final providers = ModelProviders.memory(providers: [gateway]);
    await providers.setDshModel('@gw/gpt-5');

    final plan = await DshRoutePlan.load(
      directory: home.path,
      environment: {'BAOCODE_DSH_ENV': named.path},
      providers: providers,
      endpoint: endpoint,
    );
    expect(plan.route!.provider, 'local');
    expect(plan.environment, isEmpty);

    expect(
      () => DshRoutePlan.load(
        directory: home.path,
        environment: {'BAOCODE_DSH_ENV': p.join(home.path, 'gone.env')},
        providers: providers,
        endpoint: endpoint,
      ),
      throwsA(isA<DshRouteException>()),
    );
  });

  test(
    'a pick that no longer resolves lets go: the file, else dsh\'s own',
    () async {
      final providers = ModelProviders.memory(providers: [gateway]);
      await providers.setDshModel('@gw/gpt-5');

      // The upstream turned off: the pick is stale.
      await providers.save(gateway.copyWith(enabled: false));
      final plan = await DshRoutePlan.load(
        directory: home.path,
        environment: const {},
        providers: providers,
        endpoint: endpoint,
      );
      expect(plan.route, isNull);
      expect(plan.environment, isEmpty);
    },
  );

  test(
    'a proxy that cannot start says so rather than running elsewhere',
    () async {
      final providers = ModelProviders.memory(providers: [gateway]);
      await providers.setDshModel('@gw/gpt-5');

      expect(
        () => DshRoutePlan.load(
          directory: home.path,
          environment: const {},
          providers: providers,
          endpoint: (providerId) async => throw StateError('no loopback here'),
        ),
        throwsA(
          isA<DshRouteException>().having(
            (error) => error.message,
            'message',
            contains('proxy'),
          ),
        ),
      );
    },
  );
}

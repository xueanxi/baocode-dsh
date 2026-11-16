import 'dart:io';

import 'package:baocode/kernel/dsh/dsh_route.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The file a machine keeps its dsh route in: `.env`'s shape, read as the
/// patch's provider, endpoint, credential ref and model.
void main() {
  group('reading the file', () {
    test('a route file is `.env`\'s shape, quotes and all', () {
      final route = DshRoute.parse('''
# This machine's own model.
provider=stepcodev2
base_url="https://i-ai-gw.stepx.com/v1"
api_key_env='STEPCODEV2_API_KEY'

model=deepseek-v4.1-flash
context_window=512000
''');

      expect(route.provider, 'stepcodev2');
      expect(route.baseUrl, 'https://i-ai-gw.stepx.com/v1');
      expect(route.apiKeyEnv, 'STEPCODEV2_API_KEY');
      expect(route.model, 'deepseek-v4.1-flash');
      expect(route.contextWindow, 512000);
    });

    test('a window left out is the default one, until dsh says its own', () {
      final route = DshRoute.parse('''
provider=local
base_url=http://127.0.0.1:8080/v1
api_key_env=LOCAL_API_KEY
model=local-model
''');

      expect(route.contextWindow, DshRoute.defaultContextWindow);
    });

    test('a value the patch cannot carry is refused, naming the key', () {
      expect(
        () => DshRoute.parse(
          'provider=two words\n'
          'base_url=http://127.0.0.1/v1\n'
          'api_key_env=K\n'
          'model=m\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('provider'),
          ),
        ),
      );
    });

    test('a key that is not a route\'s is refused, naming the line', () {
      expect(
        () => DshRoute.parse(
          'provider=p\n'
          'base_url=http://127.0.0.1/v1\n'
          'api_key_env=K\n'
          'model=m\n'
          'apikey=sk-oops\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('line 5'), contains('apikey')),
          ),
        ),
      );
    });

    test('a required key missing is refused by name', () {
      expect(
        () => DshRoute.parse(
          'provider=p\n'
          'base_url=http://127.0.0.1/v1\n'
          'api_key_env=K\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('model'),
          ),
        ),
      );
    });

    test('the same key twice is refused, not silently overridden', () {
      expect(
        () => DshRoute.parse(
          'provider=a\n'
          'provider=b\n'
          'base_url=http://127.0.0.1/v1\n'
          'api_key_env=K\n'
          'model=m\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('set twice'),
          ),
        ),
      );
    });

    test('a URL that is not http(s) is refused', () {
      expect(
        () => DshRoute.parse(
          'provider=p\n'
          'base_url=ftp://127.0.0.1/v1\n'
          'api_key_env=K\n'
          'model=m\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('base_url'),
          ),
        ),
      );
    });

    test('a window that is not a positive number is refused', () {
      expect(
        () => DshRoute.parse(
          'provider=p\n'
          'base_url=http://127.0.0.1/v1\n'
          'api_key_env=K\n'
          'model=m\n'
          'context_window=0\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('context_window'),
          ),
        ),
      );
    });
  });

  group('finding the file', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('baocode-dsh-route');
    });
    tearDown(() => root.delete(recursive: true));

    test('no file: dsh\'s own route, not a failure', () async {
      expect(await DshRoute.load(directory: p.join(root.path, 'dsh')), isNull);
    });

    test('the file the data folder holds is read', () async {
      final directory = p.join(root.path, 'dsh');
      await Directory(directory).create(recursive: true);
      await File(p.join(directory, DshRoute.fileName)).writeAsString('''
provider=local
base_url=http://127.0.0.1:8080/v1
api_key_env=LOCAL_API_KEY
model=local-model
''');

      final route = await DshRoute.load(directory: directory);
      expect(route?.provider, 'local');
      expect(route?.model, 'local-model');
    });

    test('a path named for the purpose is read instead', () async {
      final file = File(p.join(root.path, 'mine.env'))
        ..writeAsStringSync(
          'provider=p\n'
          'base_url=http://127.0.0.1/v1\n'
          'api_key_env=K\n'
          'model=m\n',
        );

      final route = await DshRoute.load(
        directory: p.join(root.path, 'dsh'),
        environment: {DshRoute.pathVariable: file.path},
      );
      expect(route?.provider, 'p');
    });

    test('a path named and not there is a failure, not a fallback', () async {
      expect(
        () => DshRoute.load(
          directory: p.join(root.path, 'dsh'),
          environment: {DshRoute.pathVariable: p.join(root.path, 'gone.env')},
        ),
        throwsA(isA<DshRouteException>()),
      );
    });

    test('a file that cannot be read says which file', () async {
      final directory = p.join(root.path, 'dsh');
      // A folder of that name: reading it fails.
      await Directory(p.join(directory, DshRoute.fileName))
          .create(recursive: true);

      expect(
        () => DshRoute.load(directory: directory),
        throwsA(
          isA<DshRouteException>().having(
            (error) => error.message,
            'message',
            contains(DshRoute.fileName),
          ),
        ),
      );
    });

    test('a file with a typo says which file and which line', () async {
      final directory = p.join(root.path, 'dsh');
      await Directory(directory).create(recursive: true);
      await File(p.join(directory, DshRoute.fileName)).writeAsString('''
provider=p
base_url=http://127.0.0.1/v1
api_key_env=K
model=m
nonsense=1
''');

      expect(
        () => DshRoute.load(directory: directory),
        throwsA(
          isA<DshRouteException>().having(
            (error) => error.message,
            'message',
            allOf(contains(DshRoute.fileName), contains('line 5')),
          ),
        ),
      );
    });
  });

  group('a choice a session kept from an earlier route', () {
    const route = DshRoute(
      provider: 'gw',
      displayName: 'Gateway',
      baseUrl: 'http://127.0.0.1:1/p/gw',
      apiKeyEnv: 'BAOCODE_DSH_PROXY_TOKEN',
      api: DshApi.anthropicMessages,
      model: 'gpt-5',
      contextWindow: 400000,
      models: [
        DshModel(id: 'gpt-5', contextWindow: 400000),
        DshModel(id: 'mini', contextWindow: 100000),
      ],
      viaProxy: true,
    );

    test('is declared for dsh, and still not offered', () {
      final carried = route.carrying(['["stepcodev2","deepseek-v4.1-flash"]']);

      expect(carried.recorded, [('stepcodev2', 'deepseek-v4.1-flash')]);
      // The picker's list: the route's own models, not what dsh resolves.
      expect(
        [for (final upstream in carried.declaredUpstreams) upstream.provider],
        ['gw'],
      );
      // The patch's: one more upstream, at the same endpoint and credential,
      // so a session recorded on it opens before it is moved onto `gw`.
      final upstreams = carried.patchUpstreams;
      expect(
        [for (final upstream in upstreams) upstream.provider],
        ['gw', 'stepcodev2'],
      );
      expect(upstreams.last.baseUrl, route.baseUrl);
      expect(upstreams.last.apiKeyEnv, route.apiKeyEnv);
      expect(upstreams.last.api, route.api);
      expect(
        [for (final model in upstreams.last.models) model.id],
        ['deepseek-v4.1-flash'],
      );
    });

    test('is merged under the upstream it names, where that one is kept', () {
      final carried = route.carrying(['["gw","old-model"]']);

      expect(carried.recorded, [('gw', 'old-model')]);
      expect(
        [for (final model in carried.patchUpstreams.single.models) model.id],
        ['gpt-5', 'mini', 'old-model'],
      );
      // Still not a choice of this route.
      expect(
        [for (final model in carried.declared) model.id],
        ['gpt-5', 'mini'],
      );
    });

    test('a choice the route offers, or not a dsh value, changes nothing', () {
      expect(identical(route.carrying(['["gw","mini"]']), route), isTrue);
      expect(identical(route.carrying(['claude-opus-4']), route), isTrue);
      expect(identical(route.carrying([null]), route), isTrue);
    });

    test('dsh\'s model value is the only shape read', () {
      expect(DshRoute.choiceOf('["gw","mini"]'), ('gw', 'mini'));
      expect(DshRoute.choiceOf('gw/mini'), isNull);
      expect(DshRoute.choiceOf('["gw"]'), isNull);
      expect(DshRoute.choiceOf(null), isNull);
    });
  });
}

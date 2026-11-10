import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:baocode/kernel/dsh/dsh_locate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Finding dsh in fixture folders: no dsh runs, and the PATH searched is
/// the one each test gives (or the shell's, through its own seam).
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('baocode-dsh-locate'));
  tearDown(() => root.deleteSync(recursive: true));

  String at(String relative) => p.join(root.path, relative);

  /// A file at [path] under [root], its folders made; its full path.
  String write(String path, String text) {
    final file = File(at(path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return file.path;
  }

  /// The `node` fixture in [dir] (never run).
  String node(String dir) => write(p.join(dir, 'node'), '');

  /// An npm-installed dsh whose modules are [modules], with a
  /// `package.json` at [version] unless null; its `bin.js`.
  String installIn(String modules, {String? version = '0.2.0-rc.2'}) {
    final package = p.join(modules, '@deepseek-ai', 'dsh');
    final binJs = write(p.join(package, 'lib', 'bin.js'), '');
    if (version != null) {
      write(p.join(package, 'package.json'), jsonEncode({'version': version}));
    }
    return binJs;
  }

  /// The PATH value naming [dirs], in order.
  String pathOf(Iterable<String> dirs) =>
      dirs.join(Platform.isWindows ? ';' : ':');

  group('a setting', () {
    test('naming the bin.js: the node on the PATH runs it', () async {
      final binJs = installIn(at(p.join('npm', 'node_modules')));
      final nodePath = node('bin');

      final found = await locateDsh(
        setting: binJs,
        environment: {'PATH': at('bin')},
      );

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
      expect(found.node, nodePath);
      expect(found.version, '0.2.0-rc.2');
      expect(
        found.packageDir,
        at(p.join('npm', 'node_modules', '@deepseek-ai', 'dsh')),
      );
    });

    test('naming node and bin.js apart: node is taken as named', () async {
      final binJs = installIn(
        at(p.join('npm', 'node_modules')),
        version: '0.3.0',
      );
      final nodePath = node('tools');

      final found = await locateDsh(
        setting: ' $nodePath | $binJs ',
        environment: {'PATH': ''},
      );

      expect(found, isNotNull);
      expect(found!.node, nodePath);
      expect(found.version, '0.3.0');
    });

    test('starting at ~: read from the home the environment names', () async {
      final binJs = installIn(at(p.join('home', 'npm', 'node_modules')));
      final nodePath = node(p.join('home', 'bin'));

      final found = await locateDsh(
        setting: '~/npm/node_modules/@deepseek-ai/dsh/lib/bin.js',
        environment: _homeEnvironment(at('home'), path: 'bin'),
      );

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
      // The same expansion for the node of a two-part setting.
      expect(found.node, nodePath);
    });

    test('the node of a two-part setting is expanded as well', () async {
      final binJs = installIn(at(p.join('home', 'npm', 'node_modules')));
      final nodePath = node(p.join('home', 'bin'));

      final found = await locateDsh(
        setting: '~/bin/node | ~/npm/node_modules/@deepseek-ai/dsh/lib/bin.js',
        environment: _homeEnvironment(at('home')),
      );

      expect(found, isNotNull);
      expect(found!.node, nodePath);
      expect(found.binJs, binJs);
    });

    test('a ~ that starts nothing is a character in a name', () async {
      final binJs = installIn(at(p.join('home', 'npm', 'node_modules')));
      node(p.join('home', 'bin'));

      // The file is there — this is the setting that finds it.
      expect(
        await locateDsh(
          setting: binJs,
          environment: _homeEnvironment(at('home'), path: 'bin'),
        ),
        isNotNull,
      );
      // `…/~/…` and `~someone/…` are not the home, and nothing expands them.
      expect(
        await locateDsh(
          setting: p.join(
            at('home'),
            '~',
            'npm',
            'node_modules',
            '@deepseek-ai',
            'dsh',
            'lib',
            'bin.js',
          ),
          environment: _homeEnvironment(at('home'), path: 'bin'),
        ),
        isNull,
      );
      expect(
        await locateDsh(
          setting: '~someone/npm/node_modules/@deepseek-ai/dsh/lib/bin.js',
          environment: _homeEnvironment(at('home'), path: 'bin'),
        ),
        isNull,
      );
      // No home in the environment: nothing to expand it to.
      expect(
        await locateDsh(
          setting: '~/npm/node_modules/@deepseek-ai/dsh/lib/bin.js',
          environment: {'PATH': at(p.join('home', 'bin'))},
        ),
        isNull,
      );
    });

    test('naming what is not there: none is found', () async {
      expect(
        await locateDsh(
          setting: at(p.join('nowhere', 'lib', 'bin.js')),
          environment: {'PATH': ''},
        ),
        isNull,
      );
      expect(await locateDsh(setting: '|', environment: {'PATH': ''}), isNull);
    });
  });

  group('a PATH shim', () {
    test('a shell one runs the package two folders above its bin', () async {
      final binJs = installIn(at(p.join('prefix', 'lib', 'node_modules')));
      node(p.join('prefix', 'bin'));
      write(p.join('prefix', 'bin', 'dsh'), _shellShim);

      final found = await locateDsh(
        environment: {'PATH': at(p.join('prefix', 'bin'))},
      );

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
      expect(found.node, at(p.join('prefix', 'bin', 'node')));
    });

    test('a Windows one runs the package beside it', () async {
      final binJs = installIn(at(p.join('npm', 'node_modules')));
      node('npm');
      write(p.join('npm', 'dsh.cmd'), _cmdShim);

      final found = await locateDsh(environment: {'PATH': at('npm')});

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
      expect(
        DshLocate.binJsFromShim(_cmdShim, at('npm')),
        p.join(
          at('npm'),
          'node_modules',
          '@deepseek-ai',
          'dsh',
          'lib',
          'bin.js',
        ),
      );
    });

    test('running another program is skipped', () async {
      final binJs = installIn(at(p.join('later', 'node_modules')));
      node('later');
      write(p.join('first', 'dsh'), '#!/bin/sh\nexec /opt/other/run.js\n');
      write(p.join('later', 'dsh.cmd'), _cmdShim);

      final found = await locateDsh(
        environment: {
          'PATH': pathOf([at('first'), at('later')]),
        },
      );

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
      expect(
        DshLocate.binJsFromShim(
          '#!/bin/sh\nexec /opt/other/run.js\n',
          at('first'),
        ),
        isNull,
      );
    });
  });

  group('npm\'s global folder', () {
    test(
      'a package beside a PATH folder is found (Windows)',
      () async {
        final binJs = installIn(at(p.join('npm', 'node_modules')));
        node('npm');

        final beside = await locateDsh(environment: {'PATH': at('npm')});

        expect(beside, isNotNull);
        expect(beside!.binJs, binJs);
        expect(beside.node, at(p.join('npm', 'node')));
      },
      skip: Platform.isWindows
          ? false
          : 'npm keeps packages this way on '
                'Windows only',
    );

    test('the npm folder of APPDATA is searched (Windows)', () async {
      final binJs = installIn(at(p.join('appdata', 'npm', 'node_modules')));
      node('tools');

      final found = await locateDsh(
        environment: {'PATH': at('tools'), 'APPDATA': at('appdata')},
      );

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
    }, skip: Platform.isWindows ? false : 'APPDATA is a Windows location');

    test('a package under a PATH bin\'s prefix is found (POSIX)', () async {
      final binJs = installIn(at(p.join('prefix', 'lib', 'node_modules')));
      node(p.join('prefix', 'bin'));

      final found = await locateDsh(
        environment: {'PATH': at(p.join('prefix', 'bin'))},
      );

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
    }, skip: Platform.isWindows ? 'npm keeps packages elsewhere here' : false);

    test('~/.npm-global is searched (POSIX)', () async {
      final binJs = installIn(
        at(p.join('home', '.npm-global', 'lib', 'node_modules')),
      );
      node('tools');

      final found = await locateDsh(
        environment: {'PATH': at('tools'), 'HOME': at('home')},
      );

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
    }, skip: Platform.isWindows ? 'npm-global is a POSIX prefix' : false);

    test('every Node of ~/.nvm is searched (POSIX)', () async {
      final binJs = installIn(
        at(
          p.join(
            'home',
            '.nvm',
            'versions',
            'node',
            'v24.12.0',
            'lib',
            'node_modules',
          ),
        ),
      );
      node('tools');

      final found = await locateDsh(
        environment: {'PATH': at('tools'), 'HOME': at('home')},
      );

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
    }, skip: Platform.isWindows ? 'nvm lives elsewhere here' : false);
  });

  test('the version is unknown where package.json is not there', () async {
    final binJs = installIn(at(p.join('npm', 'node_modules')), version: null);
    node('bin');

    final found = await locateDsh(
      setting: binJs,
      environment: {'PATH': at('bin')},
    );

    expect(found, isNotNull);
    expect(found!.version, 'unknown');
  });

  test(
    'with no environment given, the login shell\'s PATH is searched',
    () async {
      final binJs = installIn(at(p.join('npm', 'node_modules')));
      node('npm');
      write(p.join('npm', 'dsh.cmd'), _cmdShim);
      ClaudeEnvironment.use({'PATH': at('npm')});
      addTearDown(() => ClaudeEnvironment.use(null));

      final found = await locateDsh();

      expect(found, isNotNull);
      expect(found!.binJs, binJs);
    },
  );

  group('what a shim and a setting are written as', () {
    test('a setting is one path, or node and the path apart by a pipe', () {
      expect(DshLocate.splitSetting(' /x/lib/bin.js '), (
        node: null,
        binJs: '/x/lib/bin.js',
      ));
      expect(DshLocate.splitSetting('/usr/bin/node | /x/lib/bin.js'), (
        node: '/usr/bin/node',
        binJs: '/x/lib/bin.js',
      ));
      expect(DshLocate.splitSetting('|/x/lib/bin.js'), isNull);
      expect(DshLocate.splitSetting('/x/lib/bin.js|'), isNull);
      expect(DshLocate.splitSetting('/a|/b|/c'), isNull);
      expect(DshLocate.splitSetting('  '), isNull);
    });

    test('a shim names the package\'s bin.js, from the folder it is in', () {
      expect(
        DshLocate.binJsFromShim(_cmdShim, at('npm')),
        p.join(
          at('npm'),
          'node_modules',
          '@deepseek-ai',
          'dsh',
          'lib',
          'bin.js',
        ),
      );
      expect(
        DshLocate.binJsFromShim(_shellShim, at('bin')),
        p.normalize(
          p.join(
            at('bin'),
            '..',
            'lib',
            'node_modules',
            '@deepseek-ai',
            'dsh',
            'lib',
            'bin.js',
          ),
        ),
      );
      expect(
        DshLocate.binJsFromShim('#!/bin/sh\nexec dsh "\$@"\n', at('bin')),
        isNull,
      );
    });

    test('a package.json gives its version, or unknown', () {
      expect(DshLocate.versionIn('{"version":"0.2.0-rc.2"}'), '0.2.0-rc.2');
      expect(DshLocate.versionIn('{"version":" 0.3.0 "}'), '0.3.0');
      expect(DshLocate.versionIn('{"name":"x"}'), 'unknown');
      expect(DshLocate.versionIn('{"version":""}'), 'unknown');
      expect(DshLocate.versionIn('not json'), 'unknown');
    });
  });
}

/// The environment of a test whose home is [home]: the home as both platforms
/// name it, and a PATH of [path] under it (empty for none).
Map<String, String> _homeEnvironment(String home, {String path = ''}) => {
  'HOME': home,
  'USERPROFILE': home,
  'PATH': path.isEmpty ? '' : p.join(home, path),
};

/// An npm `.cmd` shim's text, as npm writes it on Windows.
const _cmdShim = r'''
@ECHO off
SETLOCAL
SET dp0=%~dp0
endLocal & "%_prog%"  "%dp0%\node_modules\@deepseek-ai\dsh\lib\bin.js" %*
''';

/// A shell npm shim's text, for a package under the prefix of the `bin` it
/// sits in.
const _shellShim = r'''
#!/usr/bin/env bash
basedir=$(dirname "$0")
exec "$basedir/node"  "$basedir/../lib/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@"
''';

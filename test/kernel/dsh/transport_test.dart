import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/dsh/dsh_locate.dart';
import 'package:baocode/kernel/dsh/dsh_transport.dart';
import 'package:baocode/kernel/dsh/dsh_transport_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A `node -e` stand-in for dsh runs here, never dsh: it answers the lines
/// written to it in JSON, so no token is spent and no real session starts.
void main() {
  late Directory dir;
  late File registryFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('baocode-dsh-transport');
    registryFile = File(p.join(dir.path, 'dsh-processes.json'));
    // Never the user's own list, nor their processes.
    DshProcessTransport.registry = DshProcessRegistry(
      file: registryFile,
      lookup: (_) async => null,
      signal: (_) => false,
    );
    // A dsh gets seconds to flush and end; a stand-in need not that long.
    DshProcessTransport.exitGrace = const Duration(milliseconds: 200);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Ends [transport] after the test, and waits for its process to go.
  void endAfter(DshTransport transport) {
    addTearDown(() async {
      transport.close();
      await transport.exited.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
    });
  }

  /// Waits (a while) for the first of [messages] that [test] takes.
  Future<Map<String, Object?>> messageWhere(
    List<Map<String, Object?>> messages,
    bool Function(Map<String, Object?>) test,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (true) {
      for (final message in messages) {
        if (test(message)) return message;
      }
      if (DateTime.now().isAfter(deadline)) fail('No such message: $messages');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'runs node with the ACP profile, the patch and the permission mode',
    () async {
      final standIn = File(p.join(dir.path, 'stand-in.js'))
        ..writeAsStringSync(_standIn);
      final patchFile = p.join(dir.path, 'acp.patch.yml');
      final transport = await DshProcessTransport.start(
        DshLaunch(
          cwd: dir.path,
          install: DshInstall(
            node: nodePath(),
            binJs: standIn.path,
            version: '0.0.0',
            packageDir: dir.path,
          ),
          patchFile: patchFile,
          permissionMode: 'read-only',
        ),
      );
      endAfter(transport);

      final messages = <Map<String, Object?>>[];
      transport.messages.listen(messages.add);
      transport.write({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ask',
        'ask': true,
      });

      final facts = await messageWhere(messages, (m) => m['type'] == 'facts');
      expect(facts['mode'], 'read-only');
      expect(facts['argv'], [
        standIn.path,
        '--profile',
        'acp',
        '--patch',
        patchFile,
      ]);
      expect(
        p.equals('${facts['cwd']}', dir.path),
        isTrue,
        reason: '${facts['cwd']}',
      );
    },
  );

  test(
    'decodes each line, and keeps what is not protocol for the report',
    () async {
      final process = await Process.start(nodePath(), ['-e', _standIn]);
      final transport = DshProcessTransport.forProcess(process);
      endAfter(transport);
      final messages = <Map<String, Object?>>[];
      final done = Completer<void>();
      transport.messages.listen(messages.add, onDone: done.complete);

      transport.write({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      transport.write({'jsonrpc': '2.0', 'id': 2, 'method': 'ping'});
      transport.write({'stop': true});
      await done.future.timeout(const Duration(seconds: 20));

      final echoed = [
        for (final message in messages)
          if (message['echo'] case final Object echo) echo,
      ];
      expect(echoed, [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'ping'},
      ]);
      // Not protocol: it goes in the report, not into the conversation.
      expect(echoed, isNot(contains('dsh stand-in says hello')));
      final exit = messages.last;
      expect(exit['type'], DshExit.type);
      expect(exit['code'], 3);
      expect('${exit['stderr']}', contains('dsh stand-in says hello'));
      expect('${exit['stderr']}', contains('dsh stand-in says goodbye'));
    },
  );

  test('a credential is taken out before the line is kept', () async {
    final process = await Process.start(nodePath(), ['-e', _leaky]);
    final transport = DshProcessTransport.forProcess(process);
    endAfter(transport);
    final messages = <Map<String, Object?>>[];
    final done = Completer<void>();
    transport.messages.listen(messages.add, onDone: done.complete);

    await done.future.timeout(const Duration(seconds: 20));

    final stderr = '${messages.last['stderr']}';
    // The line it printed, with the credential said as its shape alone.
    expect(stderr, contains('Authorization: Bearer ***'));
    expect(stderr, isNot(contains('sk-live-123')));
    // A long opaque run is a key until it is known not to be.
    expect(stderr, contains('a long key ***'));
    expect(stderr, isNot(contains(_longKey)));
    // A non-JSON line on stdout goes the same way, and one line is one line:
    // what was taken out does not swallow the line after it.
    expect(stderr, contains('on stdout too: Bearer ***'));
    expect(stderr, contains('and this line is readable'));
  });

  group('a stderr line, before it is kept', () {
    test('keeps what a credential was, and none of what it was', () {
      expect(
        DshRedact.line('Authorization: Bearer sk-abc123'),
        'Authorization: Bearer ***',
      );
      expect(
        DshRedact.line('authorization=Basic dXNlcjpwYXNz'),
        'authorization: ***',
      );
      expect(
        DshRedact.line('sent with Bearer abc.def/ghi'),
        'sent with Bearer ***',
      );
      expect(DshRedact.line('key $_longKey'), 'key ***');
      // Said again, it is already said: a detail read twice does not change.
      expect(
        DshRedact.line('Authorization: Bearer ***'),
        'Authorization: Bearer ***',
      );
    });

    test('leaves what is not a credential as it was', () {
      const line = 'Error: cannot find module /opt/dsh/lib/bin.js';
      expect(DshRedact.line(line), line);
      expect(
        DshRedact.line('the git bash is C:/Program Files/Git/bin/bash.exe'),
        'the git bash is C:/Program Files/Git/bin/bash.exe',
      );
    });
  });

  test('close ends a process that would go on, after its grace', () async {
    final process = await Process.start(nodePath(), ['-e', _stubborn]);
    final transport = DshProcessTransport.forProcess(process);
    final done = Completer<void>();
    transport.messages.listen((_) {}, onDone: done.complete);

    transport.close();
    await transport.exited.timeout(const Duration(seconds: 15));
    await done.future.timeout(const Duration(seconds: 5));

    expect(process.kill(ProcessSignal.sigkill), isFalse);
  });

  test('a node that is not there: the start fails, saying which', () async {
    final node = p.join(dir.path, 'nope', 'node.exe');

    await expectLater(
      DshProcessTransport.start(
        DshLaunch(
          cwd: dir.path,
          install: DshInstall(
            node: node,
            binJs: p.join(dir.path, 'lib', 'bin.js'),
            version: '0.0.0',
            packageDir: dir.path,
          ),
          patchFile: p.join(dir.path, 'acp.patch.yml'),
          permissionMode: 'workspace-write',
        ),
      ),
      throwsA(
        isA<DshUnavailable>().having((e) => '$e', 'error', contains(node)),
      ),
    );
  });

  test('stopAll ends every process it started, and forgets it', () async {
    final process = await Process.start(nodePath(), ['-e', _stubborn]);
    final transport = DshProcessTransport.forProcess(process);
    final done = Completer<void>();
    transport.messages.listen((_) {}, onDone: done.complete);

    await DshProcessTransport.stopAll(timeout: const Duration(seconds: 2));
    await transport.exited.timeout(const Duration(seconds: 15));
    await done.future.timeout(const Duration(seconds: 5));

    expect(process.kill(ProcessSignal.sigkill), isFalse);
    await expectListed(registryFile, isEmpty);
  });

  group('the processes a later run may end', () {
    test('are only those running dsh\'s ACP profile', () {
      const binJs = '/opt/npm/node_modules/@deepseek-ai/dsh/lib/bin.js';

      expect(
        DshProcessRegistry.isDsh(
          '/usr/local/bin/node $binJs --profile acp --patch /tmp/a.yml',
        ),
        isTrue,
      );
      expect(
        DshProcessRegistry.isDsh('/usr/local/bin/node "$binJs" --profile acp'),
        isTrue,
      );
      expect(
        DshProcessRegistry.isDsh('/usr/bin/grep dsh --profile acp'),
        isFalse,
      );
      expect(
        DshProcessRegistry.isDsh('/usr/local/bin/node $binJs --profile web'),
        isFalse,
      );
      expect(
        DshProcessRegistry.isDsh(
          '/usr/local/bin/node /opt/other/lib/bin.js --profile acp',
        ),
        isFalse,
      );
      expect(DshProcessRegistry.isDsh('dsh --profile acp'), isFalse);
      expect(DshProcessRegistry.isDsh('/usr/local/bin/node $binJs'), isFalse);
      expect(DshProcessRegistry.isDsh(''), isFalse);
    });
  });
}

/// Reads the lines it is given and answers in JSON; `ask` answers with what
/// it was started as, `stop` prints a last line and exits 3.
const _standIn = r'''
const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin });
console.log('dsh stand-in says hello');
rl.on('line', (line) => {
  const message = JSON.parse(line);
  if (message.stop === true) {
    console.log('dsh stand-in says goodbye');
    process.exit(3);
  }
  if (message.ask === true) {
    console.log(JSON.stringify({
      type: 'facts',
      argv: process.argv.slice(1),
      mode: process.env.DSH_PERMISSION_MODE,
      cwd: process.cwd(),
    }));
    return;
  }
  console.log(JSON.stringify({ echo: message }));
});
''';

/// The key the leaky stand-in prints: long enough to be one, and not a word.
const _longKey = 'abcdefghijklmnopqrstuvwxyz012345';

/// Prints a credential on both streams, says one line after it, and exits 4.
final _leaky =
    '''
console.log('on stdout too: Bearer sk-live-123');
console.error('Authorization: Bearer sk-live-123');
console.error('a long key $_longKey');
console.error('and this line is readable');
process.exit(4);
''';

/// Goes on whatever its input says: only being ended stops it.
const _stubborn = r'''
console.log('up');
setInterval(() => {}, 1000);
''';

/// The `node` to run the stand-in with, from this machine's PATH.
String nodePath() {
  final found = Platform.isWindows
      ? Process.runSync('where', ['node'])
      : Process.runSync('which', ['node']);
  final paths = '${found.stdout}'
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  if (found.exitCode != 0 || paths.isEmpty) {
    fail('These tests run node, and none was found on the PATH.');
  }
  return paths.first;
}

/// Waits (a while) for [file], written in the background, to list what
/// [matcher] matches.
Future<void> expectListed(File file, Object? matcher) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final text = file.existsSync() ? file.readAsStringSync() : '';
    final found = text.isEmpty ? null : jsonDecode(text);
    if (wrapMatcher(matcher).matches(found, {}) ||
        DateTime.now().isAfter(deadline)) {
      expect(found, matcher);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

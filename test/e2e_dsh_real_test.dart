// Reports what the real dsh did, for a person to read: the tool it called, the
// panel's answer, and the turn's end. Opt in with
// `flutter test --run-skipped -t dsh-e2e` (spends a few cents).
// ignore_for_file: avoid_print
@Tags(['dsh-e2e'])
library;

import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_kernel.dart';
import 'package:baocode/kernel/dsh/dsh_locate.dart';
import 'package:baocode/kernel/dsh/dsh_sessions.dart';
import 'package:baocode/kernel/dsh/dsh_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// A new git repository to run dsh in, removed after the test.
Future<String> _tempProject() async {
  final dir = await Directory.systemTemp.createTemp('baocode-dsh-e2e-');
  final cwd = dir.resolveSymbolicLinksSync();
  await Process.run('git', ['init', '-q'], workingDirectory: cwd);
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return cwd;
}

void main() {
  test(
    'real dsh asks with the panel, and the answer goes back',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      final install = await locateDsh();
      expect(
        install,
        isNotNull,
        reason: 'dsh is not installed on this machine',
      );
      final cwd = await _tempProject();
      final kernel = DshKernel(
        KernelRegistry.dsh,
        KernelContext(cwd: cwd),
        start: startDsh,
        locate: locateDsh,
        environment: ClaudeEnvironment.of,
        sessions: MemoryDshSessionStore(),
      );
      addTearDown(() async {
        kernel.dispose();
        await kernel.stopped;
      });

      final events = <KernelEvent>[];
      QuestionRequest? asked;
      kernel.events.listen((event) {
        events.add(event);
        if (event is! InteractionRequested) return;
        final request = event.request;
        if (request is! QuestionRequest) return;
        asked = request;
        print('[panel] ${request.title}: ${request.questions.first.prompt}');
        // As the panel's answer does: outside the event the kernel is
        // delivering (answering within the listener fires into a controller
        // already firing).
        Future.microtask(
          () => kernel.answer(
            request.id,
            QuestionAnswer([
              for (final question in request.questions)
                [
                  question.options
                      .map((option) => option.label)
                      .firstWhere(
                        (label) => label.toLowerCase().contains('apple'),
                        orElse: () => question.options.first.label,
                      ),
                ],
            ]),
          ),
        );
      });

      kernel.prepare();
      await _until(
        () => kernel.health.status == KernelHealthStatus.ready,
        'the handshake',
      );
      kernel.send(
        KernelTurn(
          id: 'ask-1',
          text:
              'Use the ask_user_question tool to ask me which fruit I want, '
              'with options Apple and Banana. Then tell me which fruit I '
              'picked. Do not ask in plain text.',
        ),
      );
      await _until(
        () => events.whereType<TurnEnded>().isNotEmpty,
        'the turn to end',
        timeout: const Duration(minutes: 3),
      );

      expect(asked, isNotNull, reason: 'the model never asked with the tool');
      final tools = [
        for (final event in events.whereType<ItemUpserted>())
          if (event.item case final ToolCallItem call) call,
      ];
      for (final tool in tools) {
        print('[tool] ${tool.target}: ${tool.output}');
      }
      expect(
        tools.any((tool) => '${tool.output}'.contains('Apple')),
        isTrue,
        reason: 'the answer never reached dsh',
      );
      final said = [
        for (final event in events.whereType<ItemUpserted>())
          if (event.item case final AssistantTextItem text) text.text,
      ].join('\n');
      print('[assistant] $said');
      expect(said.toLowerCase(), contains('apple'));
      expect(kernel.health.status, isNot(KernelHealthStatus.failed));
    },
  );
}

/// Runs the event loop until [done] holds, giving up after [timeout].
Future<void> _until(
  bool Function() done,
  String what, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

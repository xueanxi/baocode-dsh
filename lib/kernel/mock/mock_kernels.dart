import 'package:flutter/material.dart';

import '../agent_kernel.dart';
import '../claude_code/claude_code_kernel.dart';
import '../claude_code/mock_claude_code_transport.dart';
import '../codex/codex_kernel.dart';
import '../codex/mock_codex_transport.dart';
import '../dsh/dsh_kernel.dart';
import '../dsh/dsh_locate.dart';
import '../dsh/dsh_sessions.dart';
import '../dsh/mock_dsh_transport.dart';
import '../../customize/customizations.dart';

/// Kernels over scripted transports: the real adapters, fed recorded
/// protocol, for tests and demos. Not offered in the app.
abstract final class MockKernels {
  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: 'Anthropic’s coding agent',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      start: MockClaudeCodeTransport.start,
    ),
  );

  static final KernelDescriptor codex = KernelDescriptor(
    id: 'codex',
    label: 'Codex',
    icon: Icons.data_object_rounded,
    description: 'OpenAI’s coding agent',
    create: (_) => CodexKernel(codex, MockCodexTransport()),
  );

  /// DSH over [transport], its process: what it plays is what dsh answers,
  /// and what the kernel wrote is kept there, for a test to read.
  ///
  /// [sessions] is where its conversations are kept, and offered as a
  /// catalog when given: a test restarting a conversation gives a store
  /// that outlives the kernel. Otherwise they are kept for this run only,
  /// and listed nowhere.
  static KernelDescriptor dshOn(
    MockDshTransport transport, {
    DshSessionStore? sessions,
  }) {
    final store = sessions ?? MemoryDshSessionStore();
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'dsh',
      label: 'DSH',
      icon: Icons.auto_awesome_rounded,
      description: 'DeepSeek Harness',
      // Its own skills, as the app's dsh keeps them.
      customizations: CustomizationAgent.dsh,
      create: (context) => DshKernel(
        descriptor,
        context,
        start: (_) async => transport,
        locate: _locateDsh,
        sessions: store,
        // No login shell is asked: a mock process is not one to run
        // anything, and the shell's would be a test's own.
        environment: () async => const {'PATH': '/usr/bin'},
        // Nor is the machine's own credential store read: a mock declares no
        // route of its own, so the preflight is never asked, and nothing of
        // the user's is looked at.
        credentials: (_) async => true,
        // No loopback either: a widget test's fake async owns no socket, and
        // there is no one behind a mock's panel to answer.
        questionServer: (_) async =>
            throw UnsupportedError('mock kernels ask nothing'),
      ),
      catalog: sessions == null ? null : DshCatalog(sessions: store),
    );
    return descriptor;
  }

  /// DSH over a mock process of its own: not in [all], which stands for the
  /// kernels the app offers, DSH being off where a test's workspace is not
  /// one it can work in.
  static final KernelDescriptor dsh = dshOn(MockDshTransport());

  /// The dsh this machine has, the one the adapter was probed against: no
  /// test looks for one.
  static Future<DshInstall?> _locateDsh() async => const DshInstall(
    node: 'node',
    binJs: '/opt/dsh/lib/bin.js',
    version: '0.2.0-rc.2',
    packageDir: '/opt/dsh',
  );

  static final List<KernelDescriptor> all = [claudeCode, codex];
}

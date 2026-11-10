import 'package:flutter/material.dart';

import 'agent_kernel.dart';
import 'claude_code/claude_code_kernel.dart';
import 'dsh/dsh_kernel.dart';
import 'dsh/dsh_locate.dart';
import 'dsh/dsh_path_setting.dart';
import 'dsh/dsh_sessions.dart';
import 'dsh/dsh_transport.dart';
import '../remote/remote_claude.dart';
import '../remote/remote_location.dart';

/// The kernels the user can pick from. Another kernel is an adapter and a
/// line here.
abstract final class KernelRegistry {
  static final KernelDescriptor claudeCode = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: 'Anthropic’s coding agent',
    create: (context) => ClaudeCodeKernel(
      claudeCode,
      context,
      // On the project's host: this machine, or a remote one's.
      start: startClaude,
      readHistoryPage: readClaudeHistoryPage,
      readGoal: readClaudeGoal,
      forkSession: forkClaudeSession,
      usageOffBy: () => claudeUsageOffByAt(context.cwd),
      rejectTooOld: rejectTooOldClaude,
    ),
    catalog: const ClaudeCatalog(),
  );

  /// DeepSeek Harness, on this machine only: its process works in one
  /// project folder, and needs a dsh installed here (see `dsh_locate.dart`).
  static final KernelDescriptor dsh = KernelDescriptor(
    id: 'dsh',
    label: 'DSH',
    icon: Icons.auto_awesome_rounded,
    description: 'DeepSeek Harness',
    create: (context) => DshKernel(
      dsh,
      context,
      start: startDsh,
      // The user's own dsh, where Settings names one.
      locate: () => locateDsh(setting: DshPathSetting.current()),
    ),
    // A multi-folder workspace is not one project folder, and another
    // machine's project has no dsh of this one to run in it.
    available: (context) =>
        context.workspace?.call() == null &&
        switch (context.cwd) {
          final cwd? => !RemoteLocation.isRemote(cwd),
          // No project said: nothing says another machine.
          null => true,
        },
    // What BaoCode started with dsh: dsh names no titles and replays no
    // history, so those are kept here (see [DshCatalog]).
    catalog: const DshCatalog(),
  );

  static List<KernelDescriptor> _all = [claudeCode, dsh];

  static List<KernelDescriptor> get all => _all;

  /// What the app itself offers, in the order its pickers show them: for a
  /// test to check while [all] stands in for it with mocks.
  static List<KernelDescriptor> get builtIn => [claudeCode, dsh];

  /// Replaces the kernels on offer, e.g. with mock ones under test.
  static void use(List<KernelDescriptor> kernels) => _all = kernels;
}

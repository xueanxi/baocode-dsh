import 'package:flutter/material.dart';

import '../../customize/customization_store.dart';
import '../../customize/customizations.dart';
import '../../customize/customize_view.dart';
import '../../workspace/workspace.dart';

/// An agent's customizations, as a settings page: skills, subagents,
/// commands and rules edited in place, the other files (MCP servers, hooks,
/// plugins) shown and edited whole. The same view as Customize beside the
/// chat (⌘⇧K, or the sidebar's), reached here from the settings' search too.
///
/// Claude Code's, or dsh's skills where the agent in view is dsh's.
class CustomizeSettingsPage extends StatelessWidget {
  const CustomizeSettingsPage({
    super.key,
    required this.customizations,
    this.workspace,
  });

  /// The customizations; none where there are no files (the web).
  final CustomizationStore? customizations;

  /// The projects whose customizations show beside the user's, and the
  /// agent whose they are: the one in view's, else the next one's.
  final Workspace? workspace;

  @override
  Widget build(BuildContext context) {
    final kernel = workspace?.current?.kernel ?? workspace?.preferredKernel;
    final store = (customizations ?? CustomizationStore()).forAgent(
      kernel?.customizations ?? CustomizationAgent.claudeCode,
    );
    final projects = workspace?.projects ?? const <Project>[];
    return CustomizeView(
      store: store,
      projects: projects,
      project: projects.firstOrNull,
      showTitleBar: false,
      kind: CustomizationKind.skills,
      onClose: () {},
    );
  }
}

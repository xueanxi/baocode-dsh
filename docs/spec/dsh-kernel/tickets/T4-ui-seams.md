# T4 — 界面闭环：可用性谓词、图片谓词、mock 描述符与标题门禁

> 依赖：T2（需要 `DshKernel` 与 `KernelRegistry.dsh` 存在）
> 规格：`docs/spec/dsh-kernel.md` §5.1（接口增量）、§5.2、§5.10

## 目标

让「并存」真正成立：DSH 只在能工作的项目里出现（单目录、本机）；图片入口随内核真实能力开关；手动「总结标题」不再把 DSH 对话发给 Claude Haiku；给 UI 测试一个不启动进程的 DSH 描述符。**不改内核的协议逻辑。**

## 独占路径

- `lib/kernel/agent_kernel.dart`（只加两个成员：`AcceptsImages.supportsImages`、`KernelDescriptor.available`）
- `lib/chat/chat_session.dart`（`acceptsImages` 读谓词；`kernelChoice` 过滤不可用项；保存的内核不可用时回落第一项）
- `lib/kernel/claude_code/claude_code_kernel.dart`（只加 `bool get supportsImages => true`）
- `lib/kernel/codex/codex_kernel.dart`（只加 `bool get supportsImages => true`）
- `lib/kernel/mock/mock_kernels.dart`（新增 `dsh` 描述符；**`all` 保持 `[claudeCode, codex]` 不变**）
- `lib/workspace/workspace.dart`（只加手动起标题的 `canRename` 门禁）
- `test/kernel_ui_test.dart`（追加用例）
- `test/kernel/dsh_capabilities_test.dart`（新增，纯单元测试）

明确不改：`lib/kernel/dsh/**`（只有 T2/T3 改）、`lib/main.dart`、`lib/settings/**`、`lib/l10n/**`、`lib/workspace/workbench.dart`（除非门禁必须在那边，届时回传说明）。

## 实现要求

### 两个接口增量（保持向后兼容）

```dart
abstract interface class AcceptsImages {
  /// Whether a picture sent now would actually reach the model: kernels that
  /// can only take them on some routes say so here.
  bool get supportsImages;
}

class KernelDescriptor {
  /// Whether this kernel can work in [context] at all, e.g. a dsh kernel
  /// needs one folder and the machine it runs on: not offered otherwise.
  final bool Function(KernelContext context)? available;
}
```

- `ChatSession.acceptsImages` 从 `_kernel is AcceptsImages` 改成 `_kernel is AcceptsImages k && k.supportsImages`（现调用点在 `chat_session.dart` 内；composer 只读这个 getter）。
- `KernelDescriptor.available` 为 null 视为可用。`KernelRegistry.dsh` 的谓词：
  `context.workspace?.call() == null && !ProjectHost.isRemote(context.cwd)`（用 `lib/remote/project_host.dart` 里现有的判断；若没有现成 API，就在 `kernel_registry.dart` 内用现有全局 host 状态判断，并在回传里说明用了什么）。
- `ChatSession.kernelChoice`：先按 `available` 过滤；过滤后不足 2 个就返回 null（保持现有的“少于两个不显示”）；挂起的 `kernel` 若不可用（例如恢复出来的线程），`_connect` 用过滤后的第一项。
- 现有测试的内核列表是 `MockKernels.all`（claude+codex），两者 `available` 都是 null，行为不变。

### 标题

- 自动起标题：DSH 不声明 `RenamesSession`，已天然不触发，不需要改。
- 手动「总结标题」（`workspace.dart` 里 `summarizeTitle` 一类入口）：加 `if (!session.canRename) return;`，与自动路径一致。回传里指出确切方法名与行为。

### mock 描述符

- `MockKernels.dsh`：`id: 'dsh'`、`label: 'DSH'`、`description: 'DeepSeek Harness'`，`create: (context) => DshKernel(dsh, context, start: ..., locate: ...)`，用 T2 的 `MockDshTransport` 与本票的 `MockKernels.dsh` 自身作为描述符，测试里可脚本化。
- **不要**把它加进 `MockKernels.all`：`workspace.dart:698` 用 `kernels.lastOrNull` 当 codex，追加会污染现有 demo/UI 测试。新测试显式传 `[MockKernels.claudeCode, MockKernels.dsh]`。

### 测试要覆盖

- 谓词：多文件夹（`workspace` 非空）与远端（模拟 host）下 `available` 为 false；单目录本机为 true。
- `kernelChoice`：两个可用内核时出现；其中一个不可用时只剩一个 → 返回 null；保存的内核不可用时回落到第一个可用项。
- `acceptsImages`：`supportsImages=false` 时 `ChatSession.acceptsImages` 为 false（composer 的图片按钮据此隐藏；这条用 widget 测试验）。
- 手动起标题：`canRename=false` 时不调用 titler。
- 追加到 `test/kernel_ui_test.dart` 的用例：DSH 与 Claude 同时在选择器里、默认是 Claude、首条消息后锁定；权限档位在首条消息后只剩一项。

## 判据

1. `flutter analyze --fatal-infos` → No issues found
2. `dart format` 改动文件 → 0
3. `flutter test test/kernel_ui_test.dart test/kernel/dsh_capabilities_test.dart` → 全绿
4. 现有 `test/kernel_ui_test.dart` 原有用例**不改动**且仍绿

## 交付回传

分支、HEAD、diff stat、三条命令末行与退出码、用例名、`available` 谓词实际用了哪个远程判断 API、路径外改动、遗留。

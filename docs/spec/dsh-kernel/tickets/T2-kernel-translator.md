# T2 — 内核核心与翻译层

> 依赖：T1
> 规格：`docs/spec/dsh-kernel.md` §5.1、§5.2、§5.5、§5.6、§5.8、§5.9，事实 F1–F27

## 目标

把 T1 的定位/传输/补丁装成一个真正的内核：`prepare` 起进程并握手，第一条消息时建会话，一轮完整地走「TurnStarted → 用户消息 → agent 条目 → TurnEnded」，模型/上下文/图片/健康态都对。**本票不含审批交互（T3）与界面谓词（T4）**，但要把它们要用的字段与方法留出来。

## 独占路径

- `lib/kernel/dsh/dsh_kernel.dart`
- `lib/kernel/dsh/dsh_translator.dart`
- `lib/kernel/dsh/mock_dsh_transport.dart`
- `lib/kernel/kernel_registry.dart`
- `test/kernel/dsh_kernel_test.dart`
- `test/kernel/dsh_turn_test.dart`

明确不改：T1 的四个文件、`lib/kernel/agent_kernel.dart`、`lib/chat/**`、`lib/main.dart`、`lib/l10n/**`、审批相关（T3 的地盘）。

## 实现要求

### 构造与注入

```dart
typedef DshStarter = Future<DshTransport> Function(DshLaunch launch);
typedef DshLocator = Future<DshInstall?> Function();

class DshKernel with KernelEventSource
    implements AgentKernel, SelectsModel, SelectsEffort, SelectsPermission,
               ReportsContext, AcceptsImages {
  DshKernel(this.descriptor, this._context, {required DshStarter start, required DshLocator locate});
}
```

测试全部用 `MockDshTransport`（同目录），绝不启动真实进程。

### 生命周期

- `prepare()`：`idle → starting` → 定位（失败 `failed` + 安装指引）→ 补丁 → 起进程 → `initialize`（记 image 能力）→ `ready`。**不建会话**。
- 第一次 `send(turn)`：有 `sessionId` 先 `session/resume {sessionId, cwd}`，否则 `session/new {cwd, mcpServers: []}`；sessionId 立即上报（`String? get sessionId`）。
- `release()`：空闲关进程并等 `exited`（最多 5 秒）；忙碌时本轮结束后再关。
- 再次 `prepare()` 若要 resume：先 `await` 旧进程 `exited`；`-32603 already owned` / `-32602 already active` 重试一次，其余判致命。
- `dispose()`/`stopped`：关 stdin，等 6 秒，仍在则交给 T1 的 `close()`（进程树收尾）；`stopped` 在进程退出后完成。
- `restart()`：仅 failed 后重试。

### 一轮（翻译层负责，内核只调它）

固定顺序，缺一不可：

```
TurnStarted(turnId)
ItemUpserted(turnId, UserMessageItem(text, images))   // id == turnId
… AssistantTextItem / ThinkingItem / ToolCallItem / NoticeItem …
TurnEnded(turnId, interrupted:, worked:, usage:)
```

- 文本：`ItemUpserted('message:<n>', AssistantTextItem(text), streaming: false)`；不发 `TextDelta`、不发 `ItemCompleted`；`n` 自增，跨轮不重置。
- 思考：`ItemUpserted('thought:<n>', ThinkingItem(text))`。
- 工具：`tool_call` → `ToolCallItem(kind: ToolKind.command, target: title, label: title, detail: <rawInput 单行>, status: running)`；`tool_call_update` → 同 id、`status: succeeded/failed`、`output` 拼文本块。`ToolKind` 没有 other，不要加。
- `usage_update` → `UsageReported(ContextUsage(window: size, used: used))`，记住 size 作 `contextWindow`（初值取补丁里的 512000）。
- prompt 结果 `{stopReason}` → `TurnEnded`；`cancelled` → `interrupted: true`。
- `-32603`：先 error `NoticeItem`（文本取 `data.details` 去掉 `turn failed: ` 前缀，拿不到就用 message），再 `TurnEnded(interrupted: true)`；健康态保持 `ready`。
- 事件 `seq` 全程单调；重启进程后延续。
- 健康态/选项/选中/contextWindow 变化都要 `emitInfoChanged()`。

### 选项

- 模型：`configOptions` 中 `id == 'model'`，按 `group` 做 `KernelOptionGroup`；`value` 原样保存；选择写 `session/set_config_option {configId:'model', value}`；不重启。
- **`session/new` 与 `session/resume` 返回的 `configOptions` 都要应用**（不只 `config_option_update`），否则 resume 回来的选择器是空的。
- `KernelContext.settings` 里的 model/effort/permission 若不是本内核的选项 id，一律忽略并用默认：跨内核的「上次选择」是全局按 kind 存的，不丢会导致串味。
- 思考强度：`id == 'reasoning_effort'` 时提供，否则 `optionsFor(model)` 返回空。
- 权限：内核自己的 `_Choice implements KernelChoiceSource`（不要用 `LocalChoice`）。三档，默认 `KernelContext.settings['permission'] ?? 'workspace-write'`；首条消息发出后 `options` 只保留当前项、`select` 无效；`danger-full-access` 的 `caution: true`。档位经 `DshLaunch.permissionMode` 传给 T1 的传输层；自己校验取值。
- `AcceptsImages`：本次实现 `supportsImages => _imageCapable`（取自 `initialize.promptCapabilities.image`，握手前 false）。注意 T4 会把这个 getter 加进接口——本票在本地先实现同名 getter，合并时以接口为准。

### 健康与失败

- `failed` 只有两种：定位失败（message 含 `npm i -g @deepseek-ai/dsh`，detail 带设置项位置）、起进程/握手失败（detail 带 stderr 尾部）。
- 凭据/模型问题走轮次错误（`turn failed` → error Notice），健康态不变。
- 进程以 0 退出且原为 ready → `idle`。
- `package.json` 版本低于验证版本（0.2.0-rc.2）→ 一条 warning `NoticeItem`，健康态不变。

### 注册表

```dart
static final KernelDescriptor dsh = KernelDescriptor(
  id: 'dsh', label: 'DSH', icon: Icons.auto_awesome_rounded,
  description: 'DeepSeek Harness',
  create: (context) => DshKernel(dsh, context, start: startDsh, locate: locateDsh),
);
static List<KernelDescriptor> _all = [claudeCode, dsh];
```

同时暴露 `static List<KernelDescriptor> get builtIn => [claudeCode, dsh];`（T4 用它断言顺序；测试引导会把 `all` 换掉）。

## 判据

1. `flutter analyze --fatal-infos` → No issues found
2. `dart format` 改动文件 → 0
3. `flutter test test/kernel/dsh_kernel_test.dart test/kernel/dsh_turn_test.dart` → 全绿

覆盖：握手（含 image true/false 与版本提醒）、`session/new` 的 `[]` 与 cwd、模型分组与 opaque 值、无 effort、contextWindow 初值 512000 与 usage 覆盖、prepare 不建会话、首条消息才建、release/resume 顺序、TurnStarted→用户条目(id==turnId)→TurnEnded、整条文本、思考、工具成功/失败、-32603 也发 TurnEnded 且健康不变、cancel、权限选项首条消息后收敛、`KernelRegistry.dsh.id == 'dsh'`。

## 交付回传

分支、HEAD、diff stat、三条命令末行与退出码、用例名、路径外改动、遗留。

# T3 — 审批往返与会话内提示

> 依赖：T2
> 规格：`docs/spec/dsh-kernel.md` §5.6 的审批细则、§5.9、§5.10（提示不新增 UI）

## 目标

让 dsh 的沙箱升级审批在 BaoCode 里变成一次真实的问答：弹窗带工具名与理由，允许/拒绝映射成正确的线形；本地取消时把未决审批回掉。同时把版本提醒、缺凭据提醒、图片被丢弃的提醒这三条会话内提示做出来。**不新增 UI 控件，不改 l10n。**

## 独占路径

- `lib/kernel/dsh/dsh_approval.dart`
- `lib/kernel/dsh/dsh_notices.dart`
- `lib/kernel/dsh/dsh_kernel.dart`（只加审批与提示的接线；不改 T2 的其它逻辑）
- `test/kernel/dsh_approval_test.dart`

明确不改：T1 的四个文件、`lib/kernel/agent_kernel.dart`、`lib/chat/**`、`lib/l10n/**`、`lib/main.dart`、`lib/settings/**`。

## 实现要求

### 审批

- `session/request_permission`（服务端请求，带 id）→ `InteractionRequested(ApprovalRequest(...))`：
  - `id`：用 `toolCall.toolCallId` 之外再加一个请求序号（同一工具可能被问两次也无所谓，用 fresh id）。
  - `title`：该 `toolCallId` 对应的 `tool_call.title`（工具名）。**`toolName` 字段不会被渲染，必须放 title。**
  - `reason`：该 `tool_call.rawInput.justification`；拿不到就写 `dsh did not give a reason`。
  - `alwaysAllowLabel`：**必须为 null**（否则 UI 会多一个「总是允许」，而 dsh 只有 allow-once）。
- 应答 `answer(requestId, InteractionAnswer)`：
  - 允许 → `{jsonrpc:'2.0', id:<请求 id>, result:{outcome:{outcome:'selected', optionId:'allow-once'}}}`，并发 `InteractionResolved`
  - 拒绝 → 同上但 `optionId:'reject-once'`；用户在拒绝框里写的文字**丢弃**（dsh 不要）
  - 取消本轮 / 内核 dispose 时对未决审批回 `{outcome:{outcome:'cancelled'}}`，并 `InteractionResolved`
  - 迟到的应答（请求已解决）忽略，不抛错
- 关联失败（审批先于同 id 的 tool_call 到达）时：title 用 `Approval needed`，reason 用 `dsh did not give a reason`，不要崩。

### 三条提示（全部英文，与 Claude 的内核提示一致）

- 版本低于 `0.2.0-rc.2`：`dsh <version> is older than the version BaoCode was tested with (0.2.0-rc.2); some behaviour may differ.`（`NoticeKind.warning`）
- 凭据预检失败：`dsh has no credential for <ref>; add it in dsh web (Models) or set the environment variable.`（`NoticeKind.error`，且不阻止起进程）
- 图片被丢弃（`supportsImages == false` 且本条消息带图）：`This dsh route cannot take images; they were left out.`（`NoticeKind.warning`）

提示都是 `ItemUpserted('<notice>:<n>', NoticeItem(kind, text))`，同一轮内不重复发同一条。

## 判据

1. `flutter analyze --fatal-infos` → No issues found
2. `dart format` 改动文件 → 0
3. `flutter test test/kernel/dsh_approval_test.dart` → 全绿

覆盖：请求挂起为一个待批准；allow-once / reject-once 的线形逐字；reason 取自 justification；没有对应 tool_call 时的回退文案；本地取消回 cancelled 且 `InteractionResolved`；迟到应答被忽略；三条提示各出现一次、不重复；版本正常时不发提示。

## 交付回传

分支、HEAD、diff stat、三条命令末行与退出码、用例名、路径外改动（尤其 `dsh_kernel.dart` 改了哪几处）、遗留。

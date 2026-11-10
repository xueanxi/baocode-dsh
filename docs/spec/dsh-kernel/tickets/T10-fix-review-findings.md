# T10 — 修复票：双轴代码评审的发现

> 依赖：T1–T9 已并入集成分支（HEAD `585cba51`）
> 来源：`/code-review` 的 Spec 轴与 Standards 轴

## 必须修（行为与文档不一致 / 真 bug）

1. **`~` 不展开**：规格 §5.3 与 `docs/dsh-kernel.md` 都说设置值里的 `~` 会展开，`DshLocate.splitSetting` 原样返回，`_install` 直接 `File(...)`。用登录 shell 环境的 HOME 展开（只展开开头的 `~` 或 `~/`），补用例。
2. **stderr 未脱敏**：规格 §5.11 要求 `Bearer` / `Authorization` / 长 token 形状进 UI 与日志前脱敏；`_stderrLine` 原样保留，`_fail(detail: _stderrTail())` 直接进 `KernelHealth.detail`。在 `_stderrLine` 落库前脱敏（保留行数与可读性），补用例：喂一行 `Authorization: Bearer abc…`，退出信息里是 `Bearer ***`。
3. **图片提示落在轮次之外 + 能力可能过期**：`send` 在 `_translator.begin` 之前调 `_acceptableImages` 并可能发 `notice:images:<turnId>`，于是提示排在 `TurnStarted` 前面（违反 §5.5 的固定顺序）。另外 `_imageCapable` 握手前是 false，用户抢在 ~6 秒握手完成前发图会被无声丢弃，而文档说「能力为 true 时图片随消息」。要求：
   - 提示必须在 `TurnStarted` 之后发（同一轮内）；
   - 带图且握手未完成时，等握手再决定（`_startTurn` 里 `_ensureStarted` 之后再判），必要时把 `begin` 推到那时——只有「带图且尚未 ready」这一条罕见路径会晚一点出现 TurnStarted，可接受；
   - `_imageCapable` 在 `_teardown` 里复位，避免 release 后 resume 到另一条路由还沿用旧能力。
4. **512000 两处硬编码**：`dsh_patch.dart` 与 `dsh_translator.dart` 各写一遍。收成一处（`DshPatch.contextWindow`），翻译层引用它。
5. **两套凭据注入并存**：`DshCredentials.use`（静态）与 `DshKernel(credentials:)`（实例）。删掉静态 seam，`dsh_approval_test` 改用实例注入。
6. **smoke 脚本的过时断言**：`tool/dsh_smoke.mjs` 注释说「适配器不传 bashPath」，但 T8 已经传了；`docs/dsh-kernel.md` 说它「按与内核相同的补丁内容」也是假的（它是第三份手抄）。把注释与文档改成「镜像 `DshPatch.content`，dsh 升级或补丁改了两边要一起改」，并在脚本里把补丁内容集中到一处常量。

## 顺带修（低风险）

7. `ChatSession._standing` 改名 `_availableKernel`（名字要说明它做什么）。
8. `docs/dsh-kernel.md` 的模块表补上 `dsh_bash.dart`、`dsh_bash_test.dart`、`test/kernel_ui_test.dart`、`test/settings/dsh_page_test.dart`。
9. 文档补一句现存行为：线程保存的内核在当前项目不可用时（如把 DSH 对话挪到多文件夹项目），会话会以第一个可用内核打开；这一点规格 §5.10 也要写。

## 不改（评审提到但属于规模/流程，交付报告里说明）

- 400 行上限、merge commit、`merge(tN):` 标题、没有 issue 链接：这些都是「推送成 PR」的门禁，本任务是本地分支 + 票图合并，用户明确不 push、不开远程单。
- `_Choice`/`_ModelSetting` 与 Claude 内核的同名类重复：抽公共类要动 `claude_code_kernel.dart` 的大块代码，收益不抵风险，记为已知代价。
- 权限档位是裸字符串、`(Fnn)` 引用风格、测试目录分散：记为已知，不改。

## 独占路径

`lib/kernel/dsh/dsh_locate.dart`、`dsh_locate_io.dart`、`dsh_transport_io.dart`、`dsh_kernel.dart`、`dsh_notices.dart`、`dsh_patch.dart`、`dsh_approval.dart`、`lib/chat/chat_session.dart`（只改 `_standing` 的名字）、`tool/dsh_smoke.mjs`、`docs/dsh-kernel.md`、`docs/spec/dsh-kernel.md`、`test/kernel/dsh*`、`test/kernel_ui_test.dart`。

## 判据

1. `flutter analyze --fatal-infos` → No issues found
2. `dart format` 改动文件 → 0
3. `flutter test test/kernel/dsh test/kernel/dsh_kernel_test.dart test/kernel/dsh_turn_test.dart test/kernel/dsh_approval_test.dart test/kernel/dsh_notices_test.dart test/kernel/dsh_bash_test.dart test/kernel/dsh_capabilities_test.dart test/kernel/dsh_integration_test.dart test/kernel_ui_test.dart test/l10n_test.dart test/settings/dsh_page_test.dart` → 全绿（现基线 +170 ~4）
4. `HOME=/tmp/empty-home-t10 flutter test test/kernel/dsh_turn_test.dart test/kernel_ui_test.dart` → 全绿
5. `node tool/dsh_smoke.mjs --help` → 用法、exit 0

## 交付回传

分支、HEAD、diff stat、五条命令末行与退出码、每条发现的落点、有没有弱化断言、遗留。

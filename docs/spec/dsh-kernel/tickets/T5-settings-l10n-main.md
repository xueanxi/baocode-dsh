# T5 — 设置、文案、main 接线与退出清理

> 依赖：T1（`DshPathSetting`、`stopAll`/`reap` 的传输层函数）
> 规格：`docs/spec/dsh-kernel.md` §5.3、§5.7、§5.12，§9 的已知代价

## 目标

让用户看得见、能覆盖 dsh 的位置，把权限三档与设置项说成人话，并在应用启动/退出时把 DSH 子进程纳入与 Claude 同一套清理。

## 独占路径

- `lib/settings/pages/general_page.dart`
- `lib/settings/app_settings.dart`
- `lib/main.dart`
- `lib/l10n/app_en.arb`、`lib/l10n/app_zh.arb`
- `lib/l10n/app_localizations.dart`、`app_localizations_en.dart`、`app_localizations_zh.dart`（`flutter gen-l10n` 生成）
- `lib/chat/composer/kernel_option_text.dart`
- `test/l10n_test.dart`
- `test/settings/dsh_page_test.dart`（新增；若现有 `settings_wiring_test.dart` 更适合，改成追加并在回传说明）

明确不改：`lib/kernel/**`、`lib/chat/chat_session.dart`、`lib/workspace/**`、`lib/customize/**`。

## 实现要求

### 设置页

- 新分组 `DSH`，放在 Claude Code 分组之后，一条「可执行文件」路径行：
  - 键 `dshCode.path`；空 = 自动发现
  - 说明包含三句：自动发现 PATH 上的 dsh；覆盖时填 `bin.js` 或 `node|bin.js`；**历史会话在 dsh web 里查看**（本内核不列会话），且 DSH 只在单目录的本地项目里出现
  - 写入走既有设置存储；改完不必重启应用，下次起进程生效
- 不加「启用 DSH」开关；不加状态探测（起进程才知道）。

### main 接线

- `DshPathSetting.current = () => DshPathSetting.parse(files.settings[DshPathSetting.settingKey]);`（照 Claude 的写法，`main.dart` 里现有位置旁）。
- 启动回收：与 `reapClaudeProcesses()` 并列加 `reapDshProcesses()`。
- 退出收尾：放进现有的退出 `Future.wait`（`main.dart` 里 `stopClaudeProcesses()` 那一组），加 `stopDshProcesses()`。等待时长由传输层自己保证（关 stdin + 6 秒 + 兜底 taskkill），这里只 await。

### 本地化

新增键（英文 + 中文）：
- DSH 分组标题
- 路径行标签、说明（含上面三句）、占位提示
- 权限三档标签与说明：
  - `read-only` → 只读 / 只能读取与查看；shell 命令在 Windows 上会被限制为受限语言模式
  - `workspace-write` → 只改工作区 / 可改项目文件与执行命令；越出工作区时询问
  - `danger-full-access` → 无限制 / 不受工作区限制，也不再询问；走审批通道的请求会被拒绝
- 首条消息后锁定的提示（设置项说明里一句即可，不做行内提示）

跑 `flutter pub get`（会触发 `gen-l10n`），把三个生成文件一起提交。**不要**给内核发出的会话内提示加键（它们是英文，见 T3）。

### 权限选项文案

`localizedKernelOption` 增加 `('dsh', KernelChoiceKind.permission, 'read-only'|'workspace-write'|'danger-full-access')` 三条，指向上面的键；其它保持原文。

### 测试

- `test/l10n_test.dart`：照 Claude 的那段，为 dsh 三档加一组断言（中文标签变了、id/icon/caution 不变）。
- `test/settings/dsh_page_test.dart`：临时数据目录 + `SettingsFiles`，写入 `dshCode.path` 后能被 `DshPathSetting.parse` 读回；清空回到自动发现；应用以 `main()` 的方式装配时该行存在（照 `settings_wiring_test.dart` 的写法）。

## 判据

1. `flutter pub get` → 成功且生成物有变更
2. `flutter analyze --fatal-infos` → No issues found
3. `dart format` 改动文件（含生成物）→ 0
4. `flutter test test/l10n_test.dart test/settings/dsh_page_test.dart` → 全绿

## 交付回传

分支、HEAD、diff stat（生成物单列）、四条命令末行与退出码、main.dart 加的两处行号、路径外改动、遗留。

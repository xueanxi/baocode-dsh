# T9 — 修复票：合并后的三处红与一个真机 bash 隐患

> 依赖：T1–T8 已并入集成分支（HEAD `028a2fa2`）
> 来源：集成分支上跑全套 DSH 用例时发现的三处红，以及 T8 回传的遗留。

## 问题

1. `test/kernel/dsh_turn_test.dart` 的「a turn: started, …」红了：`events.first` 是 `ItemUpserted` 而不是 `TurnStarted`。原因：T7 把凭据预检做成可能发提示，而这个 rig 没有注入 credentials，预检读不到 `HOME` 下的 `~/.dsh`，于是先发一条 `notice:credential:*`。
2. `test/kernel_ui_test.dart` 的两条图片用例红了：`pumpPictured` 等不到 `ready`，健康态停在 `starting`。原因：`MockKernels.dshOn(transport)` 没有注入 credentials，内核走默认预检（内部要读登录 shell 环境），在 widget 测试的假时钟下挂住。
3. `findGitBash` 直接取 PATH 上第一个存在的 `bash.exe`，可能命中 WSL 的 `C:\Windows\System32\bash.exe`——那东西在 Windows 上跑 Linux 语义的路径，dsh 的 shell 工具会全错。
4. 小腐化：`dsh_patch.dart` 注释里的 F17/F19/F21 与规格事实表编号对不上。

## 独占路径

- `lib/kernel/mock/mock_kernels.dart`（`dshOn` 注入 credentials，必要时给固定环境）
- `lib/kernel/dsh/dsh_bash.dart`（过滤 WSL bash）
- `lib/kernel/dsh/dsh_patch.dart`（只改注释编号）
- `test/kernel/dsh_turn_test.dart`（rig 注入 credentials）
- `test/kernel_ui_test.dart`（只改 `pumpPictured` 的构造，不改断言语义）
- `test/kernel/dsh_bash_test.dart`（加 WSL 过滤用例）

## 要求

1. 让测试完全封闭：`MockKernels.dshOn` 与 `dsh_turn_test` 的 rig 都注入
   `credentials: () async => {DshPatch.credentialRef}`，且不读真机 `~/.dsh`、不等登录 shell 环境。
   **不要**通过放宽断言或改事件顺序来变绿。
2. `findGitBash`：命中 `System32/bash.exe`（以及 `WindowsApps/bash.exe`）时跳过，继续找下一个候选；其它逻辑不变。
3. `dsh_patch.dart` 注释编号按规格事实表校正（版本→F3、凭据→F24、补丁语义→F21）。
4. 跑整套 DSH 相关用例全绿（见判据）。

## 判据

1. `flutter analyze --fatal-infos` → No issues found
2. `dart format` 改动文件 → 0
3. `flutter test test/kernel/dsh test/kernel/dsh_kernel_test.dart test/kernel/dsh_turn_test.dart test/kernel/dsh_approval_test.dart test/kernel/dsh_notices_test.dart test/kernel/dsh_bash_test.dart test/kernel/dsh_capabilities_test.dart test/kernel/dsh_integration_test.dart test/kernel_ui_test.dart test/l10n_test.dart test/settings/dsh_page_test.dart` → 全绿（之前是 +163 −3）
4. `HOME=/tmp/empty-home-t9 flutter test test/kernel/dsh_turn_test.dart test/kernel_ui_test.dart` → 全绿（证明不依赖真机凭据）

## 交付回传

分支、HEAD、diff stat、四条命令末行与退出码、用例名、有没有为了变绿而弱化断言（必须没有）、遗留。

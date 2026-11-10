# T8 — 修复票：让「装插件即得 bash」真的成立

> 依赖：T7（已并入集成分支）
> 来源：T2 回留 ① 与 T6 发现 —— `DshKernel` 调 `DshPatch.ensure` 时从不传 `bashPath`，导致补丁里那两行永远不出现；规格 §5.4 与文档都承诺「装了插件就自动带上」。

## 问题

规格 §5.4：插件存在时补丁追加 `bash-sandbox` 与 `tool-bash: disabled: false` 两行。实现里 `DshPatch.ensure(bashPath: …)` 的调用点从不传值，`_gitBash(null, …)` 直接返回 null，于是**即使按文档装了插件，acp profile 里 `tool-bash` 仍是禁用**，bash 永远不会出现。承诺与行为不一致。

## 独占路径

- `lib/kernel/dsh/dsh_bash.dart`（新增：发现本机 Git 的 bash.exe）
- `lib/kernel/dsh/dsh_kernel.dart`（只改 `_launch` 里 `DshPatch.ensure` 的调用，传 `bashPath`）
- `test/kernel/dsh_bash_test.dart`（新增）
- `test/kernel/dsh_kernel_test.dart`（追加：插件存在 + 找到 bash → 补丁含两行；插件存在 + 没找到 → 不含）
- `docs/spec/dsh-kernel.md`（只改两处：§5.4 补「bash 由内核在起进程前发现」，并把补丁文件名写成实现的 `acp.patch.yml`）

## 要求

1. `dsh_bash.dart`：
   ```dart
   /// The Git for Windows bash to run dsh's shell commands with, where one is
   /// installed; null when none is.
   Future<String?> findGitBash({Map<String, String>? environment, bool Function(String path)? exists});
   ```
   - 顺序：`BAOCODE_GIT_BASH`（绝对路径，存在即用）→ 登录 shell 环境里 `bash` 的解析结果（PATH 上第一个存在的）→ `git --exec-path` 推出 `<git>/bin/bash.exe`（往上一级到 Git 根，再拼 `bin/bash.exe`）→ 常见安装位置 `C:/Program Files/Git/bin/bash.exe`、`C:/Program Files (x86)/Git/bin/bash.exe`。
   - 非 Windows 返回 null（POSIX 不需要这个插件）。
   - `exists` 参数默认 `File(path).existsSync`，测试传假实现；不读真机。
2. `dsh_kernel.dart`：`_launch` 里改为 `bashPath: await findGitBash(environment: <登录 shell 环境>)`；`DshPatch.ensure` 已经按「插件目录存在才用」判断，保持不动。
3. 测试（全用假 exists，不碰真机）：
   - `BAOCODE_GIT_BASH` 命中；
   - PATH 上的 bash 命中（用假 exists 只让某一个路径存在）；
   - `git --exec-path` 推导命中（这一条允许注入一个假的 exec-path 字符串，不要真跑 git）；
   - 都没有 → null；
   - 非 Windows → null；
   - 内核：插件目录存在 + `findGitBash` 给出路径 → 补丁文本含 `bash-sandbox` 与 `tool-bash`；插件不存在或没找到 bash → 不含。
4. 规格两处措辞按实现修。

## 判据

1. `flutter analyze --fatal-infos` → No issues found
2. `dart format` 改动文件 → 0
3. `flutter test test/kernel/dsh_bash_test.dart test/kernel/dsh_kernel_test.dart test/kernel/dsh` → 全绿
4. 手工：`flutter test test/kernel/dsh_kernel_test.dart` 在空 `HOME` 下也绿（沿用 T7 的隔离口径）

## 交付回传

分支、HEAD、diff stat、四条命令末行与退出码、用例名、遗留。

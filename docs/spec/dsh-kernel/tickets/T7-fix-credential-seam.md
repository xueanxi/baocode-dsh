# T7 — 修复票：凭据预检不能读真机文件

> 依赖：T3（已并入集成分支）
> 来源：T3 回传的遗留 ② —— T2 的「正常版本不发提示」用例现在依赖本机真实 `~/.dsh/.credentials.yaml`；在没装 dsh 或没配 key 的机器（CI）上会因为合法的「缺凭据」提示而变红。

## 问题

`dsh_notices.dart` 的凭据预检直接读 `~/.dsh/.credentials.yaml`。内核在没有注入点的情况下被测试构造，于是**单测依赖真机状态**：本机绿、CI 红。这违反仓库的「测试不碰用户数据」惯例。

## 独占路径

- `lib/kernel/dsh/dsh_notices.dart`
- `lib/kernel/dsh/dsh_patch.dart`（只把 `STEPCODEV2_API_KEY` 抽成一处常量）
- `lib/kernel/dsh/dsh_kernel.dart`（只加构造参数透传）
- `test/kernel/dsh_notices_test.dart`（新增）
- `test/kernel/dsh_kernel_test.dart`（只改那条依赖真机的用例）

## 要求

1. 预检变成可注入：
   ```dart
   /// The credential refs dsh can resolve, as ~/.dsh's credentials file names
   /// them; overridden in tests, which must not read the user's own.
   typedef DshCredentialRefs = Future<Set<String>> Function();
   ```
   `DshKernel(..., {DshCredentialRefs? credentials})`，缺省读真机（解析 `refs:` 的 key 名即可，不读值）；测试传固定集合。
2. 抽常量：`DshPatch.credentialRef = 'STEPCODEV2_API_KEY'`，`dsh_notices.dart` 引用它，不再各自写一遍。
3. 改 `test/kernel/dsh_kernel_test.dart` 里那条「当前版本不发提示」：注入含该 ref 的集合，断言不出现任何提示；另加一条注入空集合的用例，断言出现「缺凭据」且内核仍能起进程。
4. `test/kernel/dsh_notices_test.dart`：预检的三种情况（有 ref / 无 ref / 文件解析失败）各一条；版本比较的边界（`0.2.0-rc.2` 不算旧、`0.2.0-rc.1` 算旧、`unknown` 不提示）各一条。
5. 规格补一句：会话内提示的 id 是 `notice:version` / `notice:credential:<ref>` / `notice:images:<turnId>`（不是字面的 `<notice>:<n>`）；凭据预检可注入，测试不得读真机。

## 判据

1. `flutter analyze --fatal-infos` → No issues found
2. `dart format` 改动文件 → 0
3. `flutter test test/kernel/dsh_notices_test.dart test/kernel/dsh_kernel_test.dart test/kernel/dsh_approval_test.dart` → 全绿
4. 把 `HOME` 指向一个空目录再跑 `flutter test test/kernel/dsh_kernel_test.dart`（Git Bash: `HOME=/tmp/empty-home flutter test ...`）→ 仍全绿（证明不再依赖真机凭据）

## 交付回传

分支、HEAD、diff stat、四条命令末行与退出码、用例名、遗留。

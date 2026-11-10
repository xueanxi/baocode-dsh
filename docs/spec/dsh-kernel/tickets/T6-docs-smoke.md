# T6 — 文档、smoke 脚本与跨票回归

> 依赖：T3、T4、T5
> 规格：`docs/spec/dsh-kernel.md` 全篇（尤其 §9 已知代价）

## 目标

把实现期确认的事实写成使用者与维护者能读的文档；给一条手动 smoke；补一条跨票回归。**不引入新功能。**

## 独占路径

- `docs/dsh-kernel.md`（新建）
- `tool/dsh_smoke.mjs`（新建）
- `test/kernel/dsh_integration_test.dart`（新建）

明确不改：`lib/**`、`docs/spec/**`（规格与票面已定稿；发现真 bug 回传父代理另开修复票）。

## 实现要求

### `docs/dsh-kernel.md`

写给两类人：用 DSH 的人、以后接第三个内核的人。必须包含：

1. 这是什么：第二个内核，与 Claude Code 并存；Claude Code 仍是默认，bots 仍是 Claude
2. 前提：`npm i -g @deepseek-ai/dsh`；共享 `~/.dsh`（会话/模型/凭据与 dsh web 互通）；BaoCode 不写 `~/.dsh`
3. 三个权限档位各允许什么；**首条消息后锁定**及原因（dsh 把档位写进会话日志，resume 不改）
4. 审批只在 shell 越界时出现；弹窗里的理由来自 `rawInput.justification`，没有就明说
5. 已知限制逐条：文本整条出现；不列历史（去 dsh web）；多文件夹与远端项目不提供 DSH；Windows 默认 pwsh（要 bash 的安装命令与「read-only 对 bash 不生效」）；读不作围栏（agent 可读 `~/.dsh` 含凭据文件）；`danger-full-access` 的审批是 never（拒绝而非自动批准）；用量不进 BaoCode 账本；切视图回来要重新握手约 6 秒
6. 协议映射表（六种 update → 事件，turn 的固定顺序）
7. 补丁文件在哪、什么时候重建、不含密钥、`apiKeyEnv` 必须与 `~/.dsh` 的 refs 同名
8. 排障：找不到 dsh / profile 起不来（看 stderr 尾部与 `~/.dsh/logs/startup-*.log`）/ 缺凭据 / resume 失败（`already owned` 可重试、`cwd does not match` 致命）
9. 验收步骤：`flutter analyze --fatal-infos`、定向测试、`node tool/dsh_smoke.mjs`、一次真实对话的人工检查清单

### `tool/dsh_smoke.mjs`

- `node tool/dsh_smoke.mjs [--cwd <dir>] [--prompt <text>]`；`BAOCODE_DSH_PATH` 可覆盖定位
- 行为：按 `package.json` 找 bin.js → 用与内核相同的补丁内容写到临时目录（绝对路径）→ 起 `node bin.js --profile acp --patch <tmp>` → initialize → session/new → 一轮 prompt → 打印收到的 update 类型与最终 stopReason → 自动允许审批（allow-once）→ 退出码 0/1
- 注释写清：会花一次模型调用；不进 CI

### 跨票回归

`test/kernel/dsh_integration_test.dart`，用 T2 的 `MockDshTransport` 串起：
prepare（不建会话）→ 首条消息建会话 → 一轮含工具（含审批）→ 下一轮纯文本 → 出错轮（仍发 TurnEnded）→ release → 再 prepare 并 resume → dispose。断言事件顺序、`TurnEnded` 一定出现、健康态保持、审批线形、`session/resume` 参数。

## 判据

1. `flutter analyze --fatal-infos` → No issues found
2. `dart format` 改动文件 → 0
3. `flutter test test/kernel/dsh_integration_test.dart` → 全绿
4. `node tool/dsh_smoke.mjs --help`（或 `--cwd` 缺失时的用法输出）→ 不启动 dsh、打印用法、退出码 0
5. 真实 smoke 不要求自动化；若你手动跑了，把最后几行贴回（会花一次模型调用）

## 交付回传

分支、HEAD、diff stat、四条命令末行与退出码、smoke 是否手动跑过、文档每条限制对应的事实编号（F1–F27）、路径外改动。

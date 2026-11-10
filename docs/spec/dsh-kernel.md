# DSH 内核：与 Claude Code 并存的第二个 agent

> 状态：v3（2026-11-09，六轴评审后重写），待实现
> 范围：新增一个内核适配器；不改动 Claude Code 的既有行为（只为同一接口加一个可选的运行时谓词）
> 依据：本机 dsh 0.2.0-rc.2 的 ACP 实测（握手、会话、审批、中断、续接、真实对话）+ 本仓库内核层/UI 的只读勘察 + 六轴（协议、内核契约、跨面、自洽、票图/测试、安全进程）评审

## 1. Problem Statement

BaoCode 的对话只能跑 Claude Code 一个 agent。本机已装 dsh（DeepSeek Harness），自带 `--profile acp`：JSON-RPC over stdio 的嵌入协议，能跑工具、问审批、切模型、续接会话。想用 dsh 时只能离开 BaoCode，项目上下文、文件树、diff 都要重新对一遍。

要的是并存，不是替换：两者各有合适场景。

## 2. Solution

新增内核 `dsh`（id `dsh`、显示名 `DSH`、描述 `DeepSeek Harness`），排在 Claude Code 之后；Claude Code 仍是默认，bots 仍固定 Claude Code。

选中 DSH 后，BaoCode 在**项目目录**里起一个 ACP 子进程，把会话更新翻译成既有对话事件；权限三档在**首条消息之前**选定，之后锁定（dsh 的档位写在会话日志里，`session/resume` 不会改它——实测）。模型实时切换。历史会话不在 BaoCode 列（不做会话目录），正文在 `~/.dsh`，去 dsh web 看。

不安装 dsh、不安装插件、不写 `~/.dsh` 的任何文件：只用 `--patch` 叠加配置，凭据沿用 dsh 自己的 `refs`。

## 3. 已核实的事实

标注「实测」的来自本机对 `node <dsh>/lib/bin.js --profile acp --patch <abs.yaml>` 的探针；其余为源码阅读。

| # | 事实 |
|---|---|
| F1 | 传输：newline-delimited JSON-RPC 2.0 over stdio；stdin EOF 让服务正常退出（它自己 flush + 取消 + dispose，约 5 秒）；客户端必须保持 stdin 打开 |
| F2 | `initialize` → `protocolVersion: 1`（不协商）、`agentInfo {name: deepseek-harness-acp, version: "0.0.1"}`、`sessionCapabilities {close, list, resume}`、`promptCapabilities.image`、`mcpCapabilities.http`；`clientCapabilities` 被忽略 |
| F3 | `agentInfo.version` 是 ACP 桥的常量 `"0.0.1"`（实测），**不是** dsh 版本；版本一律读被定位包的 `package.json` |
| F4 | `session/new {cwd, mcpServers}`：两者必填；`mcpServers` 必须传 `[]`（非空会真的拉起 MCP 子进程）；`additionalDirectories` 非空 → `-32602` |
| F5 | **会话头 cwd 是本会话的 workspace-write 边界**（`sandbox-policy` 的 workspaceRoot 取 `session.header.cwd ?? 部署根`）；进程 cwd 只是 fs-sandbox 的默认根与回退。两者都要给项目目录 |
| F6 | `configOptions`：`model`（按 provider 分组，值是 `JSON.stringify([provider, model])` 的不透明串）与可选的 `reasoning_effort`。**用本设计的补丁时只有 `model`**（该路由未声明 reasoningEfforts）；模型列表会列出所有已挂 adapter，包括没有凭据的 |
| F7 | `session/update` 六种：`agent_thought_chunk`、`agent_message_chunk`、`tool_call`、`tool_call_update`、`usage_update`、`config_option_update` |
| F8 | 文本按**已提交的整条消息**送达，一次 `agent_message_chunk` 带完整文本（实测），没有 token 流；一轮多步会有多条这样的消息，需按到达顺序成为多个条目。**chunk 不带消息 id**，id 得自己生成 |
| F9 | `tool_call {toolCallId, title, kind:"other", status:"in_progress", rawInput}`；`tool_call_update {toolCallId, status: completed|failed, content}`；`kind` 恒为 `"other"`，没有中间进度 |
| F10 | 审批是服务端请求：`session/request_permission {sessionId, toolCall:{toolCallId}, options:[{optionId:"allow-once",kind:"allow_once"},{optionId:"reject-once",kind:"reject_once"}]}`。**请求里没有工具名与理由**；理由要从前一条同 `toolCallId` 的 `tool_call.rawInput.justification` 关联，拿不到就明说 |
| F11 | 审批只在 **shell 沙箱升级**时触发；工作区内普通读写与命令不问（实测：写到工作区外也没有询问）。读不作围栏：agent 仍可读 `~/.dsh`（含凭据文件）并经网络外发 |
| F12 | `session/prompt {sessionId, prompt:[{type:"text"}]}` → `{stopReason}`；并发第二个 prompt → `-32602 a prompt is already in flight`；失败 → `-32603 "Internal error"`，细节在 `data.details = "turn failed: …"`，**没有 stopReason** |
| F13 | stopReason 映射：completed→`end_turn`、max-tokens→`max_tokens`、aborted→`end_turn`、blocked→`end_turn`、interrupted→`cancelled`；错误回合拒绝、不返回 stopReason |
| F14 | `session/cancel {sessionId}` 是通知，不回应答 |
| F15 | `session/resume {sessionId, cwd}` → `{configOptions}`，不重放历史。错误四种：同进程 `-32602 session is already active`（先于 cwd 检查）、跨进程旧进程仍持锁 `-32603 already owned by an active write handle`、未知/子代理 `-32602 not resumable`、cwd 不符 `-32602 session cwd does not match`。旧进程退出后跨进程 resume 成功（实测，Windows 无锁文件，进程亡即释放） |
| F16 | **resume 不改变权限档位**：dsh 在会话创建时把预设写进会话日志，`sandbox mode = 请求覆盖 ?? 会话日志 ?? 启动默认`（实测：read-only 建的会话，用 danger-full-access 重启并 resume 后仍受限；新建会话才生效） |
| F17 | `session/list {cwd?, cursor?}` 只给 `{sessionId, cwd}` 与 `nextCursor`（100/页，最新优先）；没有标题与时间，不可重放 |
| F18 | `session/close` 存在（释放写锁）；`session/load`、`fork`、`delete`、`set_mode`、`rename`、`fs/*`、`terminal/*` 全为 `-32601`；没有 modes |
| F19 | `usage_update {used, size}` 附着在每条 assistant 消息之后，需要 token-meter 与 contextWindow 都在 |
| F20 | 起进程到能握手约 6 秒（实测） |
| F21 | 补丁：顶层 YAML 数组，`--patch` 可重复；**相对路径按被启动进程的 cwd 解析**，必须传绝对路径；id 命中的条目**整体替换** `config`（不深合并），已有 id 的 `name` 被忽略；插件名解析失败被**静默忽略**，进程照常启动 |
| F22 | `DSH_PERMISSION_MODE` 决定 `sandbox-policy.mode`（默认 `workspace-write`）与 `approval.policy`（仅 `danger-full-access` 为 `never`，其余 `ask`）；非法值**不 fail-loud**，降级启动并在 stderr 打 `N entries did not activate` / ValidationError |
| F23 | `danger-full-access` = 审批 `never`，而 `never` 会**拒绝**走审批通道的请求（不是"自动批准"） |
| F24 | 凭据在 `~/.dsh/.credentials.yaml` 的 `refs`（本机有 `STEPCODE_API_KEY`、`STEPCODEV2_API_KEY`、`OPENROUTER_API_KEY`）；provider 的 `apiKeyEnv` 必须与 refs 的 key 逐字一致；不需要把 key 放进环境或命令行 |
| F25 | 会话落点 `$DSH_HOME/sessions/<cwd 编码>/<sessionId>/session.v4.jsonl.zstd`；`session/new` 就会建文件（空会话也建） |
| F26 | Windows 上 base 禁用 `tool-bash` 与 `bash-sandbox`，启用 `tool-pwsh`/`pwsh-sandbox`；`dsh-gitbash-shell` 装在 web profile 的 node_modules，acp profile 解析不到，补丁里引用它会被静默忽略（实测：仍是 pwsh） |
| F27 | read-only 档位在 Windows 上通过 PowerShell 的 ConstrainedLanguage 限制 pwsh（实测报 "Only core types are supported in this language mode"）；若装了 gitbash 插件，其执行器在 win32 是 **unconfined**，该档位不限制 bash |
| F28 | 补丁层改不了一个已存在 id 的 `name`：`- id: bash-sandbox` + `name: dsh-gitbash-shell/shell` 被跳过（stderr：`patch: name mismatch for "bash-sandbox" (expected "@deepseek-ai/dsh-bash-sandbox", got "dsh-gitbash-shell/shell"), skipping`），因为 `bash-sandbox` 在 base 里属于官方 `@deepseek-ai/dsh-bash-sandbox`。`dsh-gitbash-shell` 0.38.5 自己的 bundle patch 已 insert `gitbash-executor`（`bashPath: ''` = 自动解析，本机解析到 `D:/tools/git/Git/bin/bash.exe`，source `path-git`），所以补丁只需 `tool-bash: disabled: false`。另：0.52.0 的 peer 要求 dsh ≥ 0.2.2-rc.1，装 0.2.0-rc.2 会被拒 |

## 4. User Stories

1. 作为用户，我想在新对话里看到 Claude Code 与 DSH 两个选项，按任务挑 agent
2. 作为长期使用 Claude Code 的用户，我想让新对话默认仍是 Claude Code
3. 作为用户，我想让「上次用哪个内核」被记住
4. 作为用户，我想在对话开始后内核选择器锁定，不会误换 agent
5. 作为用户，选中 DSH 后直接输入任务就能跑，不用先去设置里配
6. 作为用户，我想看到 DSH 的完整回复（整条消息出现也可以）
7. 作为用户，我想在 dsh 调用工具时立刻看到工具卡（工具名与参数）
8. 作为用户，我想在工具结束后看到结果文本；失败时看到失败状态与错误文本
9. 作为用户，我想中途停止一个跑偏的任务，并且停止后还能继续对话
10. 作为用户，我想切换模型（列表来自 dsh 配置、按 provider 分组），切换立即生效、不重启
11. 作为用户，我想在 dsh 报出思考强度时调整它；它没报就不显示这个选项
12. 作为用户，我想看到上下文占用与窗口大小（窗口在第一次回复前就按补丁里的 512K 显示）
13. 作为用户，我想在**首条消息之前**选权限档位（只读 / 只改工作区 / 无限制），默认「只改工作区」；发出第一条消息后这个选择锁定，想换档就新开对话
14. 作为用户，我想在 dsh 发起沙箱升级审批时看到工具名与理由（拿不到理由就明说），并选择「允许一次 / 拒绝」
15. 作为用户，我想在 dsh 找不到时看到可执行的修复指引（`npm i -g @deepseek-ai/dsh` 与设置项位置）
16. 作为用户，我想在设置里有 DSH 单独一组，能覆盖 dsh 路径，并读到「历史在 dsh web 里看」
17. 作为用户，我想不用手填路径也能用起来（自动发现）
18. 作为用户，我想在 dsh 版本低于验证版本时看到一条会话内提醒，但仍然能用
19. 作为用户，我想让 dsh 的会话仍写在 `~/.dsh`，dsh web 里能看到同一批会话
20. 作为用户，我想在同时开着 dsh web 时不被 BaoCode 破坏状态（不写 `~/.dsh`、不抢锁）
21. 作为用户，我想让 DSH 只在单目录的本地项目里出现：多文件夹工作区与远端项目里不提供这个内核，免得「以为它在我的项目里干活」
22. 作为用户，我想让 `@` 文件补全照常可用（BaoCode 自带的文件提及，不依赖 dsh）
23. 作为用户，我想在退出应用时 dsh 子进程被正常收尾（先让它自己 flush，再强杀兜底）
24. 作为用户，我想让 dsh 的轮次错误以会话内错误气泡呈现，而不是把整个内核判成不可用
25. 作为用户，我想让 DSH 与 Claude Code 在切项目、切对话时互不影响（各自的进程、各自的选项）
26. 作为开发者，我想让新增内核不触碰 Claude Code 的启动、会话、用量、标题生成等既有链路
27. 作为开发者，我想让能力通过既有接口声明即可生效，UI 按声明显示或隐藏
28. 作为开发者，我想让 dsh 的协议细节集中在翻译层里，dsh 升级时只改一处
29. 作为开发者，我想让补丁由程序生成并缓存，文件头记 dsh 版本，版本或内容变化后自动重建
30. 作为开发者，我想在不启动真实 dsh、不花 token 的前提下用脚本化消息验证全部适配行为
31. 作为开发者，我想有一个手动 smoke 脚本，需要时真跑一次 dsh，不进 CI
32. 作为开发/维护者，我想让每张票的改动范围独占，能与其他票并行实现

## 5. Implementation Decisions

### 5.1 模块与改动面

- **内核适配器**（新）：实现 `AgentKernel` 与能力接口；`prepare` 起进程并握手，第一条消息时才 `session/new`。
- **翻译层**（新）：把六种 update、prompt 结果、JSON-RPC 错误翻译成 `KernelEvent`，并负责 turn 的起止。
- **审批**（新）：`request_permission` → `InteractionRequested`，应答映射；与前一条 `tool_call` 关联工具名与理由。
- **传输层**（新）：起 `node <dsh>/lib/bin.js --profile acp --patch <abs>`、按行收发 JSON-RPC、stderr 环、退出信息、Windows 进程树收尾、子进程登记。
- **定位**（新）：登录 shell 环境 → 设置值 → PATH 垫片 → 平台 npm 全局根；输出 `node`、`bin.js`、版本、包目录。
- **补丁生成**（新）：应用数据目录 `dsh/acp.patch.yml`，原子写，头部记版本，内容变化即重建。
- **设置**（新）：`dshCode.path`（用户作用域），带解析函数与 `current` 静态缝，接入设置页与启动装配。
- **接口增量**（唯一一处既有接口改动）：`AcceptsImages` 增加 `bool get supportsImages`；`KernelDescriptor` 增加可选的 `available` 谓词；`ChatSession.acceptsImages` 改为读谓词。Claude 返回 `true`、Codex 沿用现有行为。
- **注册表**：增加 DSH 描述符，排在 Claude Code 之后；`available` 谓词表达「单目录 + 本机」。
- **本地化**：设置页与权限档位文案进两份 arb；内核发出的会话内提示用英文（与 Claude 一致，不进 arb）。
- **退出接线**：应用启动回收与退出收尾各加一条 DSH 的（`main.dart`）。

### 5.2 能力声明

声明：`SelectsModel`、`SelectsPermission`、`SelectsEffort`、`ReportsContext`、`AcceptsImages`。
不声明：会话目录、`LoadsHistory`、fork、rewind、重命名、消息排队、后台任务、MCP 管理、计划模式、`SuggestsFiles`、`ReportsUsage`、`ReportsUsageLimit`、`WatchesEdits`、`MovesSessions`、`StartsPlans`、`RevertsChanges`。

要点：

- `SelectsEffort` 始终实现，但 `optionsFor(model)` 在 dsh 没报 `reasoning_effort` 时返回空（本设计的补丁下就是空，UI 不显示）。
- `ReportsContext.contextWindow` 初值取补丁里的 `contextWindow: 512000`，`usage_update.size` 到达后覆盖。
- `AcceptsImages.supportsImages` 取 `initialize.promptCapabilities.image`（本设计的补丁下为 true）；为 false 时，发送前剥掉图片并发一条 warning 提示。
- `SelectsPermission` 是内核自己的 `_Choice` 实现（不用 `LocalChoice`，因为 `LocalChoice.select` 会立刻改 `selected`）：首条消息之前三档可选，之后 `options` 只保留当前项（选择器自然只剩一项）。

### 5.3 启动、定位与 profile

- 命令：`node <bin.js> --profile acp --patch <绝对路径>`；**不设** `runInShell`（`.cmd` + 管道会 EINVAL）；cwd = 项目目录。
- 环境：以**登录 shell 的环境**为底（macOS 从 Finder 启动时 PATH 极简；Windows 用应用自身环境），加 `DSH_PERMISSION_MODE=<档位>`；不设 `DSH_HOME`。
- 定位顺序：
  1. 设置值（`bin.js` 单段，或 `node` 与 `bin.js` 两段）；两段都展开**开头**的 `~`（`~/…`，Windows 上用反斜杠写的开头 `~` 同样），按登录 shell 环境的家目录（Windows 取 USERPROFILE，其余取 HOME）；中间的 `~` 与 `~user/…` 不展开；
  2. PATH 上的 `dsh` / `dsh.cmd` / `dsh.ps1` 垫片，解析出 `lib/bin.js`；
  3. 平台 npm 全局根：POSIX `<prefix>/lib/node_modules/@deepseek-ai/dsh/lib/bin.js`（prefix 取 PATH 里 `bin/node` 上两级，另加 `/usr/local`、`~/.npm-global`、nvm 的 `versions/node/*`）；Windows `%APPDATA%\npm\node_modules\@deepseek-ai\dsh\lib\bin.js`。
- 解析 `package.json` 的 `version`；失败记 `unknown`，不阻断。
- 只接受 `bin.js` 作为 spawn 目标（`.cmd`/`.ps1` 只用于解析路径）。
- 版本与补丁头不一致、或补丁内容变化 → 原子重建补丁。
- 起进程前做一次凭据预检：补丁里用到的 `apiKeyEnv` 必须能在 `~/.dsh/.credentials.yaml` 的 `refs` 里找到同名 key（或环境里存在）；找不到就发一条「缺凭据」提示（说明 ref 名与在 dsh web 的 Models 页写入的方法），不让每轮都以 `MISSING_CREDENTIAL` 失败。

### 5.4 profile 补丁

```yaml
# Generated by BaoCode for dsh <version>. Do not edit.
- id: llm-pi-ai
  name: '@deepseek-ai/dsh-llm-pi-ai'
  config:
    providers:
      stepcodev2:
        displayName: stepcodev2
        apiKeyEnv: STEPCODEV2_API_KEY
        api: openai-completions
        baseURL: https://i-ai-gw.stepx.com/v1
        models:
          - id: deepseek-v4.1-flash
            name: deepseek-v4.1-flash
            contextWindow: 512000
            input: [text, image]
- id: acp
  name: '@deepseek-ai/dsh-acp'
  inject: [acpAppStartup]
  config:
    provider: stepcodev2
    model: deepseek-v4.1-flash
```

- 只有当 `<DSH_HOME>/profiles/acp/node_modules/dsh-gitbash-shell` 存在时，才再追加一行：

```yaml
- id: tool-bash
  disabled: false
```

  执行器不写在补丁里：插件装进 profile 后，它自己的 bundle patch 会插入 `gitbash-executor`（`bashPath: ''` = 自动解析）并禁用 `pwsh-sandbox`。补丁层也写不进去——`bash-sandbox` 在 base 里属于官方 `@deepseek-ai/dsh-bash-sandbox`，`- id: bash-sandbox` + `name: dsh-gitbash-shell/shell` 会被判 name mismatch 跳过（F28）。默认不写这一行：插件不存在时 `tool-bash` 没有执行器，bash 并不会出现（F26）。安装命令要卡版本：`dsh plugin --profile acp add dsh-gitbash-shell@0.38.5`（0.49 起要求 dsh ≥ 0.2.2-rc.1，0.39 起换 route B，都不认这套补丁）。
- 补丁文件是 `<应用数据目录>/dsh/acp.patch.yml`；`findGitBash` 仍在起进程前发现 bash（`lib/kernel/dsh/dsh_bash.dart`），顺序：`BAOCODE_GIT_BASH`（绝对路径，存在即用）→ 登录 shell 环境里 PATH 上第一个非 WSL 的 `bash.exe` → `git --exec-path` 所属 Git 的 `<Git>/bin/bash.exe` → `C:/Program Files/Git/bin/bash.exe`、`C:/Program Files (x86)/Git/bin/bash.exe`；但结果只当开关用：找到才写 `tool-bash` 那一行，路径本身不进补丁。非 Windows 恒为 null（bash 就是 shell 本身）。
- 目录 `0700`、文件 `0600`，先写临时文件再 rename；内容不含 `!!js`、不含任何密钥；被外部改动即重建。
- `apiKeyEnv` 必须与 `refs` 的 key 逐字一致（F24）。

### 5.5 一轮的事件契约（必须先于协议映射读）

一轮固定为：

```
TurnStarted(turnId)
ItemUpserted(turnId, UserMessageItem(text, images))     // id 必须等于 turnId
… 任意个条目：AssistantTextItem / ThinkingItem / ToolCallItem / NoticeItem …
TurnEnded(turnId, interrupted: bool, worked: Duration?, usage: …)
```

- 用户消息必须由内核自己发出（ACP 不回显）：`TurnStarted` 之后、任何 agent 条目之前。
- 用户消息的条目 id **必须**等于 `turnId`，否则耗时与 usage 不落到这条消息上。
- 带图而 `initialize` 还没回来时，本轮等握手再决定图片去留：`TurnStarted` 因此晚一点出现（只有「握手完成前就发图」这一条罕见路径，界面上通常到不了：粘贴图片先要 `supportsImages` 为真）。「图被丢掉」的提示在 `TurnStarted` 之后、同一轮内，不排在本轮之前。
- 文本落地：`ItemUpserted(id, AssistantTextItem(整条文本), streaming: false)`；不发 `TextDelta`，不需要 `ItemCompleted`。
- `agent_message_chunk` / `agent_thought_chunk` 不带 id：内核按到达顺序生成 `message:<n>` / `thought:<n>`（n 自增，重启进程后继续）；同一轮多步会产生多个条目。
- 出错（`-32603`）：先 `ItemUpserted('<error>:<turnId>', NoticeItem(NoticeKind.error, 文本))`，再 `TurnEnded(turnId, interrupted: true)`。**不发 `TurnEnded` 会让会话永远停在“进行中”、发送按钮不可用。**
- 取消：发 `session/cancel` 通知；prompt 以 `stopReason: cancelled` 收尾 → `TurnEnded(interrupted: true)`。
- 事件 `seq` 单调递增，重启进程后延续，不复位。
- 凡健康态、可用选项、当前选中、`contextWindow` 有变化，都必须 `emitInfoChanged()`（否则工具栏与选择器不重绘）。

### 5.6 协议映射

| dsh | 对话事件 |
|---|---|
| `agent_message_chunk` | `ItemUpserted('message:<n>', AssistantTextItem(text))`（整条，不流式） |
| `agent_thought_chunk` | `ItemUpserted('thought:<n>', ThinkingItem(text))` |
| `tool_call` | `ItemUpserted(toolCallId, ToolCallItem(kind: ToolKind.command, target: title, label: title, detail: <rawInput 单行摘要>, status: running))` |
| `tool_call_update` | 同 id：`status: succeeded/failed`，`output:` 拼 `content` 里的文本块；`kind` 恒 `other`，`ToolKind` 没有 other 成员，不为它加成员 |
| `usage_update` | `UsageReported(ContextUsage(window: size, used: used))`，并记下 size |
| `config_option_update` | 重建选项 + `emitInfoChanged()` |
| `session/prompt` 的 `{stopReason}` | `TurnEnded(turnId)`；`cancelled` → `interrupted: true` |
| `session/request_permission` | `InteractionRequested(ApprovalRequest(...))`；应答后 `InteractionResolved` |
| JSON-RPC `error` | error `NoticeItem` + `TurnEnded(interrupted: true)`，健康态不变 |

审批映射细节：

- `alwaysAllowLabel` 必须为 null（否则 UI 会多出一个“总是允许”）。
- 工具名放 `ApprovalRequest.title`（`toolName` 不渲染）；理由放 `reason`，取自同 `toolCallId` 的 `rawInput.justification`；拿不到写「dsh 未提供理由」。
- 允许→`allow-once`，拒绝→`reject-once`（拒绝时 UI 附带的文字 dsh 不要）。
- 应答与取消都要发 `InteractionResolved`；本地取消本轮时对未决审批回 `{outcome:{outcome:'cancelled'}}`。
- 本机串行化 prompt：内核在上一轮未结束时不再发 `session/prompt`（dsh 会 `-32602`）。

### 5.7 权限三档（选定后锁定）

- 选项：`read-only` / `workspace-write` / `danger-full-access`；默认取 `KernelContext.settings['permission']`（用户上次选的），否则 `workspace-write`。
- 档位在起进程时用 `DSH_PERMISSION_MODE` 传入；内核自己校验取值（F22：非法值会静默降级）。
- 发出第一条消息后锁定：`options` 只保留当前档，`select` 无效果。理由：dsh 把档位写进会话日志，resume 不会改（F16，实测）；与其“显示新档、跑旧档”，不如在首条消息前选定。
- `danger-full-access` 的选项 `caution: true`；文案要写明「不再弹审批；走审批通道的请求会被拒绝」（F23）。
- 说明文案要写明：审批只在 shell 越界时出现，普通文件写入不会询问（F11）。

### 5.8 生命周期

- `prepare()`（视图出现）：定位 → 补丁 → 起进程 → `initialize`。**不建会话**（否则每打开一个 DSH 对话就在 `~/.dsh` 留一个空会话）。
- 第一次 `send()`：若已有 `sessionId`（本次运行内 release 过）先 `session/resume`，否则 `session/new {cwd, mcpServers: []}`；`sessionId` 在 `session/new` 返回后立刻上报。
- `release()`（视图全关）：空闲则关进程并等它退出（最多 5 秒）；忙碌则本轮结束后再关。
- 下一次 `prepare()` 若要 resume，必须**先** `await` 旧进程 `exited`（否则 dsh 报 `session is already active` / `already owned`）；`-32603 already owned` 与 `-32602 already active` 可重试一次，其余错误判致命。
- `dispose()`：关 stdin → 等 dsh 自己 flush（≥6 秒）→ 仍在则 `taskkill /pid <pid> /T /F`；从子进程登记器移除。`stopped` 在进程退出后完成。
- `restart()`：仅用于 `failed` 后重试（先定位与补丁重算，再起进程）。
- 应用级：启动时回收上次残留（`reapDshProcesses`），退出时 `stopDshProcesses` 与其他清理并列（`main.dart`）。Windows 上崩溃残留无法可靠回收，文档不承诺。

### 5.9 失败与健康

- `failed` 只有两种：找不到 dsh（文案含 `npm i -g @deepseek-ai/dsh` 与设置项位置）、profile 起不来（stderr 尾部，含 `N entries did not activate` / ValidationError 视为降级）。
- 凭据/模型不可用是**轮次错误**：error `NoticeItem` 原样带 dsh 的 `turn failed:` 文本，健康态保持 `ready`。不要用 `noModel`（那会把用户带到 BaoCode 自己的模型设置）。
- 进程以 0 退出而健康态为 `ready` → `idle`。
- 版本低于验证版本（从 `package.json` 读）：一条 warning `NoticeItem`，健康态不变，不阻止使用。
- 会话内提示的 id 是 `notice:version` / `notice:credential:<ref>` / `notice:images:<turnId>`（不是字面的 `<notice>:<n>`），各只说一次；凭据预检可注入（`DshKernel(credentials:)`，缺省只解析 `~/.dsh` 里 `refs:` 的 key 名、不读值），测试不得读真机。

### 5.10 跨面与界面

- **可用性**：`KernelDescriptor.available` 谓词。DSH 仅当「项目是单目录、且在本机」时可用；多文件夹工作区（cwd 是 `<data>/workspaces/<id>` 的空目录）与远端项目下不提供。Claude 不设谓词（永远可用）。
- **标题**：DSH 不声明 `RenamesSession`，自动起标题已经因此不触发；手动「总结标题」也要按 `canRename` 关掉，避免把 DSH 对话文本发给 Claude Haiku。
- **图片**：`AcceptsImages.supportsImages`；真实能力为 false 时剥掉图片并提示（提示在同一轮内）。握手未完成时它是 false（「还不知道」），带图的一轮等握手再决定，不抢先剥掉。
- **线程记住的内核在本项目不可用**（例如把 DSH 对话挪进多文件夹项目）：会话以当前第一个可用内核打开（`ChatSession._availableKernel`）；一个都不可用时才保留原内核。不报错。
- **用量**：不声明 `ReportsUsage`，设置→用量里没有 DSH 的账（文档写明）。
- **自定义页**：Customize 是全局页、与内核无关，**不改**；文档说明它只作用于 Claude Code。
- **提示落点**：不新增空态/头部 UI；「历史在 dsh web」「只用单目录项目」写进设置项说明与 `docs/dsh-kernel.md`。
- **`notes`**：`KernelTurn.notes` 不发送（dsh 没有对应通道）；`mentions` 已包含在文本里。文档写明。

### 5.11 安全与数据

- 不写 `~/.dsh` 下任何文件（不跑 `--dump-config`、不跑 `plugin`、不动 profiles/sessions/projcache）。
- 定位到的 dsh 必须与用户 `dsh web` 用的是同一份安装（同版本），不打包、不下载第二份。
- 补丁是**可执行配置**：不含 `!!js`，目录 0700 / 文件 0600，原子重建，被改动即重建。
- 不读、不复制 `~/.dsh/.credentials.yaml` 的值，不把 key 放进命令行/环境/补丁；只传 `apiKeyEnv` 的名字。
- 子进程登记器识别器：解析命令行，精确匹配 node 可执行名 + 分辨后的绝对 `lib/bin.js` + `--profile acp`；禁止子串匹配。
- 子进程 stderr 在**落库前**脱敏（`DshRedact`，`dsh_transport_io.dart` 的 `_stderrLine`）：`Bearer <token>` → `Bearer ***`，`Authorization[:=] <value>` → `Authorization: ***`，≥32 字符的不透明串 → `***`。因此 `DshExit` 的 stderr 与 `KernelHealth.detail` 已经干净，不需要在展示处再洗一遍（脱敏按形状做，极长的单个路径段偶尔也会变 `***`）。
- 已知的安全事实要写进文档：读不作围栏（agent 可读凭据文件）；Windows 上 `read-only`/`workspace-write` 只约束 pwsh（ConstrainedLanguage），装了 gitbash 插件后该执行器 unconfined；`danger-full-access` 的审批是 `never`，会拒绝而非自动批准。

### 5.12 本地化

- 进 arb：DSH 设置分组与路径行（含历史提示）、权限三档的标签与说明、错误指引的界面文案。
- 不进 arb：内核发出的会话内提示（英文，与 Claude 一致）、工具名、模型名。
- `localizedKernelOption` 增加 `('dsh', permission, <id>)` 三条；未知保持原文。
- 生成物（`app_localizations*.dart`）随 arb 一起提交。

## 6. Testing Decisions

缝的形状（评审修正后）：**以构造函数注入传输工厂为主缝**，其余都是既有测试惯例，不新增抽象：

- 走线上的一切（握手、会话、六种 update、审批、取消、错误、`DSH_PERMISSION_MODE` 与 cwd/argv 通过替身 `node` 脚本回显）→ mock 传输。
- 定位与补丁 → 纯函数 + 临时目录 + 可覆盖的环境映射（照 `CliLocator.use`）。
- 设置 → 临时数据目录（照 `settings_wiring_test.dart`）。
- 注册表顺序 → 暴露 `KernelRegistry.builtIn` 供普通测试断言（测试引导会把 `all` 换成 mock 列表）。
- 选择器/审批面板 → `MockKernels.dsh` + `pumpSession`。
- 退出清理 → 替身进程；`main.dart` 的接线本身不测，只在票面写明。
- 起进程失败/凭据提示 → 注入的 `start` 抛错。

必须覆盖的行为（按测试文件）：

- `dsh_transport_test.dart`：按行解码、非 JSON 行进 stderr、替身脚本回显 args/cwd/env、退出信息、stderr 脱敏（`Bearer ***` / `Authorization: ***` / 长串）、`close()`、识别器正负例
- `dsh_profile_test.dart` / `dsh_locator_test.dart`：补丁两行条件、版本头、重建、定位顺序、平台根、`~` 展开、两段式设置值
- `dsh_kernel_test.dart`：握手、`session/new` 的 `[]` 与 cwd、模型分组、无 effort、contextWindow 初值、健康失败两种、版本提醒、选项在首条消息后收敛
- `dsh_turn_test.dart`：TurnStarted/用户条目/TurnEnded 顺序与 id、整条文本、思考、工具卡成功/失败、usage、-32603 也发 TurnEnded、cancel
- `dsh_approval_test.dart`：请求挂起、allow-once/reject-once/cancelled 线形、工具名与理由关联与缺失回退、迟到应答忽略
- `kernel_ui_test.dart`（追加）：选择器两个内核、默认 Claude、首条消息后锁定、权限档位首条消息后只剩一项、图片开关随 `supportsImages`
- `l10n_test.dart`（追加）：三档中文标签
- `settings` 测试：`dshCode.path` 往返

不跑：真实 dsh 进程、全量套件、`-t e2e`。命令：`dart format <改动文件>` → `flutter analyze --fatal-infos` → `flutter test <本票文件>`。

## 7. 任务图

| 票 | 目标 | 独占路径 | 依赖 |
|---|---|---|---|
| T1 | 定位 + 传输 + 补丁 + 路径设置类 | `lib/kernel/dsh/dsh_locate*.dart`、`dsh_transport*.dart`、`dsh_patch.dart`、`dsh_path_setting.dart`、`lib/platform/data_dir.dart`（只加 `dshDir`）、`test/kernel/dsh/` | — |
| T2 | 内核核心 + 翻译层（握手、会话、turn 契约、模型/上下文、生命周期） | `lib/kernel/dsh/dsh_kernel.dart`、`dsh_translator.dart`、`mock_dsh_transport.dart`、`lib/kernel/kernel_registry.dart`、`test/kernel/dsh_kernel_test.dart`、`dsh_turn_test.dart` | T1 |
| T3 | 审批 + 提示与错误路径（含版本提醒、缺凭据、取消） | `lib/kernel/dsh/dsh_approval.dart`、`dsh_notices.dart`，以及 `dsh_kernel.dart` 的审批接线；`test/kernel/dsh_approval_test.dart` | T2 |
| T4 | 界面闭环：可用性谓词、图片谓词、MockKernels.dsh、标题门禁 | `lib/kernel/agent_kernel.dart`、`lib/chat/chat_session.dart`、`lib/kernel/mock/mock_kernels.dart`、`lib/kernel/claude_code/claude_code_kernel.dart`（只加 `supportsImages` 与 `available` 相关）、`lib/kernel/codex/codex_kernel.dart`、`lib/workspace/workspace.dart`（标题门禁）、`test/kernel_ui_test.dart` | T2 |
| T5 | 设置 + 文案 + main 接线 + 退出清理 | `lib/settings/pages/general_page.dart`、`lib/settings/app_settings.dart`、`lib/main.dart`、`lib/l10n/*.arb` 及生成物、`lib/chat/composer/kernel_option_text.dart`、`test/l10n_test.dart`、`test/settings/` | T1 |
| T6 | 文档 + smoke + 跨票回归 | `docs/dsh-kernel.md`、`tool/dsh_smoke.mjs`、`test/kernel/dsh_integration_test.dart` | T3、T4、T5 |

并行：T1 完成后 T2 与 T5 并行；T2 完成后 T3 与 T4 并行；T6 收口。

## 8. Out of Scope

- 会话目录、续接旧会话、删除会话（也没有“会话被别处占用”的交互）
- token 级流式文本
- 会话内切换权限档位（dsh 不支持改已建会话的档位）
- fork / rewind / 重命名 / 消息排队 / 后台任务 / MCP 管理 / 计划模式
- 编辑监听与 diff review
- 远端 SSH 主机上的 dsh、多文件夹工作区里的 dsh
- 自动安装或升级 dsh、自动安装 `dsh-gitbash-shell`
- BaoCode 自有工具（generate_image、浏览器、远端操作、用量查询）接入 dsh：ACP 只能接外部 MCP server，进程内工具传不过去
- 改 README 宣传文案、把设计发到 GitHub Issue

## 9. 已知代价

1. 文本按整条消息出现；一轮多步会分成多条。
2. 不列历史会话：重启后侧栏没有 dsh 对话，正文在 `~/.dsh`，去 dsh web 看。
3. 权限档位在首条消息后锁定；想换档只能新开对话。
4. 多文件夹工作区与远端项目不提供 DSH。
5. Windows 默认只有 pwsh；要 bash 得把 `dsh-gitbash-shell` 装进 acp profile，且装了之后 read-only 档位对 bash 不生效。
6. 审批只在 shell 越界时出现；文件写入不问。
7. 读不作围栏：agent 可以读 `~/.dsh`（含凭据文件）并把内容发出去。
8. 跨内核的“上次选择”按 kind 全局保存，切内核后可能要重选档位/模型（DSH 会丢弃不认识的 id）。
9. dsh 的用量不进 BaoCode 的用量账本。
10. 视图切换会结束进程再 resume，回来时要重新等握手（约 6 秒）。

## 10. Further Notes

- 注册表顺序决定默认内核：DSH 必须排在 Claude Code 之后；测试里 `all` 被替换，顺序由 `builtIn` 断言。
- 只测上线行为，不给翻译层写私有函数测试；协议细节集中在翻译层，dsh 升级时只改一处。
- 设计期探针已在收尾清理；实现时不要往 `~/.dsh` 留测试残留。

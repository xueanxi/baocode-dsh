# DSH 内核：与 Claude Code 并存的第二个 agent

> 状态：v4（2026-11-10，补上消息排队），已实现
> 范围：新增一个内核适配器；不改动 Claude Code 的既有行为（只为同一接口加一个可选的运行时谓词）
> 依据：本机 dsh 0.2.0-rc.2 的 ACP 实测（握手、会话、审批、中断、续接、真实对话）+ 本仓库内核层/UI 的只读勘察 + 六轴（协议、内核契约、跨面、自洽、票图/测试、安全进程）评审

## 1. Problem Statement

BaoCode 的对话只能跑 Claude Code 一个 agent。本机已装 dsh（DeepSeek Harness），自带 `--profile acp`：JSON-RPC over stdio 的嵌入协议，能跑工具、问审批、切模型、续接会话。想用 dsh 时只能离开 BaoCode，项目上下文、文件树、diff 都要重新对一遍。

要的是并存，不是替换：两者各有合适场景。

## 2. Solution

新增内核 `dsh`（id `dsh`、显示名 `DSH`、描述 `DeepSeek Harness`），排在 Claude Code 之后；Claude Code 仍是默认，bots 仍固定 Claude Code。

选中 DSH 后，BaoCode 在**项目目录**里起一个 ACP 子进程，把会话更新翻译成既有对话事件；权限三档在**首条消息之前**选定，之后锁定（dsh 的档位写在会话日志里，`session/resume` 不会改它——实测）。模型实时切换。历史会话不在 BaoCode 列（不做会话目录），正文在 `~/.dsh`，去 dsh web 看。

不安装 dsh、不安装插件、不写 `~/.dsh` 的任何文件：只用 `--patch` 叠加配置。模型与凭据有两个来源（§5.4）：设置 → 模型选的那条路由走 app 自己的本地模型代理，上游 key 留在 app；否则沿用 dsh 自己的 `refs` 与 profile，或 `dsh/dsh.env` 给出的路由。

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
| F9 | `tool_call {toolCallId, title, kind:"other", status:"in_progress", rawInput}`；`title` 是工具名（如 `bash`、`read`），`rawInput` 是本次调用的参数对象；`tool_call_update {toolCallId, status: completed|failed, content}`；`kind` 恒为 `"other"`，没有中间进度 |
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
| F24 | 凭据在 `~/.dsh/.credentials.yaml` 的 `refs`（本机有 `STEPCODE_API_KEY`、`STEPCODEV2_API_KEY`、`OPENROUTER_API_KEY`）；provider 的 `apiKeyEnv` 必须与 refs 的 key 逐字一致；文件路由不需要把 key 放进环境或命令行。这个 ref 名由本机路由文件给出（§5.4），代码里不再写死。app 自己的路由是例外：它把本地代理的 token 放进子进程环境（不是上游 key），见 §5.4 的决策 |
| F25 | 会话落点 `$DSH_HOME/sessions/<cwd 编码>/<sessionId>/session.v4.jsonl.zstd`；`session/new` 就会建文件（空会话也建） |
| F26 | Windows 上 base 禁用 `tool-bash` 与 `bash-sandbox`，启用 `tool-pwsh`/`pwsh-sandbox`；`dsh-gitbash-shell` 装在 web profile 的 node_modules，acp profile 解析不到，补丁里引用它会被静默忽略（实测：仍是 pwsh） |
| F27 | read-only 档位在 Windows 上通过 PowerShell 的 ConstrainedLanguage 限制 pwsh（实测报 "Only core types are supported in this language mode"）；若装了 gitbash 插件，其执行器在 win32 是 **unconfined**，该档位不限制 bash |
| F28 | 补丁层改不了一个已存在 id 的 `name`：`- id: bash-sandbox` + `name: dsh-gitbash-shell/shell` 被跳过（stderr：`patch: name mismatch for "bash-sandbox" (expected "@deepseek-ai/dsh-bash-sandbox", got "dsh-gitbash-shell/shell"), skipping`），因为 `bash-sandbox` 在 base 里属于官方 `@deepseek-ai/dsh-bash-sandbox`。`dsh-gitbash-shell` 0.38.5 自己的 bundle patch 已 insert `gitbash-executor`（`bashPath: ''` = 自动解析，本机解析到 `D:/tools/git/Git/bin/bash.exe`，source `path-git`），所以补丁只需 `tool-bash: disabled: false`。另：0.52.0 的 peer 要求 dsh ≥ 0.2.2-rc.1，装 0.2.0-rc.2 会被拒 |
| F29 | 一次性问答（`--profile headless --patch … --json -`，任务走 stdin）：stdout 是逐行事件，答案在最后一个 `{"type":"final","text":…}`；`thinking` 单独一条事件，不经 `--json` 时会混进 stdout，所以必须用 `--json` 只取 `final`。`agent-default-model` 的 `config`（默认 `deepseek-official`/`deepseek-flash`）决定它的模型；`session-persistence-jsonl.config.root` 可以改会话落点（实测指到临时目录后 `~/.dsh/sessions` 不新增），指到临时目录时不再有 `session-checkpoint-policy` 的 "did not activate" 警告（`disabled: true` 会警告）；进程退出码与 `status` 的 `turn_end.reason.error.message` 说明失败（模型 id 不存在时实测 exit 1、`final.text` 空、stderr 一行 503）；本机一次问答约 6.3 s |
| F30 | **ACP 没有命令面**：`initialize`、`session/new`、`session/*` 都不返回命令列表，dsh 0.2.0-rc.2 里也没有 `available_commands_update`/`AvailableCommand` 类型（`dsh-acp` 与全包源阅读）；web 客户端的 `skills/list` 是会话 Remote，不是 ACP 方法。但 **`/name` 作为正文发出去会被 dsh 加载**：`dsh-tool-skill` 的 `agent/pre-step` 用 `(^|\s)/([a-z0-9]+(?:-[a-z0-9]+)*)(?=\s|$)` 扫用户消息的文本块，命中且 `user-invocable` 就注入该 skill 的 `SKILL.md`。skill 根见 `dsh-skill-filesystem`：项目 `.dsh/skills`(100)、`.agents/skills`(200)，用户 `$DSH_HOME/skills`(400，跳过 `.system`)、`$DSH_AGENTS_HOME/skills`(500)，`$DSH_BUNDLED_SKILL_DIR`(600)；项目根是最近的带 `.git` 的祖先 |
| F31 | 选项提问：ACP profile 的 `dsh-base` 已挂 `user-questions` 服务，但**没有**任何 answerer（web 专属）；`@deepseek-ai/dsh-tool-ask-user` 不在 ACP bundle 里。补丁 `insert` 可挂它，并挂一个 `file://` 绝对 URL 的本地插件（实测 dsh 0.2.0-rc.2 能加载）；插件用 `ctx.on('user-questions/request', …)` 回答，answer 形状 `{answers:[{id, selected:[…], custom?}]}`。不能改走 ACP 的 `mcpServers`（streamable-http）：dsh 的 MCP 客户端对单次 `tools/call` 有 **60 s 硬超时**，ACP 没暴露 `toolCallTimeoutMs`，等用户超过一分钟必然失败（实测代码：`dsh-mcp-client` 默认 `DEFAULT_TOOL_CALL_TIMEOUT_MS = 6e4`） |

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
33. 作为用户，我想在输入框的 `/` 菜单里看到 dsh 会加载的 skill（包括我刚放进 `~/.dsh/skills` 的），选中后由 dsh 真的加载它，而不是只发一段普通文本
34. 作为用户，我想在 dsh 需要我拍板时看到可点选的选项（而不是一段文字问题），选完它继续干活；这和 Claude Code 的 AskUserQuestion 是同一张面板
35. 作为用户，我想在 dsh 干活时接着发下一句，它排在当前任务之后，不会因为发送按钮变灰而丢掉

## 5. Implementation Decisions

### 5.1 模块与改动面

- **内核适配器**（新）：实现 `AgentKernel` 与能力接口；`prepare` 起进程并握手，第一条消息时才 `session/new`。
- **翻译层**（新）：把六种 update、prompt 结果、JSON-RPC 错误翻译成 `KernelEvent`，并负责 turn 的起止。
- **审批**（新）：`request_permission` → `InteractionRequested`，应答映射；与前一条 `tool_call` 关联工具名与理由。
- **选项提问**（新）：补丁 `insert` 挂 `dsh-tool-ask-user` 与一个 `file://` 本地桥插件；插件监听 `user-questions/request`，经本机 loopback 端点把问题送进 `QuestionRequest`，答案按 `{selected, custom}` 回去（§5.16）。
- **传输层**（新）：起 `node <dsh>/lib/bin.js --profile acp --patch <abs>`、按行收发 JSON-RPC、stderr 环、退出信息、Windows 进程树收尾、子进程登记。
- **定位**（新）：登录 shell 环境 → 设置值 → PATH 垫片 → 平台 npm 全局根；输出 `node`、`bin.js`、版本、包目录。
- **补丁生成**（新）：应用数据目录 `dsh/acp.patch.yml`，原子写，头部记版本，内容变化即重建。
- **skill 发现**（新）：`dsh_skills*.dart` 读 dsh 的默认 skill 根，给 `/` 菜单与“打开详情”用（§5.15）。
- **设置**（新）：`dshCode.path`（用户作用域），带解析函数与 `current` 静态缝，接入设置页与启动装配。
- **接口增量**（唯一一处既有接口改动）：`AcceptsImages` 增加 `bool get supportsImages`；`KernelDescriptor` 增加可选的 `available` 谓词；`ChatSession.acceptsImages` 改为读谓词。Claude 返回 `true`、Codex 沿用现有行为。
- **注册表**：增加 DSH 描述符，排在 Claude Code 之后；`available` 谓词表达「单目录 + 本机」。
- **本地化**：设置页与权限档位文案进两份 arb；内核发出的会话内提示用英文（与 Claude 一致，不进 arb）。
- **退出接线**：应用启动回收与退出收尾各加一条 DSH 的（`main.dart`）。

### 5.2 能力声明

声明：`SelectsModel`、`SelectsPermission`、`SelectsEffort`、`ProvidesCommands`、`ReportsContext`、`AcceptsImages`、`QueuesMessages`、`RewindsConversation`、`RenamesSession`、`TitlesItsOwnSessions`；描述符带 `catalog: DshCatalog`（见 §5.13）。`RenamesSession` 是 BaoCode 自己的改名接口（ACP 的 `session/rename` 仍是 `-32601`，见 F18）；`TitlesItsOwnSessions` 让新会话的首条消息由 dsh 自己的 `headless` 一次性问答起标题（§5.14）。
不声明：`LoadsHistory`、fork、后台任务、MCP 管理、计划模式、`SuggestsFiles`、`ReportsUsage`、`ReportsUsageLimit`、`WatchesEdits`、`MovesSessions`、`StartsPlans`、`RevertsChanges`。

要点：

- `SelectsEffort` 始终实现，但 `optionsFor(model)` 在 dsh 没报 `reasoning_effort` 时返回空（本设计的补丁下就是空，UI 不显示）。
- `ReportsContext.contextWindow` 初值取路由文件的 `context_window`（没写时 200000），`usage_update.size` 到达后覆盖。
- `AcceptsImages.supportsImages` 取 `initialize.promptCapabilities.image`（本设计的补丁下为 true）；为 false 时，发送前剥掉图片并发一条 warning 提示。
- `SelectsPermission` 是内核自己的 `_Choice` 实现（不用 `LocalChoice`，因为 `LocalChoice.select` 会立刻改 `selected`）：首条消息之前三档可选，之后 `options` 只保留当前项（选择器自然只剩一项）。
- `QueuesMessages` 是**适配器自己的队列**，不是 dsh 的能力：dsh 一次只收一个 prompt（F12），所以工作中发来的消息由内核先收下，当前轮结束后再依次发出（§5.17）。
- `ReportsUsage` 是账号额度，不是每笔调用的令牌：后者由补丁挂的 `baocode-usage-bridge` 从 dsh 的 `assistant/message` 事件取 `usage`，经本机端点记入用量账本（§5.18）。
- `RewindsConversation` 不是 ACP 的能力：`rewind` 只在本地记下“要回到第几条”，把要丢弃的轮数编码进**下一条 prompt**。补丁挂的 `baocode-edit-bridge` 是 dsh 的 agent 插件，在 `agent/pre-step` 去掉标记、在 `agent/request` 用空的 `developer/message` 覆写旧尾部（surface replace，投影不出模型消息）；于是同一条 dsh 会话、同一个 session id，模型看到的历史就是编辑后的历史（§5.19）。

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
- 起进程前做一次凭据预检：有路由时，补丁里用到的 `apiKeyEnv` 必须能在**dsh 将拿到的环境**里找到（app 自己的路由带进去的代理 token，或登录 shell 环境），或在 `~/.dsh/.credentials.yaml` 的 `refs` 里；找不到就发一条「缺凭据」提示（说明 ref 名与在 dsh web 的 Models 页写入的方法），不让每轮都以 `MISSING_CREDENTIAL` 失败。没有路由就没有可预检的 ref，dsh 用自己的配置与凭据。

### 5.4 profile 补丁

模型路由不在代码里：`DshRoute`（`lib/kernel/dsh/dsh_route.dart`）有两个来源，由 `DshRoutePlan`（`dsh_route_plan.dart`）按下面的顺序选一个：

1. `BAOCODE_DSH_ENV` 指名的文件——脚本或测试的明确指令，缺了报错、不回退；
2. **设置 → 模型 → 「DSH 模型」**（`models.dsh`，一个 `modelRef`）：路由按这个上游与模型现算，`baseURL` 指向 app 自己的本地模型代理（`lib/models/proxy/model_proxy.dart`），`apiKeyEnv` 是 `BAOCODE_DSH_PROXY_TOKEN`，token 只放在起 dsh 的环境里；补丁声明该上游**所有**会话模型（图片模型除外），dsh 的模型选择器因此能在同一个上游内切换而不重启；
3. 应用数据目录的 `dsh/dsh.env`：`provider`、`base_url`、`api_key_env`、`model` 与可选的 `context_window`（`.env` 的写法，`BAOCODE_DSH_ENV` 可改路径）；
4. 都没有：下面 `llm-pi-ai` 与 `acp.config` 两段都不写，dsh 用它自己 profile 的模型。

文件存在但不可用（缺键、未知键、坏 URL、坏窗口、读不了）时启动失败，报文件与行号，不回退。文件只含 ref 名，不含 key（F24）；设置里选的那条路由也不含 key，上游的 key 从不离开 app。

**为什么 app 的路由走本地代理（决策，2026-11-11）。** 上游的协议（Anthropic / OpenAI Chat / Responses / Codex 账号）、鉴权方式（`x-api-key` / bearer）与自定义请求头各不相同，而 pi-ai 的一种 `api` 只对应一种；把上游 key 或带 key 的自定义头写进补丁更是把密钥落盘。app 的模型代理已经为 Claude Code 把这几件事都做完了（协议转换、账号轮换、错误回报、用量记录），dsh 因此只说一种协议（Anthropic Messages，代理的 `/p/<provider>`），拿到的唯一秘密是一个**只监听 loopback、每次运行重新生成**的 token。这条路由也顺带关闭 dsh 的 DeepSeek 适配器（`llm-deepseek` / `llm-deepseek-account`）：它们会以「没有凭据」的样子出现在模型选择器里，正是本次要修的那个坑。代理从 `x-baocode-usage: off` 头认出 dsh 的请求，不重复记用量——dsh 通过 `baocode-usage-bridge` 自己报（§5.18），两边都记会翻倍。

下面的补丁取自本机的一份 `dsh.env`（示例值；app 路由的形状相同，只是 `api` 是 `anthropic-messages`、`baseURL` 是 `http://127.0.0.1:<port>/p/<provider>`、多一行 `headers`）：

```yaml
# Generated by BaoCode for dsh <version>. Do not edit.
- id: llm-pi-ai
  name: '@deepseek-ai/dsh-llm-pi-ai'
  config:
    providers:
      'stepcodev2':
        displayName: 'stepcodev2'
        apiKeyEnv: 'STEPCODEV2_API_KEY'
        api: 'openai-completions'
        baseURL: 'https://i-ai-gw.stepx.com/v1'
        models:
          - id: 'deepseek-v4.1-flash'
            name: 'deepseek-v4.1-flash'
            contextWindow: 512000
            input: [text, image]
- id: acp
  name: '@deepseek-ai/dsh-acp'
  inject: [acpAppStartup]
  config:
    provider: 'stepcodev2'
    model: 'deepseek-v4.1-flash'
```

- 每个标量都加单引号（`''` 转义内部的 `'`）：provider、模型 id、显示名、URL 来自用户设置，一个冒号或方括号不能让补丁变成别的东西。
- app 路由还多两段：`headers: { x-baocode-usage: 'off' }`（上一段说的用量），以及 `- id: llm-deepseek` / `- id: llm-deepseek-account` 的 `disabled: true`。文件路由不写这两段。

- 只有当 `<DSH_HOME>/profiles/acp/node_modules/dsh-gitbash-shell` 存在时，才再追加一行：

```yaml
- id: tool-bash
  disabled: false
```

  执行器不写在补丁里：插件装进 profile 后，它自己的 bundle patch 会插入 `gitbash-executor`（`bashPath: ''` = 自动解析）并禁用 `pwsh-sandbox`。补丁层也写不进去——`bash-sandbox` 在 base 里属于官方 `@deepseek-ai/dsh-bash-sandbox`，`- id: bash-sandbox` + `name: dsh-gitbash-shell/shell` 会被判 name mismatch 跳过（F28）。默认不写这一行：插件不存在时 `tool-bash` 没有执行器，bash 并不会出现（F26）。安装命令要卡版本：`dsh plugin --profile acp add dsh-gitbash-shell@0.38.5`（0.49 起要求 dsh ≥ 0.2.2-rc.1，0.39 起换 route B，都不认这套补丁）。
- 补丁文件是 `<应用数据目录>/dsh/acp.patch.yml`；`findGitBash` 仍在起进程前发现 bash（`lib/kernel/dsh/dsh_bash.dart`），顺序：`BAOCODE_GIT_BASH`（绝对路径，存在即用）→ 登录 shell 环境里 PATH 上第一个非 WSL 的 `bash.exe` → `git --exec-path` 所属 Git 的 `<Git>/bin/bash.exe` → `C:/Program Files/Git/bin/bash.exe`、`C:/Program Files (x86)/Git/bin/bash.exe`；但结果只当开关用：找到才写 `tool-bash` 那一行，路径本身不进补丁。非 Windows 恒为 null（bash 就是 shell 本身）。
- 目录 `0700`、文件 `0600`，先写临时文件再 rename；内容不含 `!!js`、不含任何密钥；被外部改动即重建。
- `apiKeyEnv` 必须与 `refs` 的 key 逐字一致（F24）；文件路由的名字来自 `api_key_env`，app 路由的是固定的 `BAOCODE_DSH_PROXY_TOKEN`，由启动环境给出。

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
| `agent_thought_chunk` | `ItemUpserted('thought:<n>', ThinkingItem(text))`；`seconds` 取与上一个 step 的间隔，第一段从本轮开始算（dsh 不计时） |
| `tool_call` | `ItemUpserted(toolCallId, …)`：`title == todo_write` 时 `ToolCallItem(kind: todo, tool: "todo_write", input: rawInput, target: 进行中的那一项)`；`title` 为 `bash`/`pwsh` 时 `TerminalItem(command: rawInput.command, description: rawInput.description, background: rawInput.run_in_background)`（与 Claude Code 的 Bash 同一张命令卡）；`title == read` 时 `ToolCallItem(kind: read, target: 文件名, path: rawInput.file_path, detail: offset 与 limit 都给时为 L<起>-<止>)`（与 Claude Code 的 Read 同一步；成功时不保留返回内容，失败才留作 output）；`title == send_message` 时 `ToolCallItem(kind: message, target: rawInput.message 单行, output: 送达后整条 message，失败时为返回错误)`（与 Claude Code 的 SendMessage 同一步）；其余 `ToolCallItem(kind: command, target: title, label: title, detail: <rawInput 单行摘要>, status: running)` |
| `tool_call_update` | 同 id：按首次 `tool_call` 重建（todo 的清单、命令卡的命令与描述、read 的文件与行范围、message 的正文不靠 update）；`status: succeeded/failed`（命令卡为 `CommandStatus`），`output:` 拼 `content` 里的文本块；`kind` 恒 `other`，`ToolKind` 没有 other 成员，不为它加成员 |
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
- 本机串行化 prompt：内核在上一轮未结束时不再发 `session/prompt`（dsh 会 `-32602`）；这期间发来的消息进内核的队列，见 §5.17。

### 5.7 权限三档（选定后锁定）

- 选项：`read-only` / `workspace-write` / `danger-full-access`；默认取 `KernelContext.settings['permission']`（用户上次选的），否则 `workspace-write`。
- 档位在起进程时用 `DSH_PERMISSION_MODE` 传入；内核自己校验取值（F22：非法值会静默降级）。
- 发出第一条消息后锁定：`options` 只保留当前档，`select` 无效果。理由：dsh 把档位写进会话日志，resume 不会改（F16，实测）；与其“显示新档、跑旧档”，不如在首条消息前选定。
- `danger-full-access` 的选项 `caution: true`；文案要写明「不再弹审批；走审批通道的请求会被拒绝」（F23）。
- 说明文案要写明：审批只在 shell 越界时出现，普通文件写入不会询问（F11）。

### 5.8 生命周期

- `prepare()`（视图出现）：读回上次的会话（若 `KernelContext.resume` 给了 id，见 §5.13）→ 定位 → 补丁 → 起进程 → `initialize`。**不建会话**（否则每打开一个 DSH 对话就在 `~/.dsh` 留一个空会话）。
- 第一次 `send()`：若已有 `sessionId`（`KernelContext.resume` 给的旧会话，或本次运行内 release 过）先 `session/resume`，否则 `session/new {cwd, mcpServers: []}`；`sessionId` 在 `session/new` 返回后立刻上报并记进本地账本。
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
- **标题**：DSH 声明 `RenamesSession` 与 `TitlesItsOwnSessions`。新会话的首条消息后，内核用 `askDsh` 走**同一条路由**（设置 → 模型选的那条，或 `dsh.env`）做一次性标题生成（不把 DSH 对话文本发给 Claude Haiku），成功则写回账本并发 `SessionRenamed`；失败或取消时保留首行。手动双击改名只写账本；手动「总结标题」也走内核的 `titleFor`（`askDsh`）。ACP 的 `session/rename` 仍不提供（F18）。
- **图片**：`AcceptsImages.supportsImages`；真实能力为 false 时剥掉图片并提示（提示在同一轮内）。握手未完成时它是 false（「还不知道」），带图的一轮等握手再决定，不抢先剥掉。
- **线程记住的内核在本项目不可用**（例如把 DSH 对话挪进多文件夹项目）：会话以当前第一个可用内核打开（`ChatSession._availableKernel`）；一个都不可用时才保留原内核。不报错。
- **用量**：不声明 `ReportsUsage`（那是账号额度）；每笔调用的令牌由 `baocode-usage-bridge` 记入设置→用量（§5.18）。
- **自定义页**：Customize 是全局页、与内核无关，**不改**；文档说明它只作用于 Claude Code。
- **提示落点**：不新增空态/头部 UI；「历史在 dsh web」「只用单目录项目」写进设置项说明与 `docs/dsh-kernel.md`。
- **`notes`**：`KernelTurn.notes` 不发送（dsh 没有对应通道）；`mentions` 已包含在文本里。文档写明。

### 5.11 安全与数据

- 不写 `~/.dsh` 下任何文件（不跑 `--dump-config`、不跑 `plugin`、不动 profiles/sessions/projcache）；BaoCode 自己的账本写在应用数据目录（`dsh/acp.patch.yml` 与 `dsh/sessions/`，见 §5.13）。
- 定位到的 dsh 必须与用户 `dsh web` 用的是同一份安装（同版本），不打包、不下载第二份。
- 补丁是**可执行配置**：不含 `!!js`，目录 0700 / 文件 0600，原子重建，被改动即重建。
- 不读、不复制 `~/.dsh/.credentials.yaml` 的值，不把**上游的** key 放进命令行/环境/补丁；文件路由只传 `apiKeyEnv` 的名字。app 自己的路由（§5.4）把上游 key 留在 app 里，交给 dsh 的只是本地代理的 loopback token（`BAOCODE_DSH_PROXY_TOKEN`，每次运行重新生成），且只放在子进程环境里。
- 子进程登记器识别器：解析命令行，精确匹配 node 可执行名 + 分辨后的绝对 `lib/bin.js` + `--profile acp`；禁止子串匹配。
- 子进程 stderr 在**落库前**脱敏（`DshRedact`，`dsh_transport_io.dart` 的 `_stderrLine`）：`Bearer <token>` → `Bearer ***`，`Authorization[:=] <value>` → `Authorization: ***`，≥32 字符的不透明串 → `***`。因此 `DshExit` 的 stderr 与 `KernelHealth.detail` 已经干净，不需要在展示处再洗一遍（脱敏按形状做，极长的单个路径段偶尔也会变 `***`）。
- 已知的安全事实要写进文档：读不作围栏（agent 可读凭据文件）；Windows 上 `read-only`/`workspace-write` 只约束 pwsh（ConstrainedLanguage），装了 gitbash 插件后该执行器 unconfined；`danger-full-access` 的审批是 `never`，会拒绝而非自动批准。

### 5.12 本地化

- 进 arb：DSH 设置分组与路径行（含历史提示）、权限三档的标签与说明、错误指引的界面文案。
- 不进 arb：内核发出的会话内提示（英文，与 Claude 一致）、工具名、模型名。
- `localizedKernelOption` 增加 `('dsh', permission, <id>)` 三条；未知保持原文。
- 生成物（`app_localizations*.dart`）随 arb 一起提交。

### 5.13 会话与历史（BaoCode 自己的账本）

不读 `~/.dsh` 的原因：`session/list` 只给 id 与 cwd（F17），`session/resume` 不重放历史（F15），session 文件是 dsh 的内部格式（`session.v4.jsonl.zstd`，可能随 dsh 升级变化）。所以 BaoCode 记自己的一份：

- **位置**：`<data>/dsh/sessions/index/<id>.json`（`id`、`cwd`、`title`、`updatedAt`）与 `history/<id>.json`（条目用 `ChatCodec` 编码）。一个会话一对文件，几个内核同时写也互不加锁；原子写。
- **何时写**：`session/new` 返回后立刻写索引（本轮失败也算存在过）；每轮 `TurnEnded` 写历史与时间。标题先取第一条消息的第一行（与侧栏命名新 agent 的规则一致），dsh 的一次性标题回来后再写一次（§5.10、§5.14）；用户改名立即写。
- **何时读**：`DshCatalog.projects()` / `sessionsIn()` 读索引，侧栏据此列出；`prepare()` / 第一次 `send()` 起进程之前按 `KernelContext.resume.id` 读历史，以 `HistoryPrepended` 先发出去。dsh 的 `session/resume` 在这之后才发生，顺序不能反。
- **id**：读回历史里的 `message:<n>` / `thought:<n>` 让翻译层从最大的 n 继续；新进程从 1 数起会覆盖旧条目。
- **删除**：`DshCatalog.delete` 只删本地这对文件；dsh 自带的 session 文件仍在，dsh web 仍能看到。本版本之前建的会话没有本地记录，不会出现在侧栏。
- **限制**：本地历史是快照。在 dsh web 里接着说过的内容不会进入这份快照；继续对话时 dsh 自己的上下文仍是完整的，只是 BaoCode 界面看不到那几轮。
### 5.14 应用自己问的一句话

「生成提交消息」「输入框的提示词增强」这类**应用自己问**的请求，原来固定走 Claude Code 的 Haiku（`ideClaudeCommitMessage` / `polishComposerText` → `askClaudeHaiku`）。本机 `claude.exe` 被策略按文件名静默拦截（退出码 0、零输出），于是这两个功能只能报错；DSH 能跑，却没人问它。

- **路由按内核走**：`ideCommitMessage(kernel:)` 里 `dsh` → `askDsh`，其余内核 → 原来的 Claude 路径。内核由工作台取「该项目 IDE 里那个 chat 的内核」，没有 chat 时取 `Workspace.preferredKernel`（`_commitMessageKernel`）。不改 `IdeCommitMessageModel` 的形状，SCM 输入框、提交面板、rebase/merge 弹窗的 AI 都因此一起换过去。
- **提示词增强同一路由**：`polishComposerText(kernel:)` 同样在 `dsh` 时走 `askDsh`，其余内核仍走 `askClaudeHaiku`；输入框把 `session.kernel.id` 传进来，因此增强用的就是这条对话正在跑的内核。增强自己的标记还原与长度判据不动，只换提问的那一侧。
- **一次性问答走 `headless`，不走 ACP**：ACP 的 `session/new` 会在 `~/.dsh` 落一个会话（F25），而这是**应用自己的**请求，不该出现在用户的会话列表里；`headless` 是 dsh 自带的一次性 profile（"answer one task and exit"）。
- **不落会话的做法**：`DshPatch.askContent` 把 `session-persistence-jsonl.root` 指到本次运行的临时目录，并关掉 `session-title-llm`；进程退出后整目录删除（F29 实测 `~/.dsh/sessions` 不新增）。补丁每次现写（路径里有临时目录），不缓存。
- **不给它工具的空子**：`DSH_PERMISSION_MODE=read-only`、cwd 就是临时目录，`system-prompt` 关掉 identity 与 runtime context、persona 改成"一次回答、不要工具"；即使模型仍去调工具，读到的也只是个空目录，写入会被拒（F23 的 `ask` 无人应答即拒）。
- **解析只认 `final`**：`dshAskAnswer` 取最后一个 `final.text`；空则用 `turn_end.reason.error.message`，再退到 stderr 尾部（`DshRedact` 过），最后是 `dsh gave no answer (exit N).`。
- **不做跨内核回退**：内核是 Claude Code 就仍问 Claude（哪怕它的 CLI 在这台机器上坏了），是 DSH 就问 DSH；失败照原话报出。跨内核偷偷换模型会让"我的提交消息是谁写的"说不清。
- **局限**：每次约 6 秒（起 node + 一次模型调用）；远端项目与多文件夹工作区不提供 DSH，自然仍走 Claude；会话标题现在也走这条路（DSH 内核的 `askDshTitle`，见 §5.10），Stash AI 这类同源调用仍走 `askClaudeHaiku`。

### 5.15 `/` 菜单里的 skill

ACP 不给命令列表（F30），但 `/name` 当正文发出去会被 dsh 加载，所以内核实现 `ProvidesCommands`，自己读 dsh 的 skill 根：

- **位置**：`lib/kernel/dsh/dsh_skills.dart`（frontmatter、rank、去重）与 `dsh_skills_io.dart`（项目根、目录扫描）；web 端 `dsh_skills_stub.dart` 返回空（DSH 本来也不在 web 上提供）。
- **根与顺序**同 `dsh-skill-filesystem` 的默认根：项目 `.dsh/skills`(100)、`.agents/skills`(200)，用户 `$DSH_HOME/skills`(400，跳过 `.system`)、`$DSH_AGENTS_HOME/skills`(500)，`$DSH_BUNDLED_SKILL_DIR`(600)；同名先到先得。项目根是最近的带 `.git` 的祖先，没有就是 cwd。`customSkillDirs` 不读——那是 dsh 的组合配置，BaoCode 不解析别人的 profile 层。
- **frontmatter**：`name` 与 `description` 必填；`name` 匹配 `^[a-z0-9]+(?:-[a-z0-9]+)*$`；`user-invocable: false` 不列；`disable-model-invocation: true` 照列（它只有这个入口）；布尔按 dsh 的严格语法（`true/false/yes/no/on/off/1/0`），非法值整条丢弃；`userInvocable`/`modelInvocable`/`disableModelInvocation` 旧键出现即丢弃。目录 bundle（`<name>/SKILL.md`）与平铺 `<name>.md` 都认。
- **刷新**：每次 `prepare()` 重读；列表有变化才 `emitInfoChanged()`。对话开着时不热更新（与 dsh 的 watcher 无关：菜单不是 dsh 发的）。
- **文件**：`KernelCommand.path` 带 `SKILL.md` 的绝对路径；`ChatScreen._commandFile` 先看内核给的路径，再退回 `CustomizationStore`（Claude Code 的 skills 走那条）。
- **不做**：dsh 的主机命令（`/compact`、`/goal` 等）不列——命令面只在 dsh 自己的 TUI/Web 里挂，ACP 下执行不了；BaoCode 也不替用户改写消息，`/name` 字面照发。

### 5.16 选项提问（`ask_user_question`）

目标：dsh 需要用户拍板时，复用 Claude Code 的那张 `InteractionPanel`，而不是让模型在正文里列问题（用户故事 34）。

- **为什么不能直接用 dsh 自带的工具**：ACP profile 的 `dsh-base` 挂了 `user-questions` 服务，但 answerer 只在 web 客户端（F31）；`dsh-tool-ask-user` 不在 ACP bundle 里，模型根本没有这个工具。
- **为什么不用 ACP 的 `mcpServers` 挂一个 app 内 MCP server**：协议上可行（`mcpCapabilities.http`），但 dsh 的 MCP 客户端对单次 `tools/call` 有 60 s 硬超时，ACP 未暴露 `toolCallTimeoutMs`，而"等用户选"天然会超过一分钟（F31）。所以采用 dsh 的**原生工具通道**。
- **接法**：补丁 `insert` 两个条目——`baocode-ask`（`@deepseek-ai/dsh-tool-ask-user`）与 `baocode-ask-bridge`（BaoCode 写的 `ask_bridge.mjs`，`file://` 绝对 URL）。补丁只在**用户在电脑前**时插（`KernelWorkspace.approvesAll` 为 true 的 bot 会话不插），端点起不来也不插。
- **桥**：`ctx.on('user-questions/request')` 里 POST 问题到 `http://127.0.0.1:<随机端口>/questions`，随后每 300 ms 轮询；端点只认 `Authorization: Bearer <本次对话的随机 token>`；token 与 URL 走 dsh 的环境变量 `BAOCODE_ASK_URL` / `BAOCODE_ASK_TOKEN`，**不进补丁**。轮次取消时 `request.signal` 触发一次 cancel，插件停止轮询。
- **面板映射**：`questions[].id/question/header/options/multi_select` → `QuestionRequest`（`allowMultiple = multi_select`，`allowOther = true`）；标题固定 `DSH has a question`。
- **答案映射**：命中选项标签 → `selected`；用户自己写的（Other）→ `custom`；面板跳过 → 空 `selected`（dsh 读作 skipped，不是取消）。轮次结束、release、进程退出、dispose → 待答问题标 `cancelled` 并发 `InteractionResolved`（面板不悬空）。
- **测试**：端点/插件写入用纯 Dart + 真 loopback；内核线形用 mock 传输 + 真 HTTP；真实 dsh 一条 `-t dsh-e2e` 冒烟（真模型一次，不进 CI）。

### 5.17 工作中发送的消息（排队）

目标：dsh 干活时，用户能像在 Claude Code 下一样接着发下一句，而不是发送按钮变灰（用户故事 35）。

- **为什么由适配器排队**：ACP 一次只接受一个 `session/prompt`，并发第二个是 `-32602 a prompt is already in flight`（F12）；dsh 没有“把消息塞进当前轮”的接缝，也没有自己的队列可交接。
- **收下与显示**：一轮未结束时 `send` 不发给 dsh，而是入内核队列，并发 `ItemUpserted(id, UserMessageItem(queued: true))`：消息显示在输入框上方的队列面板里，不进入对话正文，直到被取用。
- **依次发出**：`TurnEnded` 之后 `_settleTurn` 取队首，按正常一轮开始（`TurnStarted` + `UserMessageItem(queued: false)`），再发 `session/prompt`；因此每一句都是独立轮次，不会合并进上一轮。错误、取消、进程退出同样会触发下一句；每句仍各自有 `TurnEnded`。
- **插入当前任务**：不实现。`chat.queuedMessages` 的 `duringTurn`（Claude Code 的“插入当前任务”）对 DSH 不生效，队列恒为 `afterTurn`；界面上可选项仍是全局设置，切换内核时行为随内核能力。
- **撤回 / 立即发送 / 移动**：`cancelQueued` 只从本地队列删除并发 `ItemRemoved`；`moveQueued` 重排并发 `QueueReordered`；`sendQueuedNow` 把目标移到队首，再 `session/cancel` 当前轮（prompt 以 `cancelled` 收尾），当前轮结束后目标先发。当前轮还没到 dsh（会话正在建）时，它在本地结束，目标等同一个 `session/new` 结果，不会建出两个会话。
- **release**：只要队列非空，进程不释放；全部发完后才按 `_releaseWanted` 释放。

### 5.18 用量账本（token 精确，金额估算）

目标：DSH 对话在设置→用量里也有账，且 **tokens 与供应商报的一致**；金额可以按价格估算（用户故事 36）。

- **不读会话文件**：不解析 `~/.dsh/sessions/**/session.v4.jsonl.zstd`（内部格式，升级会变）。dsh 的 ACP `usage_update` 只有上下文占用（`used/size`），也不是一次调用花掉的令牌。
- **接法**：补丁 `insert` `baocode-usage-bridge`（BaoCode 写的 `usage_bridge.mjs`，`file://` 绝对 URL）。插件监听 `ctx.on('session/event')` 的 `assistant/message` 事件（每次模型调用提交一次），把 `event.data.usage` 的 `inputTokens` / `outputTokens` / `cacheReadTokens` / `cacheWriteTokens` / `reasoningTokens` 原样 POST 到本机端点 `/usage`；`message.source.provider/model` 与 `replayState.response.responseModel/stopReason` 一并带上。`step/start` → `assistant/message` 的间隔作为这次调用的时长。
- **端点**：`DshUsageServer` 是独立于问题端点的 loopback HTTP server，只认 `Authorization: Bearer <本次对话的随机 token>`；token 与 URL 走 dsh 环境变量 `BAOCODE_USAGE_URL` / `BAOCODE_USAGE_TOKEN`，不进补丁。**`approvesAll` 的 bot 会话也挂**：没有用户可答问题，不代表没有调用。
- **记账**：`DshUsageMeter` 把报告变成 `UsageCall`：`input` 是不含缓存的输入，`cacheRead`/`cacheWrite` 单列，`output` 是全部输出，`reasoning` 是输出的子集；`total = input + cacheRead + cacheWrite + output`。报告里没有任何 token 就丢弃，不猜。会话 id 用主对话的 dsh session；子代理会话的调用也记在主对话上，`requestClass = subagent`，`agentId` 是那个子会话。
- **金额**：`UsagePrices` 先看用户为这条路由设的价格；没有时，若 model 在内置估算表里（`DeepSeekPrices`，目前是 `deepseek-v4.1-flash`：输入 $0.28/M、输出 $0.42/M、缓存读 $0.028/M、缓存写 $0.28/M），就用它并在价格卡上标为内置估算，否则仍是未定价；用户设了价格即覆盖。tokens 不做任何估算。
- **重复与历史**：dsh 的 `session/event` 不重放 seed 事件，resume 不会把旧调用再记一遍；每条 `assistant/message` 只提交一次，插件也只报一次。只从装了 usage 桥的进程开始记：修复前的 DSH 调用**不回填**。
- **测试**：`dsh_usage_server_test.dart`（插件文件、token、报告解码）、`dsh_kernel_test.dart`（精确 tokens、时长、子代理归属、无 token 不记）、`dsh/patch_test.dart`（usage-only insert）。

### 5.19 编辑用户消息（会话内 rewind）

目标：点用户气泡能改这条指令并重发，行为与 Claude Code 一致（用户故事：会话内编辑）。ACP 没有 rewind / fork / `session/load`，所以不能靠协议调用。

- **接口**：`DshKernel` 实现 `RewindsConversation`。`rewind` 不发任何请求，只清掉本地队列、记下 `turns`、发 `Rewound(itemId, index)`；调用方随后 `send` 的新消息就是这条 rewind 的载体。没有插件（`_editBridge` 为 false）时返回 false 并发一条 error 走马灯，不发消息。
- **载体**：`_promptContent` 在文本前加 `turns` 个 `DshEditBridge.marker`（`\u200B\u200C`，每轮一对）。翻译层仍用原文，所以界面上看不到标记；标记只在进程内写到 dsh 的 prompt 里。轮次可能排队，所以标记按 turn id 保存，真正发出时才取。
- **插件**：补丁 `insert` `baocode-edit-bridge`（`edit_bridge.mjs`，`file://` 绝对 URL，无需端点与 token）。它不监听 `session/event`（dsh 正在发布事件时再 append 会被拒），而是用 agent loop 的两个钩子，且都在本 step 组请求之前：
  - `agent/pre-step`：拿到被 claim 的 prompt，数出开头 N 对标记，去掉标记（**保留 message id**，ACP 还等着它做模型选择关联），并按 session 记下“这一 turn/step 要丢 N 轮”；
  - `agent/request`：此时 `step/start` 已提交、本 step 的 system prompt 与 prompt 还没进历史。插件从**可见的**用户 prompt 里倒数第 N 条定位编辑目标，用 `developer/message`（`content: []`）对 old tail 做一次 surface replace；范围终点是当前 `turn/start` 之前的最后一个 surface 节点。`sourceEventSeqs` 带上被覆写的全部 surface 节点，满足 dsh 的 surface 校验。
  - 随后 loop 正常追加本 step 的 system prompt 和**已去标记**的 prompt。空 `developer/message` 不投影模型消息，所以模型历史是：旧前缀 + 本轮 system prompt + 干净的新 prompt。替换发生在 `buildRequest` 之前，`contentGeneration` 的变化也会让本 step 正确地开新 message series。
- **为什么不用 `session/fork`**：ACP 不暴露 fork；即使 fork，session id 会变，BaoCode 的会话账本与后续 `session/resume` 都要搬家。surface replace 留在同一会话内，也不删 dsh 的日志。
- **排队的消息**：`ChatSession.editMessage` 只把**真正发出去过**的用户消息算作 turn（排队中的、子代理的都不算），否则会多丢 dsh 里的轮次。rewind 时内核自己的 `_queued` 清空，界面的 `Rewound` 截断之后的条目。
- **测试**：`dsh_kernel_test.dart`（`RewindsConversation`、标记数量、界面文本无标记）、`dsh_edit_bridge_test.dart`（插件文件、replace/清标记逻辑）、`dsh/patch_test.dart`（edit-only insert）。

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
- `dsh/skills_test.dart`：frontmatter（引号、折叠块、非法布尔、旧键、`user-invocable: false`、无效名字）、项目根（最近 `.git`）、rank 去重（项目盖过用户）、`DSH_HOME` 覆盖、没有 `SKILL.md` 的目录
- `dsh_kernel_test.dart`：握手、`session/new` 的 `[]` 与 cwd、模型分组、无 effort、contextWindow 初值、健康失败两种、版本提醒、选项在首条消息后收敛；`prepare()` 后 `commands` 来自 `$DSH_HOME/skills`、带 `SKILL.md` 路径、再次 `prepare()` 收录新增项
- `dsh_turn_test.dart`：TurnStarted/用户条目/TurnEnded 顺序与 id、整条文本、思考、工具卡成功/失败、usage、-32603 也发 TurnEnded、cancel；排队（轮次中发送→当前轮后依次发、撤回、重排、立即发送、会话创建中立即发送只建一个会话）
- `dsh_approval_test.dart`：请求挂起、allow-once/reject-once/cancelled 线形、工具名与理由关联与缺失回退、迟到应答忽略
- `dsh_question_server_test.dart`：桥插件文件写入/不重写、`file://` URL、端点 token 校验、未知问题 404
- `dsh_usage_server_test.dart`：usage 插件文件写入/不重写、`file://` URL、端点 token 校验、报告解码；`dsh_kernel_test.dart`（追加）：精确 tokens 记账（含缓存与 reasoning）、时长、子代理归属、无 token 不记；`dsh/patch_test.dart`（追加）：usage-only insert
- `dsh_kernel_test.dart`（追加）：问题 → `QuestionRequest`、面板回答的 `selected`/`custom`、跳过、release 时 `cancelled`、无人在场不插桥
- `e2e_dsh_real_test.dart`：`-t dsh-e2e`，真实 dsh 调 `ask_user_question`，自动答 Apple，断言工具结果与回复（不进 CI）
- `dsh_restart_test.dart`：重启后 resume 而非 new、历史与标题的读写、`message:<n>` 续号、`DshCatalog` 列项、文件账本与删除
- `kernel_ui_test.dart`（追加）：选择器两个内核、默认 Claude、首条消息后锁定、权限档位首条消息后只剩一项、图片开关随 `supportsImages`；`ChatSession` 在 DSH 流式中 `canSend` 为真、消息进队列
- `l10n_test.dart`（追加）：三档中文标签
- `ask_test.dart`：一次性问答的 argv（headless、`--json`、任务走 stdin 的 `-`）、只取 `final` 的文本、空答案的三种说明（`turn_end` 的错误、stderr、退出码）、非事件行忽略
- `commit_message_test.dart`（追加）：内核是 DSH 时问 dsh 并清洗回复、dsh 的错误原话上报、取消映射成取消（Claude 路径不动）
- `composer_polish_test.dart`（追加）：内核是 DSH 时提示词增强问 dsh 并按标记还原、dsh 的错误原话上报、Claude 路径不动、输入框传会话内核
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
| T7 | 选项提问：provider + loopback 端点 + 桥插件 + 补丁/环境接线 | `lib/kernel/dsh/dsh_questions.dart`、`dsh_question_server*.dart`、`dsh_ask_bridge.dart`、`dsh_patch.dart` 的 insert、`dsh_kernel.dart` 的接线；`test/kernel/dsh_question_server_test.dart`、`dsh_kernel_test.dart`（追加）、`test/e2e_dsh_real_test.dart` | T2、T3 |

并行：T1 完成后 T2 与 T5 并行；T2 完成后 T3 与 T4 并行；T6 收口。

## 8. Out of Scope

- 列出 dsh web 里开始的会话；用 dsh 的 `session/delete` 真删会话（本版本 ACP 没有 delete，BaoCode 的删除只删本地账本）
- token 级流式文本
- 会话内切换权限档位（dsh 不支持改已建会话的档位）
- fork / 后台任务 / MCP 管理 / 计划模式（编辑用户消息见 §5.19：用 surface replace，不是 fork/rewind 协议；ACP 的 `session/rename` 仍不支持，BaoCode 侧的改名与标题见 §5.10）
- 把工作中发送的消息插进当前轮（`chat.queuedMessages` 的 `duringTurn`）：ACP 一次只收一个 prompt，DSH 恒为当前轮结束后再发
- 编辑监听与 diff review
- 远端 SSH 主机上的 dsh、多文件夹工作区里的 dsh
- 自动安装或升级 dsh、自动安装 `dsh-gitbash-shell`
- BaoCode 自有工具（generate_image、浏览器、远端操作、用量查询）接入 dsh：ACP 只能接外部 MCP server，进程内工具传不过去。**选项提问是例外**（§5.16）：接的是 dsh 自己的 `ask_user_question` 与其 answerer，不是把进程内工具搬过去
- 读 dsh 组合配置里的 `customSkillDirs`、把 dsh 的主机命令（`/compact`、`/goal` 等）搬进 BaoCode 的 `/` 菜单、skill 列表热更新
- 改 README 宣传文案、把设计发到 GitHub Issue

## 9. 已知代价

1. 文本按整条消息出现；一轮多步会分成多条。
2. 历史是 BaoCode 自己的快照：重启后能列出并读回 BaoCode 建的会话，但在 dsh web 里接着说过的内容不会出现在这份快照里；删除会话只删本地记录，`~/.dsh` 里的 session 仍在。本版本之前建的会话没有本地记录，仍只在 dsh web 里。
3. 权限档位在首条消息后锁定；想换档只能新开对话。
4. 多文件夹工作区与远端项目不提供 DSH。
5. Windows 默认只有 pwsh；要 bash 得把 `dsh-gitbash-shell` 装进 acp profile，且装了之后 read-only 档位对 bash 不生效。
6. 审批只在 shell 越界时出现；文件写入不问。
7. 读不作围栏：agent 可以读 `~/.dsh`（含凭据文件）并把内容发出去。
8. 跨内核的“上次选择”按 kind 全局保存，切内核后可能要重选档位/模型（DSH 会丢弃不认识的 id）。
9. dsh 的 tokens 进 BaoCode 的用量账本（供应商报的精确值）；金额是估算：内置 DeepSeek 价覆盖 `deepseek-v4.1-flash`，其他 model 未设价时仍显示未定价，可在设置→用量里为这条路由改价。
10. 视图切换会结束进程再 resume，回来时要重新等握手（约 6 秒）。
11. 应用自己的提问（提交消息）每次起一次 `headless`，约 6 秒；只在那一个内核是 DSH 的项目里如此。
12. `/` 菜单只读 dsh 的默认 skill 根：不读 `customSkillDirs`，对话开着时不热更新，下次 `prepare()` 才重读。
13. 选项提问依赖 dsh 的内部接缝（`user-questions/request`、`dsh-tool-ask-user`），验证于 0.2.0-rc.2；dsh 改事件名/包名时工具会静默缺失。桥插件与端点只在本地，不走网络；dsh 自己跑的 shell 能读到环境里的 token，属于本机开发工具的威胁模型。
14. 工作中发送的消息只能在**当前轮结束后**依次发出：ACP 一次只收一个 prompt；设置里的“插入当前任务”对 DSH 不生效。
15. 编辑用户消息靠 dsh 的 surface replace，不是真删日志：旧事件仍在 `~/.dsh` 里（人能读，模型看不到）；插件没写成时内核不会发这条编辑；插件在但替换失败时，界面已截断而 dsh 保留旧上下文，标记在 `agent/pre-step` 已去掉、不会进模型，也不会报错。

## 10. Further Notes

- 注册表顺序决定默认内核：DSH 必须排在 Claude Code 之后；测试里 `all` 被替换，顺序由 `builtIn` 断言。
- 只测上线行为，不给翻译层写私有函数测试；协议细节集中在翻译层，dsh 升级时只改一处。
- 设计期探针已在收尾清理；实现时不要往 `~/.dsh` 留测试残留。

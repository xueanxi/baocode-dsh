# DSH 内核

DSH（DeepSeek Harness）是 BaoCode 的第二个 agent 内核，与 Claude Code 并存：

- **Claude Code 仍是默认**：新对话默认选它，它在选择器里排第一。
- **bots 仍固定 Claude Code**（`lib/bots/bots.dart` 只认 `KernelRegistry.claudeCode.id`）。
- **BaoCode 开过的 DSH 会话会记住**：重启后侧栏仍列出，点开能读回当时的对话；在 dsh web 里开始的会话不列（见 §5）。
- **工作中可以接着发下一句**：消息先排在输入框上方，当前轮结束后依次发出；可撤回、重排或“立即发送”（立即发送会停掉当前轮，见 §5）。
- DSH 只在**单目录的本地项目**里出现：多文件夹工作区（cwd 是 `<data>/workspaces/<id>`）与 SSH 远端项目里，选择器不列它（`KernelRegistry.dsh.available`）。

接入方式是 `node <dsh>/lib/bin.js --profile acp --patch <补丁>`：dsh 自带的 ACP profile，JSON-RPC 2.0 over stdio。BaoCode 把六种会话更新翻译成既有的对话事件，不引入新的 UI 协议。

设计依据、事实编号（F1–F27）与取舍见 [`docs/spec/dsh-kernel.md`](spec/dsh-kernel.md)；本文写的是**现在怎么用、出问题怎么查、以后怎么接第三个内核**。

## 目录

1. [快速开始](#1-快速开始)
2. [前提与边界](#2-前提与边界)
3. [权限三档](#3-权限三档)
4. [审批](#4-审批)
5. [已知限制](#5-已知限制)
6. [协议映射](#6-协议映射)
7. [补丁文件](#7-补丁文件)
8. [排障](#8-排障)
9. [验收清单](#9-验收清单)
10. [接第三个内核](#10-接第三个内核)
11. [代码与测试地图](#11-代码与测试地图)

## 1. 快速开始

1. 装 dsh：`npm i -g @deepseek-ai/dsh`（本适配器按 `0.2.0-rc.2` 验证）。
2. 模型由 dsh 自己的 profile 决定：在 dsh web 里配好模型和它的 key 即可。要在本机固定一个路由（测试用），写一份 `dsh/dsh.env`（见 §7）；**代码里不写死任何 provider 或 model**。
3. BaoCode 里新建对话，内核选 **DSH**，输入任务。
4. 第一次发消息时才会在 `~/.dsh` 里建会话；发之前先把权限档位选好（见 §3）。

不想动 UI 时可以手动跑一次 smoke（**会花一次模型调用，不在 CI 里**）：

```bash
node tool/dsh_smoke.mjs --help          # 只打印用法，不启动任何进程
node tool/dsh_smoke.mjs                 # 在当前目录跑一轮
node tool/dsh_smoke.mjs --cwd D:/work/code/project --prompt "列出 TODO"
node tool/dsh_smoke.mjs --env-file D:/work/me/dsh.env   # 指定路由文件
BAOCODE_DSH_PATH=/path/to/dsh/lib/bin.js node tool/dsh_smoke.mjs
```

它把补丁内容写到临时目录（绝对路径），起 `node bin.js --profile acp --patch <tmp>`，走 `initialize` → `session/new` → 一次 `session/prompt`，打印收到的 update 类型与最终 `stopReason`；审批自动回 `allow-once`；成功退出码 0，失败 1（stderr 会带上 dsh 的最后几行输出）。补丁的**形状**是从 `DshPatch.content` 手抄的一份镜像，模型路由不抄：它和应用读同一个路由文件（`--env-file`、`BAOCODE_DSH_ENV`，默认 `<应用数据目录>/dsh/dsh.env`），没有就同样不声明。不含 Git Bash 那两行（脚本不发现 bash）：dsh 升级或 `dsh_patch.dart` 改了两边要一起改。它不写 `~/.dsh`，只由 dsh 自己按正常流程建会话。

## 2. 前提与边界

| 事项 | 说明 |
|---|---|
| dsh | 需要本机装好 `@deepseek-ai/dsh`。BaoCode **不安装、不升级、不打包** dsh，只定位已有的那一份，所以 `dsh web` 与 BaoCode 跑的是同一份安装。 |
| 共享 `~/.dsh` | 会话、模型路由、凭据都在 `~/.dsh`（`DSH_HOME` 生效）；BaoCode 补丁要固定的路由来自本机的 `dsh/dsh.env`（§7），不是源码。BaoCode 在 dsh web 里能看到同一批会话；反过来 dsh web 也能看到 BaoCode 建的会话。 |
| 不写 `~/.dsh` | BaoCode 自己不写 `~/.dsh` 下任何文件：不跑 `plugin`、不跑 `--dump-config`，不动 profiles/sessions/projcache。会话文件是 **dsh 自己**在建会话时写的（`session.v4.jsonl.zstd`），与 dsh web 的行为一致。 |
| BaoCode 自己的会话账本 | dsh 的 `session/list` 没有标题与时间、`session/resume` 不回放历史，所以 BaoCode 把**自己开过的**会话记在应用数据目录的 `dsh/sessions/`（id、cwd、标题、时间与对话条目）。重启后侧栏据此列出、点开读回；在 dsh web 里开始的会话不在其中。 |
| 凭据 | 补丁只写路由文件里的 `apiKeyEnv`（本机示例 `STEPCODEV2_API_KEY`）这个名字，不写 key；BaoCode 也不读 `~/.dsh/.credentials.yaml` 的**值**，预检只看 `refs:` 下的 key 名。没有路由文件时不声明路由，也就不预检。 |
| 项目目录 | 进程的 cwd 与 `session/new` 的 `cwd` 都是项目目录。会话头里的 cwd 就是本会话 `workspace-write` 的边界（F5）。 |
| 版本 | 版本从被定位包的 `package.json` 读（F3；ACP 桥自报的 `agentInfo.version` 恒为 `"0.0.1"`，不是 dsh 版本）。低于验证版本只发一条会话内提醒，仍然可用。 |
| 图片 | 以 `initialize` 的 `promptCapabilities.image` 为准；为 false 时发送前剥掉图片并发一条警告，不会把模型没看到的图片当成已发送。握手还没回来时这条能力是「不知道」（`supportsImages` 为 false）：带图的一轮会等握手结束再决定，因此这一轮的 `TurnStarted` 会晚几秒。这在界面上是罕见路径——粘贴图片本身就要求能力已知，所以通常只出现在直接调用内核的代码里（测试、集成）。 |
| 提示词里的 notes | `KernelTurn.notes` 不发送（dsh 没有对应通道）；`mentions` 已经包含在正文里。 |
| 工作中发送的消息 | dsh 一次只收一个 prompt（F12），所以由内核排队，当前轮结束后再依次发出；`chat.queuedMessages` 的“插入当前任务”对 DSH 不生效（§5 第 22 条）。 |
| Customize 页 | 跟随当前对话的内核：DSH 时「技能」页只列和编辑 dsh 的 skill（`$DSH_HOME/skills`、项目的 `.dsh/skills`），不显示 Claude Code 的其它种类和开关；Claude Code 时仍是 `~/.claude`。 |
| BaoCode 自有工具 | `generate_image`、浏览器、远端操作、用量查询等进程内工具传不给 dsh：ACP 只能接外部 MCP server，而本适配器固定传 `mcpServers: []`。 |

定位顺序（`lib/kernel/dsh/dsh_locate_io.dart`）：

1. 设置里的 `dshCode.path`（`lib/bin.js` 单段，或 `node|bin.js` 两段）：两段都展开**开头**的 `~`（`~/…`，Windows 上用反斜杠写的开头 `~` 同样），按登录 shell 环境的家目录拼（Windows 取 USERPROFILE，其余取 HOME）；中间的 `~` 和 `~user/…` 不展开，因为它们不是家目录；
2. PATH 上的 `dsh` / `dsh.cmd` / `dsh.ps1` 垫片，从垫片文本解析出 `lib/bin.js`；
3. npm 全局根：Windows 上 PATH 各目录的 `node_modules` 与 `%APPDATA%\npm\node_modules`；POSIX 上 PATH 里含 `node`/`dsh` 的 `bin` 上两级、`/usr/local`、`~/.npm-global`、nvm 的 `versions/node/*`。

设置非空时**只认设置**：指到不存在的文件会直接报“找不到 dsh”，不会再回退到 PATH。想恢复自动发现，把设置清空。

### 斜杠菜单里的 skill

在输入框打 `/`，除了 BaoCode 自己的 `btw` 与 `fork`，还列出 **dsh 会加载的 skill**。ACP 没有命令面（F30）：dsh 从不告诉客户端它有哪些 skill，所以内核读 dsh 自己会扫的那些目录，并按同一套 rank 顺序合并同名项：

| rank | 来源 | 目录 |
|---|---|---|
| 100 | 项目 | `<项目>/.dsh/skills` |
| 200 | 项目 | `<项目>/.agents/skills` |
| 400 | 用户 | `$DSH_HOME/skills`（默认 `~/.dsh/skills`；跳过 `.system`） |
| 500 | 用户 | `$DSH_AGENTS_HOME/skills`（默认 `~/.agents/skills`） |
| 600 | dsh 自带 | `$DSH_BUNDLED_SKILL_DIR`（设了才读） |

- 项目根是最近的带 `.git` 的祖先目录；一个都没有，就是项目目录本身。
- 只列 `user-invocable` 不是 false 的；`disable-model-invocation: true` 的仍列（它只有斜杠这一个入口）。frontmatter 缺 `name`/`description`、名字不是 kebab-case、布尔值不合法，或写了 dsh 已废弃的 `userInvocable`/`modelInvocable`/`disableModelInvocation`，整条跳过——与 dsh 一致。
- 目录 bundle（`<name>/SKILL.md`）与平铺 `<name>.md` 都认。
- 选中后发出去的仍是字面的 `/名字`，由 dsh 在 `agent/pre-step` 里匹配并加载 `SKILL.md`（F30）；BaoCode 不替换文本，也不自己加载。
- `/名字` 标签的“打开详情”会打开它的 `SKILL.md`：内核把路径放在 `KernelCommand.path` 上，composer 先用它，再退回当前内核的 CustomizationStore（DSH 时在 `.dsh/skills` 里找，Claude Code 时在 `~/.claude/skills` 里找）。
- 「技能」页（侧栏 Customize、⌘⇧K、设置 → Customize）在 DSH 对话下读的也是 dsh 的根：用户级 `$DSH_HOME/skills`（默认 `~/.dsh/skills`）、项目级 `<项目>/.dsh/skills`；平铺 `<name>.md` 也列出。新建写进 `skills/<名字>/SKILL.md`，删除删掉它的文件夹或那个文件；`.agents/skills` 与 `$DSH_BUNDLED_SKILL_DIR` 只在 `/` 菜单里，不在页面上编辑。
- 列表在每次打开对话时（`prepare()`）重读，新放的 skill 下次进这个对话就能看到；对话开着时不热更新。
- 用户在自己的 profile 补丁里写的 `customSkillDirs` 不读：那是 dsh 的组合配置，BaoCode 不解析。
- dsh 的主机命令（`/compact`、`/goal` 等）不列：命令面只在 dsh 自己的 TUI/Web 里挂，ACP 下没有（`dsh-commands` 的 README 明说 ACP automation 不提供这个面）。

## 3. 权限三档

dsh 的三个沙箱档位（`DSH_PERMISSION_MODE`，F22）：

| 档位 | 界面标签 | 允许什么 | 审批 |
|---|---|---|---|
| `read-only` | 只读 | 读与查看，不改文件。Windows 上 pwsh 被限到 ConstrainedLanguage；装了 Git Bash 插件后 bash 执行器**不受该限制**（F27）。 | 命令需要越出只读沙箱时问（同一套 allow-once / reject-once） |
| `workspace-write` | 只改工作区（默认） | 改项目目录、在项目里跑命令；这是默认档。 | 只有命令**越出工作区**时才问（F11） |
| `danger-full-access` | 无限制 | 不受工作区限制。 | 策略是 `never`：走审批通道的请求会被**拒绝**，不是自动批准（F23） |

三个档位里只有 `danger-full-access` 的审批策略是 `never`，另外两档是 `ask`（F22）——但问的只有“命令要越出当前沙箱”这一种情况，不是每次文件写入都问。

- 默认取用户上次选的档位（`KernelContext.settings['permission']`），没有就是 `workspace-write`。
- 内核自己校验取值：非法值 dsh 会静默降级，BaoCode 不把非法值传下去。
- 档位是**起进程时**传的。在首条消息之前改档，内核会在发消息前重启进程，让会话建在**界面上显示的那一档**里（不会“显示新档、跑旧档”）。

### 首条消息后锁定

发出第一条消息之后，权限选择器只剩当前项，改不动了。原因很硬：**dsh 在建会话时就把档位写进会话日志**，`session/resume` 不会改它（F16，实测：read-only 建的会话，用 danger-full-access 重启并 resume 后仍然受限）。与其显示一个不生效的新档，不如在首条消息前选定。想换档只能新开对话。

`danger-full-access` 的选项带 `caution` 标记，说明文案写明“不再弹审批；走审批通道的请求会被拒绝”。

## 4. 审批

审批只在**命令要越出 shell 沙箱**时出现（F11）。文件写入本身不触发审批——实测写到工作区外也没有弹窗（那是拒绝还是放行由 dsh 的沙箱决定，不是审批面板决定），所以别把它当“每次写入都审查”。

弹窗里的内容来自两条消息的关联：

- dsh 的 `session/request_permission` **只带 toolCallId**，没有工具名和理由（F10）；
- 工具名取自同 `toolCallId` 的前一条 `tool_call` 的 `title`；理由取自那条 `tool_call.rawInput.justification`；
- 拿不到工具名时标题是 `Approval needed`；拿不到理由时明说 `dsh did not give a reason`，不编造。

按钮只有“允许一次 / 拒绝”：dsh 只提供 `allow-once` 与 `reject-once`，所以 `alwaysAllowLabel` 为 null，UI 不会多出“总是允许”。允许回 `allow-once`；拒绝回 `reject-once`，拒绝时用户附带的文字被丢弃（dsh 没地方放）。审批悬而未决时轮次结束或进程关闭，内核会对未决请求回 `cancelled` 并发 `InteractionResolved`，面板不会一直等。迟到或未知的应答被忽略，不抛错。

注意：`danger-full-access` 下审批策略是 `never`，需要审批的请求会被拒绝（F23）。

## 4.1 选项提问（`ask_user_question`）

dsh 自带的 `ask_user_question` 在 ACP profile 里默认**用不了**：base 挂了 `user-questions` 服务，但只有 web 客户端实现了它的 answerer，ACP 只桥审批。所以有用户在场时，补丁会插两行：

- `id: baocode-ask` 挂 `@deepseek-ai/dsh-tool-ask-user`，模型看到的工具就是 `ask_user_question`；
- `id: baocode-ask-bridge` 挂 BaoCode 自己的 `ask_bridge.mjs`（写在应用数据目录的 `dsh/` 下，补丁用 `file://` 绝对 URL 引用）。

桥插件监听 dsh 的 `user-questions/request` 瀑布，把问题 POST 到内核起的**本机 loopback 端点**（随机端口；端点只在本次对话内有效，token 随机生成），随后每 300ms 轮询答案。端点地址与 token 只放在 dsh 的环境变量 `BAOCODE_ASK_URL` / `BAOCODE_ASK_TOKEN` 里，**不写进补丁**。

问题进 `QuestionRequest`，与 Claude Code 的 AskUserQuestion 共用同一张选项面板：`1-9` 选择、`↑/↓` 移动、多选、Other 自由输入、可折叠、可跳过。回答按 dsh 的形状回：

- 命中选项标签的进 `selected`；用户自己写的进 `custom`；
- 跳过回空 `selected`（dsh 的工具把它读作 skipped，不是取消）；
- 轮次结束、进程退出、release 时把待答问题标成 `cancelled`，插件停止等待，面板不会一直挂着。

**为什么不用 ACP 自带的 MCP server**：ACP 的 `mcpServers` 确实能给 dsh 挂 streamable-http MCP，但 dsh 的 MCP 客户端对单次工具调用有 **60 秒硬超时**，而 ACP 没有暴露 `toolCallTimeoutMs`、补丁也改不到动态创建的 MCP client；等用户超过一分钟就会失败。桥插件走 dsh 自己的工具通道，没有这个上限。

没有人在电脑前的会话（`KernelWorkspace.approvesAll`，bot 的）**不插**这两行；端点起不来时同样不插。两种情况 agent 都退回文字提问，其余照常。

## 5. 已知限制

以下每条都对应规格 §9 与事实表，接受它们再用这个内核：

1. **文本按整条消息出现**（F8）：dsh 提交完整消息才发一个 `agent_message_chunk`，没有 token 流；一轮多步会变成多条消息条目，按到达顺序排列。
2. **会话账本是本地的**：重启后能列出并读回 **BaoCode 开过的** DSH 对话；在 dsh web 里开始的会话不列，在 dsh web 里接着说过的内容也不会出现在本地快照里。删除对话只删本地记录，`~/.dsh` 里的 session 仍在（dsh web 还看得到）。本版本之前建的会话没有本地记录，仍只在 dsh web 里。
3. **权限档位首条消息后锁定**（F16）：想换档只能新开对话（见 §3）。
4. **多文件夹工作区与远端项目不提供 DSH**：dsh 的沙箱边界是单个项目目录（F5），本机 dsh 也跑不到远端主机上。DSH 不出现在这些项目里是设计，不是故障。
5. **Windows 默认只有 pwsh**（F26）：base 禁用 `tool-bash`/`bash-sandbox`，启用 `tool-pwsh`/`pwsh-sandbox`。要让 dsh 用 bash，把 `dsh-gitbash-shell@0.38.5` 装进 acp profile：
   ```bash
   dsh plugin --profile acp add dsh-gitbash-shell@0.38.5
   ```
   版本要卡住：0.49 起要求 dsh ≥ 0.2.2-rc.1，0.39 起改成 route B、不再由 `dsh-gitbash-shell/shell` 顶替 `ctx.shell`——这份内核验证的是 0.2.0-rc.2 + 0.38.5。插件装上后它自己的 bundle patch 会插 `gitbash-executor` 并禁用 `pwsh-sandbox`；BaoCode 发现本机 `bash.exe` 时只追加启用 `tool-bash` 的一行（执行器路径由插件自己解析，补丁改不动，见 F28）。**装了 bash 之后，`read-only` 档位对 bash 不生效**：该执行器在 Windows 上是 unconfined（F27），受限的只有 pwsh。
6. **审批只在 shell 越界时出现**：普通文件写入不问（F11），见 §4。
7. **读不作围栏**：agent 仍可读 `~/.dsh`（包括凭据文件）并经网络把内容发出去。沙箱限制的是写与命令，不是读（F11、F24）。
8. **跨内核的“上次选择”按 kind 全局保存**：不同内核共用一份按 kind（model/effort/permission）记的选择；DSH 会丢弃它不认识的 id（例如 Claude 的 model id），所以切内核后可能要重选档位/模型。
9. **用量进 BaoCode 的账本**：`usage_update` 只用来刷新工具栏的上下文占用与窗口大小；每次模型调用的 **tokens** 由补丁挂的 `baocode-usage-bridge` 从 dsh 的 `assistant/message` 事件取出，经本机端点记入设置→用量，数值与供应商报的一致。金额是估算：本机路由的 model 没在设置→用量里设价时，若它在内置估算表里（目前是 `deepseek-v4.1-flash`）就用 DeepSeek 公开价，否则仍显示未定价；设了价就用你的。dsh 仍不声明 `ReportsUsage`（那是账号额度，不是每笔调用）。
10. **切视图回来要重新握手（约 6 秒）**：视图全关时内核释放进程，下次进入重新定位、起进程、`initialize`，再 `session/resume`。这 6 秒是 dsh 的启动时间（F20），不是卡死。
11. 其他不做的：token 级流式、会话内切换档位、fork/rewind/重命名/后台任务/MCP 管理/计划模式、编辑监听与 diff review、自动安装或升级 dsh、把 BaoCode 自有工具接进 dsh（**选项提问是唯一的例外**：它靠一个 profile 内的小桥插件，不是把进程内工具搬过去，见 §4.1）。
12. 本设计的补丁只声明 `model`，没有声明 `reasoningEffort`（F6）：dsh 不报 `reasoning_effort`，所以思考强度选择器不显示（内核实现了 `SelectsEffort`，选项为空时 UI 自然不显示）。
13. 上下文窗口在 dsh 报告前按路由文件的 `context_window` 显示（没写或没有路由文件时用 `DshRoute.defaultContextWindow`，200000），`usage_update.size` 到达后覆盖。
14. 版本低于 `0.2.0-rc.2` 时只发一条 warning（每个会话一次），不阻止使用；`unknown` 版本不做比较、不提醒。
15. 图片：能力为 false 时剥掉并发一次 warning；能力为 true 时图片随消息放在文本前。握手未完成时能力未知，带图的一轮等握手（TurnStarted 因此晚一点出现；界面上粘贴图片要先知道能力，所以这是罕见路径）；提示与消息都在同一轮内，提示不会跑到 TurnStarted 前面。能力随进程走，`release` 或进程退出后复位为未知。
16. Windows 上崩溃/强杀残留的 dsh 进程无法可靠回收；正常退出会 `stopDshProcesses`，启动时会 `reapDshProcesses`，但崩溃这种场景不承诺。
17. 会话的 `cwd` 是它的 workspace 边界（F5）；项目挪了位置，旧会话 resume 会因 `cwd does not match` 失败（显示为轮次错误），只能新开对话。
18. dsh 的 `session/list` 只有 `{sessionId, cwd}`、没有标题与时间（F17），所以列表与标题来自 BaoCode 自己的账本（§2、规格 §5.13），不来自 dsh。
19. 线程记住的内核在当前项目不可用时（例如把 DSH 对话挪进多文件夹工作区，或挪到远端项目），会话会以当前第一个可用的内核打开（通常是 Claude Code），不报错；一个都不可用时才保留原内核。这是通用的线程恢复行为（`ChatSession._availableKernel`），不是 DSH 特有。
20. **斜杠菜单只读 dsh 的默认 skill 根**（§2 的「斜杠菜单里的 skill」）：不读用户 profile 里的 `customSkillDirs`，对话开着时也不热更新，下一次打开对话（`prepare()`）才重读。放进 `~/.dsh/skills` 的 skill，重开或重进对话即可见。
21. 选项提问依赖 dsh 的内部接缝 `user-questions/request` 与 `dsh-tool-ask-user`（验证于 0.2.0-rc.2）。dsh 换掉这个事件名或包名时，工具会静默不在或调用失败；桥接文件随应用一起更新，不写进 `~/.dsh`。另外，dsh 的环境里有端点 token，它自己跑的 shell 命令理论上能读到并伪造一次提问（本机开发工具的威胁模型，不承诺防御）。
22. **工作中发送的消息只能在当前轮结束后依次发出**：ACP 一次只收一个 prompt（F12），“插入当前任务”的 `duringTurn` 设置对 DSH 不生效。撤回、重排、立即发送都在 BaoCode 这一侧完成；“立即发送”会停掉当前轮，等 `session/cancel` 收尾后再发。

## 6. 协议映射

启动：`node <bin.js> --profile acp --patch <绝对路径>`，cwd = 项目目录；stdin 保持打开（EOF 会让 dsh 自己 flush 后退出，约 5 秒，F1）。环境以登录 shell 的环境为底，加 `DSH_PERMISSION_MODE`；有选项提问时再加 `BAOCODE_ASK_URL` 与 `BAOCODE_ASK_TOKEN`（§4.1）。不设 `DSH_HOME`。

握手：`initialize {protocolVersion: 1}` → `protocolVersion: 1`、`agentCapabilities.promptCapabilities.image`、`sessionCapabilities {close, list, resume}`；`clientCapabilities` 被忽略（F2）。

会话：`prepare()` **不建会话**（否则每开一个对话就在 `~/.dsh` 留一个空会话）；第一条消息才 `session/new {cwd, mcpServers: []}`——两个字段都必填，`mcpServers` 必须传 `[]`（非空会真的拉起 MCP 子进程），`additionalDirectories` 不能传非空值（会 `-32602`，F4）。

| dsh | 对话事件 |
|---|---|
| `agent_message_chunk` | `ItemUpserted('message:<n>', AssistantTextItem(整条文本))`，不流式（F8） |
| `agent_thought_chunk` | `ItemUpserted('thought:<n>', ThinkingItem(text))`；dsh 不计时，`seconds` 取与上一个 step（思考/消息/工具开始或结束）的间隔，即这次思考前的等待；第一段从本轮开始算。不取本轮已运行的秒数——那样折线把每段累加后会远大于实际 |
| `tool_call` | `ItemUpserted(toolCallId, …)`：`title` 为 `todo_write` 时 `ToolCallItem(kind: todo, tool, input, target)`（清单在调用里，不靠 `content`）；`title` 为 shell 工具（`bash`/`pwsh`）时 `TerminalItem(command: rawInput.command, description: rawInput.description, background: rawInput.run_in_background)`，与 Claude Code 的 Bash 同一张命令卡（行上是描述，展开是整条命令与输出）；`title` 为 `read` 时 `ToolCallItem(kind: read, target: 文件名, path: rawInput.file_path, detail: offset 与 limit 都给时为 L<起>-<止>)`，与 Claude Code 的 Read 同一步（行上是文件名，可从行打开文件；成功时不保留返回内容，失败才留作 output）；`title` 为 `send_message` 时 `ToolCallItem(kind: message, target: rawInput.message 单行, output: 送达后是整条 message、失败时是返回的错误)`，与 Claude Code 的 SendMessage 同一步；其余 `ToolCallItem(kind: command, target/label: title, detail: rawInput 单行摘要)`（F9） |
| `tool_call_update` | 同 id：按首次 `tool_call` 重建（todo 的清单、命令卡的命令与描述、read 的文件与行范围、message 的正文都不靠 update）；`completed → succeeded`、`failed → failed`（命令卡映射到 `CommandStatus`），`output` 拼 `content` 里的文本块；`kind` 恒 `other`，历史没有该成员，不新增 |
| `usage_update` | `UsageReported(ContextUsage(window: size, used: used))`；窗口变化时补一条 `KernelInfoChanged` |
| `config_option_update` | 重建模型/思考强度选项并 `emitInfoChanged()` |
| `session/prompt` 的 `{stopReason}` | `TurnEnded`；`cancelled` → `interrupted: true`（F13） |
| （客户端）工作中发送的消息 | 不发给 dsh：先 `ItemUpserted(id, UserMessageItem(queued: true))` 进队列面板；`TurnEnded` 后取队首，按正常一轮发 `session/prompt` |
| JSON-RPC 错误（如 `-32603`） | 先 `ItemUpserted('error:<turnId>', NoticeItem(error, 文本))`，再 `TurnEnded(interrupted: true)`；健康态保持 `ready`（F12） |
| `session/request_permission` | `InteractionRequested(ApprovalRequest)`；应答后 `InteractionResolved`（F10） |
| `user-questions/request`（桥插件） | 插件 POST 到本机 `/questions` → `InteractionRequested(QuestionRequest)`；应答后插件轮询到 `{answers:[{id, selected, custom?}]}` → `InteractionResolved`；轮次结束/进程退出 → `cancelled`（§4.1） |
| 其他服务端请求 | 回 `{outcome: {outcome: 'cancelled'}}`，不让轮次悬着 |

一轮的固定顺序（§5.5）：

```text
TurnStarted(turnId)
ItemUpserted(turnId, UserMessageItem(text, images))   // id 必须等于 turnId
… AssistantTextItem / ThinkingItem / ToolCallItem / NoticeItem / Interaction…
TurnEnded(turnId, interrupted:, worked:)
```

- 用户消息由内核自己发出（ACP 不回显），`id` 必须等于 `turnId`，否则耗时与 usage 落不到这条消息上。
- **每个开过的轮次都必须有 `TurnEnded`**：出错、取消、进程退出、release 都要走到。没有它，会话永远停在“进行中”，发送按钮不可用。
- 出错文本优先取 `data.details`，去掉 dsh 的 `turn failed:` 前缀；错误是本轮的，不是内核的，健康态不变。
- 取消：`session/cancel` 是通知、不回应答（F14），prompt 以 `cancelled` 收尾；prompt 还没发出去时在本地直接结束。被中断时仍在 running 的工具卡会补成 `failed`，不会一直转圈。
- 事件 `seq` 单调递增，重启进程后延续，不复位。
- 一次只发一个 prompt：上一轮未结束时不再发（dsh 会 `-32602`）；这期间用户发的消息进内核队列，等当前轮结束后依次发（§5 第 22 条）。同一个 `turnId` 只跑一次。
- 模型选项按 provider 分组，值是 `JSON.stringify([provider, model])` 的不透明串（F6）。选择走 `session/set_config_option`，dsh 拒绝时以它返回的 `currentValue` 为准。会话建立前，选择器显示上一次会话报的列表（`state/storage.json` 的 `dshCode.models`），首条消息后换成 dsh 当下报的 `configOptions`。
- 没有命令面：`initialize` 与 `session/*` 不带 `availableCommands`，dsh 也从不发 `available_commands_update`（F30）。`/` 菜单里的 skill 是内核读 dsh 的 skill 根得到的（§2），`/名字` 由 dsh 的 `agent/pre-step` 在用户消息正文里认领并加载。

`session/resume {sessionId, cwd}` 不重放历史（F15）。错误分四种：`session is already active`（同进程，`-32602`）与 `already owned by an active write handle`（跨进程旧锁，`-32603`）可以重试——内核先 `await` 旧进程退出，再重试一次；`not resumable`（未知会话/子代理会话）与 `session cwd does not match`（cwd 不符）是致命的，显示为本轮错误。旧进程退出后跨进程 resume 成功（Windows 无锁文件，进程亡即释放）。

## 7. 补丁文件

- 位置：应用数据目录下的 `dsh/acp.patch.yml`（Windows `%APPDATA%\baocode\dsh\acp.patch.yml`；macOS `~/Library/Application Support/baocode/dsh/acp.patch.yml`；Linux `~/.config/baocode/dsh/acp.patch.yml`）。测试里是临时数据目录。
- 会话账本也在应用数据目录下：`dsh/sessions/index/<id>.json` 与 `dsh/sessions/history/<id>.json`，与补丁无关，不会因补丁重建而丢失（见规格 §5.13）。
- 内容由 `DshPatch.content` 生成：`llm-pi-ai` 的路由（`provider`、`baseURL`、`apiKeyEnv`、模型与 `contextWindow`）来自本机的**路由文件**，不是代码里的常量（见下）；`api` 固定 `openai-completions`、`input: [text, image]`。`acp` 声明同一个 provider 与 model。装了 Git Bash 插件、且本机找得到 Git Bash 时，再追加启用 `tool-bash` 的一行——执行器由插件的 bundle patch 插入，补丁里写不进去（F28）。
- 有选项提问时（§4.1），再追加一个 `insert`，挂上 `@deepseek-ai/dsh-tool-ask-user` 与 `file://` 绝对 URL 的 `ask_bridge.mjs`；插件文件与补丁同在 `dsh/` 下，内容变了就重写。补丁里不写端点地址与 token（它们在 dsh 的环境变量里）。
- **不含密钥**：只写 `apiKeyEnv` 的名字；key 留在 `~/.dsh`，由 dsh 自己读。文件里也不会出现 `!!js`（生成时会检查）。
- `apiKeyEnv` 必须与 `~/.dsh/.credentials.yaml` 的 `refs:` 里的 key **逐字一致**（F24）。改路由名时就改路由文件的 `api_key_env`，否则预检会报缺凭据、每轮以 `MISSING_CREDENTIAL` 失败。
- 什么时候重建：内容与目标文本不一致就重建——dsh 版本变了（文件头记版本）、补丁内容变了（例如多出启用 `tool-bash` 的一行）、或被外部改过/删掉。内容一致就原样保留。
- 原子写；POSIX 上目录 0700、文件 0600（Windows 继承用户目录 ACL）。**不要手改**：下次启动会按内容重建，改了也会被覆盖。
- `--patch` 必须传绝对路径：相对路径按被启动进程的 cwd 解析（F21）。补丁是**可执行配置**，id 命中的条目会整体替换其 `config`（不深合并），已有 id 的 `name` 被忽略；引用了没安装的插件会被**静默忽略**，进程照常启动（F21）。

### 模型路由文件（`dsh/dsh.env`）

- 位置：应用数据目录下的 `dsh/dsh.env`，与补丁同目录（Windows `%APPDATA%\baocode\dsh\dsh.env`；macOS `~/Library/Application Support/baocode/dsh/dsh.env`；Linux `~/.config/baocode/dsh/dsh.env`）。`BAOCODE_DSH_ENV` 可指向别的文件（脚本、测试用）；指了却不存在会直接报错，不回退。
- 格式与 `.env` 相同：一行一个 `KEY=value`，`#` 起注释，值可用引号。必填 `provider`、`base_url`、`api_key_env`、`model`；可选 `context_window`（缺省 200000）。本机测试用的一份：

```text
provider=stepcodev2
base_url=https://i-ai-gw.stepx.com/v1
api_key_env=STEPCODEV2_API_KEY
model=deepseek-v4.1-flash
context_window=512000
```

- **没有这个文件就是没有路由**：补丁不写 `llm-pi-ai`、不写 `acp.config`，dsh 用它自己 profile 里的模型——也就是 dsh web 里配的那一套。对话与一次性问答都按这条走。
- 文件存在但不可用（缺键、认不得的键、`base_url` 不是 http(s)、`context_window` 不是正数、读不了）→ 启动失败，健康态详情带**文件路径与行号**，不回退到 dsh 的配置。
- 文件里只有 ref 名，没有 key：密钥仍留在 `~/.dsh`，由 dsh 自己读（F24）。BaoCode 既不写也不删这个文件。

### 应用自己问的一句话（`ask.patch.yml`）

「生成提交消息」「输入框的提示词增强」这类**应用自己问**的一句话（不是对话的一轮），在项目内核是 DSH 时由 dsh 回答，不再走 Claude Code 的 Haiku：一次

```bash
node <dsh>/lib/bin.js --profile headless --patch <临时补丁> --json -
```

任务写在 stdin，答案取最后一个 `final` 事件的 `text`——`thinking`（模型的思考）与 `status`（步骤）都丢掉。

- 补丁由 `DshPatch.askContent` **每次提问现写**，落在本次运行的临时目录里（`<系统临时目录>/baocode-dsh-ask-<pid>-<n>/ask.patch.yml`）：路由与 ACP 那份读**同一份 `dsh.env`**（没有就都不声明），`agent-default-model` 指到它，`session-persistence-jsonl.root` 指到该目录下的 `sessions/`，并关掉 `session-title-llm`（起标题是又一次模型请求，这里没人看标题）。
- 进程结束整目录删掉，所以 **`~/.dsh/sessions` 里不会多出会话**——这条是硬要求，不是优化。
- 提问的 cwd 也是那个临时目录：dsh 的沙箱根在那里，`DSH_PERMISSION_MODE=read-only` 由 BaoCode 写上——没有人守着审批，越界请求会被拒（F23）。
- 一次约 6 秒（实测 6.3 s：起 node + 一次模型调用）；取消或超时（2 分钟）连同进程树一起结束。
- 提问方有两个：`IdeCommitMessage`（「生成提交消息」）与 `polishComposerText`（输入框的提示词增强，`kernel:` 取会话的内核）。两者都只在项目内核是 DSH 时改问 dsh，回复的清洗、判据各自不变。
- 内核是 Claude Code 的项目**仍然走 Claude Code 的 Haiku**；没有跨内核回退：DSH 答不上就照它的话报出来（路由要的 ref 缺失时预检直接说，不起进程）。

## 8. 排障

按原因排，不要先怀疑 UI。

### 找不到 dsh

界面提示 `DSH is not installed: run npm i -g @deepseek-ai/dsh…`。依次检查：

1. 真的装了吗：`npm i -g @deepseek-ai/dsh`；
2. 设置 → 通用 → DSH 的路径：留空表示自动发现；填了就必须是存在的 `lib/bin.js`，或 `node|bin.js` 两段。**设置非空只看设置**，指错文件会直接报错而不回退；
3. 自动发现看的是**登录 shell 的 PATH**（macOS 从 Finder 启动时 PATH 极简）与 npm 全局根（Windows `%APPDATA%\npm\node_modules`，POSIX `/usr/local`、`~/.npm-global`、nvm）；
4. `node` 也要能找到——被定位的 dsh 用登录 shell 里的 `node` 跑；npm 全局目录旁的 `node` 是兜底。

`node tool/dsh_smoke.mjs --help` 不启动任何东西，可以用来确认脚本本身没问题；`BAOCODE_DSH_PATH` 只影响这个 smoke 脚本，不影响应用。

### profile 起不来

健康态 `failed`，详情是 dsh 的 **stderr 尾部**。它在落库前已脱敏：`Bearer <token>` → `Bearer ***`、`Authorization: <值>` → `Authorization: ***`、≥32 字符的不透明串 → `***`，所以把详情整段贴出来是安全的（代价是极长的单个路径段也可能变成 `***`）。先看那几行：

- `N entries did not activate` 或 `ValidationError`：补丁里有 dsh 没认下的条目，dsh 会**降级启动**而不是报错退出——看补丁文件是否被手改、插件是否真的装进了 acp profile；
- 检查 `~/.dsh/logs/startup-*.log`（dsh 自己的启动日志，文件名随版本），对照本次启动时间；
- `DSH_PERMISSION_MODE` 由 BaoCode 自己写入并校验过（非法值 dsh 会静默降级，F22），所以档位不对时优先看设置与补丁，而不是这个变量。

### 缺凭据

会话里出现 error 提示：`dsh has no credential for <路由文件的 api_key_env>; add it in dsh web (Models) or set the environment variable.`（本机示例是 `STEPCODEV2_API_KEY`）。这不是启动失败，进程照常起，每轮会以 `MISSING_CREDENTIAL: …` 失败。修法：在 **dsh web → Models** 里给该 provider 写入 key，或用环境变量提供同名 ref。BaoCode 不复制、不读取 key 的值。

同一条提示每个会话只说一次（`notice:credential:<ref>`）。

### 生成提交消息或提示词增强报 dsh 的错

项目内核是 DSH 时，「生成提交消息」与输入框的「提示词增强」走的是 `headless` 一次性问答（§7）。界面上是一条 error 通知，文本就是 dsh 的话：

- `DSH is not installed…`：与对话那条同样的定位问题（§8「找不到 dsh」）；
- `dsh has no credential for <路由文件的 api_key_env>…`：预检在起进程之前就说了，没花模型调用；
- `dsh gave no answer (exit N).`：它退出了却没打印 `final` 事件，常见于路由/额度/模型 id 的问题——文本后面会带 dsh 的 stderr 尾部（已脱敏）；
- `dsh did not answer within N minutes.`：超时被杀；先看 dsh web 里同一个模型能不能答。

它不落会话：若在 dsh web 的会话列表里看到提交消息、提示词增强这类会话，说明有人把补丁的 `session-persistence-jsonl.root` 改回去了（不要手改补丁，见 §7）。

### resume 失败

- `session is already active` / `already owned by an active write handle`：上一个进程还没退干净。内核会等旧进程退出并重试一次；仍失败通常是同会话被另一个 BaoCode 窗口或 dsh 进程持有。
- `session cwd does not match`：项目路径变了（挪了目录、换了挂载点）。旧会话固定在原 cwd，**无法**在新路径续接；新开对话。
- `not resumable`：会话不存在，或那是个子代理会话。新开对话。

resume 不会重放历史，也不会改权限档位（F16）。

### 装了 Git Bash 插件仍是 pwsh

说明没找到本机 Git 的 `bash.exe`。检查：

1. Git for Windows 装了吗；
2. 在**登录 shell**里 `bash --version` 能跑吗（Finder 启动的 app 用的是登录 shell 环境）；
3. 插件是否装进 **acp** profile：看 `~/.dsh/profiles/acp/node_modules/dsh-gitbash-shell` 是否在；安装用 `dsh plugin --profile acp add dsh-gitbash-shell`（其他子命令以 `dsh plugin --help` 为准）；
4. 插件在 acp profile 的 `node_modules` 里存在后，补丁才会带上两行；否则 BaoCode 不写它们（写了也会被静默忽略，F21）。

另外记住：装了 gitbash 之后，`read-only` 档位对 bash **不生效**（该执行器在 win32 是 unconfined，F27）；受限的只有 pwsh。

### 选项提问没出现，或答案没回到 dsh

`ask_user_question` 在 ACP profile 里不是 dsh 自带的：它来自补丁插的两行和 BaoCode 的桥插件（§4.1）。

1. 先看补丁（`<应用数据>/dsh/acp.patch.yml`）里有没有 `- insert:` 与 `baocode-ask`。没有就是“没有人在场”或端点没起来——看应用日志里有没有 `DSH questions:`。
2. 看 `<应用数据>/dsh/ask_bridge.mjs` 是否存在。它的 URL 是 `file://` 绝对路径；路径里有空格/中文不影响，但文件被删或被杀软隔离会失败。
3. 面板出现但模型没收到答案：检查 dsh 的环境里 `BAOCODE_ASK_URL` / `BAOCODE_ASK_TOKEN` 是否在（桥插件读不到就什么也不做），以及本机防火墙是否拦了 loopback。
4. 只在轮次进行中才有面板：轮次结束、`release`、进程退出都会把待答问题取消，这是有意的。
5. 模型只是没用工具、改用文字提问：重试时明确说“用 `ask_user_question` 问”；工具在工具列表里时它通常会照做。

### 其他

| 现象 | 原因 / 处理 |
|---|---|
| 回复整条弹出，没有逐字流 | 正常：dsh 按整条消息提交（F8） |
| 侧栏看不到旧 DSH 对话 | 正常：不列历史；去 dsh web 看（§5） |
| 切走再回来要等约 6 秒 | 正常：重新握手 + resume（F20）；不是卡死 |
| 上下文窗口显示 512K 但用量不涨 | 用量在 dsh 发 `usage_update` 时更新（每条 assistant 消息之后，F19）；没有该更新就还是初值 |
| 设置→用量里没有 DSH | 先确认这次对话是在修复后启动的（旧进程没有 usage 桥；修复前的调用不回填）；DSH 不声明 `ReportsUsage`（账号额度），但每笔调用的 tokens 会经 `baocode-usage-bridge` 记账（§5 第 9 条） |
| 图片被丢掉并提示 | 该路由的 `promptCapabilities.image` 为 false |
| 版本提醒 | dsh 低于验证版本，仍可使用 |
| 想换权限档 | 首条消息后不可换，新开对话（F16） |
| 多文件夹/远端项目没有 DSH | 设计如此（§5 第 4 条、§5.10 的可用性谓词） |
| 工具卡一直转圈 | 中断时会补成 failed；正常轮次由 `tool_call_update` 收尾。若仍出现，连同会话里的错误文本与 dsh 的 stderr 一起报上来 |
| 审批弹窗没有理由 | 该 `tool_call` 没给 `justification`，显示 `dsh did not give a reason` 是有意的 |

## 9. 验收清单

命令（在本仓库根目录，改的是 dsh 相关文件时）：

```bash
flutter analyze --fatal-infos
dart format --output=none --set-exit-if-changed <改动的 .dart 文件>
flutter test test/kernel/dsh_integration_test.dart
flutter test test/kernel/dsh/ask_test.dart test/kernel/dsh/patch_test.dart
node tool/dsh_smoke.mjs --help        # 打印用法，退出 0，不启动 dsh
```

手动 smoke（可选，花一次模型调用，**不进 CI**）：
`node tool/dsh_smoke.mjs --prompt "…"`，看最后两行 `updates:` 与 `stopReason:`，退出码 0。

人工检查清单（一次真实对话）：

- [ ] 新对话内核选择器有 Claude Code 与 DSH，默认 Claude Code
- [ ] 多文件夹工作区、SSH 远端项目里选择器**没有** DSH
- [ ] 首条消息前能选三档，默认“只改工作区”；发出后选择器只剩当前档
- [ ] 回复整条出现；工具卡出现、结束有结果文本（失败时是失败状态）
- [ ] 命令越出工作区时弹审批：有工具名与理由（没有理由时明说），只有“允许一次 / 拒绝”
- [ ] 允许后任务继续；拒绝后本轮能正常结束
- [ ] 让 agent 用 `ask_user_question` 问一个选择题：面板出现，`1-9` 可选，选完本轮继续并复述所选
- [ ] 面板上按 Esc 跳过：本轮继续，dsh 收到空选择；轮次结束或切走视图不留下悬空面板
- [ ] 中途停止可用，停止后还能继续对话
- [ ] 切换模型立即生效，不重启；dsh 没报思考强度时没有该选项
- [ ] 第一次回复前上下文窗口显示 512K，之后随 `usage_update` 变化
- [ ] 设置 → 用量里能看到这次 DSH 对话的调用：输入/输出/缓存 tokens 与 dsh 的账一致，金额有估算价
- [ ] 视图切走再回来约 6 秒后可用，会话接着上一轮
- [ ] 错误轮显示 error 气泡，按钮恢复可用，内核仍是 ready
- [ ] 退出应用后没有残留的 dsh 进程（任务管理器 / `tasklist`）
- [ ] 设置 → 通用 → DSH 的路径能覆盖；清空后回到自动发现
- [ ] 退出应用再打开：侧栏仍有这个 DSH 对话，点开能看到刚才的消息，接着发能继续
- [ ] 删除这个 DSH 对话后重启：侧栏不再出现（`~/.dsh` 里的 session 仍在，dsh web 还看得到）
- [ ] 内核选 DSH 的项目里「生成提交消息」有结果（约 6 秒），dsh web 的会话列表**没有**多出这次提问
- [ ] 同一个项目里输入框的「提示词增强」有结果（约 6 秒），dsh web 的会话列表**没有**多出这次提问
- [ ] 输入框打 `/` 能看到 `~/.dsh/skills` 里的 skill（选中后发给 dsh 的是字面 `/名字`），点它的“打开详情”能打开 `SKILL.md`
- [ ] 切到 DSH 后打开侧栏「技能」：列出的是 `~/.dsh/skills` 的 skill，新建的落在这个目录，改/删不动 `~/.claude/skills`
- [ ] agent 干活时再发一句：输入框可用，消息出现在输入框上方的队列里；当前轮结束后它自己开始，回复接在后面
- [ ] 队列里的消息能撤回、拖到别的位置；“立即发送”会停掉当前轮，先发这一句

## 10. 接第三个内核

新增一个内核 = 一个适配器 + 注册表一行，不碰 Claude Code 的既有链路。步骤：

1. **描述符**：在 `lib/kernel/kernel_registry.dart` 加 `KernelDescriptor`（`id`/`label`/`icon`/`description`/`create`，可选 `available` 谓词与 `catalog`）。顺序决定默认内核：默认是第一个。
2. **适配器**：实现 `AgentKernel`，按能力实现 `SelectsModel`、`SelectsPermission`、`SelectsEffort`、`ReportsContext`、`AcceptsImages` 等接口；**不声明就表示没有**，UI 不应自行假设。
3. **健康态**：`idle` / `starting` / `ready` / `failed`。只有“运行时不在/起不来”才 `failed`；轮次错误保持 `ready`，用会话内 error 气泡表达。
4. **事件契约**（最容易漏的）：每个开过的轮次都必须以 `TurnEnded` 收尾；`TurnStarted` 之后、任何 agent 条目之前发用户消息，且 `id == turnId`；`seq` 单调递增；健康/选项/上下文变化都要 `emitInfoChanged()`。
5. **生命周期**：`prepare()` 只做“能开始”的准备（本例：定位、补丁、起进程、握手），不要建会话；`release()` 让出进程（忙则等本轮结束）；`dispose()` 关 stdin、等运行时自己 flush、超时再强杀，并让 `stopped` 在进程退出后完成；`restart()` 只从 `failed` 重试。
6. **可注入的缝**：照 `DshKernel` 的构造函数注入 `start`（传输工厂）、`locate`、`environment`、`credentials`。测试不启动真实运行时、不读用户凭据；桩传输放在 `lib/kernel/<id>/`（本例 `mock_dsh_transport.dart`），测试里复用。
7. **进程登记与收尾**：用 `ChildProcessRegistry` 记录进程，识别器按**解析后的参数**精确匹配，禁止子串匹配；`main.dart` 启动时回收残留、退出时停掉（见 `reapDshProcesses` / `stopDshProcesses`）。
8. **安全**：不把 key 写进命令行、环境或配置；stderr 进 UI/日志前脱敏；明确“读不作围栏”这类运行时事实并写进文档。
9. **本地化**：只把 UI 文案（设置分组、选项标签、错误指引）放进 arb；运行时自己说的话（本例的会话内 notice）保持英文，与 Claude Code 一致。
10. **测试**：协议细节集中在翻译层，测线上行为，不给翻译层写私有函数测试；至少覆盖握手、会话创建时机、六种更新、审批线形、取消、错误仍 `TurnEnded`、release/resume、选项锁定。再补一条跨票回归（`test/kernel/dsh_integration_test.dart` 是范例）。
11. **文档**：一篇像本文的 `docs/<id>-kernel.md` + 设计规格里的事实表；注明验证过的运行时版本与 smoke 脚本。

## 11. 代码与测试地图

| 路径 | 职责 |
|---|---|
| `lib/kernel/dsh/dsh_locate.dart`、`dsh_locate_io.dart` | 定位 dsh，解析 shim、设置值、平台 npm 全局根，读 `package.json` 版本 |
| `lib/kernel/dsh/dsh_patch.dart` | 生成/缓存 ACP 补丁，原子写、权限位、bash 两行的条件；`askContent`（一次性问答的补丁） |
| `lib/kernel/dsh/dsh_route.dart` | 本机路由文件 `dsh/dsh.env`：`.env` 解析、校验、路径与 `BAOCODE_DSH_ENV`；上下文窗口的缺省值 |
| `lib/kernel/dsh/dsh_ask.dart`、`dsh_ask_io.dart` | 一次性问答：`headless` 的 argv、`final` 事件的解析、起进程与收尾（临时目录、会话根、read-only、超时/取消） |
| `lib/kernel/dsh/dsh_bash.dart` | 找本机 Git 的 `bash.exe`：`BAOCODE_GIT_BASH` → 登录 shell 的 PATH（跳过 WSL 的那份）→ `git --exec-path` 所属 Git → Program Files 里的 Git |
| `lib/kernel/dsh/dsh_transport.dart`、`dsh_transport_io.dart` | 子进程传输：按行 JSON-RPC、stderr 环（落库前脱敏）、退出消息、进程树收尾与登记 |
| `lib/kernel/dsh/dsh_kernel.dart` | 适配器：握手、会话创建/续接、选项、健康、生命周期、审批接线；会话账本与历史回读的接线 |
| `lib/kernel/dsh/dsh_sessions.dart`、`dsh_sessions_io.dart` | BaoCode 自己的会话账本与目录（`DshCatalog`）：索引、历史（`ChatCodec`）、删除；一个会话一对文件 |
| `lib/kernel/dsh/dsh_skills.dart`、`dsh_skills_io.dart` | `/` 菜单里的 skill：按 dsh 的默认根与 rank 扫描、解析 frontmatter、合并同名；web 用 `dsh_skills_stub.dart`（没有文件系统） |
| `lib/kernel/dsh/dsh_translator.dart` | 六种 update、prompt 结果、JSON-RPC 错误 → `KernelEvent` 与 turn 契约 |
| `lib/kernel/dsh/dsh_approval.dart` | 审批请求/应答/取消，工具名与理由的关联 |
| `lib/kernel/dsh/dsh_questions.dart` | `ask_user_question` → `QuestionRequest`，应答/跳过/取消 |
| `lib/kernel/dsh/dsh_question_server.dart`、`dsh_question_server_io.dart`、`dsh_question_server_stub.dart` | 本机 loopback 提问端点：token、POST/轮询/取消，把选项标签映射成 dsh 的 `{selected, custom}` |
| `lib/kernel/dsh/dsh_ask_bridge.dart` | 写 `ask_bridge.mjs`（监听 dsh 的 `user-questions/request`，轮询上面的端点），返回补丁用的 `file://` URL |
| `lib/kernel/dsh/dsh_usage_server.dart`、`dsh_usage_server_io.dart`、`dsh_usage_server_stub.dart` | 本机 loopback 用量端点：token、`POST /usage`，把报告交给内核 |
| `lib/kernel/dsh/dsh_usage_bridge.dart` | 写 `usage_bridge.mjs`（监听 dsh 的 `assistant/message`，把供应商 tokens POST 到上面的端点），返回补丁用的 `file://` URL |
| `lib/kernel/dsh/dsh_usage_meter.dart` | 把一份用量报告变成 `UsageCall`：精确 tokens、时长、主/子代理归属 |
| `lib/kernel/dsh/dsh_notices.dart` | 会话内提示（版本、凭据、图片）与按 ref 的凭据预检 |
| `lib/kernel/dsh/dsh_path_setting.dart` | `dshCode.path` 的解析与 `current` 缝 |
| `lib/kernel/dsh/mock_dsh_transport.dart` | 测试用的脚本化 dsh 进程 |
| `lib/kernel/kernel_registry.dart` | `dsh` 描述符、注册顺序、`available` 谓词、内核 id 常量 |
| `lib/settings/pages/general_page.dart` | 设置 → 通用 → DSH 分组 |
| `lib/main.dart` | 启动回收、退出收尾、路径设置的 `current` |
| `tool/dsh_smoke.mjs` | 手动 smoke（花一次模型调用，不进 CI） |

测试：

- `test/kernel/dsh/`（`locate_test.dart`、`route_test.dart`、`patch_test.dart`、`transport_test.dart`、`ask_test.dart`、`skills_test.dart`）：定位（含开头的 `~` 展开）、路由文件的解析与定位、补丁（ACP 与一次性问答两份）、传输与问答的纯函数和临时目录测试、stderr 脱敏，以及 skill 的 frontmatter、项目根与 rank 合并；
- `test/kernel/dsh_kernel_test.dart`：握手、会话时机、模型、健康、权限锁定、release/resume、能力随进程复位、`prepare()` 后 `/` 菜单来自 skill 根并带文件路径；
- `test/kernel/dsh_turn_test.dart`：一轮的事件顺序（含带图时提示在同一轮内、握手前发图等握手）、文本、思考、工具、usage、错误、取消；
- `test/kernel/dsh_approval_test.dart`：审批的挂起、三种应答线形、理由回退、迟到应答；
- `test/kernel/dsh_question_server_test.dart`：桥插件文件的写入与不重写、端点的 token 校验、未知问题 404；
- `test/kernel/dsh_usage_server_test.dart`：usage 插件文件的写入与不重写、端点的 token 校验、用量报告解码；`dsh_kernel_test.dart` 追加精确 tokens、时长、子代理归属与无 token 不记；
- `test/kernel/dsh_kernel_test.dart`（追加）：问题走面板、回答的 `selected`/`custom`、跳过、release 时 `cancelled`、无人在场时不插桥；
- `test/e2e_dsh_real_test.dart`：`-t dsh-e2e` 才跑，真 dsh 调 `ask_user_question`，自动替用户答 Apple，断言工具结果与回复；
- `test/kernel/dsh_integration_test.dart`：跨票回归，prepare → 首条消息建会话 → 工具+审批 → 下一轮 → 出错轮 → release → prepare/resume → dispose；
- `test/kernel/dsh_restart_test.dart`：重启后再续（resume 而非 new）、历史与标题的读写、文件账本与目录；
- `test/kernel/dsh_capabilities_test.dart`、`dsh_notices_test.dart`：能力声明与提示去重、凭据预检；
- `test/kernel/dsh_bash_test.dart`：Git Bash 的发现顺序、跳过 WSL、无 git 时不跑 git、POSIX 返回 null；
- `test/kernel_ui_test.dart`：选择器、权限档位锁定、图片开关等界面接缝；
- `test/ide/git/commit_message_test.dart`（追加）：内核是 DSH 时问 dsh 并清洗回复、dsh 的错误原话上报、取消映射成取消；
- `test/chat/composer_polish_test.dart`（追加）：内核是 DSH 时提示词增强问 dsh 并把回答按标记还原、dsh 的错误原话上报、Claude 路径不动；输入框把会话的内核传给增强；
- `test/settings/dsh_page_test.dart`：`dshCode.path` 的往返。

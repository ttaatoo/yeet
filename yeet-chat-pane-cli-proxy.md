# Yeet Chat Pane：本机 CLI 的 GUI 代理

Status: 设计记录（未开 issue、未实现）
Date: 2026-09-03
Repo: [ttaatoo/yeet](https://github.com/ttaatoo/yeet)
Related: Yeet 0.1.61；T3 Code [pingdotgg/t3code](https://github.com/pingdotgg/t3code)

本文记录从「能不能做成更现代的 ADE」到「chat 作为一等 pane、只包本机 CLI」的全部讨论、调研和已拍板决策。不是实现 spec；实现时以当时代码为准，以这里的 *Decided* 为约束。

---

## 1. 问题

Yeet 今天是 AppKit + Alacritty PTY 的 macOS 终端。pane 只有：

| `Content` | 含义 |
|---|---|
| `session` | PTY / 活的 shell 或 agent TUI |
| `file` | 编辑器 |
| `browser` | 内嵌浏览 |
| `diff` | Git diff |

用户希望加一种 **chat pane**：看起来像 T3 Code / cc-gui 那种对话面，但 **Yeet 不直连 LLM、不持 API key、不卖 token**。Chat 只是已经安装并登录过的 coding CLI 的 GUI。

参考截图（用户提供）是 cc-gui 一类：会话列表 + 居中输入条 + `@` 文件 / `/` 命令。那是 Claude CLI 的壳。Yeet 要的是同一哲学，落在现有 recursive split 上。

---

## 2. 决策日志

| # | 决策 | 状态 | 备注 |
|---|---|---|---|
| D1 | Chat 做成 **一等 pane**（`Content.chat`），走现有 recursive split | Decided | 方案 A。不把整个窗口改成纯 chat 壳。 |
| D2 | Chat **不直连 LLM**。不调 Anthropic / OpenAI / xAI HTTP。 | Decided | 智能在 CLI 里。 |
| D3 | Chat 只包 **系统已安装的 CLI**（PATH 或显式 binary path）。未安装的灰掉。 | Decided | 与 T3「bring your own subscription」相同。 |
| D4 | 协议优先于 PTY：prompt 走 JSON-RPC / SDK / ACP，**禁止从终端文字猜 agent 状态**（延续 Yeet 现有原则）。 | Decided | 可保留可选 PTY pane 给人看 TUI。 |
| D5 | 第一刀只做 **Codex**：`codex app-server` + stdio JSON-RPC。 | Decided | 和现有 Unix socket 总线最像。 |
| D6 | Claude 放后面：用 Agent SDK（或独立 helper 讲 Yeet socket），**不要刮 TUI**。 | Decided | Claude 没有 Codex 那种 app-server。 |
| D7 | Cursor / Grok 走 **ACP**（`cursor-agent acp`、`grok agent stdio`）；OpenCode 走 `opencode serve` HTTP。第二波。 | Decided | |
| D8 | 现在 **不开 GitHub issue**。先文档 + UI 原型，选交互再开工。 | Decided | 2026-09-03 |
| D9 | 不搬 T3 的 Node WebSocket 中台 / Electron。控制面留在 Yeet 进程 + 现有 Unix socket。 | Decided | |
| D10 | 会话 resume 用 CLI 原生 cursor（Codex thread id / Claude session_id），**不是** PTY scrollback。 | Decided | |
| D11 | 权限弹窗画在 chat 里，回答走 adapter（`respondToRequest`），不是往 PTY 打 y/n。 | Decided | |
| D12 | 模型、登录、额度是 CLI 的事。Yeet 最多显示「未 `codex login` / 二进制不在 PATH」。 | Decided | |
| D13 | `@文件` 插入工作区路径；`/` 映射 Yeet 已有命令，不新造一套 slash 语言。 | Decided | |
| D14 | 多 agent 舰队布局（Agents 列 + chat + file + diff）是终局，不是第一刀。 | Decided | 方案 E 延后 |
| D15 | Chat 不当右侧 inspector 的第三 tab 当终局（Files/Git/Chat）。inspector 太挤。 | Decided | 方案 C 可作过渡，不作目标 |
| D16 | 浮层 composer 覆盖 PTY（Spotlight 式）可作快捷输入，但不能替代 chat pane。 | Soft | 可后期加 |
| D17 | 第一刀不改左侧 sidebar 的信息架构，不重做右侧 inspector 的 chrome。只加实验性可插拔 `Content.chat`。 | Decided | 被 D18 收窄 |
| D18 | Chat pane **不要**内嵌完整文件/diff。过程（thinking / tool / command / 审批）留在 chat；文件树和 diff **复用现有右侧 inspector**（及已有 `file`/`diff` pane）。Chat 卡只做摘要，点击则 reveal。 | Decided | 2026-09-03 |

未决（要等原型选择）：

| # | 问题 | 选项 |
|---|---|---|
| O1 | Chat 默认占位 | 与 PTY 左右劈 / 独占 tab / 主区 + 线程列表 |
| O2 | 线程列表放哪 | 复用 Yeet tab / 项目下二级列表 / T3 式 inbox |
| O3 | 未选 CLI 时 empty state | 只显示 PATH 上已安装的 provider 卡片 |
| O4 | 默认权限模式 | Supervised vs auto-accept-edits（应对齐 T3，默认 Supervised） |
| O5 | worktree | 复用已有 `+agent start --worktree`，chat 开线程时是否默认开 |

---

## 3. 讨论过、否决或降级的方向

五张早期产品草图（coral Yeet chrome）：

- **A Chat 一等 pane** — 采纳为骨架。
- **B Chat 当主工作区**（cc-gui 空状态 + pill）— 产品味对，但工程量和会话模型都大；可作皮肤，不可当唯一信息架构。
- **C Inspector Chat tab** — 改动最小，聊天面太窄。降级。
- **D 浮层 composer** — 适合 TUI agent 应急，没有气泡/可点 diff。降级为快捷键。
- **E 多 agent ADE** — 终局拼图，依赖 A 的 pane 契约。

否决：

- Yeet 自己做 runtime / 持 API key。
- 把 T3 的 `apps/server` Node + WS 嵌进 Yeet。
- SwiftUI 再堆一层会全量刷新的 inspector（PR #19 的教训）。
- 往 PTY `send-keys` 假装 GUI。

---

## 4. T3 Code 调研（实现，不是营销）

来源：`pingdotgg/t3code` `main`（约 2026-09），`AGENTS.md`、`docs/architecture/overview.md`、`docs/user/install.md`、`docs/user/permission-modes.md`、`apps/server/src/provider/*`。

### 4.1 一句话

T3 是 **agent harness control surface**：GUI 发现本机 CLI、spawn **无头结构化子进程**、把 native 事件投影成 thread。客户端从不写 PTY。

### 4.2 控制流

```
Web / Electron / Mobile
        │  typed WS  (thread.turn.start, thread.approval.respond, …)
        ▼
apps/server  OrchestrationEngine  (event sourced, SQLite)
        │
        ▼
ProviderAdapter  (per driver)
        │  JSON-RPC / SDK / ACP / HTTP
        ▼
本机 CLI  (codex / claude / cursor-agent / grok / opencode)
```

Adapter 形状（`ProviderAdapterShape`）：`startSession`、`sendTurn`、`interruptTurn`、`respondToRequest`、`streamEvents`。

统一事件大致包括：`user_message`、`assistant_message`、tool item（command / file_change）、`content.delta`、`turn.diff.updated`、`request.opened` / `request.resolved`、`user-input.requested`。

### 4.3 发现

默认二进制名：`codex`、`claude`、`cursor-agent`、`grok`、`opencode`。扫 PATH（Windows 含 PATHEXT），可设 Settings → Binary path。GUI 启动的 server 会 merge login-shell PATH，否则看不到 Homebrew。

### 4.4 Provider 表

| Provider | Spawn | 协议 | 注入用户消息 | Resume |
|---|---|---|---|---|
| Codex | `{codex} app-server [launchArgs]` | JSON-RPC stdio：`initialize`、`thread/start\|resume`、`turn/start` | `turn/start` | Codex thread id |
| Claude | SDK `query()` spawn `{claude}`（`pathToClaudeCodeExecutable`） | Claude Agent SDK（内部 stream-json；T3 **不**自己传 `--print`） | prompt async iterable / queue | SDK `session_id` |
| Cursor | `{cursor-agent} [-e endpoint] acp` | ACP JSON-RPC stdio | `session/prompt` | `session/load` |
| Grok | `{grok} [--permission-mode] agent stdio` | ACP JSON-RPC stdio | 同上 | 同上 |
| OpenCode | `{opencode} serve --hostname --port` | HTTP SDK `session.promptAsync` | HTTP | OpenCode session id |

关键文件：

- Drivers: `apps/server/src/provider/Drivers/{Codex,Claude,Cursor,Grok,OpenCode}Driver.ts`
- Adapters: `apps/server/src/provider/Layers/{Codex,Claude,…}Adapter.ts`
- Codex RPC: `packages/effect-codex-app-server`（spawn 见 probe：`codex app-server`）
- ACP: `packages/effect-acp`、`apps/server/src/provider/acp/*`
- PATH: `packages/shared/src/shell.ts`
- Launch args: `apps/server/src/provider/Layers/codexLaunchArgs.ts`

### 4.5 权限

T3 线程有 runtime mode：Supervised / auto-accept-edits / auto / full-access。审批 **inline**。

- Codex：spawn 时 `approvalPolicy` + sandbox；入站 `item/commandExecution/requestApproval`
- Claude：`permissionMode` + `canUseTool` → `request.opened`
- Cursor/Grok：ACP `session/request_permission`
- OpenCode：`permission.asked` / `permission.reply`

### 4.6 交互（产品，给 Yeet UX 抄的）

市面参考（Better Stack / flavio / Sidebar V2 文章，2026）：

- **三栏**：项目列表 | 线程列表 | chat（计划、tool call、文本分开）。
- **Sidebar V2**：线程 inbox，不是文件夹树。Active 卡片 + Settled 压缩行。
- Composer：model、reasoning、chat vs plan、supervised vs full access。
- 输入：macOS `⌘Enter` 发送；有的版本 `⌘Enter` 把当前 turn 丢后台并开新线程。
- 每 turn diff（unified / split）；集成终端是**另一块表面**，不是 chat。
- Worktree 隔离；做完可 commit / push / PR。
- 工具调用和推理视觉分离，避免被 CLI 刷屏淹没。

Yeet **不抄**：远程手机控制、Electron 壳、T3 自己的 checkpoint git ref 系统（除非以后要）、把项目模型改成「T3 项目管理器」（Yeet 已有项目栏）。

### 4.7 Claude 风险（为何第一刀不是它）

没有 `app-server`。会话是 SDK `query()` 循环；后续消息进队列而不是 `turn/start` RPC。Resume 依赖 `session_id`。审批绑在进程内 `canUseTool`。中断可能 SIGKILL。Yeet 若不愿嵌 `@anthropic-ai/claude-agent-sdk`，需要一个小 helper 或锁死的 stream-json CLI——两者都会漂。PTY expect 会在主题、分页、权限快捷键上炸掉。

---

## 5. 映射到 Yeet

**已有、要复用**

- `+agent start`、`agentKind`、`agent.wait`、Unix socket 总线
- `+agent start --worktree`（PR #18）
- Alacritty PTY pane（给人，不给 chat 当协议）
- Recursive `LayoutSnapshot`（加 `Content.chat` 几乎不改布局器）
- 项目栏、Files/Git inspector（AppKit）

**要加**

1. PATH probe（`codex` 先；其余灰显）
2. `Content.chat(provider, resumeCursor, …)` 快照字段
3. Codex adapter：spawn `codex app-server`（pipes，非 PTY），把 JSON-RPC 翻成 Yeet 事件，从 socket 进 chat view
4. 发送：输入条 → socket `chat.turn.start`（名字待定）→ adapter `turn/start`
5. 审批卡 → `chat.approval.respond`
6. Resume cursor 存在 layout/sidecar，不进 `TerminalHistoryStore`

**明确不在第一刀**

- Claude SDK、ACP、OpenCode HTTP
- 线程 inbox / Settled
- 一键 PR
- 远程/手机
- 新的 slash 语言

建议 socket 方法保持「Yeet 拥有、CLI 不懂 Yeet」：CLI 只懂自己的协议；Yeet adapter 翻译。

---

## 6. UX 原则（画原型时用）

1. 打开 chat pane = 选一个已安装 CLI，不是选一个云模型。
2. 空状态只展示 PATH 上找得到的 provider。没有 Codex 就写 `brew install` / `codex login`，不要空白 pill 假装能聊。
3. 运行中：文本气泡 + 独立的 tool 块 + 权限卡。不要把 `codex` TUI 嵌进 chat。
4. Diff 点开走现有 `diff` pane 或右侧抽屉，不要在气泡里塞整份 patch。
5. 可选「Show PTY」劈出 `session` pane，给还想盯 TUI 的人。
6. Provider chip 显示 `codex` + 识别状态（沿用 mint recognized 点），不是 `gpt-5` 营销名当主标签（模型名可作次级，来自 CLI）。
7. 权限默认 Supervised，和 T3 一致。
8. Chrome：Yeet Dark + coral `#E07A5F`，AppKit 密度，不要 Electron 大圆角聊天站。

---

## 7. 原型套数（供选择）

均遵守 D1–D16。差别只在信息架构。

| 代号 | 名字 | 抄谁 | 主张 |
|---|---|---|---|
| P1 | Split native | Yeet 自己 + 一点 Cursor | 项目栏不动；tab 内 chat \| 可选 PTY |
| P2 | T3 三栏 | T3 Code 经典 | 项目 \| 线程 \| chat；Yeet 项目栏可折叠成第一栏 |
| P3 | Thread inbox | T3 Sidebar V2 | 活动线程卡片 + Settled；chat 占主区 |
| P4 | Chat + turn diff | T3 / Codex desktop | 左对话（含审批），右当前 turn 的 diff |
| P5 | Empty + CLI picker | cc-gui 空状态，语义改成 CLI | 未开线程时居中选 Codex/Claude/… |

实现成本粗排：P1 < P4 < P5 < P2 < P3。

---

## 8. 参考链接

- https://github.com/pingdotgg/t3code
- https://t3.codes
- https://github.com/pingdotgg/t3code/blob/main/docs/architecture/overview.md
- https://github.com/ttaatoo/yeet
- Yeet agent 总线、worktree、AppKit inspector：PR #16–#19、#24

---



---

## 10. 合成方向（2026-09-03 后续）

用户选择：**P1 + P4 + P5 结合**。约束放宽：

- 左侧 sidebar **允许重新设计**（不再死守现在的项目列表形态）
- 右侧 inspector **允许重新设计**（不必只是 Files / Git / Info）
- 目标气质：**终端里的 T3 Code + Codex desktop**（pane 仍是一等公民：chat / session / file / diff 可任意劈）

### 10.1 状态机（三套图共用）

```
打开 Content.chat
  ├─ 未绑定 CLI        → P5 空态（只列出 PATH 上的二进制）
  ├─ 已绑定、无 turn    → 同一 pane 的 composer
  ├─ 进行中            → P1 对话：文本 / tool 块 / 审批卡
  ├─ 本 turn 有文件改动 → P4：自动露出 diff 表面（劈 pane 或 inspector tab）
  └─ 用户随时            → 再劈 Content.session（PTY，可选）
```

Chat **从不**住进 inspector。Diff / Files / Git 才是右侧审查面。PTY 永远是 pane，不是 chat 的背景。

### 10.2 三套完整窗方案

| 方案 | 左栏 | 中 | 右 | 像谁 |
|---|---|---|---|---|
| **S1 Dock** | 项目 + 其下线程（T3 经典三栏压成 Yeet） | 当前 chat pane；可再劈 PTY | inspector：Diff（当前 turn）/ Files / Git | T3 三栏的终端移植 |
| **S2 Inbox** | 线程 inbox（Active / Settled）+ 项目作 filter | chat 主区；需要时向下劈 PTY | 固定 turn-diff；Files/Git 收进 diff 头上的 tab | T3 Sidebar V2 + Codex diff |
| **S3 Terminal-first** | 瘦 icon 轨（项目） | 仍以 PTY 为默认 tab；chat 是你开的 pane | 原 inspector 升级：Files / Git / **Turn** | 现在的 Yeet + 最小侵入 |

S1 是「Yeet 变成终端版 T3」。S3 是「Yeet 还是终端，chat 长进去」。S2 最像 Codex/T3 任务管理器。

### 10.3 右侧 inspector 新契约

Tabs：`Files` | `Git` | `Turn`。

- `Turn`：当前 chat pane 焦点 turn 的 unified/split diff。无改动时 empty：「本 turn 还没有文件」。
- 焦点不在 chat 时，`Turn` 灰显或回落到 Git。
- Chat 自己的审批卡留在 chat pane，不搬到 inspector。

### 10.4 左侧 sidebar 新契约

- 第一等对象变成 **thread**（一次 CLI 会话 / 一个 Codex thread id），不是文件。
- 每个 thread 记住：provider（codex）、resume cursor、可选 worktree、绑着的 pane id。
- 项目仍在：S1 里当分组；S2 里当 filter；S3 里当现在的项目栏。

## 9. 下一步

用户从 P1–P5 选交互（可混合，例如「P1 骨架 + P4 的 diff 抽屉」）。选完再开 issue / spike，范围锁在 Codex-only `Content.chat`。


---

## 11. 实验性 Chat Pane（已拍板，替代「先改窗」）

比 S1–S3 大刀阔斧更合理，原因：

- pane 已是一等公民，加 `Content.chat` 不碰项目模型和 inspector 性能（#19 的坑）。
- 失败可以关：设置里关掉 / 不出现在 pane 菜单，零迁移成本。
- T3 的信息密度（thinking、tool、command、turn diff）本来就该发生在**对话表面**，不必先为它重做两栏。
- Codex `app-server` 事件已经按 turn 分组；先在一个 NSView 里投影，比先发明线程 inbox 更验证协议。

### 11.1 范围内

在 **这一个 pane** 里实现（可插拔，默认实验开关）：

1. Empty：P5 CLI picker（PATH 上的 `codex` 等）
2. Composer：发送 → adapter `turn/start`（不 write PTY）
3. 消息流按 T3 分块：
   - assistant text
   - **thinking / reasoning**（可折叠）
   - **tool use** 卡（读/改文件，路径 + ±line）
   - **command** 卡（命令、exit、duration、可展开 output preview）
   - **output / stdout** preview（截断，点开仍在 pane 内展开，不跳 inspector）
4. **Turn 文件摘要**（路径 + ±line）。完整 hunk 不进 chat，点进右侧 Git/Files（D18）
5. **审批卡**：Allow / Deny → `respondToRequest`
6. 可选：同一 tab 里再劈一个真正的 `session` PTY（用户主动，不是默认）

### 11.2 范围外（第一刀）

- 重做左侧 sidebar（项目→线程、inbox、Settled）
- 重做右侧 inspector（加 Turn tab）
- 线程 inbox、一键 PR、远程
- Claude SDK / ACP / OpenCode（仍 Codex-only）
- Yeet 调 LLM HTTP

### 11.3 可插拔

- `Content.chat` 快照字段存在，但创建入口藏在实验菜单 / Settings「Experimental: Chat pane」
- 关开关：已有 chat pane 仍能打开（避免丢会话），不能新建
- 不写进默认新窗口布局
- adapter 进程随 pane 关闭（或随 tab 关）tear down；resume cursor 可留在快照里以便再开

### 11.4 和现有 pane 的关系

| 还用现有 pane | 何时 |
|---|---|
| `file` / `diff` | 用户从 preview 卡 **Open in pane**（可选，第一刀可以只有 pane 内 preview） |
| `session` | 用户显式 split，看 TUI |
| inspector Files/Git | 完全不动 |

默认路径：人待在 chat pane 里把一轮看完。


---

## 12. Chat 太重 → 过程在 chat，产物在 inspector（D18）

全部塞进 chat pane 不合理：T3 把 diff/output 堆在时间线上，是因为它没有 Yeet 这种已经做好的 Files/Git inspector。Yeet 再复制一份会：

- 时间线被 hunk 和测试日志撑爆，对话滚不动
- 和右侧 Git 状态双份真相
- 第一刀变成「做一个迷你 IDE」而不是验证 CLI adapter

### 12.1 切开

| 留在 chat pane | 复用已有表面 |
|---|---|
| 空态 CLI picker | — |
| composer、审批 Allow/Deny | — |
| thinking（折叠） | — |
| tool 卡：**一行摘要**（Edit `GitStatusModel.swift` +24 −4） | 点击 → inspector 选中该文件，Git 的 diff 或已有 `Content.diff` |
| command 卡：**命令 + exit + duration** | 点击 → 在 chat 内展开短 preview（≤20 行）或劈 `session` 看全量；不在 inspector 里塞终端 |
| turn 文件列表（短） | 默认打开/聚焦右侧 Git；工作区本来就会脏 |

不新增 Turn tab（那是改 inspector 信息架构）。Git 已经按工作区列改动；agent 改文件后现有 Git 模型刷新即可。

### 12.2 点击契约

- tool 卡点路径：`Files` 树 reveal + 若 Git 有 diff 则切到 Git 并选中该 path（现成选中逻辑）
- 「Open in pane」可选：打开已有 `file` / `diff` pane（第一刀可以没有，inspector 够用）
- 审批仍然只在 chat：inspector 不负责 Allow/Deny

### 12.3 第一刀视觉重量

Chat 时间线 ≈ T3 的文字 + 窄卡片。宽 diff、文件内容、完整 test log **不进气泡**。

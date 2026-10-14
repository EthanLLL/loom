# 后端:Claude Code 与 Codex

loom 把 agent 本体交给这两个 CLI。本文是**实测出来的**协议事实和由此确定的设计 ——
不是读文档推的,每条带数字的都跑过。loom 自己的结构在 [architecture.md](architecture.md)。

- Claude Code `2.1.296`,Codex `0.162.1`,macOS 26.7.1 / arm64
- 实测日期 2026-10-14

---

## 1. 为什么不自研 loop

2026-10-14 之前 loom 自己跑 agent loop:`bedrock.ex`、`tools/*`、`compactor.ex`、
`memory.ex`、`prompt.ex`、`workspace.ex`,约 2,400 行。拆掉的理由只有一条:

**上下文管理"自己写也不贵"在真做 compaction + memory 的时候被证明是贵的,而那恰好是
最不差异化的部分。** CC 的 `--autocompact` 和 Codex 的 `thread/compact/start` 是一个
flag 换掉一周的工作。工具质量也不是一个量级。

代价是产品锁定。对冲办法是同时支持两家,边界就是 `Loom.Agent.Backend` behaviour。

剩下的全是 loom 的差异化:多端同步、PTY、认证、落盘、UI。

---

## 2. 两边的状态模型不对称

**适配器必须按 turn 抽象,不能按进程抽象。**

### 2.1 Claude Code:一个会话一个长驻进程

会话落在 `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`。`--session-id <uuid>` 指定,
`--resume <uuid>` 继续,**跨 cwd 有效**(实测:在 `/private/tmp` 建的会话从
`/tmp/otherdir` resume,正确回忆出上一轮内容)。

**启动成本是每个会话一次,不是每个 turn 一次。** 实测同一个进程连续三个 turn,第二条
消息是等 `result` 到了之后才写的:

```
turn 1(冷)  init 4.65s   首字 9.70s   done 9.74s   rss 275MB
turn 2        init 0.02s   首字 1.91s   done 1.93s   rss 277MB
turn 3        init 0.01s   首字 1.65s   done 1.76s   rss 279MB
```

turn 3 正确答出前两轮说过的内容 —— 对话真的活在进程里,不是靠 `--resume` 重读文件。
内存每轮只涨约 2MB。

三条路对比:

| | 第一个 turn | 后续 turn | 空闲内存 |
|---|---|---|---|
| 每 turn 冷启 | ~6s | **每次 ~6s** | 0 |
| 每 turn 预热 | ~6s | ~0s | 275MB |
| **长驻复用(选这个)** | ~6s | **~0.02s** | 275MB |

预热(上个 turn 结束就 spawn 下一个)和长驻**占的内存完全相同**,还要白白 churn 一个
275MB 进程 —— 没有任何好处。

让它划算的是 `release/1` + 空闲定时器(15 分钟):人在用就值这 275MB,人走了就是纯浪费。
对话不受影响,下次重付一次冷启动。

> 那 ~6 秒是在一台**公司管的 Mac** 上量的(toolbox shim + 企业初始化流程)。服务器上干净
> 装一份大概率明显更快,**当上限看**,部署后重新量。

### 2.2 Codex:一个全局 app-server 托管所有会话

`codex app-server` 是讲换行分隔 JSON-RPC 的 stdio 进程。协议规模:**105 个 client
方法、~85 个 server notification、10 个 server→client request**。

```bash
codex app-server generate-json-schema --out <dir>
```

→ 照它生成解码器,不要手写。

实测同一个进程里 `thread/start` 两次拿到两个 threadId(cwd 还可以不同),两个 turn
**并发**跑完(8.8s / 8.9s),各自记住自己的暗号(ALPHA / BETA)互不串台。所以 loom
常驻的子进程**只有一个**,RSS ~24MB(11 launcher + 13 本体)。

`thread/resume {threadId, excludeTurns: true}` 只要 threadId,cwd 从 thread 记录里自己
带回来。实测换一个全新进程 resume 同一个 threadId,接着问"你刚写的是哪个数字"答
"Seven"。

生命周期:`thread/start` → `turn/start` → notification 流 → `turn/completed`。

---

## 3. 追加输入:两边都原生支持 mid-turn 注入

这是本次调研最有价值的一条,而且一开始判断错了。

### 3.1 Claude Code:写 stdin,在下一个工具边界注入

```
[  0.0] SEND task: 分 5 步跑 echo + sleep 4
[  7.2] tool_use Bash: echo step-one; sleep 4
[ 11.4] tool_result: 'step-one'
[ 14.0] tool_use Bash: echo step-two; sleep 4
[ 16.0] SEND interject: STOP. 放弃剩下的步骤,只说 BANANA     ← turn 正跑着
[ 18.0] tool_result: 'step-two'
[ 18.0] USER REPLAY: 'STOP. Abandon the steps...'            ← 同一刻被注入
[ 19.7] assistant: 'BANANA'
[ 19.7] ===== RESULT #1 (success) =====                      ← 只有一个 result
```

**一个 `result`。** 新消息在下一个 tool_result 边界进了同一个 turn,模型连着工具输出
一起看到。**没有工具边界可插的情况**(纯文本生成中)会落到下一个 turn —— 早期一次只测
了这种情况,所以误判成"CC 只会排队"。

我们这边就是一行 `Port.command`,**不做任何边界判断** —— 等待发生在 CC 进程内部。

### 3.2 Codex:`turn/steer`,立刻注入

```
[ 16.4] exec: 'echo step-two; sleep 4'
[ 22.5] SEND turn/steer (expectedTurnId=ec2af0)
[ 22.5] userMessage INJECTED: 'STOP. Abandon the steps...'    ← 0.0s
[ 24.6] agent: 'BANANA'
[ 24.6] ===== turn/completed #1 =====                          ← 一个 turn
```

`expectedTurnId` 让它防竞态:turn 已经结束就失败,而不是把消息错投到下一个 turn。
失败时 loom 把消息落进队列,下个 turn 带上 —— **晚到胜过丢掉**。

### 3.3 通过 Session 的端到端验证

```
========== claude_code ==========          ========== codex ==========
t1 冷: running@4.8s  done@7.7s             t1: running@0.0s  done@3.0s
t2 热: 1462ms                              t2: 1982ms
t3: submit → {:ok, :steered}               t3: submit → {:ok, :steered}
    assistant "BANANA" @29.6s                  assistant "BANANA" @22.5s
    turns=3  ← 并入同一个 turn                 turns=3
```

---

## 4. 中止

### 4.1 Claude Code:走 control 协议,不要 kill

```
[  7.0] OUT> {"type":"control_request","request_id":"int_1",
              "request":{"subtype":"interrupt"}}
[  7.2] IN < control_response {"subtype":"success","response":{"still_queued":[]}}
[  7.2] IN < result/error_during_execution  terminal_reason=aborted_streaming
[ 25.0] --- 进程仍然存活 ---
```

kill 也能用(实测 turn 中途 SIGKILL 整个进程组,会话仍可 `--resume`:记住暗号 ZEBRA →
中途 killpg → resume 后答出 ZEBRA),但会烧掉热进程让下个 turn 变冷。

代价是被中止的 turn 报 `result/error_during_execution` —— **不是错误**。handle 上的
`interrupted?` 让 `decode` 认出"这是我们要的"并闭嘴,否则会给用户报一个他自己造成的失败。

### 4.2 Codex:`turn/interrupt`

```
resp {} → thread/status/changed {idle} → turn/completed {status: "interrupted"}
```

形状更干净,不用从错误码反推。要求 `codex_turn_id` 落盘。

---

## 5. 事件映射

### 5.1 Claude Code

| 输出 | loom |
|---|---|
| `system/init` | `:status` → `:running`;记 `session_id` |
| `stream_event` + `content_block_start` | `:block_start` / `:tool_use_start` delta |
| `stream_event` + `content_block_delta` | `:text` / `:thinking` delta |
| `stream_event` + `message_start` | **记录真实上下文**(见 §6.1) |
| `assistant` | `:assistant_text` / `:thinking` / `:tool_use` 事件 |
| `user` (tool_result) | `:tool_result` |
| `result/success` | `:turn_done` + usage |
| `result/error_during_execution` + `interrupted?` | 什么都不发 |
| `result/*` 其他 | `:turn_failed` |
| `system/permission_denied` | automode 下不该出现,`Logger.error` |

`stream_event` 包的是原始 Anthropic SSE,正是 `block_id` 协议当初照着设计的东西 ——
这一层几乎零成本。`input_json_delta` / `signature_delta` 刻意丢掉:半截 JSON 参数对
客户端没用,权威版本在 `assistant` 消息里。

### 5.2 Codex

| notification | loom |
|---|---|
| `turn/started` | `:status` → `:running`;记 `turn.id` |
| `item/started` (agentMessage / reasoning) | `:block_start` delta |
| `item/agentMessage/delta` | `:text` delta |
| `item/reasoning/{textDelta,summaryTextDelta}` | `:thinking` delta |
| `item/started` (commandExecution / fileChange / mcpToolCall / webSearch) | `:tool_use` |
| `item/*/outputDelta`、`item/mcpToolCall/progress` | `:tool_output` delta |
| `item/completed` | `:assistant_text` / `:thinking` / `:tool_result` |
| `thread/tokenUsage/updated` | 上下文和窗口(见 §6.1) |
| `turn/completed` status=interrupted | 什么都不发 |
| `turn/completed` | `:turn_done` |
| `thread/compacted` | 一行 notice |

工具名映射:`commandExecution` → `shell`、`fileChange` → `apply_patch`、
`webSearch` → `web_search`、`mcpToolCall` → `item["tool"]`。

**`exitCode != 0` 要覆盖 `status`** —— codex 的 `status: "completed"` 描述的是"这次调用
完成了",不是"命令成功了"。一个编译失败被显示成成功,正是让 transcript 说谎的那类 bug。

**结构化进度通用序列化后照样发**,只去掉路由用的 `threadId`/`turnId`/`itemId`。流式的
意义就是证明有东西在动,一个没专门解析过的形状仍然是证据。

---

## 6. 坑

### 6.1 turn 级 usage 是累加,不是上下文大小 ⚠️

**两边都踩了。** agentic turn 每次工具调用都要重读一遍缓存前缀,所以 turn 级的 usage
是真实上下文的好几倍。同一个四步 shell 任务:

CC 的逐次调用:
```
call 1: in=2  cache_read=10112   cache_write=20958  → 31072
call 2: in=2  cache_read=31070   cache_write=  141  → 31213
call 3: in=2  cache_read=31211   cache_write=  359  → 31572
call 4: in=2  cache_read=31570   cache_write=  141  → 31713
call 5: in=2  cache_read=31711   cache_write=  141  → 31854   ← 真实
result: in=10 cache_read=135674  cache_write=21740  → 157424  ← 累加
```

Codex:
```
after echo a   last.input=15154   total.total=15216
after echo b   last.input=15264   total.total=30519
after echo c   last.input=15351   total.total=45909
after echo d   last.input=15436   total.total=61384
final          last.input=15522   total.total=76954
```

对话一直是 31.8K / 15.5K。把累加值当上下文显示,会告诉用户"你在 157K"而其实是 32K。

**正确的取法:**

- **CC**:每个 API 调用在 `stream_event / message_start` 报自己的 usage,**最后一个赢**。
  窗口从 `result.modelUsage[model].contextWindow` 取(opus-5[1m] = 1,000,000)。
- **Codex**:`thread/tokenUsage/updated` 直接给 `last`(上下文)、`total`(累加)和
  **`modelContextWindow`**(实测 258,400)。只用 `last`。

修正后实测:`claude_code: 31847 / 1000000`,`codex: 15497 / 258400`。

**成本不显示。** Codex 根本不报 USD(订阅制),一边有一边没有的数字比没有更糟。

### 6.2 Codex 的 writer lock 会变成僵尸 ⚠️

Codex 对每个 thread 强制单写者,锁是 `<codexHome>/thread-writer-locks/<threadId>.lock`。
实测进程被 SIGKILL 后锁**不自动释放**,再 resume 拿到:

```
-32600  thread 01a1384e-… already has an active writer
```

后续 `turn/start` 直接报 `thread not found`。锁文件是 0 字节,`pkill` 掉所有 codex 进程后
**依然**被拒;删掉那个 `.lock` 之后 resume 立刻成功。

`Codex.Server` 的处理:`thread/resume` 回 `-32600 active writer` 就删掉锁重试一次,再
失败就报错不再重试。`codexHome` 从 `initialize` 的响应里读,不假设 `~/.codex`。单租户
单实例下"锁是我们自己的"这个判断是安全的。

**这个自愈逻辑在真实会话上触发过** —— 重启后 `restored 2/2`。

### 6.3 CC 的三级进程树

`claude` 是 shim(12MB)→ launcher(13MB)→ 运行时(199MB)。**只杀最外层会留两个孤儿**:

```
descendants before kill: [8302, 8314]
   8301  11 MB  claude            ← 杀这个
   8302  24 MB  .../bin/claude
   8314 224 MB  .../claude
--- 3s 后 still alive: 8302, 8314 ---
```

所以 `kill_tree/1` 必须**先用 `pgrep -P` 递归快照再杀** —— 父进程一死,子进程被 reparent
到 init,父子关系就查不到了。

另外 `Port.close/1` **之后** Erlang 仍会投递 `exit_status 137`(我们自己的 SIGKILL),
得专门吞掉,否则每次 release 都打一行日志。

### 6.4 走过的两个弯路(别改回去)

- `result` 处**曾经 teardown 进程** → 每个 turn 都要重新冷启。
- 更早一版**既不 teardown 也不保留** → 漏一个 275MB 进程,而且 `port` 还是 live 的,
  后续 turn 全部撞上 "already running" 守卫,**会话永久卡死**。

现在是"保留 + 空闲定时释放"。

### 6.5 被打断的 turn,partial 文本不进后端历史

实测中断后 `thread/items/list` 只剩 `userMessage` 和 `reasoning`,流出来的 agentMessage
不在历史里。所以 loom 的 `events.jsonl` 是展示真相、后端是推理真相,重新 attach 时
不要拿后端历史去校正事件流。

### 6.6 CC 的配置面

```
--setting-sources ""     20 tools,  0 MCP, 15,555 prompt tokens
--setting-sources user   90 tools, 67 MCP, 31,001 prompt tokens   ← 用这个
```

`--setting-sources ""` 单独用也会把 MCP 干掉 —— MCP 配置是从 settings 来的。保留 `user`、
排除 `project`/`local`,因为所有会话都在 home 下,不该被路边某个
`.claude/settings.local.json` 改行为。提示词翻倍但第一个 turn 之后全是 cached read。

实测 MCP 确实到位了:模型报出 `mcp__agentcore-websearch__…___WebSearch`。

两个看着诱人但不能用的:

- `--strict-mcp-config` 砍一半提示词,代价是**所有 MCP server 都没了**。MCP 是现在唯一的
  扩展点。
- `--bare` 砍到 1,604 token,但**连 CC 自己的 system prompt 一起砍了**,只剩
  `Bash, Edit, Read`。那是我们换后端的全部理由。

还有:`claude -p "<提示词>"`(argv 形式)会**等 stdin 3 秒**才开跑
(`no stdin data received in 3s`),而且得把用户任意文本塞进命令行。所以用
`--input-format stream-json`,port 开好立刻写。`--output-format stream-json` 必须配
`--verbose`,否则直接报错退出。

### 6.7 Codex 的全量 hydration 已废弃

`thread/resume` 不带 `excludeTurns: true` 会收到 deprecation 通知。历史靠
`thread/turns/list` + `thread/items/list` 分页拿 —— 后者**不需要先 resume、不需要 cwd、
不占 writer lock**,纯读,重建 transcript 不用抢锁。

### 6.8 共享即连坐

`Codex.Server` 挂了,所有 codex 会话一起掉。退出路径要做三件事:

1. 所有 in-flight 的 JSON-RPC 调用方收到 `{:error, :server_down}`
2. **所有 thread owner 收到 `{:codex_down, thread_id}`** —— 没有这个,会话会永远等一个
   已经没人在跑的 turn
3. 清掉所有 writer lock

`Backend.Codex` 把它翻成 `:turn_failed` 并打 `stale?`,下个 turn 开始前先 `thread/resume`
重新 attach。所以一次重启对用户的可见影响只有**死掉的那一个 turn**。

OS 进程的重生在 GenServer **内部**做(1s → 60s 指数退避),不是靠自己死掉让 supervisor
重启:一个立刻失败的 `codex`(没装、登录过期)会 crash-loop,而 permanent child 的
crash-loop 会把整个 application 带下去。内部重生则退化成 `port: nil`,所有 call 立即回
`{:error, :server_down}`,loom 其余部分照常跑。

---

## 7. 不做的

**权限确认。** Codex 侧是免费的 —— server→client 的 JSON-RPC request
(`item/commandExecution/requestApproval`、`item/fileChange/requestApproval`、
`item/permissions/requestApproval`、`item/tool/requestUserInput`、
`mcpServer/elicitation/request`),决策枚举 `accept` / `acceptForSession` / `decline` /
`cancel`,还有 `serverRequest/resolved` 通知让多端看到"已被别人答了"。形状和我们做过的
`ask_user` 几乎一样。

CC 侧不是:实测 `--permission-mode manual --permission-prompts host` **自动拒绝**(发
`system/permission_denied` + `is_error` 的 tool_result)。补发 `control_request/initialize`
握手(成功回了 control_response)**仍然自动拒绝**。有文档的路子是
`--permission-prompt-tool <mcp_tool_name>`,得自己起个 MCP server。

两边不对称、产品上也不需要,所以**都走 automode**:CC `--permission-mode bypassPermissions`,
Codex `approvalPolicy: "never"` + `sandbox: "danger-full-access"`。

但**意料外的 server→client request 必须主动拒绝,不能忽略** —— 没人应答会让 turn
永久挂住,连错误都没有,比拒绝糟得多。

**自己做 compaction / memory。** 后端在做:CC 的 `--autocompact <auto|tokens>`,Codex 的
`thread/compact/start` + `thread/compacted`。memory 退化成我们递过去的一个字符串
(`thread/start` 的 `developerInstructions` / CC 的 `--append-system-prompt`)。

---

## 8. 复现命令

```bash
# CC:基本流式(stream-json 必须配 --verbose)
echo '{"type":"user","message":{"role":"user","content":"hi"}}' \
| claude -p --verbose --input-format stream-json --output-format stream-json \
         --include-partial-messages --session-id "$SID" \
         --setting-sources user --permission-mode bypassPermissions

# Codex:导出全量协议 schema
codex app-server generate-json-schema --out /tmp/codexschema

# Codex:跑一个 thread(换行分隔 JSON-RPC 走 stdio)
codex app-server
# {"id":1,"method":"initialize","params":{"clientInfo":{"name":"loom","version":"0.1"}}}
# {"id":2,"method":"thread/start","params":{"cwd":"…","sandbox":"danger-full-access",
#                                           "approvalPolicy":"never"}}
# {"id":3,"method":"turn/start","params":{"threadId":"…","input":[{"type":"text","text":"…"}]}}
# {"id":4,"method":"turn/steer","params":{"threadId":"…","expectedTurnId":"…","input":[…]}}
# {"id":5,"method":"turn/interrupt","params":{"threadId":"…","turnId":"…"}}
```

关键参数(取自 schema):

```
TurnStartParams      required: threadId, input
                     optional: approvalPolicy, sandboxPolicy, model, effort, cwd, …
TurnSteerParams      required: threadId, expectedTurnId, input
TurnInterruptParams  required: threadId, turnId
ThreadStartParams    optional: cwd, sandbox, approvalPolicy, model,
                               baseInstructions, developerInstructions, ephemeral, …
ThreadResumeParams   required: threadId   optional: excludeTurns, cwd, model, …

AskForApproval  = "untrusted" | "on-request" | "never" | {granular: {...}}
SandboxMode     = "read-only" | "workspace-write" | "danger-full-access"
```

---

## 9. 脑洞

**自动路由后端。** 新建会话时不让用户选,而是用一次极轻量的 LLM 调用根据第一句话判断
交给 CC 还是 Codex。现在不做 —— 它只影响"第一次 `start/2` 之前选哪个实现",适配器边界
不用动。

# Loom 架构

一个单租户的云端 agent 前厅:浏览器/手机多端连同一个会话,状态常驻服务端并落盘,
agent 本体交给 Claude Code 或 Codex。

- 本文是 **loom 自己**的结构。
- 后端(CC / Codex)的协议细节和实测数据在 [backends.md](backends.md)。
- PTY 终端(`Loom.Terminal.*`)保留,和 agent 共存 —— 那条路是给人用的终端。

最后更新 2026-10-14,159 个测试。

---

## 1. 它不做什么

**不做多租户。** 那需要 Firecracker / gVisor 级别隔离,是另一个量级的工程。单密码 →
token,多设备共用凭据,agent 以 BEAM 同一 uid 运行,无沙箱。

**不做权限确认。** 跑在自己的服务器上,全程 automode。agent 要删文件就删,这是刻意的
—— 没人在旁边按 y 的场景里,确认框只会让它停在那儿。

**不自己跑 agent loop。** 工具、上下文管理、system prompt、compaction、memory 全部属于
后端。loom 2026-10-14 之前自研过一套(~2400 行),拆掉的理由见
[backends.md §7](backends.md)。

**不给会话工作目录。** 创建接口不收 `cwd`,所有会话都在用户 home 下。"这次在搞哪个
项目"是对话里的事实,不是配置 —— 用户说"咱们搞 `~/dev/newproject`",这句话进了上下文,
模型自己组装路径。

---

## 2. 一个会话 = 一个 GenServer

```
Loom.Agent.Session        ← 一个会话一个进程,restart: :transient
  ├─ Loom.Agent.Backend   ← behaviour,后端适配器
  ├─ Loom.Agent.Store     ← meta.json + events.jsonl
  └─ PubSub "agent:<id>"  ← 事件/delta 广播
```

**为什么 1:1 而不是一个进程管多个会话**:turn 状态和失败域都是按会话划分的 —— 一个
畸形响应把一个会话打崩,不该连带九个别的会话的 transcript。共享进程还会让互不相关的
对话排在彼此的慢活后面。

会话进程**不持有任何 socket**。所有浏览器都关掉,turn 照样跑完 —— 这是整个产品的前提:
发指令、合上电脑、到家打开手机看进度。

### 2.1 状态机

```
:idle ──提交──→ :starting ──后端 init──→ :running ──turn 结束──→ :idle
                                            │
                                     interrupt│
                                            ↓
                                      :interrupted ──提交──→ :starting
```

- **`:starting`** 是后端启动的间隙。CC 第一个 turn 要几秒,没有这个状态 UI 看着像挂了。
- **`:interrupted`** 存在的唯一目的是**压住"空闲且队列非空就出队"这条规则**。按停之后
  不能有东西自己动起来,那不是 ESC 的语义。要继续就打字,新消息和暂存的一起发出去 ——
  所以没有 resume 按钮,恢复路径和普通提交是同一条代码。

### 2.2 提交:跑着的时候直接注入

| 当前状态 | 行为 | 返回 |
|---|---|---|
| `:idle` | 起一个新 turn | `:started` |
| `:starting` / `:running` | **注入当前 turn** | `:steered` |
| 注入被拒 | 落队列 | `:queued` |
| `:interrupted` | 队列 + 新消息合并,起 turn | `:started` |

两个后端都原生支持 mid-turn 注入([backends.md](backends.md) 有实测),所以把消息压在
队列里等 turn 结束,等于把"打一句话就能当场把它拉回来"白白扔掉。

**队列只剩两个来源**:`:interrupted` 下打的字,和注入被拒的消息(Codex 的
`expectedTurnId` 对不上时会拒绝而不是错投)。队列落盘,因为重启不能把用户特意停下来的
消息冲出去。

### 2.3 崩溃恢复

会话进程挂掉 → supervisor 用**原始 spec** 重启 → `init/1` 发现盘上有 `meta.json` →
reattach 而不是新建。盘上的状态永远赢过 spec,否则会给一个已有后端会话的 session 再绑
一个新的。

**中途挂掉 = 非自愿的 interrupt。** 老的自研 loop 能接着跑,因为 loop 是它自己的;后端
的 turn 是本节点的子进程,跟着节点一起死,接不回来。而且重发更糟 —— 用户那条消息已经在
后端自己的历史里,模型会看见两遍。所以回来是 `:interrupted` + 队列保留 + 一个带原因的
status 事件(不然客户端只看到一段无解释的空白)。

---

## 3. 客户端协议:两层,区别就是全部设计

```
event  — 有 seq,落 events.jsonl,重连时重放。真相。
delta  — 无 seq,瞬时,永不重放。打字机。
```

delta 按 `block_id` 追加到一个 placeholder;携带同一个 `block_id` 的 event 到达时
**整体替换**它。所以流断在半句话上零成本:placeholder 被下一个 event 盖掉,或者重连时
丢掉再从 `since_seq` 取回。

客户端要认的 delta 只有六种:

| type | 载荷 | 来源 |
|---|---|---|
| `:block_start` | `block_type` | 两边 |
| `:block_end` | — | 两边 |
| `:text` | `chunk` | 两边 |
| `:thinking` | `chunk` | 两边 |
| `:tool_use_start` | `name`, `id` | 两边 |
| `:tool_output` | `chunk` | 只有 Codex |

`:tool_output` 用**和工具卡片相同的 `block_id`**,所以前端是往已渲染的那张卡里追加,
`:tool_result` 事件到达时整体替换 —— 和文本块完全同一套模式,不是新概念。

### 3.1 seq 归 loom

`Loom.Agent.Session` 是 `events.jsonl` 的**唯一写者**,`seq` 由它分配。后端自己的 id
(CC 的 message uuid、Codex 的 `turnId`/`itemId`)作为 `backend_ref` 塞进 payload,
重新 attach 时靠它去重,而不是比内容。

### 3.2 多端

每次状态变化都是一个 event,广播在 `"agent:<id>"`。客户端带上自己见过的最后一个 `seq`
加入,只拿缺的那段。进程不维护订阅者列表 —— PubSub 负责扇出,没人听的广播是 no-op,
这正是"状态活过浏览器"需要的性质。

channel 层(`LoomWeb.AgentChannel`)不持有任何会话状态,只做转发。

---

## 4. 落盘

```
<data_dir>/<id>/meta.json     header,原地重写(temp + rename)
<data_dir>/<id>/events.jsonl  规范化的 transcript,append-only
```

**没有消息日志。** 以前有一份原始 API messages,因为 loom 自己跑 loop 需要有东西可以
恢复。现在对话归后端所有(CC 在 `~/.claude/projects/…`,Codex 在它的 thread store),
在这儿再存一份就是第二个真相源,而且没有东西能用来对账。

所以 **`events.jsonl` 只是展示真相**。它可以合法地和后端历史不一致 —— 被 interrupt
之前流出来的文字在用户看过的 transcript 里,但后端会丢掉它。**不要拿一边去校正另一边。**

日志用 `:sync` 打开,每次 append 落盘后才返回。一个 turn 要几秒,每行几毫秒 fsync 是
免费的 —— 换来的是盘上状态永不落后于模型已经动作过的状态。末尾被截断的半行在读取时
直接丢掉,所以 append-only 日志不需要任何恢复流程。

`meta.json` 的关键字段:

```jsonc
{
  "backend": "claude_code",      // 终身不变
  "cc_session_id": "...",        // 或 codex_thread_id / codex_turn_id
  "status": "idle",              // 重启据此判断是否中途挂掉
  "queue": ["..."],              // 被 park 的消息
  "seq": 42,
  "context_tokens": 31847,
  "context_window": 1000000
}
```

> **坑**:`Store.read_meta/1` 用 `String.to_existing_atom/1`,atom 不存在就退回字符串键。
> Elixir 模块懒加载,boot 时 adapter 模块可能还没加载,`:cc_session_id` 就不是已存在的
> atom。所以 adapter 一律用 `Backend.meta_get/2` 读,两种键都接受。这条真的让一个会话
> 恢复失败过。

---

## 5. 后端绑定是终身的

创建会话时必须选 `claude_code` 或 `codex`,**没有默认值**。对话存在各自后端的 store 里,
换后端等于丢掉整段历史,没有可迁移的东西 —— 猜错不可恢复,所以宁可让调用方说清楚。

`POST /api/agents` 缺 `backend` 返回 422。UI 上侧边栏的 `+` 是个下拉,不是一个"直接
建一个"的按钮。

标题(`/rename`、双击标题栏)**只存在 loom 这一侧**,不透传后端 —— 它是侧边栏的展示
属性,透传会引入"谁是真相"的双向同步问题。

---

## 6. 监督树

```
Loom.Supervisor
├─ Phoenix.PubSub
├─ Registry (Loom.Terminal.Registry)       ← PTY
├─ DynamicSupervisor (Terminal.Session…)
├─ Loom.Terminal.Layout
├─ Registry (Loom.Agent.Registry)
├─ DynamicSupervisor (Loom.Agent.SessionSupervisor)
│    max_restarts: 20 / 5s —— 默认的 3 次会让几个互不相关的会话一起崩时
│    把这个 supervisor 连带所有活会话一起带下去
├─ Task.Supervisor (Loom.Agent.TaskSupervisor)
├─ Loom.Agent.Codex.Server                 ← 全局一个 codex app-server
├─ Loom.Agent.Bootstrap                    ← 开机恢复所有落盘会话
└─ LoomWeb.Endpoint
```

`Codex.Server` 的 OS 进程重生是**在 GenServer 内部**做的(指数退避),不是靠自己死掉让
supervisor 重启 —— 一个立刻失败的 `codex`(没装、登录过期)会 crash-loop,而 permanent
child 的 crash-loop 会把整个 application 带下去。详见 [backends.md](backends.md)。

---

## 7. 前端

```
App.tsx      布局:| sidebar | chat | terminals |,三栏恒定
Sidebar.tsx  会话列表 + 后端徽章 + 新建下拉
Chat.tsx     timeline / 工具卡片 / 队列面板 / composer
agent.ts     纯函数:applySnapshot / applyEvent / applyDelta / buildTimeline
useAgent.ts  一个 channel 的生命周期
```

**`agent.ts` 全部是对 `Transcript` 的纯函数**,规则集中在一处而不是散在组件里。

两个值得记住的点:

- **channel params 是个函数**,所以 phoenix.js 在每次 rejoin 时重新求值,重连会用"我
  真正见过的最后一个 seq"去要那一段差异,回复是**合并**而不是替换状态。
- **队列状态不从事件推算**,服务端的 `:queue` 事件直接给完整列表。队列有四种变化方式
  (注入成功就不入队、注入被拒入队、interrupt 暂存、drain 清空),计数器推一定会漂。

输入框的 IME 守卫:Chrome 的提交 keydown 带 `isComposing === true`,Safari 的
`compositionend` 在那个 keydown **之后**才来 —— 所以两个条件都要判,否则中文输入法用
回车上字的时候会把半截内容发出去。

---

## 8. 还没做的

- **delta 的前端渲染有待优化**(已知,下一步)
- `:question` 事件没接:CC 的 `AskUserQuestion` / Codex 的 `item/tool/requestUserInput`
  都能映射成选项按钮,现在问题以普通文本出现,用户照常打字回答
- Codex daemon 模式,让 turn 活过 loom 重启
- 工具输出截断没有视觉提示

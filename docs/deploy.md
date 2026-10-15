# 部署

EC2 一台机器,BEAM 自己监听 HTTP,`cloudflared` 在同一台机器上把它接出去。
**没有 nginx,没有 CloudFront,没有 TLS 在本机终结。**

```
浏览器 ──https──→ Cloudflare 边缘 ──隧道(出站)──→ cloudflared ──http──→ 127.0.0.1:4000
```

---

## 1. 为什么绑 loopback

`cloudflared` 是**往外**拨的,所以 loom 不需要被网络上任何人访问到 —— 安全组可以
一条入站规则都没有(连 22 都可以走 SSM)。默认就是 `127.0.0.1`。

隧道跑在别的机器上才需要 `LOOM_BIND=0.0.0.0`,那种情况下务必把入站限制到隧道那台
机器:能碰到这个端口的人,拿到的是一个 automode、无沙箱的 agent,前面只有一个密码。
`LOOM_BIND` 只接受 IP,写错直接启动失败,不会静默退化成全网监听。

**要不要再加一层**:Cloudflare Access 在隧道前面挂一条策略(只允许你的邮箱)是免费的,
一个开关,比单密码强得多。loom 自己的密码照旧生效,互不影响。

## 2. 前端由 BEAM 自己伺服

`Plug.Static` 从 `priv/static` 发,`/` 由 `LoomWeb.SpaController` 发 `index.html`。
以前这件事是 nginx 干的 —— 所以**必须先 build 再打 release**:

```sh
mix assets.deploy          # pnpm install && pnpm build → priv/static/
MIX_ENV=prod mix release
```

`mix release` 原样拷 `priv`,漏了第一步就会得到一个 API 正常、浏览器白屏的 release。
`test/loom_web/controllers/spa_controller_test.exs` 守这件事。

没 build 过时 `/` 返回 404 + `run mix assets.deploy` 的提示,而不是一个莫名其妙的错误。

## 3. `.env`

放在 release 根目录,`rel/env.sh.eex` 每次启动自动 source。**必需两项**:

```sh
SECRET_KEY_BASE=   # mix phx.gen.secret;换了会让所有登录 token 失效
LOOM_PASSWORD=     # 唯一的登录密码
PHX_SERVER=true    # 不写 release 不开 HTTP
```

其余全是可选,默认值就是这套架构要的:`PORT=4000`、`LOOM_BIND=127.0.0.1`、
`LOOM_HOME=~/.loom`、`PHX_HOST`(只影响生成的绝对 URL,loom 不生成)。
完整清单见 [.env.example](../.env.example)。

**不需要**:任何 TLS/证书配置、`force_ssl`、`check_origin` 白名单、模型 API key
(agent 跑的是 `claude` / `codex` 自己的登录)。

## 4. 两个 CLI 必须先登录

loom 自己不发模型请求,所以服务器上:

```sh
claude          # 登录一次(或 CLAUDE_CODE_USE_BEDROCK=1 + AWS 凭据)
codex login
```

loom 启动时会拉起一个共享的 `codex app-server`,每个活跃会话一个 `claude` 进程
(闲置 15 分钟后释放)。

## 5. 老数据

`~/.loom/sessions/` 是现在的落盘位置。如果机器上有旧版本留下的
`<旧 release>/priv/agent_sessions/`,开机迁移只会看**新** release 的 `priv`,所以要
手工搬一次:

```sh
cp -R /path/to/old-release/lib/loom-*/priv/agent_sessions/. ~/.loom/sessions/
```

迁移逻辑只拷不覆盖、按会话按文件,所以先拷后启、先启后拷都安全,重复执行也安全。

## 6. systemd

```ini
[Unit]
Description=loom
After=network-online.target

[Service]
Type=exec
User=loom
WorkingDirectory=/srv/loom
ExecStart=/srv/loom/bin/loom start
Restart=always
RestartSec=3
# agent 会 spawn claude/codex 和它们的子进程,停服务时要整棵树一起走
KillMode=control-group
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
```

`cloudflared` 自己一个 service,`ingress` 指向 `http://localhost:4000`:

```yaml
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/<tunnel-id>.json
ingress:
  - hostname: loom.example.com
    service: http://localhost:4000
    originRequest:
      # 终端和 agent 流都是 WebSocket,长连接不能被当成超时
      noTLSVerify: false
      connectTimeout: 30s
  - service: http_status:404
```

### 在 loom 里部署 loom

这台机器上实际在用的 unit 文件是 `rel/systemd/loom.service`（`User=ubuntu`，跑在
`~/loom` 下）。改了它之后要重新 `cp` 到 `/etc/systemd/system/`，再执行
`daemon-reload`。

在 loom 里跑的 agent 也在这个 service 的进程树里，重启 loom 会把它自己也杀掉。所以
agent 不能直接重启，而是走 `rel/deploy.sh`：

1. 把 release 打到 `_build/prod/rel/loom.next`，正在跑的那份不动。
2. 调用 `Loom.Restarter.request()`。等**所有**会话的 turn 都结束了（包括发起部署的
   这个），`System.stop()` 停掉节点。
3. `Restart=always` 把它拉起来，`ExecStartPre` 的 `promote-next.sh` 先把
   `loom.next` 换上来，旧版本保留成 `loom.prev`。

等不到所有会话空闲的话，请求 10 分钟后自动作废，不会强制重启。也不做自动回滚：
新版本起不来时，systemd 连续失败 5 次后就停止重试，这时手动把 `loom.prev` 挪回去。

## 7. 两个会咬人的限制

- **Cloudflare 免费/Pro 版请求体上限 100 MB。** 附件单文件上限是 25 MB,所以正常
  用不到 —— 但超过的话 413 来自 Cloudflare,loom 的日志里什么都看不到。
- **WebSocket 空闲超时。** Phoenix channel 默认 30 秒心跳,低于 Cloudflare 的空闲
  阈值,所以不用动。改心跳间隔的话记得这件事。

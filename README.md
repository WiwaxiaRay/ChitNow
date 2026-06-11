# ChitNow

Approve AI agent shell commands from your Apple Watch before they execute.

> **中文说明见下方 / Chinese documentation below ↓**

---

When Claude Code or Codex wants to run a high-risk command (`rm -rf`, `git push --force`, `sudo`, etc.), a hook pauses execution and sends a push notification to your Apple Watch. You tap Approve or Deny — then the agent proceeds or stops.

## How push notifications work

**LAN (always active):** The Mac broker stores requests locally. The iPhone app polls the broker every 5 seconds while foregrounded, and the Watch app polls every 5 seconds while open. No cloud involved.

**Cloudflare relay (recommended for reliability):** A Cloudflare Worker relays a generic wake-up push to your iPhone via Apple APNs. The relay sends only `{"event": "approval_pending"}` — it never receives commands, summaries, broker URLs, or approval decisions. The full command is fetched directly from the LAN broker after the iPhone wakes.

> **Important:** Watch background polling is not guaranteed by watchOS. Without the relay, the Watch app must be open to receive approval requests. With the relay, the iPhone is woken by push and relays the request to the Watch via WatchConnectivity.

> **Codex:** ChitNow only receives commands that Codex routes into PermissionRequest. Install or merge `codex/default.rules.example` to cover recommended high-risk commands. After a 15-second timeout with no Watch response, ChitNow cancels and falls back to Codex's native approval UI.

## Requirements

- macOS (tested on Sequoia / Ventura)
- Python 3.11+
- iPhone with iOS 26.5+
- Apple Watch with watchOS 26.5+
- Same Wi-Fi network as your Mac
- **Optional:** [codexbar](https://github.com/steipete/codexbar) for token/cost display on Watch
- **Optional:** Cloudflare account for relay push delivery

## Install

```bash
git clone https://github.com/WiwaxiaRay/thenow
cd thenow
bash install.sh
```

`install.sh` does the following:
1. Creates Python venv and installs broker dependencies
2. Installs and starts the broker as a launchd agent (auto-starts on login)
3. Copies the hook script to `~/.claude/scripts/`
4. Adds the PreToolUse hook entry to `~/.claude/settings.json`

To set the relay URL on first installation:
```bash
CHITNOW_RELAY_URL=https://your-worker.workers.dev bash install.sh
```

After installation, install the iPhone app via Xcode, then open the setup-token
pairing URL printed by `install.sh`. A plain `https://localhost:8000/pair`
request is intentionally rejected.

> Your browser will show a certificate warning — this is expected. The certificate is self-signed and generated locally on your Mac. Click **Advanced → Proceed to localhost** (Chrome) or **Show Details → visit this website** (Safari).

Scan the QR code in the ChitNow iPhone app to complete pairing.

## Approval routing

The iPhone app includes a **Use Apple Watch for approvals** switch:

- On: high-risk commands are sent to Apple Watch for approval.
- Off: ChitNow immediately returns the command to the native Claude Code or
  Codex approval screen. Commands are never automatically allowed.

The Mac Broker stores the authoritative setting. The switch changes only after
the iPhone successfully updates the Broker. If the Broker is unreachable, the
hook still denies by default instead of silently falling back.

## Cloudflare relay setup

The Cloudflare relay sends a generic APNs wake-up push when a new approval request is created. It never contains the command or summary.

1. Create a Cloudflare D1 database and Worker (see `relay/README.md`)
2. Set `RELAY_MASTER_SECRET_V1`, `APNS_PRIVATE_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` as Wrangler secrets
3. Apply the schema: `wrangler d1 execute chitnow-relay --file=relay/schema.sql`
4. Deploy: `cd relay && npm run deploy`
5. Set the relay URL in `broker/config.json`:
   ```json
   {"api_key": "...", "relay_url": "https://your-worker.workers.dev"}
   ```
   Or set it on first install: `CHITNOW_RELAY_URL=https://your-worker.workers.dev bash install.sh`
6. Re-pair (scan QR again) — the iPhone will register with the relay and send credentials to the broker

## Codex hook

Add to `~/.codex/config.toml`, then re-trust in the Codex TUI (`/hooks`):

Run `bash install.sh` — it prints the exact config snippet with absolute paths for your system.

```toml
[[hooks.PermissionRequest]]
matcher = "^Bash$"
[[hooks.PermissionRequest.hooks]]
type = "command"
# Replace /ABSOLUTE/PATH with your actual clone path (install.sh prints this for you)
command = "env THENOW_CONFIG_PATH=/ABSOLUTE/PATH/broker/config.json /ABSOLUTE/PATH/broker/.venv/bin/python ~/.claude/scripts/thenow_hook.py"
timeout = 190
statusMessage = "Waiting for Apple Watch approval..."

[features]
hooks = true
```

## Uninstall

```bash
bash uninstall.sh
```

Use `bash uninstall.sh --purge-data` to also remove the local database, logs,
broker API key, relay credentials, and generated TLS certificates.

## Architecture

```
Hook (Claude Code / Codex)
  → high-risk command detected
  → POST /approval-requests to LAN broker (HTTPS, TLS-pinned)
  → blocks on SSE /wait/{id}

Broker sends push (two parallel paths):
  1. Cloudflare relay: POST /v1/push with HMAC auth
       → Worker sends generic APNs "wake up" push (no command data)
       → iPhone wakes → polls /pending-requests → pings Watch
  2. iPhone foreground polling every 5s (always active when app open)
  3. Watch polling every 5s (always active when Watch app open)

User approves/denies on Watch or iPhone notification
  → POST /decision/{id} directly to LAN broker
  → SSE unblocks → hook exits with allow/deny
```

The relay payload sent to Apple APNs contains only:
```json
{"aps": {"alert": {"title": "ChitNow", "body": "New approval request — open ChitNow to review"}, "content-available": 1}, "type": "approval_request"}
```
No commands, summaries, broker URLs, API keys, or fingerprints pass through the relay or Apple's servers.

## Limitations

- **Relay wake-up only.** The Watch receives full request details (command, summary) from the LAN broker directly — never through the relay.
- **LAN required for approvals.** Mac and iPhone/Watch must be on the same network. Approval decisions go directly to the LAN broker.
- **Watch background execution.** watchOS limits background URLSession; the Watch app must be open for reliable delivery without relay.
- **Single user.** One API key shared across clients. No per-device revocation (relay installations can be revoked individually).
- **codexbar is optional.** Token usage, daily cost, and quota rings on Watch require codexbar running on your Mac.

## Broker API

Normal broker endpoints require `X-API-Key`. Pairing uses short-lived setup and
pairing tokens instead.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness probe |
| POST | `/approval-requests` | Create request, send push |
| GET | `/wait/{id}` | SSE — blocks until decision or 180s |
| POST | `/decision/{id}` | Record approve/deny |
| GET | `/pending-requests` | List non-expired pending requests |
| GET | `/usage` | Claude + GPT token/cost summary (requires codexbar) |
| GET | `/broker-ip` | Returns current HTTPS broker URL |
| GET | `/approval-routing` | Return whether Watch approval routing is enabled |
| PUT | `/approval-routing` | Enable/disable Watch approval routing |
| GET | `/pair?setup_token=...` | Pairing page (localhost + setup token) |
| GET | `/audit` | Last 100 audit entries |
| POST | `/relay-credentials` | Update relay installation credentials |
| DELETE | `/relay-credentials` | Remove relay installation credentials |

## Logs

```bash
tail -f broker/broker.log
```

---

# ChitNow（中文说明）

在 AI 编程助手执行高危 Shell 命令前，用 Apple Watch 审批。

Claude Code 或 Codex 要执行 `rm -rf`、`git push --force`、`sudo` 等危险命令时，Hook 会暂停执行，向 Apple Watch 发送推送通知。你在 Watch 上点击**批准**或**拒绝**，助手再继续或中止。

## 推送通知的工作方式

**局域网轮询（始终可用）：** Mac Broker 将请求保存在本地 SQLite。iPhone App 在前台时每 5 秒轮询一次，Watch App 打开时每 5 秒轮询一次。不依赖任何云服务。

**Cloudflare Relay（推荐，提升可靠性）：** Cloudflare Worker 通过 Apple APNs 向 iPhone 发送一个通用的"有新请求"唤醒推送。Relay 只发送 `{"event": "approval_pending"}`，不包含命令内容、摘要、Broker 地址或任何敏感数据。iPhone 被唤醒后，直接向局域网 Broker 获取完整请求详情。

> **注意：** watchOS 不保证 Watch 的后台运行。未配置 Relay 时，Watch App 必须处于打开状态才能收到审批请求。配置 Relay 后，iPhone 被 APNs 唤醒，再通过 WatchConnectivity 通知 Watch。

> **Codex 用户：** ChitNow 只拦截进入 PermissionRequest 流程的命令。请安装或合并 `codex/default.rules.example` 以覆盖推荐的高危命令。Watch 15 秒内无响应时，ChitNow 会自动取消并回退到 Codex 原生审批界面。

## 系统要求

- macOS（在 Sequoia / Ventura 上测试）
- Python 3.11+
- iPhone，iOS 26.5+
- Apple Watch，watchOS 26.5+
- 与 Mac 处于同一 Wi-Fi 网络
- **可选：** [codexbar](https://github.com/steipete/codexbar) —— 在 Watch 上显示 Token 用量和每日费用
- **可选：** Cloudflare 账号 —— 用于 Relay 推送

## 安装

```bash
git clone https://github.com/WiwaxiaRay/thenow
cd thenow
bash install.sh
```

`install.sh` 会自动完成：
1. 创建 Python venv 并安装 Broker 依赖
2. 将 Broker 注册为 launchd Agent（登录后自动启动）
3. 将 Hook 脚本复制到 `~/.claude/scripts/`
4. 将 PreToolUse Hook 配置写入 `~/.claude/settings.json`

首次安装时配置 Relay 地址：
```bash
CHITNOW_RELAY_URL=https://your-worker.workers.dev bash install.sh
```

安装完成后，通过 Xcode 将 iPhone App 安装到手机，然后在浏览器中打开 `install.sh` 打印出的带 setup_token 的配对 URL。直接访问 `https://localhost:8000/pair`（不带 token）会被拒绝。

> 浏览器会显示证书警告，这是正常现象——证书是本地自签名的。点击**高级 → 继续访问**（Chrome）或**显示详细信息 → 访问此网站**（Safari）即可。

在 ChitNow iPhone App 中扫描二维码完成配对。

## 审批路由开关

iPhone App 提供 **使用 Apple Watch 审批** 开关：

- 开启：高风险命令发送至 Apple Watch 审批。
- 关闭：立即转交 Claude Code 或 Codex 的 Mac 原生审批界面，绝不会自动允许命令。

Mac Broker 保存权威状态。只有 iPhone 成功更新 Broker 后，开关才会生效。
如果 Broker 不可达，Hook 仍然默认拒绝，不会静默回退原生审批。

## Cloudflare Relay 配置

1. 创建 Cloudflare D1 数据库和 Worker（详见 `relay/README.md`）
2. 通过 Wrangler 设置 Secrets：`RELAY_MASTER_SECRET_V1`、`APNS_PRIVATE_KEY`、`APNS_KEY_ID`、`APNS_TEAM_ID`、`APNS_BUNDLE_ID`
3. 应用数据库 Schema：`wrangler d1 execute chitnow-relay --file=relay/schema.sql`
4. 部署 Worker：`cd relay && npm run deploy`
5. 在 `broker/config.json` 中设置 Relay 地址，或首次安装时通过环境变量传入：
   ```bash
   CHITNOW_RELAY_URL=https://your-worker.workers.dev bash install.sh
   ```
6. 重新配对（重新扫码）——iPhone 会向 Relay 注册并将凭证发送给 Broker

## Codex Hook 配置

运行 `bash install.sh`，安装完成后会打印出适合你系统的完整配置片段。将以下内容合并到 `~/.codex/config.toml`，然后在 Codex TUI 中执行 `/hooks` 重新信任：

```toml
[[hooks.PermissionRequest]]
matcher = "^Bash$"
[[hooks.PermissionRequest.hooks]]
type = "command"
# 将 /ABSOLUTE/PATH 替换为你实际的克隆路径（install.sh 会打印出来）
command = "env THENOW_CONFIG_PATH=/ABSOLUTE/PATH/broker/config.json /ABSOLUTE/PATH/broker/.venv/bin/python ~/.claude/scripts/thenow_hook.py"
timeout = 190
statusMessage = "Waiting for Apple Watch approval..."

[features]
hooks = true
```

## 卸载

```bash
bash uninstall.sh
```

使用 `bash uninstall.sh --purge-data` 同时删除本地数据库、日志、API Key、Relay 凭证和 TLS 证书。

## 审批模式

通过环境变量 `THENOW_APPROVAL_MODE` 控制拦截范围：

| 模式 | 行为 |
|------|------|
| `balanced`（默认） | 普通读取命令（如 `ls`、`cat`、`pwd`）直接放行，仅拦截高危或难以审查的命令 |
| `strict` | 所有 Bash PreToolUse 命令进入 Watch 审批，不依赖正则 |

默认使用 `balanced`，避免阻塞 Claude Code 的日常操作。需要审批所有 Bash 命令时，可显式设置 `THENOW_APPROVAL_MODE=strict`。`balanced` 依赖模式匹配，无法覆盖所有危险命令的等价写法，不是完整的安全边界。

## 系统架构

```
Hook（Claude Code / Codex）
  → 检测到高危命令
  → HTTPS POST /approval-requests 到局域网 Broker（TLS 证书锁定）
  → 阻塞在 SSE /wait/{id}

Broker 并行发送通知：
  1. Cloudflare Relay：HMAC 认证的 POST /v1/push
       → Worker 向 APNs 发通用唤醒推送（不含命令数据）
       → iPhone 唤醒 → 轮询 /pending-requests → 通知 Watch
  2. iPhone 前台轮询（App 打开时每 5 秒）
  3. Watch 前台轮询（Watch App 打开时每 5 秒）

用户在 Watch 上批准或拒绝
  → 直接 POST /decision/{id} 到局域网 Broker
  → SSE 唤醒 → Hook 退出（允许或拒绝）
```

Relay 发送给 Apple APNs 的 Payload 仅包含：
```json
{"aps": {"alert": {"title": "ChitNow", "body": "New approval request — open ChitNow to review"}, "content-available": 1}, "type": "approval_request"}
```
命令内容、摘要、Broker 地址、API Key 和 TLS 指纹**不会**经过 Relay 或 Apple 服务器。

## 已知限制

- **Relay 仅负责唤醒。** Watch 的完整请求详情（命令、摘要）直接从局域网 Broker 获取，不经过 Relay。
- **审批需要局域网。** Mac 和 iPhone/Watch 必须在同一网络。审批决定直接发送到局域网 Broker。
- **Watch 后台受限。** watchOS 限制后台 URLSession；无 Relay 时 Watch App 必须保持打开状态。
- **Mac IP 变化。** 网络切换后可能需要重新配对。
- **单用户。** 一个 API Key 共享给所有客户端，无法按设备单独撤销（Relay 安装可单独撤销）。
- **codexbar 可选。** Watch 上的 Token 用量、每日费用和额度显示需要 Mac 运行 codexbar。

## 日志

```bash
tail -f broker/broker.log
```

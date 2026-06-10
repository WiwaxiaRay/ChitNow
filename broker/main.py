#!/usr/bin/env python3
"""
thenow approval broker
Run: uvicorn main:app --port 8000
"""
import asyncio
import json
import os
import secrets
import sys
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone, timedelta
from typing import AsyncGenerator

import aiosqlite
import httpx
import jwt
from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel

# ── vendored assets ───────────────────────────────────────────────────────────
_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
with open(os.path.join(_STATIC_DIR, "qrcode.min.js")) as _f:
    _QRCODE_JS = _f.read()

# ── config ────────────────────────────────────────────────────────────────────
_DIR        = os.path.dirname(os.path.abspath(__file__))
DB_PATH     = os.path.join(_DIR, "broker.db")
TIMEOUT_SEC = 180

def _load_api_key() -> str:
    if os.environ.get("THENOW_API_KEY"):
        return os.environ["THENOW_API_KEY"]
    cfg_path = os.path.join(_DIR, "config.json")
    try:
        key = json.loads(open(cfg_path).read()).get("api_key", "")
        if not key:
            raise ValueError("api_key missing or empty in config.json")
        return key
    except Exception as e:
        print(f"[broker] FATAL: cannot load API key from {cfg_path}: {e}", flush=True)
        print("[broker] Run: python generate_config.py", flush=True)
        sys.exit(1)

def _load_cert_fingerprint() -> str:
    fp_path = os.path.join(_DIR, "certs", "fingerprint.txt")
    try:
        return open(fp_path).read().strip()
    except Exception:
        return ""

API_KEY          = _load_api_key()
CERT_FINGERPRINT = _load_cert_fingerprint()

# Fill these after downloading APNs .p8 key from Apple Developer portal
APNS_KEY_ID    = "ZRLVNRQ23Q"
APNS_TEAM_ID   = "F7PJZAN683"
APNS_KEY_PATH  = os.path.join(_DIR, "AuthKey_ZRLVNRQ23Q.p8")
BUNDLE_ID      = "com.wangyang.thenow"
_APNS_ENV  = os.environ.get("THENOW_APNS_ENV", "sandbox")  # "sandbox" | "production"
APNS_HOST  = "https://api.push.apple.com" if _APNS_ENV == "production" else "https://api.sandbox.push.apple.com"

# ── in-memory SSE waiters ─────────────────────────────────────────────────────
_waiters: dict[str, asyncio.Event] = {}
_apns_token: str | None = None
_apns_token_at: float = 0
_apns_lock = asyncio.Lock()  # guards concurrent JWT regeneration


# ── database ──────────────────────────────────────────────────────────────────
async def init_db():
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript("""
            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                device_token TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            CREATE TABLE IF NOT EXISTS approval_requests (
                id TEXT PRIMARY KEY,
                agent TEXT,
                risk TEXT,
                title TEXT,
                summary TEXT,
                command TEXT,
                cwd TEXT,
                status TEXT DEFAULT 'pending',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                expires_at TIMESTAMP,
                decided_at TIMESTAMP
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                request_id TEXT,
                action TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        # Expire requests that timed out while the broker was offline
        await db.execute(
            "UPDATE approval_requests SET status='expired' "
            "WHERE status='pending' AND datetime(expires_at) < datetime('now')"
        )
        await db.commit()


# ── APNs ──────────────────────────────────────────────────────────────────────
async def _apns_auth_token() -> str:
    global _apns_token, _apns_token_at
    now = time.time()
    if _apns_token and now - _apns_token_at < 3000:
        return _apns_token
    async with _apns_lock:
        # Re-check after acquiring lock — another coroutine may have refreshed it.
        if _apns_token and now - _apns_token_at < 3000:
            return _apns_token
        with open(APNS_KEY_PATH) as f:
            key = f.read()
        _apns_token = jwt.encode(
            {"iss": APNS_TEAM_ID, "iat": int(now)},
            key,
            algorithm="ES256",
            headers={"kid": APNS_KEY_ID},
        )
        _apns_token_at = now
    return _apns_token


async def send_push(device_token: str, title: str, body: str, request_id: str):
    if not APNS_KEY_ID or not APNS_TEAM_ID:
        print(f"[APNs] not configured — skipping push for {request_id}", flush=True)
        return
    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "category": "AGENT_APPROVAL",
            "sound": "default",
            "interruption-level": "time-sensitive",
            "content-available": 1,
        },
        "request_id": request_id,
        "type": "approval_request",
    }
    headers = {
        "authorization": f"bearer {await _apns_auth_token()}",
        "apns-topic": BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",
    }
    try:
        async with httpx.AsyncClient(http2=True) as client:
            resp = await client.post(
                f"{APNS_HOST}/3/device/{device_token}",
                json=payload,
                headers=headers,
                timeout=10,
            )
        if resp.status_code == 200:
            print(f"[APNs] push sent: {request_id}", flush=True)
        else:
            print(f"[APNs] error {resp.status_code}: {resp.text}", flush=True)
    except Exception as e:
        print(f"[APNs] exception sending push for {request_id}: {e}", flush=True)


# ── app ───────────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    asyncio.create_task(_startup_push())
    asyncio.create_task(_ip_monitor())
    yield


def _current_ip() -> str | None:
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


async def _push_broker_url(broker_url: str, label: str = "push") -> None:
    async with aiosqlite.connect(DB_PATH) as db:
        cur = await db.execute("SELECT device_token FROM devices WHERE id='default'")
        row = await cur.fetchone()
    if not row:
        print(f"[{label}] no device registered", flush=True)
        return
    payload = {
        "aps": {"content-available": 1},
        "type": "broker_started",
        "broker_url": broker_url,
    }
    headers = {
        "authorization": f"bearer {await _apns_auth_token()}",
        "apns-topic": BUNDLE_ID,
        "apns-push-type": "background",
        "apns-priority": "5",
    }
    try:
        async with httpx.AsyncClient(http2=True) as client:
            resp = await client.post(
                f"{APNS_HOST}/3/device/{row[0]}",
                json=payload, headers=headers, timeout=10,
            )
        if resp.status_code == 200:
            print(f"[{label}] broker URL sent: {broker_url}", flush=True)
        else:
            print(f"[{label}] APNs error {resp.status_code}: {resp.text}", flush=True)
    except Exception as e:
        print(f"[{label}] failed: {e}", flush=True)


async def _startup_push():
    await asyncio.sleep(2)
    ip = _current_ip()
    if ip:
        await _push_broker_url(f"https://{ip}:8000", label="startup push")
    else:
        print("[startup push] cannot determine local IP", flush=True)


async def _ip_monitor():
    """每 60s 检测 IP 变化；顺带清理 _waiters 中已无对应 pending 行的孤儿 event。"""
    last_ip: str | None = None
    while True:
        await asyncio.sleep(60)
        # Clean up orphaned waiters (requests that expired while hook was disconnected)
        try:
            async with aiosqlite.connect(DB_PATH) as db:
                cur = await db.execute(
                    "SELECT id FROM approval_requests WHERE status='pending'"
                )
                pending_ids = {row[0] for row in await cur.fetchall()}
            stale = [k for k in list(_waiters) if k not in pending_ids]
            for k in stale:
                _waiters.pop(k, None)
            if stale:
                print(f"[ip monitor] cleaned {len(stale)} orphaned waiter(s)", flush=True)
        except Exception:
            pass
        ip = _current_ip()
        if ip is None:
            continue
        if last_ip is None:
            last_ip = ip
            continue
        if ip != last_ip:
            last_ip = ip
            print(f"[ip monitor] IP changed → {ip}", flush=True)
            await _push_broker_url(f"https://{ip}:8000", label="ip monitor")

app = FastAPI(lifespan=lifespan)


def auth(x_api_key: str = ""):
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")


# ── models ────────────────────────────────────────────────────────────────────
class DeviceBody(BaseModel):
    device_token: str

class RequestBody(BaseModel):
    agent: str = "claude-code"
    risk: str = "high"
    title: str
    summary: str
    command: str
    cwd: str = ""

class DecisionBody(BaseModel):
    status: str  # "approved" | "denied"


# ── routes ────────────────────────────────────────────────────────────────────
@app.post("/register-device")
async def register_device(body: DeviceBody, x_api_key: str = Header("")):
    auth(x_api_key)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT OR REPLACE INTO devices (id, device_token) VALUES ('default', ?)",
            (body.device_token,),
        )
        await db.commit()
    print(f"[broker] device registered: {body.device_token[:12]}…")
    return {"status": "ok"}


@app.post("/approval-requests")
async def create_request(body: RequestBody, x_api_key: str = Header("")):
    auth(x_api_key)
    req_id = f"req_{uuid.uuid4().hex[:12]}"
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=TIMEOUT_SEC)

    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            """INSERT INTO approval_requests
               (id, agent, risk, title, summary, command, cwd, expires_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (req_id, body.agent, body.risk, body.title, body.summary,
             body.command, body.cwd, expires_at.isoformat()),
        )
        cur = await db.execute("SELECT device_token FROM devices WHERE id='default'")
        row = await cur.fetchone()
        await db.commit()

    _waiters[req_id] = asyncio.Event()

    if row:
        asyncio.create_task(
            send_push(row[0], body.title, body.summary, req_id)
        )

    print(f"[broker] created {req_id}: {body.summary}")
    return {"id": req_id, "expires_at": expires_at.isoformat()}


@app.get("/wait/{request_id}")
async def wait_decision(request_id: str, x_api_key: str = Header("")):
    auth(x_api_key)

    async def stream() -> AsyncGenerator[str, None]:
        event = _waiters.get(request_id)
        if event is None:
            yield f"data: {json.dumps({'status': 'not_found'})}\n\n"
            return

        try:
            await asyncio.wait_for(event.wait(), timeout=TIMEOUT_SEC)
        except asyncio.TimeoutError:
            async with aiosqlite.connect(DB_PATH) as db:
                await db.execute(
                    "UPDATE approval_requests SET status='expired' WHERE id=? AND status='pending'",
                    (request_id,),
                )
                await db.execute(
                    "INSERT INTO audit_log (request_id, action) VALUES (?, 'expired')",
                    (request_id,),
                )
                await db.commit()
            _waiters.pop(request_id, None)
            yield f"data: {json.dumps({'status': 'expired'})}\n\n"
            return

        async with aiosqlite.connect(DB_PATH) as db:
            cur = await db.execute(
                "SELECT status FROM approval_requests WHERE id=?", (request_id,)
            )
            row = await cur.fetchone()

        status = row[0] if row else "expired"
        yield f"data: {json.dumps({'status': status})}\n\n"

    return StreamingResponse(stream(), media_type="text/event-stream")


@app.post("/decision/{request_id}")
async def record_decision(request_id: str, body: DecisionBody, x_api_key: str = Header("")):
    auth(x_api_key)

    if body.status not in ("approved", "denied"):
        raise HTTPException(status_code=400, detail="status must be approved or denied")

    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(DB_PATH) as db:
        # Atomic conditional update: only succeeds if still pending and not yet expired.
        # This prevents a race condition where two concurrent decisions both pass the
        # status='pending' check before either commits.
        cur = await db.execute(
            "UPDATE approval_requests SET status=?, decided_at=? "
            "WHERE id=? AND status='pending' AND expires_at > ?",
            (body.status, now, request_id, now),
        )
        if cur.rowcount == 0:
            # Determine the reason: not found, already decided, or expired
            row = await (await db.execute(
                "SELECT status FROM approval_requests WHERE id=?", (request_id,)
            )).fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Request not found")
            if row[0] != "pending":
                raise HTTPException(status_code=409, detail=f"Already {row[0]}")
            raise HTTPException(status_code=410, detail="Request expired")

        await db.execute(
            "INSERT INTO audit_log (request_id, action) VALUES (?, ?)",
            (request_id, body.status),
        )
        await db.commit()

    print(f"[broker] decision {request_id}: {body.status}")

    event = _waiters.pop(request_id, None)
    if event:
        event.set()

    return {"status": "ok"}


@app.get("/usage")
async def get_usage(x_api_key: str = Header("")):
    auth(x_api_key)
    from pathlib import Path
    today = datetime.now().strftime("%Y-%m-%d")

    # ── Claude ────────────────────────────────────────────────────────────
    claude = {"today_cost": 0.0, "today_input": 0, "today_output": 0,
              "today_cache_read": 0, "today_cache_write": 0}
    try:
        raw = json.loads(
            (Path.home() / "Library/Caches/codexbar/cost-usage/claude-v2.json").read_text()
        )
        # collect all rows grouped by day, fall back to most recent day if today empty
        day_totals: dict = {}
        for file_data in raw.get("files", {}).values():
            for row in file_data.get("claudeRows", []):
                dk = row.get("dayKey", "")
                if not dk:
                    continue
                t = day_totals.setdefault(dk, {"cost": 0.0, "input": 0, "output": 0,
                                               "cache_read": 0, "cache_write": 0})
                t["cost"]        += row.get("costNanos", 0) / 1e9
                t["input"]       += row.get("input", 0)
                t["output"]      += row.get("output", 0)
                t["cache_read"]  += row.get("cacheRead", 0)
                t["cache_write"] += row.get("cacheCreate", 0)
        key = today if today in day_totals else (max(day_totals) if day_totals else None)
        if key:
            t = day_totals[key]
            claude["today_cost"]       = round(t["cost"], 4)
            claude["today_input"]      = t["input"]
            claude["today_output"]     = t["output"]
            claude["today_cache_read"] = t["cache_read"]
            claude["today_cache_write"]= t["cache_write"]
    except Exception as e:
        print(f"[usage] claude error: {e}")

    # ── Codex / GPT ───────────────────────────────────────────────────────
    PRICING = {
        "gpt-5.5":           {"input": 5.0,  "cache": 0.5,  "output": 30.0},
        "codex-auto-review": {"input": 5.0,  "cache": 0.5,  "output": 30.0},
    }
    DEFAULT_PRICING = {"input": 5.0, "cache": 0.5, "output": 30.0}

    gpt = {"today_cost": 0.0, "today_input": 0, "today_output": 0, "today_cache_read": 0}
    try:
        raw = json.loads(
            (Path.home() / "Library/Caches/codexbar/cost-usage/codex-v8.json").read_text()
        )
        days = raw.get("days", {})
        key = today if today in days else (max(days) if days else None)
        if key:
            for model, (total_in, cached_in, out) in days[key].items():
                p = PRICING.get(model, DEFAULT_PRICING)
                net_in = total_in - cached_in
                gpt["today_cost"] += (
                    net_in * p["input"] + cached_in * p["cache"] + out * p["output"]
                ) / 1_000_000
                gpt["today_input"]      += total_in
                gpt["today_output"]     += out
                gpt["today_cache_read"] += cached_in
            gpt["today_cost"] = round(gpt["today_cost"], 4)
    except Exception as e:
        print(f"[usage] gpt error: {e}")

    # ── Claude 订阅额度 ────────────────────────────────────────────────
    claude_quota = {"used_percent": None, "resets_at": None,
                    "week_used_percent": None, "week_resets_at": None}
    try:
        raw = json.loads(
            (Path.home() / "Library/Application Support/com.steipete.codexbar/history/claude.json").read_text()
        )
        for items in raw.get("accounts", {}).values():
            for window in items:
                entries = window.get("entries", [])
                if not entries:
                    continue
                latest = sorted(entries, key=lambda x: x["capturedAt"])[-1]
                minutes = window.get("windowMinutes", 0)
                if minutes == 300:   # 5-hour session window
                    claude_quota["used_percent"] = latest.get("usedPercent")
                    resets_at = latest.get("resetsAt")
                    if resets_at:
                        try:
                            rt = datetime.fromisoformat(resets_at.replace("Z", "+00:00"))
                            while rt < datetime.now(timezone.utc):
                                rt += timedelta(minutes=300)
                            resets_at = rt.strftime("%Y-%m-%dT%H:%M:%SZ")
                        except Exception:
                            pass
                    claude_quota["resets_at"] = resets_at
                elif minutes == 10080:  # weekly window
                    claude_quota["week_used_percent"] = latest.get("usedPercent")
                    claude_quota["week_resets_at"]    = latest.get("resetsAt")
    except Exception as e:
        print(f"[usage] claude quota error: {e}")

    # ── OpenAI 订阅额度 ────────────────────────────────────────────────
    import re as _re
    def _parse_reset_time(desc: str) -> str | None:
        """Parse 'Resets 3:07 PM' → ISO8601 timestamp (today or tomorrow)."""
        m = _re.search(r'(\d{1,2}):(\d{2})\s*(AM|PM)', desc or "", _re.IGNORECASE)
        if not m:
            return None
        h, mi, ampm = int(m.group(1)), int(m.group(2)), m.group(3).upper()
        if ampm == "PM" and h != 12:
            h += 12
        elif ampm == "AM" and h == 12:
            h = 0
        now_local = datetime.now()
        reset = now_local.replace(hour=h, minute=mi, second=0, microsecond=0)
        if reset <= now_local:
            reset += timedelta(days=1)
        return reset.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _openai_dashboard_snapshot(raw):
        if isinstance(raw, dict):
            return raw.get("snapshot", raw)
        if isinstance(raw, list):
            for item in raw:
                if isinstance(item, dict) and ("primaryLimit" in item or "snapshot" in item):
                    return item.get("snapshot", item)
        return {}

    def _future_reset(resets_at: str | None, window_minutes: int | None = None) -> str | None:
        if not resets_at:
            return None
        try:
            reset = datetime.fromisoformat(resets_at.replace("Z", "+00:00"))
            if window_minutes:
                while reset < datetime.now(timezone.utc):
                    reset += timedelta(minutes=window_minutes)
            return reset.strftime("%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            return resets_at

    def _apply_codex_quota_snapshot(snap: dict):
        primary = snap.get("primary") or snap.get("primaryLimit") or {}
        second = snap.get("secondary") or snap.get("secondaryLimit") or {}
        desc = primary.get("resetDescription")

        if primary:
            gpt_quota["used_percent"]       = primary.get("usedPercent")
            gpt_quota["resets_description"] = desc
            gpt_quota["resets_at"] = _future_reset(
                primary.get("resetsAt") or _parse_reset_time(desc),
                primary.get("windowMinutes"),
            )
        if second:
            gpt_quota["week_used_percent"] = second.get("usedPercent")
            gpt_quota["week_resets_at"] = _future_reset(
                second.get("resetsAt"),
                second.get("windowMinutes"),
            )
        if "creditsRemaining" in snap:
            gpt_quota["credits_remaining"] = snap.get("creditsRemaining")

    def _latest_codex_history_windows(raw):
        accounts = raw.get("accounts", {})
        preferred = raw.get("preferredAccountKey")
        windows = accounts.get(preferred) if preferred else None
        if not windows and accounts:
            windows = next(iter(accounts.values()))
        return windows or raw.get("unscoped", [])

    gpt_quota = {"used_percent": None, "resets_at": None, "resets_description": None,
                 "week_used_percent": None, "week_resets_at": None,
                 "credits_remaining": None}
    try:
        group_root = Path.home() / "Library/Group Containers"
        for path in group_root.glob("*.com.steipete.codexbar/widget-snapshot.json"):
            raw = json.loads(path.read_text())
            for entry in raw.get("entries", []):
                if entry.get("provider") == "codex":
                    _apply_codex_quota_snapshot(entry)
                    break
            if gpt_quota["used_percent"] is not None:
                break
    except Exception as e:
        print(f"[usage] gpt widget quota error: {e}")

    try:
        if gpt_quota["used_percent"] is None or gpt_quota["week_used_percent"] is None:
            raw = json.loads(
                (Path.home() / "Library/Application Support/com.steipete.codexbar/history/codex.json").read_text()
            )
            for window in _latest_codex_history_windows(raw):
                entries = window.get("entries", [])
                if not entries:
                    continue
                latest = sorted(entries, key=lambda x: x["capturedAt"])[-1]
                minutes = window.get("windowMinutes", 0)
                if minutes == 300:
                    gpt_quota["used_percent"] = latest.get("usedPercent")
                    gpt_quota["resets_at"] = _future_reset(latest.get("resetsAt"), minutes)
                elif minutes == 10080:
                    gpt_quota["week_used_percent"] = latest.get("usedPercent")
                    gpt_quota["week_resets_at"] = _future_reset(latest.get("resetsAt"), minutes)
    except Exception as e:
        print(f"[usage] gpt history quota error: {e}")

    try:
        if gpt_quota["used_percent"] is None or gpt_quota["week_used_percent"] is None:
            raw = json.loads(
                (Path.home() / "Library/Application Support/com.steipete.codexbar/openai-dashboard.json").read_text()
            )
            _apply_codex_quota_snapshot(_openai_dashboard_snapshot(raw))
    except Exception as e:
        print(f"[usage] gpt quota error: {e}")

    claude["quota"] = claude_quota
    gpt["quota"]    = gpt_quota

    return {"claude": claude, "gpt": gpt}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/broker-ip")
async def broker_ip(x_api_key: str = Header("")):
    auth(x_api_key)
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return {"url": f"https://{ip}:8000"}


@app.get("/pending-requests")
async def pending_requests(x_api_key: str = Header("")):
    auth(x_api_key)
    now = datetime.now(timezone.utc)
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(
            "SELECT * FROM approval_requests "
            "WHERE status='pending' AND datetime(expires_at) > datetime('now') "
            "ORDER BY created_at ASC"
        )
        rows = await cur.fetchall()

    result = []
    for r in rows:
        expires_at = datetime.fromisoformat(r["expires_at"])
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=timezone.utc)
        remaining = max(0, int((expires_at - now).total_seconds()))
        result.append({**dict(r), "remaining_seconds": remaining})
    return result


@app.get("/audit")
async def audit_log(x_api_key: str = Header("")):
    auth(x_api_key)
    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cur = await db.execute(
            "SELECT * FROM audit_log ORDER BY created_at DESC LIMIT 100"
        )
        rows = await cur.fetchall()
    return [dict(r) for r in rows]


# ── pairing ───────────────────────────────────────────────────────────────────
# In-memory pairing sessions: sid → {payload, expires_at, used}
_pairing_sessions: dict[str, dict] = {}


def _current_https_url() -> str:
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return f"https://{ip}:8000"


@app.get("/pair", response_class=HTMLResponse)
async def pair_page(request: Request):
    """Open in browser on Mac. Shows a one-time QR code for iPhone to scan."""
    # Restrict to localhost
    client_host = request.client.host if request.client else ""
    if client_host not in ("127.0.0.1", "::1"):
        raise HTTPException(status_code=403, detail="Pairing page is only accessible from localhost")
    # Expire stale sessions
    now = time.time()
    stale = [k for k, v in _pairing_sessions.items() if v["expires_at"] < now]
    for k in stale:
        _pairing_sessions.pop(k, None)

    sid          = secrets.token_hex(16)
    pairing_token = secrets.token_hex(32)   # one-time token; API key never goes in the QR
    expires_at   = now + 300  # 5 minutes
    broker_url   = _current_https_url()
    payload = {
        "v": 2,
        "url": broker_url,
        "pt":  pairing_token,
        "fp":  CERT_FINGERPRINT,
        "exp": int(expires_at),
        "sid": sid,
    }
    _pairing_sessions[sid] = {
        "pairing_token": pairing_token,
        "url": broker_url,
        "fp":  CERT_FINGERPRINT,
        "expires_at": expires_at,
        "used": False,
    }
    payload_json = json.dumps(payload)

    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>thenow — Pair iPhone</title>
<style>
  body {{ font-family: -apple-system, sans-serif; background: #1a1a1a; color: #f0f0f0;
         display: flex; flex-direction: column; align-items: center;
         justify-content: center; min-height: 100vh; margin: 0; padding: 24px; box-sizing: border-box; }}
  h1  {{ font-size: 22px; margin-bottom: 4px; }}
  p   {{ color: #999; font-size: 14px; margin: 0 0 24px; text-align: center; }}
  #qr {{ background: #fff; padding: 16px; border-radius: 12px; }}
  #timer {{ font-size: 13px; color: #888; margin-top: 16px; }}
  #status {{ margin-top: 16px; font-size: 15px; color: #4ade80; display: none; }}
</style>
</head>
<body>
<h1>thenow</h1>
<p>Open the thenow iPhone app and tap <b>Pair with Mac</b><br>then scan this code</p>
<div id="qr"></div>
<div id="timer">Expires in <span id="secs">300</span>s — <a href="/pair" style="color:#888">refresh</a></div>
<div id="status">✓ Paired successfully</div>
<script>{_QRCODE_JS}</script>
<script>
const data = {payload_json};
QRCode.toCanvas(document.createElement('canvas'), JSON.stringify(data), {{
  width: 260, margin: 2, color: {{ dark: '#000', light: '#fff' }}
}}, function(err, canvas) {{
  if (!err) document.getElementById('qr').appendChild(canvas);
}});

let secs = 300;
const ticker = setInterval(() => {{
  secs--;
  const el = document.getElementById('secs');
  if (el) el.textContent = secs;
  if (secs <= 0) clearInterval(ticker);
}}, 1000);

// Poll until confirmed or expired
const poll = setInterval(async () => {{
  try {{
    const r = await fetch('/pair/{sid}/status');
    const j = await r.json();
    if (j.status === 'confirmed') {{
      clearInterval(poll);
      clearInterval(ticker);
      document.getElementById('timer').style.display = 'none';
      document.getElementById('qr').style.opacity = '0.3';
      document.getElementById('status').style.display = 'block';
    }}
  }} catch(_) {{}}
}}, 2000);
</script>
</body>
</html>"""
    return HTMLResponse(content=html)


@app.post("/pair/{sid}/confirm")
async def pair_confirm(sid: str, x_pairing_token: str = Header("")):
    """Called by iPhone after scanning QR. Returns api_key only after validating the one-time token."""
    session = _pairing_sessions.get(sid)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")
    if session["used"]:
        raise HTTPException(status_code=409, detail="Session already used")
    if time.time() > session["expires_at"]:
        _pairing_sessions.pop(sid, None)
        raise HTTPException(status_code=410, detail="Session expired")
    if x_pairing_token != session["pairing_token"]:
        raise HTTPException(status_code=401, detail="Invalid pairing token")
    session["used"] = True
    print(f"[pair] iPhone confirmed pairing session {sid}", flush=True)
    return {
        "status":     "ok",
        "api_key":    API_KEY,
        "broker_url": session["url"],
        "cert_fp":    session["fp"],
    }


@app.get("/pair/{sid}/status")
async def pair_status(sid: str):
    """Polled by the browser page to detect when iPhone has confirmed."""
    session = _pairing_sessions.get(sid)
    if not session:
        return {"status": "expired"}
    if time.time() > session["expires_at"]:
        return {"status": "expired"}
    return {"status": "confirmed" if session["used"] else "pending"}

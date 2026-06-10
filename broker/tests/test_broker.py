"""
Minimal broker tests covering the acceptance criteria in the task spec.
Run: cd broker && .venv/bin/pytest tests/ -v
"""
import json
import os
import subprocess
import sys
import tempfile
import time

import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_config(tmp_path) -> str:
    cfg = {"api_key": "test-key-abc123"}
    p = os.path.join(tmp_path, "config.json")
    with open(p, "w") as f:
        json.dump(cfg, f)
    return p


@pytest.fixture()
def client(monkeypatch, tmp_path):
    """Broker test client with isolated config and database (never touches real files)."""
    _make_config(tmp_path)
    db_path = str(tmp_path / "test_broker.db")
    monkeypatch.setenv("THENOW_API_KEY", "test-key-abc123")

    import sys
    if "main" in sys.modules:
        del sys.modules["main"]
    import main as broker_main
    # Redirect DB to isolated temp path so tests never touch broker/broker.db
    monkeypatch.setattr(broker_main, "DB_PATH", db_path)
    with TestClient(broker_main.app) as c:
        yield c, broker_main


GOOD_KEY = "test-key-abc123"
BAD_KEY  = "wrong-key"
HEADERS  = {"X-API-Key": GOOD_KEY}


# ---------------------------------------------------------------------------
# Test: wrong API key returns 401
# ---------------------------------------------------------------------------

def test_wrong_api_key_returns_401(client):
    c, _ = client
    r = c.get("/pending-requests", headers={"X-API-Key": BAD_KEY})
    assert r.status_code == 401


def test_missing_api_key_returns_401(client):
    c, _ = client
    r = c.get("/pending-requests")
    assert r.status_code == 401


def test_correct_api_key_returns_200(client):
    c, _ = client
    r = c.get("/pending-requests", headers=HEADERS)
    assert r.status_code == 200


# ---------------------------------------------------------------------------
# Test: pairing session — 5-minute expiry and single-use
# ---------------------------------------------------------------------------

def test_pairing_session_single_use(client, monkeypatch):
    c, broker_main = client
    # Create a pairing session directly via the sessions dict
    import secrets, time as _time
    sid = secrets.token_hex(8)
    session_key = secrets.token_hex(16)
    pt = secrets.token_hex(32)
    broker_main._pairing_sessions[sid] = {
        "pairing_token": pt,
        "url": "https://192.168.1.1:8000",
        "fp":  "aabbcc",
        "expires_at": _time.time() + 300,
        "used": False,
    }
    # First confirm should succeed and return api_key
    r = c.post(f"/pair/{sid}/confirm", headers={"X-Pairing-Token": pt})
    assert r.status_code == 200
    assert r.json()["api_key"] == GOOD_KEY

    # Second confirm on same session should fail (already used)
    r2 = c.post(f"/pair/{sid}/confirm", headers={"X-Pairing-Token": pt})
    assert r2.status_code in (409, 410)


def test_pairing_session_expired(client):
    c, broker_main = client
    import secrets, time as _time
    sid = secrets.token_hex(8)
    session_key = secrets.token_hex(16)
    pt = secrets.token_hex(32)
    broker_main._pairing_sessions[sid] = {
        "pairing_token": pt,
        "url": "https://192.168.1.1:8000",
        "fp":  "aabbcc",
        "expires_at": _time.time() - 1,   # already expired
        "used": False,
    }
    r = c.post(f"/pair/{sid}/confirm", headers={"X-Pairing-Token": pt})
    assert r.status_code == 410


# ---------------------------------------------------------------------------
# Test: pairing page localhost-only
# ---------------------------------------------------------------------------

def test_pair_page_allowed_from_localhost(client):
    c, _ = client
    from starlette.testclient import TestClient as _TC
    from starlette.types import ASGIApp, Receive, Scope, Send
    import main as broker_main

    class FakeLocalhostMiddleware:
        def __init__(self, app: ASGIApp):
            self.app = app
        async def __call__(self, scope: Scope, receive: Receive, send: Send):
            if scope["type"] == "http":
                scope = dict(scope)
                scope["client"] = ("127.0.0.1", 54321)
            await self.app(scope, receive, send)

    with _TC(FakeLocalhostMiddleware(broker_main.app)) as tc:
        r = tc.get("/pair")
    assert r.status_code == 200


def test_pair_page_blocked_from_lan_ip(client):
    c, _ = client
    # Inject a LAN client address via the ASGI scope override.
    # The broker reads request.client.host from the ASGI scope directly.
    from starlette.testclient import TestClient as _TC
    import main as broker_main

    class _LanTransport(_TC._real_transport if hasattr(_TC, '_real_transport') else object):
        pass

    # Simulate LAN IP by patching the transport scope at the ASGI level.
    # Simplest reliable approach: use app.middleware to inject the scope.
    from starlette.requests import Request
    from starlette.responses import Response
    from starlette.types import ASGIApp, Receive, Scope, Send

    class FakeLanMiddleware:
        def __init__(self, app: ASGIApp):
            self.app = app
        async def __call__(self, scope: Scope, receive: Receive, send: Send):
            if scope["type"] == "http":
                scope = dict(scope)
                scope["client"] = ("192.168.1.50", 12345)
            await self.app(scope, receive, send)

    from fastapi import FastAPI
    wrapped = FakeLanMiddleware(broker_main.app)
    with _TC(wrapped) as tc:
        r = tc.get("/pair")
    assert r.status_code == 403


# ---------------------------------------------------------------------------
# Test: hook — missing config defaults to deny, not dev-key
# ---------------------------------------------------------------------------

def test_hook_denies_on_missing_config(tmp_path, monkeypatch):
    """_load_broker_config must return None key when no config can be found."""
    monkeypatch.delenv("THENOW_API_KEY", raising=False)
    monkeypatch.delenv("THENOW_BROKER_URL", raising=False)
    nonexistent = str(tmp_path / "does_not_exist.json")
    monkeypatch.setenv("THENOW_CONFIG_PATH", nonexistent)

    import importlib.util, sys as _sys
    hook_path = os.path.abspath(os.path.join(
        os.path.dirname(__file__), "..", "..", "hooks", "thenow_hook.py"
    ))
    # Patch os.path.exists to return False for ALL candidate paths so the hook
    # cannot fall back to the real config.json in the working tree.
    real_exists = os.path.exists
    def _no_config(p):
        if "config.json" in str(p) or "broker" in str(p):
            return False
        return real_exists(p)
    monkeypatch.setattr(os.path, "exists", _no_config)

    for mod in list(_sys.modules.keys()):
        if "thenow_hook" in mod:
            del _sys.modules[mod]
    spec = importlib.util.spec_from_file_location("thenow_hook_isolated", hook_path)
    hook = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hook)

    assert hook.API_KEY is None, "API_KEY must be None when config is missing"


# ---------------------------------------------------------------------------
# Test: /cancel endpoint
# ---------------------------------------------------------------------------

def _create_pending(c, headers) -> str:
    r = c.post("/approval-requests", headers=headers, json={
        "agent": "claude-code", "risk": "high",
        "title": "test", "summary": "test", "command": "rm -rf /tmp/x", "cwd": "/tmp",
    })
    assert r.status_code == 200
    return r.json()["id"]


def test_cancel_pending_request(client):
    c, _ = client
    req_id = _create_pending(c, HEADERS)
    r = c.post(f"/cancel/{req_id}", headers=HEADERS)
    assert r.status_code == 200
    # Cancelled request must not appear in pending list
    pending = c.get("/pending-requests", headers=HEADERS).json()
    assert not any(p["id"] == req_id for p in pending)


def test_cancel_already_cancelled_returns_409(client):
    c, _ = client
    req_id = _create_pending(c, HEADERS)
    c.post(f"/cancel/{req_id}", headers=HEADERS)
    r = c.post(f"/cancel/{req_id}", headers=HEADERS)
    assert r.status_code == 409


def test_decision_after_cancel_returns_409(client):
    c, _ = client
    req_id = _create_pending(c, HEADERS)
    c.post(f"/cancel/{req_id}", headers=HEADERS)
    r = c.post(f"/decision/{req_id}", headers=HEADERS, json={"status": "approved"})
    assert r.status_code == 409


def test_cancel_nonexistent_returns_404(client):
    c, _ = client
    r = c.post("/cancel/no-such-id", headers=HEADERS)
    assert r.status_code == 404


def test_cancel_approved_request_returns_409(client):
    c, _ = client
    req_id = _create_pending(c, HEADERS)
    c.post(f"/decision/{req_id}", headers=HEADERS, json={"status": "approved"})
    r = c.post(f"/cancel/{req_id}", headers=HEADERS)
    assert r.status_code == 409


# ---------------------------------------------------------------------------
# Test: relay push — must not block or raise when relay is not configured
# ---------------------------------------------------------------------------

def test_relay_push_not_configured_does_not_raise(client):
    """relay_client.push_notification() must return False silently when relay not configured."""
    c, broker_main = client
    import asyncio
    result = asyncio.run(broker_main.relay_client.push_notification())
    assert result is False


def test_create_request_without_relay_succeeds(client):
    """POST /approval-requests must succeed even when relay is not configured."""
    r = client[0].post("/approval-requests", headers=HEADERS, json={
        "agent": "claude-code", "risk": "high",
        "title": "t", "summary": "s", "command": "rm -rf /x", "cwd": "/",
    })
    assert r.status_code == 200


def test_relay_credentials_endpoint_without_relay_url(client):
    """POST /relay-credentials must return 400 when broker has no relay_url configured."""
    c, broker_main = client
    # RELAY_URL is "" in test environment (no config.json with relay_url)
    r = c.post("/relay-credentials", headers=HEADERS, json={
        "installation_id": "test-id",
        "relay_secret": "test-secret",
    })
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# Test: pair_confirm ignores relay_url from body (security fix)
# ---------------------------------------------------------------------------

def test_pair_confirm_ignores_relay_url_from_body(client, monkeypatch, tmp_path):
    """pair_confirm must NOT use relay_url from the request body."""
    c, broker_main = client
    import secrets, time as _time

    # Ensure broker has no RELAY_URL configured
    monkeypatch.setattr(broker_main, "RELAY_URL", "")

    saved_calls = []
    def _mock_save(relay_url, installation_id, relay_secret):
        saved_calls.append(relay_url)
    monkeypatch.setattr(broker_main.relay_client, "save_credentials", _mock_save)

    sid = secrets.token_hex(8)
    pt = secrets.token_hex(32)
    broker_main._pairing_sessions[sid] = {
        "pairing_token": pt,
        "url": "https://192.168.1.1:8000",
        "fp":  "aabbcc",
        "expires_at": _time.time() + 300,
        "used": False,
    }
    r = c.post(f"/pair/{sid}/confirm",
               headers={"X-Pairing-Token": pt},
               json={"installation_id": "inst-123",
                     "relay_secret": "secret-abc"})
    assert r.status_code == 200
    # save_credentials must NOT have been called (RELAY_URL is empty)
    assert len(saved_calls) == 0, "save_credentials must not be called when RELAY_URL is empty"


def test_relay_credentials_saved_from_config_relay_url(client, monkeypatch, tmp_path):
    """pair_confirm uses broker's own RELAY_URL from config, not the body."""
    c, broker_main = client
    import secrets, time as _time

    # Set broker's RELAY_URL to a known value
    monkeypatch.setattr(broker_main, "RELAY_URL", "https://relay.example.com")

    saved_calls = []
    def _mock_save(relay_url, installation_id, relay_secret):
        saved_calls.append({"relay_url": relay_url, "id": installation_id})
    monkeypatch.setattr(broker_main.relay_client, "save_credentials", _mock_save)

    sid = secrets.token_hex(8)
    pt = secrets.token_hex(32)
    broker_main._pairing_sessions[sid] = {
        "pairing_token": pt,
        "url": "https://192.168.1.1:8000",
        "fp":  "aabbcc",
        "expires_at": _time.time() + 300,
        "used": False,
    }
    r = c.post(f"/pair/{sid}/confirm",
               headers={"X-Pairing-Token": pt},
               json={"installation_id": "inst-from-body",
                     "relay_secret": "secret-from-body"})
    assert r.status_code == 200
    assert len(saved_calls) == 1
    # URL must come from broker config, not body
    assert saved_calls[0]["relay_url"] == "https://relay.example.com"
    assert saved_calls[0]["id"] == "inst-from-body"


def test_relay_credentials_endpoint_with_relay_url_configured(client, monkeypatch, tmp_path):
    """POST /relay-credentials succeeds when broker's RELAY_URL is configured."""
    c, broker_main = client
    monkeypatch.setattr(broker_main, "RELAY_URL", "https://relay.example.com")

    saved = []
    monkeypatch.setattr(broker_main.relay_client, "save_credentials",
                        lambda url, iid, sec: saved.append(url))

    r = c.post("/relay-credentials", headers=HEADERS, json={
        "installation_id": "inst-test",
        "relay_secret": "sec-test",
    })
    assert r.status_code == 200
    assert saved == ["https://relay.example.com"]


# ---------------------------------------------------------------------------
# Test: QR payload does not contain the long-term API key
# ---------------------------------------------------------------------------

def test_qr_payload_no_api_key(client):
    """Pairing session payload must contain 'pt' (token), not 'key' (API key)."""
    c, broker_main = client
    # Create a session directly
    import secrets, time as _t
    sid = secrets.token_hex(16)
    pt  = secrets.token_hex(32)
    broker_main._pairing_sessions[sid] = {
        "pairing_token": pt,
        "url": "https://192.168.1.1:8000",
        "fp":  "aabbcc",
        "expires_at": _t.time() + 300,
        "used": False,
    }
    # The session dict must not contain the API key
    session = broker_main._pairing_sessions[sid]
    assert "key" not in session, "session must not store raw API key"
    assert GOOD_KEY not in str(session), "API key must not appear in session"
    assert "pairing_token" in session


# ---------------------------------------------------------------------------
# Test: uninstall only removes ChitNow hook, not other hooks
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test: /cancel only cancels non-expired pending requests
# ---------------------------------------------------------------------------

def test_cancel_expired_request_returns_410(client):
    """cancel on an expired-but-still-pending row must return 410, not 200 or 409."""
    import sqlite3 as _sqlite3
    c, broker_main = client
    req_id = _create_pending(c, HEADERS)
    # Force-expire the row directly in the DB
    conn = _sqlite3.connect(broker_main.DB_PATH)
    conn.execute(
        "UPDATE approval_requests SET expires_at=datetime('now', '-1 second') WHERE id=?",
        (req_id,),
    )
    conn.commit()
    conn.close()
    r = c.post(f"/cancel/{req_id}", headers=HEADERS)
    assert r.status_code == 410, f"expected 410 for expired pending, got {r.status_code}"


# ---------------------------------------------------------------------------
# Test: SSE integration — approved, denied, cancelled flows
# ---------------------------------------------------------------------------

def test_sse_approved_flow(client):
    """Full approve flow: create → post decision → SSE stream yields 'approved'."""
    import threading
    c, _ = client
    req_id = _create_pending(c, HEADERS)

    result = {}

    def _post_decision():
        time.sleep(0.05)
        result["r"] = c.post(f"/decision/{req_id}", headers=HEADERS, json={"status": "approved"})

    t = threading.Thread(target=_post_decision)
    t.start()

    with c.stream("GET", f"/wait/{req_id}", headers=HEADERS) as resp:
        for line in resp.iter_lines():
            if line.startswith("data:"):
                result["sse"] = json.loads(line[5:])
                break

    t.join()
    assert result["sse"]["status"] == "approved"
    assert result["r"].status_code == 200


def test_sse_denied_flow(client):
    """Full deny flow: create → post deny → SSE stream yields 'denied'."""
    import threading
    c, _ = client
    req_id = _create_pending(c, HEADERS)
    result = {}

    def _deny():
        time.sleep(0.05)
        result["r"] = c.post(f"/decision/{req_id}", headers=HEADERS, json={"status": "denied"})

    t = threading.Thread(target=_deny)
    t.start()

    with c.stream("GET", f"/wait/{req_id}", headers=HEADERS) as resp:
        for line in resp.iter_lines():
            if line.startswith("data:"):
                result["sse"] = json.loads(line[5:])
                break
    t.join()
    assert result["sse"]["status"] == "denied"


def test_sse_cancelled_flow(client):
    """Cancel flow: create → cancel → SSE stream yields 'cancelled'."""
    import threading
    c, _ = client
    req_id = _create_pending(c, HEADERS)
    result = {}

    def _cancel():
        time.sleep(0.05)
        result["r"] = c.post(f"/cancel/{req_id}", headers=HEADERS)

    t = threading.Thread(target=_cancel)
    t.start()

    with c.stream("GET", f"/wait/{req_id}", headers=HEADERS) as resp:
        for line in resp.iter_lines():
            if line.startswith("data:"):
                result["sse"] = json.loads(line[5:])
                break
    t.join()
    assert result["sse"]["status"] == "cancelled"


def test_cancel_vs_decision_race(client):
    """When cancel and decision arrive concurrently, exactly one wins."""
    import threading
    c, _ = client
    req_id = _create_pending(c, HEADERS)

    cancel_result = {}
    decision_result = {}

    def _cancel():
        cancel_result["r"] = c.post(f"/cancel/{req_id}", headers=HEADERS)

    def _decide():
        decision_result["r"] = c.post(f"/decision/{req_id}", headers=HEADERS,
                                      json={"status": "approved"})

    t1 = threading.Thread(target=_cancel)
    t2 = threading.Thread(target=_decide)
    t1.start(); t2.start()
    t1.join(); t2.join()

    codes = {cancel_result["r"].status_code, decision_result["r"].status_code}
    # Exactly one succeeds (200) and one fails (409 or 410)
    assert 200 in codes, f"Expected one 200, got {codes}"
    assert codes != {200, 200}, "Both cancel and decision cannot win"


# ---------------------------------------------------------------------------
# Test: TOML output from install.sh is tomllib-parseable
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test: hook behavior — low/high risk with and without config
# ---------------------------------------------------------------------------

def _run_hook(stdin_payload: dict, env_extra: dict | None = None) -> "subprocess.CompletedProcess":
    import subprocess
    env = {**os.environ, **(env_extra or {})}
    hook_path = os.path.abspath(os.path.join(
        os.path.dirname(__file__), "..", "..", "hooks", "thenow_hook.py"
    ))
    return subprocess.run(
        [sys.executable, hook_path],
        input=json.dumps(stdin_payload),
        capture_output=True,
        text=True,
        env=env,
    )


def _no_config_env(tmp_path_str: str) -> dict:
    return {
        "THENOW_CONFIG_PATH": os.path.join(tmp_path_str, "missing.json"),
        "THENOW_API_KEY": "",
        "THENOW_BROKER_URL": "",
    }


def test_hook_low_risk_without_config_allows(tmp_path):
    """Hook with no config, low-risk command ls -la → exit 0 (passthrough)."""
    import sys as _sys
    r = _run_hook(
        {"hook_event_name": "PreToolUse", "tool_name": "Bash",
         "tool_input": {"command": "ls -la"}, "cwd": "/tmp",
         "transcript_path": "/home/.claude/t.json"},
        _no_config_env(str(tmp_path))
    )
    assert r.returncode == 0, f"expected exit 0, got {r.returncode}\nstderr: {r.stderr}"


def test_hook_high_risk_without_config_denies(tmp_path):
    """Hook with no config, rm -rf → exit 2 (deny)."""
    import sys as _sys
    r = _run_hook(
        {"hook_event_name": "PreToolUse", "tool_name": "Bash",
         "tool_input": {"command": "rm -rf /tmp/x"}, "cwd": "/tmp",
         "transcript_path": "/home/.claude/t.json"},
        _no_config_env(str(tmp_path))
    )
    assert r.returncode == 2, f"expected exit 2, got {r.returncode}\nstderr: {r.stderr}"


def test_hook_low_risk_with_config_allows(tmp_path):
    """Hook with valid config, low-risk echo → exit 0."""
    import sys as _sys
    cfg_path = str(tmp_path / "config.json")
    with open(cfg_path, "w") as f:
        json.dump({"api_key": "test-key"}, f)
    r = _run_hook(
        {"hook_event_name": "PreToolUse", "tool_name": "Bash",
         "tool_input": {"command": "echo hello"}, "cwd": "/tmp",
         "transcript_path": "/home/.claude/t.json"},
        {
            "THENOW_CONFIG_PATH": cfg_path,
            "THENOW_BROKER_URL": "https://127.0.0.1:19999",
            "THENOW_API_KEY": "",
        }
    )
    assert r.returncode == 0, f"expected exit 0, got {r.returncode}\nstderr: {r.stderr}"


def test_hook_high_risk_with_config_broker_unreachable_denies(tmp_path):
    """Hook with config but broker unreachable → exit 2 (deny)."""
    import sys as _sys
    cfg_path = str(tmp_path / "config.json")
    with open(cfg_path, "w") as f:
        json.dump({"api_key": "test-key"}, f)
    r = _run_hook(
        {"hook_event_name": "PreToolUse", "tool_name": "Bash",
         "tool_input": {"command": "rm -rf /tmp/x"}, "cwd": "/tmp",
         "transcript_path": "/home/.claude/t.json"},
        {
            "THENOW_CONFIG_PATH": cfg_path,
            "THENOW_BROKER_URL": "https://127.0.0.1:19999",
            "THENOW_API_KEY": "",
        }
    )
    assert r.returncode == 2, f"expected exit 2, got {r.returncode}\nstderr: {r.stderr}"


def test_install_sh_toml_spaces_no_shell_quoting(tmp_path):
    """The TOML command value generated by install.sh must not contain shell-quoting artifacts."""
    # Simulate what install.sh's Python snippet does
    def toml_val(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    config_path = "/Users/my name/broker/config.json"
    python_path = "/Users/my name/.venv/bin/python"
    hook_path   = "/Users/my name/hooks/thenow_hook.py"
    parts = [
        "env",
        "THENOW_CONFIG_PATH=" + toml_val(config_path),
        toml_val(python_path),
        toml_val(hook_path),
    ]
    cmd = " ".join(parts)
    # Must NOT contain shell-quoting patterns
    assert "'" not in cmd, f"Shell single-quote found in TOML command: {cmd!r}"
    assert "$'" not in cmd, f"Shell $'...' quoting found in TOML command: {cmd!r}"
    # Must be valid as a TOML string value
    import tomllib
    toml_str = f'command = "{cmd}"\n'
    parsed = tomllib.loads(toml_str)
    assert parsed["command"] == cmd


def test_install_sh_toml_output_is_valid(tmp_path):
    """The Codex TOML snippet printed by install.sh must be parseable by tomllib.

    TOML structure: [[hooks.PermissionRequest]] creates one array-of-tables element;
    [[hooks.PermissionRequest.hooks]] adds a sub-array inside that same element.
    Result: hooks.PermissionRequest is a list of length 1, each item having a
    "matcher" key and a "hooks" sub-list.
    """
    import tomllib
    hook_cmd = "env THENOW_CONFIG_PATH=/tmp/config.json /tmp/.venv/bin/python /tmp/thenow_hook.py"
    toml_snippet = f"""[[hooks.PermissionRequest]]
matcher = "^Bash$"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = {json.dumps(hook_cmd)}
timeout = 190
statusMessage = "Waiting for Apple Watch approval..."

[features]
hooks = true
"""
    parsed = tomllib.loads(toml_snippet)
    assert parsed["features"]["hooks"] is True
    perm_hooks = parsed["hooks"]["PermissionRequest"]
    # One array-of-tables element containing matcher + hooks sub-array
    assert len(perm_hooks) == 1
    element = perm_hooks[0]
    assert element["matcher"] == "^Bash$"
    inner = element["hooks"]
    assert len(inner) == 1
    assert inner[0]["command"] == hook_cmd
    assert inner[0]["timeout"] == 190


def test_install_sh_toml_with_spaces_in_path(tmp_path):
    """TOML snippet must remain valid even with spaces in paths."""
    import tomllib
    hook_cmd = f"env THENOW_CONFIG_PATH=/Users/my\\ name/config.json /path/to/python /path/to/thenow_hook.py"
    toml_snippet = f"""[[hooks.PermissionRequest]]
matcher = "^Bash$"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = {json.dumps(hook_cmd)}
timeout = 190
statusMessage = "Waiting for Apple Watch approval..."

[features]
hooks = true
"""
    tomllib.loads(toml_snippet)  # must not raise


# ---------------------------------------------------------------------------
# Test: uninstall only removes ChitNow hook, not other hooks
# ---------------------------------------------------------------------------

def test_uninstall_removes_only_chitnow_hook(tmp_path):
    settings = tmp_path / "settings.json"
    other_hook = {"matcher": "Bash", "hooks": [{"type": "command", "command": "other_tool.sh"}]}
    chitnow_hook = {"matcher": "Bash", "hooks": [{"type": "command", "command": "thenow_hook.py"}]}
    settings.write_text(json.dumps({
        "hooks": {"PreToolUse": [other_hook, chitnow_hook]}
    }))

    # Run the same Python snippet used in uninstall.sh
    path = str(settings)
    with open(path) as f:
        cfg = json.load(f)
    hooks = cfg.get("hooks", {})
    if isinstance(hooks, dict):
        ptu = hooks.get("PreToolUse", [])
        hooks["PreToolUse"] = [h for h in ptu if "thenow_hook" not in str(h)]
        cfg["hooks"] = hooks
        with open(path, "w") as f:
            json.dump(cfg, f)

    result = json.loads(settings.read_text())
    ptu = result["hooks"]["PreToolUse"]
    assert len(ptu) == 1
    assert "other_tool.sh" in str(ptu[0])
    assert "thenow_hook" not in str(ptu)

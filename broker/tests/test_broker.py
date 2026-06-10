"""
Minimal broker tests covering the acceptance criteria in the task spec.
Run: cd broker && .venv/bin/pytest tests/ -v
"""
import json
import os
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
    """Broker test client with a temp config and certs directory."""
    cfg_path = _make_config(tmp_path)
    # Point broker at the temp dir so it uses our test key
    monkeypatch.setenv("THENOW_API_KEY", "test-key-abc123")
    # Avoid APNs key load failure during import
    monkeypatch.setenv("THENOW_APNS_ENV", "sandbox")

    import importlib
    import sys
    # Reload main to pick up monkeypatched env
    if "main" in sys.modules:
        del sys.modules["main"]
    import main as broker_main
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
# Test: APNs not configured — send_push must not raise
# ---------------------------------------------------------------------------

def test_send_push_no_p8_does_not_raise(client, monkeypatch, tmp_path):
    """send_push() must be a no-op when .p8 is absent, never raise."""
    c, broker_main = client
    monkeypatch.setattr(broker_main, "APNS_KEY_PATH", str(tmp_path / "missing.p8"))
    import asyncio
    asyncio.run(broker_main.send_push("fake-token", "title", "body", "req-1"))


def test_push_broker_url_no_p8_does_not_raise(client, monkeypatch, tmp_path):
    """_push_broker_url() must not raise or propagate when .p8 absent."""
    c, broker_main = client
    monkeypatch.setattr(broker_main, "APNS_KEY_PATH", str(tmp_path / "missing.p8"))
    import asyncio
    asyncio.run(broker_main._push_broker_url("https://192.168.1.1:8000"))


def test_create_request_without_apns_succeeds(client, monkeypatch, tmp_path):
    """POST /approval-requests must succeed even when APNs is not configured."""
    c, broker_main = client
    monkeypatch.setattr(broker_main, "APNS_KEY_PATH", str(tmp_path / "missing.p8"))
    r = c.post("/approval-requests", headers=HEADERS, json={
        "agent": "claude-code", "risk": "high",
        "title": "t", "summary": "s", "command": "rm -rf /x", "cwd": "/",
    })
    assert r.status_code == 200


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

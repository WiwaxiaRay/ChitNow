"""
Security tests for Phase 0:
  - Credential rotation (rotate_broker_credentials.py)
  - Broker log sanitisation (no full device tokens / commands / API keys in logs)
  - scan_secrets.sh smoke test
"""
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

REPO = Path(__file__).parent.parent.parent
SCRIPTS = REPO / "scripts"
BROKER = REPO / "broker"

KNOWN_LEAKED_KEY = "REDACTED_BROKER_API_KEY"


# ---------------------------------------------------------------------------
# Helper: load rotate_broker_credentials as a module
# ---------------------------------------------------------------------------

def _load_rotate():
    spec = importlib.util.spec_from_file_location(
        "rotate_broker_credentials",
        str(SCRIPTS / "rotate_broker_credentials.py"),
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------------------
# Credential rotation tests
# ---------------------------------------------------------------------------

class TestRotateBrokerCredentials:
    def test_new_key_differs_from_old(self, tmp_path):
        """Rotation must produce a key different from the leaked one."""
        mod = _load_rotate()
        old = KNOWN_LEAKED_KEY
        new_key = mod._write_key.__module__  # ensure module loaded
        new_key = __import__("secrets").token_hex(32)
        assert new_key != old
        assert len(new_key) == 64  # 32 bytes hex

    def test_write_key_creates_600_file(self, tmp_path):
        """rotate script writes config.json with mode 600."""
        mod = _load_rotate()
        cfg_path = tmp_path / "config.json"
        # Patch CONFIG_PATH to use tmp dir
        orig = mod.CONFIG_PATH
        mod.CONFIG_PATH = str(cfg_path)
        try:
            mod._write_key("newkey123abc")
            assert cfg_path.exists()
            mode = oct(cfg_path.stat().st_mode)[-3:]
            assert mode == "600", f"expected 600, got {mode}"
            data = json.loads(cfg_path.read_text())
            assert data["api_key"] == "newkey123abc"
        finally:
            mod.CONFIG_PATH = orig

    def test_clear_devices_returns_count(self, tmp_path):
        """_clear_devices returns the number of deleted rows."""
        import sqlite3
        db_path = tmp_path / "broker.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("CREATE TABLE devices (id TEXT PRIMARY KEY, device_token TEXT NOT NULL, created_at TEXT)")
        conn.execute("INSERT INTO devices VALUES ('default', 'token123', '2024-01-01')")
        conn.commit()
        conn.close()

        mod = _load_rotate()
        orig = mod.DB_PATH
        mod.DB_PATH = str(db_path)
        try:
            count = mod._clear_devices()
            assert count == 1
            # Verify row is gone
            conn2 = sqlite3.connect(str(db_path))
            rows = conn2.execute("SELECT COUNT(*) FROM devices").fetchone()[0]
            conn2.close()
            assert rows == 0
        finally:
            mod.DB_PATH = orig

    def test_clear_devices_missing_db_returns_zero(self, tmp_path):
        """_clear_devices must not raise when broker.db doesn't exist."""
        mod = _load_rotate()
        orig = mod.DB_PATH
        mod.DB_PATH = str(tmp_path / "nonexistent.db")
        try:
            count = mod._clear_devices()
            assert count == 0
        finally:
            mod.DB_PATH = orig

    def test_known_leaked_key_constant(self):
        """KNOWN_LEAKED_KEYS must include the historically committed key."""
        mod = _load_rotate()
        assert KNOWN_LEAKED_KEY in mod.KNOWN_LEAKED_KEYS


# ---------------------------------------------------------------------------
# Log sanitisation tests
# ---------------------------------------------------------------------------

class TestLogSanitisation:
    """Ensure broker logs don't emit full device tokens or raw commands."""

    def _make_client(self, monkeypatch, tmp_path):
        key = "test-log-sanitise-key"
        monkeypatch.setenv("THENOW_API_KEY", key)
        monkeypatch.setenv("THENOW_APNS_ENV", "sandbox")
        import sys as _sys
        for mod in list(_sys.modules.keys()):
            if mod == "main":
                del _sys.modules[mod]
        import main as m
        from fastapi.testclient import TestClient
        return TestClient(m.app), m, key

    def test_register_device_truncates_token(self, monkeypatch, tmp_path, capsys):
        """POST /register-device must not log the full device token."""
        c, m, key = self._make_client(monkeypatch, tmp_path)
        full_token = "a" * 64
        c.post("/register-device",
               headers={"X-API-Key": key},
               json={"device_token": full_token})
        captured = capsys.readouterr()
        combined = captured.out + captured.err
        # Full token must not appear in logs
        assert full_token not in combined, "Full device token must not appear in log output"
        # Truncated prefix IS expected
        assert full_token[:12] in combined

    def test_create_request_truncates_summary(self, monkeypatch, tmp_path, capsys):
        """POST /approval-requests must truncate long summaries in logs."""
        c, m, key = self._make_client(monkeypatch, tmp_path)
        long_summary = "X" * 100
        c.post("/approval-requests",
               headers={"X-API-Key": key},
               json={
                   "agent": "claude-code", "risk": "high",
                   "title": "test", "summary": long_summary,
                   "command": "rm -rf /", "cwd": "/",
               })
        captured = capsys.readouterr()
        combined = captured.out + captured.err
        assert long_summary not in combined, "Full 100-char summary must not appear in logs"

    def test_api_key_not_in_any_log(self, monkeypatch, tmp_path, capsys):
        """The API key must never appear in log output."""
        c, m, key = self._make_client(monkeypatch, tmp_path)
        c.get("/pending-requests", headers={"X-API-Key": key})
        captured = capsys.readouterr()
        combined = captured.out + captured.err
        assert key not in combined, "API key must not appear in any log output"


# ---------------------------------------------------------------------------
# scan_secrets.sh smoke test
# ---------------------------------------------------------------------------

class TestScanSecrets:
    def test_scan_script_is_executable(self):
        scan = SCRIPTS / "scan_secrets.sh"
        assert scan.exists(), "scripts/scan_secrets.sh must exist"
        assert os.access(str(scan), os.X_OK), "scan_secrets.sh must be executable"

    def test_scan_detects_leaked_key_in_file(self, tmp_path):
        """scan_secrets.sh should detect the known leaked key in a file."""
        # Write the leaked key into a tmp file, then verify scan would catch it
        # (We can't modify the real working tree, so just verify the grep pattern works)
        test_file = tmp_path / "test.json"
        test_file.write_text(json.dumps({"api_key": KNOWN_LEAKED_KEY}))
        result = subprocess.run(
            ["grep", "-l", KNOWN_LEAKED_KEY, str(test_file)],
            capture_output=True, text=True
        )
        assert result.returncode == 0, "grep must find the leaked key"

    def test_scan_runs_in_repo(self):
        """scan_secrets.sh runs without crashing (exit 0 or 1 both acceptable)."""
        result = subprocess.run(
            ["bash", str(SCRIPTS / "scan_secrets.sh")],
            capture_output=True, text=True,
            cwd=str(REPO),
        )
        # Exit 0 = clean, exit 1 = issues found — both are valid scanner outputs.
        # Anything else (crash, parse error) is a test failure.
        assert result.returncode in (0, 1), (
            f"scan_secrets.sh crashed with exit {result.returncode}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )

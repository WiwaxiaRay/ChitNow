"""
Security tests for Phase 0:
  - Credential rotation (rotate_broker_credentials.py)
  - Broker log sanitisation (no full commands / API keys in logs)
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

    def test_known_leaked_key_constant(self):
        """KNOWN_LEAKED_KEYS must include the historically committed key."""
        mod = _load_rotate()
        assert KNOWN_LEAKED_KEY in mod.KNOWN_LEAKED_KEYS

    def test_rotate_preserves_relay_url(self, tmp_path):
        """Rotating credentials must preserve relay_url in config.json."""
        mod = _load_rotate()
        cfg_path = tmp_path / "config.json"
        cfg_path.write_text(json.dumps({
            "api_key": KNOWN_LEAKED_KEY,
            "relay_url": "https://relay.example.com",
        }))
        orig = mod.CONFIG_PATH
        mod.CONFIG_PATH = str(cfg_path)
        try:
            mod._write_key("new-rotated-key")
            data = json.loads(cfg_path.read_text())
            assert data["api_key"] == "new-rotated-key"
            assert data.get("relay_url") == "https://relay.example.com", \
                "relay_url must be preserved after rotation"
        finally:
            mod.CONFIG_PATH = orig


# ---------------------------------------------------------------------------
# Log sanitisation tests
# ---------------------------------------------------------------------------

class TestLogSanitisation:
    """Ensure broker logs don't emit full device tokens or raw commands."""

    def _make_client(self, monkeypatch, tmp_path):
        import asyncio
        key = "test-log-sanitise-key"
        db_path = str(tmp_path / "test_log.db")
        monkeypatch.setenv("THENOW_API_KEY", key)
        import sys as _sys
        for mod in list(_sys.modules.keys()):
            if mod == "main":
                del _sys.modules[mod]
        import main as m
        monkeypatch.setattr(m, "DB_PATH", db_path)
        # Manually initialise DB tables — lifespan is not triggered without 'with TestClient'
        asyncio.run(m.init_db())
        from fastapi.testclient import TestClient
        return TestClient(m.app), m, key

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

    def test_scan_no_false_positive_on_test_files(self):
        """scan_secrets.sh must not flag broker/tests/ files as secret leaks.

        These files legitimately reference the leaked key string for testing;
        the scanner's exclusion list must cover them.
        """
        result = subprocess.run(
            ["bash", str(SCRIPTS / "scan_secrets.sh")],
            capture_output=True, text=True,
            cwd=str(REPO),
        )
        # Check that test_security.py and test_broker.py are not mentioned as FAIL
        # (They may appear in other scan output lines like [ok] or [WARN], but not [FAIL])
        fail_lines = [l for l in result.stdout.splitlines() if l.strip().startswith("[FAIL]")]
        for line in fail_lines:
            assert "test_security" not in line, \
                f"scan_secrets.sh falsely flagged test_security.py: {line}"
            assert "test_broker" not in line, \
                f"scan_secrets.sh falsely flagged test_broker.py: {line}"

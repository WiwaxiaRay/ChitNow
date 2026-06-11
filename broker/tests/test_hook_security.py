"""
Security tests for thenow_hook.py.

Covers:
  - TLS cert missing → deny (never verify=False)
  - strict mode: all Bash PreToolUse intercepted
  - balanced mode: only high-risk + extra patterns intercepted

Run: cd <repo> && broker/.venv/bin/pytest broker/tests/test_hook_security.py -v
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
HOOK = str(REPO_ROOT / "hooks" / "thenow_hook.py")
PYTHON = sys.executable


def _run(stdin_payload: dict, env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = {**os.environ, **(env_extra or {})}
    return subprocess.run(
        [PYTHON, HOOK],
        input=json.dumps(stdin_payload),
        capture_output=True,
        text=True,
        env=env,
    )


def _claude_preuse(command: str) -> dict:
    return {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "transcript_path": "/home/user/.claude/transcript.json",
    }


def _codex_permission(command: str) -> dict:
    return {
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {"command": command},
    }


def _env_with_key_no_cert(tmp_path) -> dict:
    """Valid api_key present, cert path set but file absent."""
    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({"api_key": "test-key"}))
    cert_path = str(tmp_path / "certs" / "broker.crt")  # directory not created
    return {
        "THENOW_CONFIG_PATH": str(cfg),
        "THENOW_BROKER_URL": "https://127.0.0.1:19999",
        "THENOW_CERT_PATH": cert_path,
    }


def _env_no_api_key(tmp_path) -> dict:
    """No api_key (config missing) — hook denies at API_KEY check before cert."""
    return {
        "THENOW_CONFIG_PATH": str(tmp_path / "missing.json"),
        "THENOW_API_KEY": "",
        "THENOW_BROKER_URL": "",
    }


# ---------------------------------------------------------------------------
# TLS cert-missing denial
# ---------------------------------------------------------------------------

class TestCertMissingDenial:
    """Cert missing → deny. verify=False must never be used."""

    def test_high_risk_no_cert_denied_balanced(self, tmp_path):
        """High-risk command + missing cert → exit 2 in balanced mode."""
        env = {**_env_with_key_no_cert(tmp_path), "THENOW_APPROVAL_MODE": "balanced"}
        r = _run(_claude_preuse("rm -rf /tmp/x"), env)
        assert r.returncode == 2, f"expected deny (2), got {r.returncode}\nstderr: {r.stderr}"

    def test_high_risk_no_cert_denied_strict(self, tmp_path):
        """Any Bash command + missing cert → exit 2 in strict mode."""
        env = {**_env_with_key_no_cert(tmp_path), "THENOW_APPROVAL_MODE": "strict"}
        r = _run(_claude_preuse("sudo reboot"), env)
        assert r.returncode == 2, f"expected deny (2), got {r.returncode}\nstderr: {r.stderr}"

    def test_permission_request_no_cert_deny_json(self, tmp_path):
        """PermissionRequest + missing cert → deny JSON on stdout (exit 0)."""
        env = _env_with_key_no_cert(tmp_path)
        r = _run(_codex_permission("rm -rf /tmp/x"), env)
        assert r.returncode == 0
        out = json.loads(r.stdout)
        assert out["hookSpecificOutput"]["decision"]["behavior"] == "deny"

    def test_cert_missing_message_on_stderr(self, tmp_path):
        """Cert-missing denial must write a diagnostic to stderr."""
        env = {**_env_with_key_no_cert(tmp_path), "THENOW_APPROVAL_MODE": "balanced"}
        r = _run(_claude_preuse("sudo rm -rf /tmp/x"), env)
        assert r.returncode == 2
        assert "cert" in r.stderr.lower(), f"expected 'cert' in stderr: {r.stderr!r}"


# ---------------------------------------------------------------------------
# Strict mode
# ---------------------------------------------------------------------------

class TestStrictMode:
    """THENOW_APPROVAL_MODE=strict: every Bash PreToolUse command is intercepted."""

    def _strict_env(self, tmp_path) -> dict:
        """Strict mode, api_key present, cert missing → any Bash command denies."""
        cfg = tmp_path / "config.json"
        cfg.write_text(json.dumps({"api_key": "test-key"}))
        return {
            "THENOW_CONFIG_PATH": str(cfg),
            "THENOW_BROKER_URL": "https://127.0.0.1:19999",
            "THENOW_APPROVAL_MODE": "strict",
        }

    def test_low_risk_bash_denied_strict(self, tmp_path):
        """ls -la is normally low-risk, but strict mode intercepts it → cert missing → exit 2."""
        r = _run(_claude_preuse("ls -la"), self._strict_env(tmp_path))
        assert r.returncode == 2, f"expected deny (2) in strict mode, got {r.returncode}"

    def test_echo_denied_in_strict(self, tmp_path):
        """echo hello is benign, but strict mode intercepts all Bash → exit 2 (no cert)."""
        r = _run(_claude_preuse("echo hello world"), self._strict_env(tmp_path))
        assert r.returncode == 2

    def test_non_bash_tool_passes_strict(self, tmp_path):
        """Non-Bash tools are not intercepted even in strict mode."""
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_input": {"file_path": "/etc/hosts"},
            "transcript_path": "/home/user/.claude/transcript.json",
        }
        r = _run(payload, self._strict_env(tmp_path))
        assert r.returncode == 0, f"non-Bash tool must pass in strict mode, got {r.returncode}"


# ---------------------------------------------------------------------------
# Balanced mode — extra pattern detection
# ---------------------------------------------------------------------------

class TestBalancedModeExtraPatterns:
    """THENOW_APPROVAL_MODE=balanced: additional patterns beyond HIGH_RISK_PATTERNS."""

    def _balanced_no_key_env(self, tmp_path) -> dict:
        """Balanced mode, no api_key → intercept denies at API_KEY check (exit 2)."""
        return {**_env_no_api_key(tmp_path), "THENOW_APPROVAL_MODE": "balanced"}

    def test_low_risk_passthrough_balanced(self, tmp_path):
        """ls -la is not high-risk in balanced mode → passthrough (exit 0)."""
        r = _run(_claude_preuse("ls -la"), self._balanced_no_key_env(tmp_path))
        assert r.returncode == 0

    def test_echo_passthrough_balanced(self, tmp_path):
        """echo is not high-risk in balanced mode → passthrough (exit 0)."""
        r = _run(_claude_preuse("echo hello"), self._balanced_no_key_env(tmp_path))
        assert r.returncode == 0

    def test_git_dash_c_push_intercepted(self, tmp_path):
        """git -C <path> push is detected as high-risk in balanced mode."""
        r = _run(_claude_preuse("git -C /some/repo push origin main"),
                 self._balanced_no_key_env(tmp_path))
        assert r.returncode == 2, f"git -C push must be intercepted, got {r.returncode}"

    def test_find_delete_intercepted(self, tmp_path):
        """find ... -delete is detected as high-risk in balanced mode."""
        r = _run(_claude_preuse("find /tmp -name '*.tmp' -delete"),
                 self._balanced_no_key_env(tmp_path))
        assert r.returncode == 2, f"find -delete must be intercepted, got {r.returncode}"

    def test_bash_dash_c_intercepted(self, tmp_path):
        """bash -c <cmd> is detected as high-risk in balanced mode."""
        r = _run(_claude_preuse("bash -c 'echo hello'"),
                 self._balanced_no_key_env(tmp_path))
        assert r.returncode == 2, f"bash -c must be intercepted, got {r.returncode}"

    def test_sh_script_intercepted(self, tmp_path):
        """sh script.sh is detected as high-risk in balanced mode."""
        r = _run(_claude_preuse("sh deploy.sh"), self._balanced_no_key_env(tmp_path))
        assert r.returncode == 2, f"sh script.sh must be intercepted, got {r.returncode}"

    @pytest.mark.parametrize("command", [
        "zsh -lc 'echo hello'",
        "python3 -c 'print(1)'",
        "perl -e 'print 1'",
        "ruby -e 'puts 1'",
        "node -e 'console.log(1)'",
        "xargs rm",
        "git -C /tmp/repo reset --hard",
        "git --git-dir /tmp/repo/.git clean -fd",
    ])
    def test_opaque_and_git_override_commands_intercepted(self, tmp_path, command):
        r = _run(_claude_preuse(command), self._balanced_no_key_env(tmp_path))
        assert r.returncode == 2, f"{command!r} must be intercepted"

    def test_unknown_mode_defaults_to_strict(self, tmp_path):
        env = {**_env_no_api_key(tmp_path), "THENOW_APPROVAL_MODE": "typo"}
        r = _run(_claude_preuse("echo hello"), env)
        assert r.returncode == 2

    def test_existing_patterns_still_work_balanced(self, tmp_path):
        """Existing HIGH_RISK_PATTERNS (sudo, rm -rf) still fire in balanced mode."""
        for cmd in ["sudo reboot", "rm -rf /tmp/x"]:
            r = _run(_claude_preuse(cmd), self._balanced_no_key_env(tmp_path))
            assert r.returncode == 2, f"{cmd!r} must be intercepted in balanced mode"


class TestCodexRules:
    @pytest.mark.parametrize("command", [
        ["sudo", "echo", "test"],
        ["rm", "-rf", "/tmp/test"],
        ["git", "push"],
        ["zsh", "-lc", "echo hello"],
        ["python3", "-c", "print(1)"],
        ["git", "-C", "/tmp/repo", "push"],
    ])
    def test_rules_prompt_for_protected_commands(self, command):
        import shutil

        codex = shutil.which("codex")
        if not codex:
            pytest.skip("codex CLI not installed")
        rules = str(REPO_ROOT / "codex" / "default.rules.example")
        result = subprocess.run(
            [codex, "execpolicy", "check", "--rules", rules, *command],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, result.stderr
        assert '"decision":"prompt"' in result.stdout

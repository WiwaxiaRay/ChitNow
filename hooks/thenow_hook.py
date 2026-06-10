#!/usr/bin/env python3
"""
Claude Code PreToolUse hook for thenow approval broker.
Exit codes: 0 = allow, 2 = deny (blocks execution), 1 = hook error (non-blocking).

Set env vars (optional overrides):
  THENOW_BROKER_URL     broker HTTPS URL
  THENOW_API_KEY        API key
  THENOW_CERT_PATH      path to broker.crt for TLS pinning
  THENOW_CONFIG_PATH    path to broker config.json (set by install.sh)
"""
import json
import os
import re
import sys

import httpx

_DEBUG_LOG = "/tmp/thenow_hook_debug.log"
_DEBUG = os.environ.get("THENOW_DEBUG") == "1"


def _log_debug(msg: str):
    if not _DEBUG:
        return
    try:
        import stat
        existed = os.path.exists(_DEBUG_LOG)
        with open(_DEBUG_LOG, "a") as f:
            f.write(msg + "\n")
        if not existed:
            os.chmod(_DEBUG_LOG, stat.S_IRUSR | stat.S_IWUSR)  # 600
    except Exception:
        pass


def _load_broker_config() -> tuple[str, str, str | None]:
    """Returns (broker_url, api_key, cert_path). Env vars take priority."""
    url  = os.environ.get("THENOW_BROKER_URL")
    key  = os.environ.get("THENOW_API_KEY")
    cert = os.environ.get("THENOW_CERT_PATH")
    if not url or not key:
        # Resolve config.json: env var first, then common install paths
        _script_dir = os.path.dirname(os.path.abspath(__file__))
        _candidates = [
            p for p in [os.environ.get("THENOW_CONFIG_PATH")] if p
        ] + [
            os.path.normpath(os.path.join(_script_dir, "..", "broker", "config.json")),
            os.path.expanduser("~/chitnow/broker/config.json"),
            os.path.expanduser("~/thenow/broker/config.json"),
        ]
        cfg_path = next((p for p in _candidates if os.path.exists(p)), None)
        if cfg_path:
            try:
                cfg   = json.loads(open(cfg_path).read())
                url   = url  or "https://localhost:8000"
                key   = key  or cfg.get("api_key") or None
                cert  = cert or os.path.join(os.path.dirname(cfg_path), "certs", "broker.crt")
            except Exception as e:
                _log_debug(f"[config] parse error: {e}")
        else:
            _log_debug("[config] config.json not found in any candidate path")
        url = url or "https://localhost:8000"
    return url, key, cert

BROKER_URL, API_KEY, CERT_PATH = _load_broker_config()
TIMEOUT = 185  # slightly over broker's 180s

# API_KEY is None when config.json cannot be found or has no key.
# main() checks this and denies rather than falling back to a default.

HIGH_RISK_PATTERNS = [
    r"rm\s+-[rf]",
    r"\brm\b.*--recursive",
    r"git\s+push",
    r"git\s+reset\s+--hard",
    r"git\s+clean\s+-[fd]",
    r"chmod\s+[0-7]*7[0-7]*",
    r"curl\b.+\|\s*(ba)?sh",
    r"wget\b.+\|\s*(ba)?sh",
    r">\s*/etc/",
    r"\bdrop\s+table\b",
    r"\btruncate\s+table\b",
    r"\bsudo\b",
    r"\bpkill\b|\bkillall\b",
    r"mv\s+.+\s+/(?:etc|usr|bin|sbin|var)\b",
]


def is_high_risk(command: str) -> bool:
    return any(re.search(p, command, re.IGNORECASE) for p in HIGH_RISK_PATTERNS)


def summarize(command: str) -> str:
    c = command.strip()
    if re.search(r"rm\s+-rf?", c):
        parts = c.split()
        target = parts[-1] if len(parts) > 1 else "files"
        return f"Delete {target}"
    if "git push" in c:
        return f"Git push: {c}"
    if "git reset --hard" in c:
        return "Hard reset (destroys uncommitted changes)"
    if re.search(r"sudo\b", c):
        return f"sudo: {c[:60]}"
    return c[:80]


def _parse_input() -> tuple[str, str, str, str]:
    """返回 (command, cwd, agent, tool_name)。支持 Claude Code 和 Codex（均走 stdin JSON）。"""
    global _hook_event_name, _agent, _description
    claude_input = os.environ.get("CLAUDE_TOOL_INPUT")
    if claude_input is not None:
        # 旧版 Claude Code: env vars（保留作兼容）
        try:
            tool_input = json.loads(claude_input)
        except Exception:
            sys.exit(0)
        command   = tool_input.get("command", "")
        cwd       = os.environ.get("CLAUDE_CWD", os.getcwd())
        agent     = os.environ.get("THENOW_AGENT", "claude-code")
        tool_name = os.environ.get("CLAUDE_TOOL_NAME", "Bash")
        _log_debug(f"[claude-code-env] tool={tool_name} cmd={command[:80]!r}")
    else:
        # 新版 Claude Code 和 Codex：均通过 stdin 传 JSON
        raw = sys.stdin.read()
        _log_debug(f"[stdin] raw={raw[:600]!r}")
        try:
            data = json.loads(raw)
        except Exception:
            _log_debug("[stdin] parse failed — allowing")
            sys.exit(0)
        hook_event = data.get("hook_event_name", "")
        _hook_event_name = hook_event
        tool_input = data.get("tool_input", {})
        # PermissionRequest (Codex shell命令): command 在 tool_input 中
        # PreToolUse (Claude Code / Codex MCP工具): command 在 tool_input.command
        if hook_event == "PermissionRequest":
            if isinstance(tool_input, dict):
                raw_cmd = tool_input.get("command", tool_input.get("cmd", ""))
                _description = tool_input.get("description", "")
            elif isinstance(tool_input, list):
                raw_cmd = " ".join(map(str, tool_input))
                _description = ""
            elif isinstance(tool_input, str):
                raw_cmd = tool_input
                _description = ""
            else:
                raw_cmd = data.get("command", "")
                _description = ""
            command = raw_cmd
        else:
            command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
        cwd       = data.get("cwd", os.getcwd())
        tool_name = data.get("tool_name", hook_event or "shell_command")
        # transcript_path 字段是 Claude Code 独有的
        tp = data.get("transcript_path", "")
        if os.environ.get("THENOW_AGENT"):
            agent = os.environ["THENOW_AGENT"]
        elif tp and ".claude" in tp:
            agent = "claude-code"
        else:
            agent = "codex"
        _agent = agent
        _log_debug(f"[stdin] agent={agent} event={hook_event} tool={tool_name} cmd={command[:80]!r}")
    return command, cwd, agent, tool_name


_hook_event_name: str = ""  # set by _parse_input
_agent: str = ""            # set by _parse_input
_description: str = ""      # set by _parse_input (Codex PermissionRequest description)


def _cancel_request(req_id: str, headers: dict, verify) -> None:
    """Best-effort cancel — never raises, never blocks the fallback path."""
    try:
        httpx.post(
            f"{BROKER_URL}/cancel/{req_id}",
            headers=headers,
            timeout=3,
            verify=verify,
        )
    except Exception:
        pass


def _exit_passthrough() -> None:
    """Not high-risk — let Codex handle with its normal approval UI."""
    sys.exit(0)


def _exit_allow(message: str = "") -> None:
    """Watch approved — explicitly allow via JSON for PermissionRequest."""
    if _hook_event_name == "PermissionRequest":
        decision: dict = {"behavior": "allow"}
        if message:
            decision["message"] = message
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision,
            }
        }))
    sys.exit(0)


def _exit_deny(message: str = "") -> None:
    """Deny the command."""
    if _hook_event_name == "PermissionRequest":
        decision: dict = {"behavior": "deny"}
        if message:
            decision["message"] = message
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision,
            }
        }))
        sys.exit(0)
    # All PreToolUse denials use exit 2.
    # exit 1 means hook error (non-blocking in Claude Code); exit 2 blocks execution.
    if message:
        print(f"[thenow] denied: {message}", file=sys.stderr)
    sys.exit(2)


def main():
    global _hook_event_name, _agent, _description
    command, cwd, agent, tool_name = _parse_input()

    # Low-risk PreToolUse commands always pass through — no broker needed.
    if not command:
        _exit_passthrough()
    if _hook_event_name != "PermissionRequest" and not is_high_risk(command):
        _exit_passthrough()

    # Beyond here: high-risk command or PermissionRequest.
    if not API_KEY:
        _log_debug("[main] API_KEY is None — denying high-risk command")
        print("[thenow] broker config not found — denying high-risk command", file=sys.stderr)
        _exit_deny("ChitNow broker not configured — install ChitNow first")
        return

    summary = _description if _description else summarize(command)
    headers = {"X-API-Key": API_KEY, "Content-Type": "application/json"}

    verify: bool | str = CERT_PATH if CERT_PATH and os.path.exists(CERT_PATH) else False

    # Create approval request
    try:
        resp = httpx.post(
            f"{BROKER_URL}/approval-requests",
            json={
                "agent": agent,
                "risk": "high",
                "title": f"approve? {tool_name}",
                "summary": summary,
                "command": command,
                "cwd": cwd,
            },
            headers=headers,
            timeout=10,
            verify=verify,
        )
        resp.raise_for_status()
        req_id = resp.json()["id"]
    except Exception as e:
        print(f"[thenow] broker unreachable ({e}) — denying by default", file=sys.stderr)
        _exit_deny("broker unreachable")
        return  # _exit_deny calls sys.exit; this silences static-analysis warnings

    # PermissionRequest: give Watch 10s, then fall back to Codex's own approval UI
    # PreToolUse: wait full timeout, deny on expiry
    sse_timeout = 15 if _hook_event_name == "PermissionRequest" else TIMEOUT
    print(f"[thenow] waiting {sse_timeout}s for approval — {summary}", file=sys.stderr)

    # Wait via SSE
    try:
        with httpx.stream(
            "GET",
            f"{BROKER_URL}/wait/{req_id}",
            headers=headers,
            timeout=sse_timeout,
            verify=verify,
        ) as r:
            for line in r.iter_lines():
                if not line.startswith("data:"):
                    continue
                payload = json.loads(line[5:])
                status = payload.get("status", "expired")
                if status == "approved":
                    print("[thenow] approved ✓", file=sys.stderr)
                    _exit_allow("approved")
                else:
                    print(f"[thenow] {status} — aborting", file=sys.stderr)
                    _exit_deny(status)
    except httpx.TimeoutException:
        if _hook_event_name == "PermissionRequest":
            print("[thenow] Watch timeout — cancelling request, falling back to Codex UI",
                  file=sys.stderr)
            _cancel_request(req_id, headers, verify)
            _exit_passthrough()
        print("[thenow] SSE timeout — denying", file=sys.stderr)
        _exit_deny("timeout")
    except Exception as e:
        print(f"[thenow] SSE error ({e}) — denying", file=sys.stderr)
        _exit_deny("SSE error")

    _exit_deny("timeout")


if __name__ == "__main__":
    main()

"""
Relay client for ChitNow broker.

Calls the Cloudflare Worker /v1/push endpoint using canonical HMAC-SHA256
authentication via HTTP headers.

The relay credentials (relay_url, installation_id, relay_secret) are stored in
relay_credentials.json (600) alongside config.json. They are populated when the
paired iPhone registers with the Worker and sends the credentials back via pairing.

Relay failure is non-fatal: the broker logs a sanitised error and continues.
The LAN polling fallback (Watch + iPhone polling /pending-requests every 5s)
still handles delivery without relay.
"""
import asyncio
import hashlib
import hmac
import json
import os
import secrets
import time

import httpx

_DIR = os.path.dirname(os.path.abspath(__file__))
RELAY_CREDS_PATH = os.path.join(_DIR, "relay_credentials.json")

_ATTEMPT_TIMEOUT = 6   # seconds per attempt
_RETRY_DELAYS    = [2, 5, 15]  # seconds before 2nd, 3rd, 4th attempts

# Push status — updated by push_notification(); read by get_relay_status()
_last_push_ok: bool = False
_last_push_ok_at: float | None = None
_last_push_attempt_at: float | None = None


def _load_relay_creds() -> dict | None:
    """Returns relay credentials dict or None if not configured."""
    try:
        with open(RELAY_CREDS_PATH) as f:
            creds = json.load(f)
        if creds.get("relay_url") and creds.get("installation_id") and creds.get("relay_secret"):
            return creds
    except Exception:
        pass
    return None


def _hmac_sha256_hex(secret: str, message: str) -> str:
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()


def _sha256_hex(data: str) -> str:
    return hashlib.sha256(data.encode()).hexdigest()


def _build_auth_headers(
    method: str,
    path: str,
    body_text: str,
    installation_id: str,
    relay_secret: str,
) -> dict:
    """Build X-ChitNow-* auth headers using the canonical message signature."""
    timestamp = int(time.time())
    nonce = secrets.token_hex(16)
    body_hash = _sha256_hex(body_text)
    canonical = f"{method}\n{path}\n{timestamp}\n{nonce}\n{body_hash}"
    sig = _hmac_sha256_hex(relay_secret, canonical)
    return {
        "X-ChitNow-Installation": installation_id,
        "X-ChitNow-Timestamp":    str(timestamp),
        "X-ChitNow-Nonce":        nonce,
        "X-ChitNow-Signature":    sig,
    }


async def push_notification() -> bool:
    """
    Send a generic wake-up push via the Relay Worker.

    Retries up to 3 times (4 total attempts) with delays of 2s, 5s, 15s.
    Rate-limited (429) responses are not retried.
    Returns True on success, False on all attempts failing.
    Caller should not raise on False.
    """
    global _last_push_ok, _last_push_ok_at, _last_push_attempt_at

    creds = _load_relay_creds()
    if not creds:
        return False

    relay_url       = creds["relay_url"].rstrip("/")
    installation_id = creds["installation_id"]
    relay_secret    = creds["relay_secret"]
    body_text       = json.dumps({"event": "approval_pending"})

    for attempt, delay_before in enumerate([0] + _RETRY_DELAYS):
        if delay_before > 0:
            await asyncio.sleep(delay_before)

        _last_push_attempt_at = time.time()
        auth_headers = _build_auth_headers("POST", "/v1/push", body_text, installation_id, relay_secret)

        try:
            async with httpx.AsyncClient(timeout=_ATTEMPT_TIMEOUT) as client:
                resp = await client.post(
                    f"{relay_url}/v1/push",
                    content=body_text,
                    headers={"Content-Type": "application/json", **auth_headers},
                )
            if resp.status_code == 200:
                _last_push_ok    = True
                _last_push_ok_at = time.time()
                return True
            # Log sanitised error — never log relay_secret, installation_id value, or JWT
            reason = ""
            try:
                reason = resp.json().get("error", "")[:40]
            except Exception:
                pass
            if resp.status_code == 429:
                print(f"[relay] push rate_limited (attempt {attempt + 1})", flush=True)
                break  # don't retry on rate limit
            print(f"[relay] push failed {resp.status_code}: {reason} (attempt {attempt + 1})", flush=True)
        except Exception as e:
            print(f"[relay] push error: {type(e).__name__} (attempt {attempt + 1})", flush=True)

    _last_push_ok = False
    return False


def is_configured() -> bool:
    """Returns True if relay_credentials.json is present and complete."""
    return _load_relay_creds() is not None


def get_relay_status() -> dict:
    """Return relay status for the /health endpoint."""
    return {
        "configured": is_configured(),
        "last_push_ok": _last_push_ok,
        "last_push_ok_at": _last_push_ok_at,
        "last_push_attempt_at": _last_push_attempt_at,
    }


def save_credentials(relay_url: str, installation_id: str, relay_secret: str) -> None:
    """Write relay credentials to relay_credentials.json (mode 600).
    Called after the iPhone sends credentials back via the pairing confirm endpoint.
    """
    creds = {
        "relay_url": relay_url,
        "installation_id": installation_id,
        "relay_secret": relay_secret,
    }
    with open(RELAY_CREDS_PATH, "w") as f:
        json.dump(creds, f, indent=2)
    os.chmod(RELAY_CREDS_PATH, 0o600)
    print(f"[relay] credentials saved to {RELAY_CREDS_PATH}", flush=True)


def delete_credentials() -> None:
    """Remove relay credentials (called on uninstall or data purge)."""
    try:
        if os.path.exists(RELAY_CREDS_PATH):
            os.remove(RELAY_CREDS_PATH)
            print("[relay] credentials deleted", flush=True)
    except Exception as e:
        print(f"[relay] delete failed: {type(e).__name__}", flush=True)

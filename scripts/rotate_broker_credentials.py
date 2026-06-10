#!/usr/bin/env python3
"""
Rotate broker API key after a credential leak.

What this script does:
  1. Generates a new random 64-hex-char API key.
  2. Writes it to broker/config.json (600), preserving other fields (relay_url).
  3. Clears the devices table so stale device tokens (registered under the
     old key) are removed — all paired clients must re-register.
  4. Preserves TLS certs so re-pairing only requires scanning the QR again,
     not accepting a new certificate warning.
  5. Best-effort revokes relay installation and removes relay_credentials.json.
  6. Prints a re-pair reminder.

What this script does NOT do:
  - Clean git history (see SECURITY-ROTATION.md).
  - Restart the broker.
  - Rotate TLS certificates.

Usage:
    cd <repo-root>
    python3 scripts/rotate_broker_credentials.py
"""
import json
import os
import secrets
import sqlite3
import sys

_REPO              = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH        = os.path.join(_REPO, "broker", "config.json")
DB_PATH            = os.path.join(_REPO, "broker", "broker.db")
RELAY_CREDS_PATH   = os.path.join(_REPO, "broker", "relay_credentials.json")

KNOWN_LEAKED_KEYS = {
    "REDACTED_BROKER_API_KEY",
}


def _current_key() -> str | None:
    try:
        return json.loads(open(CONFIG_PATH).read()).get("api_key")
    except Exception:
        return None


def _write_key(new_key: str) -> None:
    # Read existing config to preserve all non-api_key fields (e.g. relay_url)
    cfg: dict = {}
    try:
        cfg = json.loads(open(CONFIG_PATH).read())
    except Exception:
        pass
    cfg["api_key"] = new_key
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_PATH, 0o600)


def _clear_devices() -> int:
    if not os.path.exists(DB_PATH):
        return 0
    try:
        conn = sqlite3.connect(DB_PATH)
        cur = conn.execute("DELETE FROM devices")
        count = cur.rowcount
        conn.commit()
        conn.close()
        return count
    except Exception as e:
        print(f"  warning: could not clear devices table: {e}", file=sys.stderr)
        return 0


def _revoke_relay_installation() -> None:
    """Best-effort: revoke relay installation and delete relay_credentials.json."""
    if not os.path.exists(RELAY_CREDS_PATH):
        return
    try:
        import hashlib
        import hmac as _hmac
        import time
        creds = json.loads(open(RELAY_CREDS_PATH).read())
        relay_url       = creds.get("relay_url", "").rstrip("/")
        installation_id = creds.get("installation_id", "")
        relay_secret    = creds.get("relay_secret", "")
        if not (relay_url and installation_id and relay_secret):
            return

        # Build auth headers for POST /v1/revoke
        import urllib.request
        timestamp = int(time.time())
        nonce = secrets.token_hex(16)
        body_text = "{}"
        body_hash = hashlib.sha256(body_text.encode()).hexdigest()
        canonical = f"POST\n/v1/revoke\n{timestamp}\n{nonce}\n{body_hash}"
        sig = _hmac.new(relay_secret.encode(), canonical.encode(), hashlib.sha256).hexdigest()

        req = urllib.request.Request(
            f"{relay_url}/v1/revoke",
            data=body_text.encode(),
            headers={
                "Content-Type": "application/json",
                "X-ChitNow-Installation": installation_id,
                "X-ChitNow-Timestamp":    str(timestamp),
                "X-ChitNow-Nonce":        nonce,
                "X-ChitNow-Signature":    sig,
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            status = resp.getcode()
        print(f"[rotate] Relay revocation: HTTP {status}")
    except Exception as e:
        print(f"[rotate] Relay revocation failed (best-effort, continuing): {type(e).__name__}: {e}",
              file=sys.stderr)
    finally:
        try:
            if os.path.exists(RELAY_CREDS_PATH):
                os.remove(RELAY_CREDS_PATH)
                print(f"[rotate] Deleted {RELAY_CREDS_PATH}")
        except Exception:
            pass


def main():
    old_key = _current_key()

    if old_key and old_key not in KNOWN_LEAKED_KEYS:
        # Prompt — the key may still be fine (user may have already rotated manually)
        answer = input(
            f"Current API key does not match known-leaked keys.\n"
            f"Rotate anyway? [y/N]: "
        ).strip().lower()
        if answer not in ("y", "yes"):
            print("Rotation cancelled.")
            sys.exit(0)

    new_key = secrets.token_hex(32)
    _write_key(new_key)
    print(f"[rotate] New API key written to {CONFIG_PATH}")

    cleared = _clear_devices()
    if cleared:
        print(f"[rotate] Cleared {cleared} device registration(s) from broker.db")

    # Best-effort relay revocation (non-fatal)
    if os.path.exists(RELAY_CREDS_PATH):
        print("[rotate] Revoking relay installation...")
        _revoke_relay_installation()

    print()
    print("=" * 60)
    print("NEXT STEPS")
    print("=" * 60)
    print("1. Restart the broker:")
    print("   launchctl unload ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist")
    print("   launchctl load  ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist")
    print()
    print("2. Re-pair all clients:")
    print("   Open https://localhost:8000/pair in your Mac browser.")
    print("   Scan the QR code in the ChitNow iPhone app.")
    print()
    print("3. Clean git history to expunge the leaked key.")
    print("   See SECURITY-ROTATION.md for instructions.")
    print()
    if old_key in KNOWN_LEAKED_KEYS:
        print("WARNING: the old key was publicly exposed in git history.")
        print("Treat it as fully compromised. Complete step 3 immediately.")
    print("=" * 60)


if __name__ == "__main__":
    main()

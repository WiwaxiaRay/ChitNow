# Security Rotation Guide

## Incident Summary

**Affected commit:** `8ea2df7580a0b9204e032d1428e34c39b402005b`  
**Affected file:** `broker/config.json`  
**Leaked secret:** API key `REDACTED_BROKER_API_KEY`  
**Gitignore fix:** commit `dfeecc3ca72bb533b4e704061b8d328e8610880d` (added broker/config.json to .gitignore)  
**Disclosure scope:** Commit is in the public repo history on GitHub.

**Risk:** Anyone who cloned or forked the repo before the gitignore fix can read the API key and impersonate a paired ChitNow client on any Mac running the broker with the leaked key. The key is LAN-scoped (HTTPS only to localhost/LAN IP) but the risk is real for developers who trusted the published commits.

---

## Immediate Remediation (already done)

1. `broker/config.json` is now gitignored (`.gitignore`).
2. `scripts/scan_secrets.sh` detects future leaks in working tree and recent history.
3. `scripts/rotate_broker_credentials.py` generates a new key and clears stale device registrations.

---

## Required: Rotate the API Key

Run once on your Mac:

```bash
cd <repo-root>
python3 scripts/rotate_broker_credentials.py
```

Then restart the broker and re-pair all iPhone clients:

```bash
launchctl unload ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist
launchctl load  ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist
# Open https://localhost:8000/pair and scan QR in iPhone app
```

---

## Required: Clean Git History

The leaked key is permanently in the git object store until history is rewritten.

> **Warning:** Rewriting history force-pushes to the remote and invalidates all forks and clones. Coordinate with all contributors before doing this.

### Using git-filter-repo (recommended)

```bash
# Install once
pip install git-filter-repo

# Replace the leaked key everywhere in history
git filter-repo --replace-text <(echo \
  "REDACTED_BROKER_API_KEY==>REDACTED_API_KEY")

# Force-push all branches
git push --force-with-lease --all
git push --force-with-lease --tags
```

> **Do not run this automatically.** Run only after coordinating with all repo collaborators, and after the broker key has already been rotated.

After force-pushing:
1. Ask GitHub Support to purge the cached views of the old commits.
2. All forks and clones must re-clone or run `git fetch --all && git reset --hard origin/main`.

---

## Preventing Future Leaks

- Run `bash scripts/scan_secrets.sh` before every push.
- Consider adding it as a pre-push git hook:
  ```bash
  echo 'bash scripts/scan_secrets.sh' >> .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  ```
- Never put secrets in `config.json`, `.env`, or any file that might slip through `.gitignore`.
- Review `.gitignore` after adding new secret-bearing files.

---

## What Is and Is Not Compromised

| Secret | Status |
|--------|--------|
| Broker API Key (historical) | **Compromised** — rotate immediately |
| TLS certificate (`broker.crt`) | Not a secret — safe to keep |
| TLS private key (`broker.key`) | Never committed — not compromised |
| APNs `.p8` key | Never committed — not compromised |
| iOS Keychain (paired devices) | Unaffected — stored locally on device |
| Watch App Group UserDefaults | Unaffected — stored locally on device |

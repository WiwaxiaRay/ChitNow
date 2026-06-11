#!/bin/bash
# scan_secrets.sh — detect credential leaks in the working tree and git history.
# Run from the repo root: bash scripts/scan_secrets.sh
# Exit 0 = clean; exit 1 = issues found.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# Use a temp file to track failures (avoids subshell variable scope issues)
FAIL_LOG=$(mktemp)
trap 'rm -f "$FAIL_LOG"' EXIT

_fail() { echo "FAIL: $1" >> "$FAIL_LOG"; echo "  [FAIL] $1"; }
_pass() { echo "  [ok]   $1"; }
_warn() { echo "  [WARN] $1"; }

echo "==> Scanning working tree for secrets..."

# ── 0. Sensitive local-file permissions ──────────────────────────────────────
for f in \
    broker/config.json \
    broker/relay_credentials.json \
    broker/AuthKey_ZRLVNRQ23Q.p8 \
    broker/certs/broker.key
do
    [ -e "$f" ] || continue
    MODE=$(stat -f '%Lp' "$f" 2>/dev/null || true)
    if [ -z "$MODE" ]; then
        _warn "Could not inspect permissions: $f"
    elif [ $((8#$MODE & 077)) -ne 0 ]; then
        _fail "Sensitive local file is group/world-readable ($MODE): $f"
    else
        _pass "Sensitive local file permissions are restricted ($MODE): $f"
    fi
done

# ── 1. APNs .p8 key in working tree ──────────────────────────────────────────
P8_FOUND=0
while IFS= read -r f; do
    P8_FOUND=1
    if git check-ignore -q "$f" 2>/dev/null; then
        _warn "Legacy APNs .p8 key present (gitignored, not committed; relay-only broker no longer needs it): $f"
    else
        _fail "APNs .p8 key NOT gitignored — would be committed: $f"
    fi
done < <(find . -name "*.p8" -not -path "./.git/*" -not -path "./.venv/*" 2>/dev/null)
if [ "$P8_FOUND" -eq 0 ]; then
    _pass "No .p8 files in working tree"
fi

# ── 2. Private keys (PEM) in tracked files ────────────────────────────────────
TRACKED_WITH_PRIVKEY=$(git ls-files -z | xargs -0 grep -IlE \
    '^-----BEGIN (EC |RSA |OPENSSH )?PRIVATE KEY-----$' 2>/dev/null || true)
if [ -n "$TRACKED_WITH_PRIVKEY" ]; then
    echo "$TRACKED_WITH_PRIVKEY" | while IFS= read -r f; do
        _fail "Private key material in tracked file: $f"
    done
else
    _pass "No private-key PEM material in tracked files"
fi

# ── 3. config.json not gitignored ────────────────────────────────────────────
if git check-ignore -q broker/config.json 2>/dev/null; then
    _pass "broker/config.json is gitignored"
else
    _fail "broker/config.json is NOT gitignored"
fi

# ── 4. Known-leaked API key in TRACKED (git-indexed) files ───────────────────
LEAKED_KEY="REDACTED_BROKER_API_KEY"
# Exclude: scripts/ (rotation/scan tools that reference the key legitimately),
#          broker/tests/ (test fixtures that reference the key for testing),
#          SECURITY-ROTATION.md (remediation documentation).
TRACKED_WITH_KEY=$(git ls-files | \
    grep -vE "^(scripts/|broker/tests/|SECURITY-ROTATION\.md)" | \
    xargs grep -l "$LEAKED_KEY" 2>/dev/null || true)
if [ -n "$TRACKED_WITH_KEY" ]; then
    echo "$TRACKED_WITH_KEY" | while IFS= read -r f; do
        _fail "Known-leaked API key in tracked file: $f"
    done
else
    _pass "Known-leaked API key not in any tracked file"
fi

# ── 5. Active config.json uses leaked key (working tree only, not git error) ──
if [ -f broker/config.json ]; then
    ACTIVE_KEY=$(python3 -c "import json; print(json.load(open('broker/config.json')).get('api_key',''))" 2>/dev/null || true)
    if [ "$ACTIVE_KEY" = "$LEAKED_KEY" ]; then
        _fail "Active broker/config.json still uses the known-leaked API key — run: python3 scripts/rotate_broker_credentials.py"
    else
        _pass "Active broker/config.json uses a different (non-leaked) API key"
    fi
fi

# ── 6. relay_credentials.json not committed ───────────────────────────────────
if git ls-files | grep -q "relay_credentials.json"; then
    _fail "relay_credentials.json is tracked by git"
else
    _pass "relay_credentials.json not tracked by git"
fi

# ── 7. Local env/Cloudflare state cannot be committed ────────────────────────
TRACKED_LOCAL_STATE=$(git ls-files | grep -E \
    '(^|/)(\.env(\..+)?|\.dev\.vars(\..+)?|\.wrangler/)' | \
    grep -vE '(\.env\.example|\.dev\.vars\.example)$' || true)
if [ -n "$TRACKED_LOCAL_STATE" ]; then
    echo "$TRACKED_LOCAL_STATE" | while IFS= read -r f; do
        _fail "Local environment/Cloudflare state is tracked: $f"
    done
else
    _pass "No local environment or Cloudflare state tracked"
fi

echo ""
echo "==> Scanning git history for secrets..."

# ── 8. config.json ever committed ────────────────────────────────────────────
if [ -n "$(git log --all --format="%H" -- broker/config.json 2>/dev/null)" ]; then
    _fail "broker/config.json appears in git history — clean with git-filter-repo (see SECURITY-ROTATION.md)"
else
    _pass "broker/config.json not in git history"
fi

# ── 9. .p8 files ever committed ──────────────────────────────────────────────
if [ -n "$(git log --all --format="%H" -- '*.p8' 2>/dev/null)" ]; then
    _fail ".p8 file appears in git history"
else
    _pass "No .p8 files in git history"
fi

# ── 10. Private key content in recent 50 commits ──────────────────────────────
RECENT_COMMITS=$(git log --all -50 --pretty="%H" 2>/dev/null)
PRIVKEY_IN_HISTORY=0
for commit in $RECENT_COMMITS; do
    MATCHES=$(git grep -IlE '^-----BEGIN (EC |RSA |OPENSSH )?PRIVATE KEY-----$' \
        "$commit" -- 2>/dev/null || true)
    if [ -n "$MATCHES" ]; then
        _fail "Private key material in commit: $commit"
        PRIVKEY_IN_HISTORY=1
        break
    fi
done
if [ "$PRIVKEY_IN_HISTORY" -eq 0 ]; then
    _pass "No private-key PEM material in recent 50 commits"
fi

echo ""
ISSUES=$(wc -l < "$FAIL_LOG")
if [ "$ISSUES" -gt 0 ]; then
    echo "==> $ISSUES issue(s) found. See SECURITY-ROTATION.md for remediation."
    exit 1
else
    echo "==> All checks passed."
    exit 0
fi

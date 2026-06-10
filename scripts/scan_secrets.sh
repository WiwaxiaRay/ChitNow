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

# ── 1. APNs .p8 key in working tree ──────────────────────────────────────────
P8_FOUND=0
while IFS= read -r f; do
    P8_FOUND=1
    if git check-ignore -q "$f" 2>/dev/null; then
        _warn "APNs .p8 key present (gitignored — OK for local APNs use, not committed): $f"
    else
        _fail "APNs .p8 key NOT gitignored — would be committed: $f"
    fi
done < <(find . -name "*.p8" -not -path "./.git/*" -not -path "./.venv/*" 2>/dev/null)
if [ "$P8_FOUND" -eq 0 ]; then
    _pass "No .p8 files in working tree"
fi

# ── 2. Private keys (PEM) in tracked files ────────────────────────────────────
TRACKED_WITH_PRIVKEY=$(git ls-files | xargs grep -l "BEGIN EC PRIVATE KEY\|BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY" 2>/dev/null || true)
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
TRACKED_WITH_KEY=$(git ls-files | grep -v "scan_secrets.sh\|rotate_broker_credentials.py\|test_security.py\|SECURITY-ROTATION.md" | \
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

echo ""
echo "==> Scanning git history for secrets..."

# ── 7. config.json ever committed ────────────────────────────────────────────
if git log --all --pretty="" --name-only 2>/dev/null | grep -q "^broker/config\.json$"; then
    _fail "broker/config.json appears in git history — clean with git-filter-repo (see SECURITY-ROTATION.md)"
else
    _pass "broker/config.json not in git history"
fi

# ── 8. .p8 files ever committed ──────────────────────────────────────────────
if git log --all --pretty="" --name-only 2>/dev/null | grep -q "\.p8$"; then
    _fail ".p8 file appears in git history"
else
    _pass "No .p8 files in git history"
fi

# ── 9. Private key content in recent 50 commits ───────────────────────────────
RECENT_COMMITS=$(git log --all --pretty="%H" 2>/dev/null | head -50)
PRIVKEY_IN_HISTORY=0
for commit in $RECENT_COMMITS; do
    if git show "$commit" 2>/dev/null | grep -q "BEGIN EC PRIVATE KEY\|BEGIN RSA PRIVATE KEY"; then
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

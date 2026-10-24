#!/usr/bin/env bash
# Small test suite for lib/picker-common.sh. Uses a fake `gh` (tests/stubs)
# so it never touches real GitHub accounts or the network.
#
# Usage:
#   bash tests/run-tests.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export PATH="$TESTS_DIR/stubs:$PATH"
export FAKE_GH_DIR="$WORK_DIR/gh"
export GIT_ACCOUNT_PICKER_CACHE_DIR="$WORK_DIR/cache"
mkdir -p "$FAKE_GH_DIR"

# shellcheck source=../lib/picker-common.sh
source "$REPO_DIR/lib/picker-common.sh"

passed=0
failed=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    passed=$((passed + 1))
    echo "ok   - $name"
  else
    failed=$((failed + 1))
    echo "FAIL - $name"
    echo "       expected: $(printf '%q' "$expected")"
    echo "       actual:   $(printf '%q' "$actual")"
  fi
}

# Fake gh state: one account name per line; the first one is active.
set_accounts() {
  printf '%s\n' "$@" > "$FAKE_GH_DIR/accounts"
}

# --- read_lines (mapfile stand-in for bash 3.2) -----------------------------

read_lines lines < <(printf '%s\n' one "two words" three)
check "read_lines keeps one element per line" "3|two words" "${#lines[@]}|${lines[1]}"

read_lines lines < <(true)
check "read_lines gives an empty array for empty input" "0" "${#lines[@]}"

# --- list_gh_accounts ------------------------------------------------------

set_accounts personal-account work-account
check "lists every signed-in account" \
  "personal-account work-account" \
  "$(list_gh_accounts github.com | tr '\n' ' ' | sed 's/ $//')"

set_accounts
check "lists nothing when no account is signed in" \
  "" \
  "$(list_gh_accounts github.com)"

# --- ensure_gh_login (with accounts already signed in: no browser) ---------

set_accounts personal-account work-account
check "ensure_gh_login returns the existing accounts" \
  "personal-account work-account" \
  "$(ensure_gh_login github.com 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# --- pick_account with a single account never prompts ----------------------

check "a single account is picked without asking" \
  "only-account" \
  "$(pick_account github.com only-account </dev/null 2>/dev/null)"

# --- validation throttling --------------------------------------------------

rm -rf "$GIT_ACCOUNT_PICKER_CACHE_DIR"
needs_validation github.com && r=yes || r=no
check "validates when never validated before" "yes" "$r"

mark_validated github.com
needs_validation github.com && r=yes || r=no
check "skips validation right after a successful check" "no" "$r"

GIT_ACCOUNT_PICKER_VALIDATE_TTL=0 needs_validation github.com && r=yes || r=no
check "validates again once the wait time has passed" "yes" "$r"

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

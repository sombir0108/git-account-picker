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
export GIT_ACCOUNT_PICKER_CONFIG_DIR="$WORK_DIR/config"
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

lines=()
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

# --- terminal detection -----------------------------------------------------

in_terminal 2>/dev/null && r=yes || r=no
check "stderr redirected away from a terminal means no terminal menu" "no" "$r"

# --- "Add account..." loop ---------------------------------------------------
# Replace the real prompt and browser sign-in with scripted versions: the
# first prompt picks "Add account...", the sign-in adds new-account, and the
# second prompt picks whatever is now last in the list.

real_prompt_once="$(declare -f prompt_once)"
real_open_browser_login="$(declare -f open_browser_login)"
prompt_once() {
  shift
  if [ ! -e "$WORK_DIR/asked-once" ]; then
    touch "$WORK_DIR/asked-once"
    printf '__ADD__'
  else
    local last
    for last; do :; done
    printf '%s' "$last"
  fi
}
open_browser_login() { echo new-account >> "$FAKE_GH_DIR/accounts"; }

set_accounts personal-account work-account
check "Add account... signs in and offers the new account" \
  "new-account" \
  "$(pick_account github.com personal-account work-account 2>/dev/null)"

rm -f "$WORK_DIR/asked-once"
set_accounts only-account
check "PICKER_ALWAYS_ASK shows the list even with one account" \
  "new-account" \
  "$(PICKER_ALWAYS_ASK=1 pick_account github.com only-account 2>/dev/null)"

# --- cancelling, or no way to ask, keeps the active account -----------------

rm -f "$WORK_DIR/browser-opened"
open_browser_login() { touch "$WORK_DIR/browser-opened"; }

set_accounts personal-account work-account
check "active_account reads the active account" "personal-account" "$(active_account github.com)"

prompt_once() { :; }
out="$(pick_account github.com personal-account work-account 2>"$WORK_DIR/err")"
check "cancelling picks nothing" "" "$out"
grep -q "Keeping the active github.com account 'personal-account'" "$WORK_DIR/err" && r=yes || r=no
check "cancelling says which account is kept" "yes" "$r"

prompt_once() { printf '__NONE__'; }
out="$(pick_account github.com personal-account work-account 2>"$WORK_DIR/err")"
check "no terminal or popup picks nothing" "" "$out"
grep -q "can't show the account picker here" "$WORK_DIR/err" && r=yes || r=no
check "no terminal or popup is reported, not silent" "yes" "$r"

touch "$FAKE_GH_DIR/token-invalid"
handle_invalid_credential github.com 2>/dev/null
check "cancelling after an expired token keeps the active account" "personal-account" "$(active_account github.com)"
[ -e "$WORK_DIR/browser-opened" ] && r=yes || r=no
check "cancelling after an expired token does not open the browser" "no" "$r"
rm -f "$FAKE_GH_DIR/token-invalid"

eval "$real_prompt_once"
eval "$real_open_browser_login"

# --- validation throttling --------------------------------------------------

rm -rf "$GIT_ACCOUNT_PICKER_CACHE_DIR"
needs_validation github.com && r=yes || r=no
check "validates when never validated before" "yes" "$r"

mark_validated github.com
needs_validation github.com && r=yes || r=no
check "skips validation right after a successful check" "no" "$r"

GIT_ACCOUNT_PICKER_VALIDATE_TTL=0 needs_validation github.com && r=yes || r=no
check "validates again once the wait time has passed" "yes" "$r"

# --- remembering which account goes with which owner -------------------------

check "owner from a credential path" "my-company" "$(owner_from_path "My-Company/repo.git")"
owner_from_path "abc123.git" >/dev/null && r=yes || r=no
check "no owner from a path without a slash (e.g. a gist)" "no" "$r"
owner_from_path "../etc/passwd" >/dev/null && r=yes || r=no
check "no owner from a path with odd characters" "no" "$r"
check "owner from an https remote" "my-company" "$(owner_from_remote_url "https://github.com/my-company/repo.git")"
check "owner from an ssh remote" "my-company" "$(owner_from_remote_url "git@github.com:my-company/repo.git")"
owner_from_remote_url "https://gitlab.com/my-company/repo.git" >/dev/null && r=yes || r=no
check "no owner from a non-GitHub remote" "no" "$r"

remember_account my-company work-account
remember_account someone-else personal-account
remember_account my-company client-account
check "remembering again replaces the old account" "client-account" "$(remembered_account my-company)"
forget_account my-company
check "forgetting removes only that owner" "|personal-account" \
  "$(remembered_account my-company)|$(remembered_account someone-else)"

# use_remembered_account switches only when needed.
set_accounts personal-account work-account
remember_account my-company work-account
use_remembered_account github.com my-company 2>/dev/null
check "switches to the remembered account" "work-account" "$(active_account github.com)"
use_remembered_account github.com unknown-owner 2>/dev/null
check "leaves the account alone for an owner with nothing remembered" "work-account" "$(active_account github.com)"

remember_account gone-owner deleted-account
use_remembered_account github.com gone-owner 2>/dev/null
check "forgets a remembered account that is no longer signed in" "" "$(remembered_account gone-owner)"

set_accounts personal-account work-account
GIT_ACCOUNT_PICKER_REMEMBER=0 use_remembered_account github.com my-company 2>/dev/null
check "GIT_ACCOUNT_PICKER_REMEMBER=0 turns it off" "personal-account" "$(active_account github.com)"

# Picking an account after a rejected credential (erase) remembers it.
prompt_once() { printf 'work-account'; }
set_accounts personal-account work-account
forget_account my-company
handle_invalid_credential github.com my-company 2>/dev/null
check "the account picked after a rejection is remembered for the owner" "work-account" "$(remembered_account my-company)"
eval "$real_prompt_once"

# End to end: git asks the helper for a credential for a remembered owner.
set_accounts personal-account work-account
out="$(printf 'protocol=https\nhost=github.com\npath=my-company/repo.git\n\n' \
  | bash "$REPO_DIR/bin/git-credential-account-picker.sh" get 2>/dev/null)"
check "credential helper answers with the remembered owner's account" "username=work-account" \
  "$(printf '%s\n' "$out" | grep '^username=')"

# Same, through real git with the useHttpPath setting install.sh adds, to
# prove git really passes the owner along. Ignores the user's git config.
set_accounts personal-account work-account
out="$(printf 'url=https://github.com/my-company/repo.git\n\n' \
  | GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 git \
      -c "credential.https://github.com.helper=!bash '$REPO_DIR/bin/git-credential-account-picker.sh'" \
      -c "credential.https://github.com.useHttpPath=true" \
      credential fill 2>/dev/null)"
check "git with useHttpPath gets the remembered owner's account" "username=work-account" \
  "$(printf '%s\n' "$out" | grep '^username=')"

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

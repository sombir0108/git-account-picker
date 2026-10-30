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

# Learning from success: git runs `store` after the server accepts a
# credential (simulated with `git credential approve`). The account that
# worked is remembered for the owner, e.g. after switching with the desktop
# shortcut, which knows nothing about repos.
forget_account new-org
printf 'url=https://github.com/New-Org/repo.git\nusername=work-account\npassword=fake\n\n' \
  | GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git \
      -c "credential.https://github.com.helper=!bash '$REPO_DIR/bin/git-credential-account-picker.sh'" \
      -c "credential.https://github.com.useHttpPath=true" \
      credential approve 2>/dev/null
check "an account that worked for an owner is remembered" "work-account" "$(remembered_account new-org)"

remember_working_account new-org work-account 2>"$WORK_DIR/err"
[ -s "$WORK_DIR/err" ] && r=yes || r=no
check "an already-remembered account is not announced again" "no" "$r"

remember_working_account gist-like "" 2>/dev/null
check "nothing is remembered without a username" "" "$(remembered_account gist-like)"

# --- "Remove account..." ------------------------------------------------------

check "nth_account picks by number" "work-account" "$(nth_account 2 personal-account work-account)"
check "nth_account ignores numbers off the list" "" "$(nth_account 3 personal-account work-account)"
check "nth_account ignores non-numbers" "" "$(nth_account x personal-account work-account)"

# Scripted prompts: first remove work-account, then pick the last one listed.
prompt_once() {
  shift
  if [ ! -e "$WORK_DIR/removed" ]; then
    touch "$WORK_DIR/removed"
    printf '__REMOVE__:work-account'
  else
    local last
    for last; do :; done
    printf '%s' "$last"
  fi
}
set_accounts personal-account work-account
remember_account my-company work-account
rm -f "$WORK_DIR/removed"
out="$(pick_account github.com personal-account work-account 2>/dev/null)"
check "Remove account... signs it out and asks again without it" "personal-account" "$out"
check "the removed account is gone from the list" "personal-account" "$(list_gh_accounts github.com | tr '\n' ' ' | sed 's/ $//')"
check "owners remembered for the removed account are forgotten" "" "$(remembered_account my-company)"

# Declining the removal (__AGAIN__) just shows the list again.
prompt_once() {
  shift
  if [ ! -e "$WORK_DIR/declined" ]; then touch "$WORK_DIR/declined"; printf '__AGAIN__'; else printf '%s' "$1"; fi
}
set_accounts personal-account work-account
out="$(pick_account github.com personal-account work-account 2>/dev/null)"
check "declining the removal asks again and keeps both accounts" "personal-account|2" \
  "$out|$(list_gh_accounts github.com | wc -l | tr -d ' ')"

# Removing the last account stops with a message instead of an empty list.
prompt_once() { printf '__REMOVE__:only-account'; }
set_accounts only-account
out="$(PICKER_ALWAYS_ASK=1 pick_account github.com only-account 2>"$WORK_DIR/err")"
check "removing the last account picks nothing" "" "$out"
grep -q "no GitHub accounts are signed in" "$WORK_DIR/err" && r=yes || r=no
check "removing the last account says so" "yes" "$r"
eval "$real_prompt_once"

# --- browser sign-in ----------------------------------------------------------

out_file="$WORK_DIR/gh-out"
echo "! First copy your one-time code: WXYZ-9876" > "$out_file"
check "reads the code from older gh output" "WXYZ-9876" "$(login_code_from "$out_file")"
echo "! One-time code (ABCD-1234) copied to clipboard" > "$out_file"
check "reads the code from newer gh output" "ABCD-1234" "$(login_code_from "$out_file")"

# Without a terminal: gh runs without asking anything (the fake gh fails if
# its input is a terminal), the page is opened, and the code is shown and
# copied; the call returns once gh has finished signing in.
real_show_login_code="$(declare -f show_login_code)"
real_open_device_page="$(declare -f open_device_page)"
real_copy_to_clipboard="$(declare -f copy_to_clipboard)"
show_login_code() { echo "$1" > "$WORK_DIR/shown-code"; }
open_device_page() { touch "$WORK_DIR/page-opened"; }
copy_to_clipboard() { echo "$1" > "$WORK_DIR/copied-code"; }
set_accounts personal-account
rm -f "$WORK_DIR/shown-code" "$WORK_DIR/page-opened" "$WORK_DIR/copied-code"
open_browser_login github.com 2>/dev/null
check "sign-in shows gh's one-time code" "ABCD-1234" "$(cat "$WORK_DIR/shown-code" 2>/dev/null)"
check "sign-in copies the code" "ABCD-1234" "$(cat "$WORK_DIR/copied-code" 2>/dev/null)"
[ -e "$WORK_DIR/page-opened" ] && r=yes || r=no
check "sign-in opens GitHub's sign-in page" "yes" "$r"
check "sign-in waits for gh to finish (new account is there)" "personal-account new-account" \
  "$(list_gh_accounts github.com | tr '\n' ' ' | sed 's/ $//')"
eval "$real_show_login_code"
eval "$real_open_device_page"
eval "$real_copy_to_clipboard"

# --- install.sh / uninstall.sh round trip -------------------------------------
# Uses a throwaway HOME and git config. Skipped on Windows, where the
# installer would touch the real desktop shortcut.

if [ "$(os_kind)" != "windows" ]; then
  fake_home="$WORK_DIR/home"
  mkdir -p "$fake_home"
  run_isolated() { env -u XDG_DATA_HOME -u XDG_CONFIG_HOME HOME="$fake_home" GIT_CONFIG_GLOBAL="$fake_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 "$@" </dev/null >/dev/null 2>&1; }
  inst="$fake_home/.git-account-picker"

  run_isolated bash "$REPO_DIR/install.sh"
  r=yes
  for f in bin/git-credential-account-picker.sh lib/picker-common.sh gui/picker-ui.ps1 uninstall.sh uninstall-windows.ps1 .git-account-picker-install; do
    [ -f "$inst/$f" ] || { r="no ($f missing)"; break; }
  done
  check "install.sh installs the tool, its uninstallers and the marker" "yes" "$r"
  check "install.sh turns on useHttpPath" "true" \
    "$(GIT_CONFIG_GLOBAL="$fake_home/.gitconfig" git config --global --get credential.https://github.com.useHttpPath)"

  if [ "$(os_kind)" = "linux" ]; then
    menu="$fake_home/.local/share/applications/switch-github-account.desktop"
    [ -f "$menu" ] && [ -f "$fake_home/Desktop/switch-github-account.desktop" ] && r=yes || r=no
    check "Linux: the app is in the applications menu and on the Desktop" "yes" "$r"
    grep -q "^Exec=bash \"$inst/bin/git-switch-account.sh\"$" "$menu" && grep -q "^Icon=$inst/gui/icon.png$" "$menu" && r=yes || r=no
    check "Linux: the menu entry runs the installed switcher with the icon" "yes" "$r"
    [ -f "$inst/gui/linux/account-picker.py" ] && r=yes || r=no
    check "Linux: the picker window is installed" "yes" "$r"
  fi

  if [ "$(os_kind)" = "macos" ]; then
    app="$fake_home/Applications/Switch GitHub Account.app"
    check "macOS: the app's Info.plist is valid" "ok" \
      "$(plutil -lint "$app/Contents/Info.plist" >/dev/null 2>&1 && echo ok || echo bad)"
    [ -x "$app/Contents/MacOS/switch-github-account" ] && r=yes || r=no
    check "macOS: the app has a runnable launcher" "yes" "$r"
    grep -q "$inst/bin/git-switch-account.sh" "$app/Contents/MacOS/switch-github-account" && r=yes || r=no
    check "macOS: the app launches the installed switcher" "yes" "$r"
    grep -q "/opt/homebrew/bin" "$app/Contents/MacOS/switch-github-account" && r=yes || r=no
    check "macOS: the app can find Homebrew's gh" "yes" "$r"
    [ -s "$app/Contents/Resources/icon.icns" ] && r=yes || r=no
    check "macOS: the app has its icon" "yes" "$r"
    [ -L "$fake_home/Desktop/Switch GitHub Account.app" ] && [ ! -e "$fake_home/Desktop/Switch GitHub Account.command" ] && r=yes || r=no
    check "macOS: the Desktop shortcut links to the app (no plain script)" "yes" "$r"
  fi

  run_isolated bash "$inst/uninstall.sh"
  [ -e "$inst" ] && r=yes || r=no
  check "the installed uninstall.sh removes its own install folder" "no" "$r"
  if [ "$(os_kind)" = "linux" ]; then
    [ -e "$fake_home/.local/share/applications/switch-github-account.desktop" ] && r=yes || r=no
    check "Linux: uninstall.sh removes the menu entry" "no" "$r"
  fi
  if [ "$(os_kind)" = "macos" ]; then
    [ -e "$fake_home/Applications/Switch GitHub Account.app" ] && r=yes || r=no
    check "macOS: uninstall.sh removes the app" "no" "$r"
  fi
  check "uninstall.sh removes the git settings" "" \
    "$(GIT_CONFIG_GLOBAL="$fake_home/.gitconfig" git config --global --get-regexp '^credential\.https://github\.com\.' || true)"

  # Run from a downloaded/cloned copy (no marker), it must never delete
  # that copy, only the default install folder.
  copy="$WORK_DIR/downloaded"
  mkdir -p "$copy/bin" "$copy/gui"
  cp "$REPO_DIR/uninstall.sh" "$copy/"
  mkdir -p "$inst"
  run_isolated bash "$copy/uninstall.sh"
  { [ -d "$copy" ] && [ ! -e "$inst" ]; } && r=yes || r=no
  check "uninstall.sh from a downloaded copy leaves that copy alone" "yes" "$r"
fi

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

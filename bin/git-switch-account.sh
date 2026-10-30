#!/usr/bin/env bash
# Standalone account switcher: prompts you to pick a `gh`-authenticated
# GitHub account and makes it the active one, independent of any git
# operation. This is what the desktop shortcut launches, and it can also
# be run directly from a terminal.
#
# Run inside a clone of a github.com repo, it also remembers the chosen
# account for that repo's owner (see README, "Remembering accounts").
#
# Usage:
#   git-switch-account.sh                 pick an account
#   git-switch-account.sh --list          show remembered owner -> account
#   git-switch-account.sh --forget OWNER  stop using a remembered account
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/picker-common.sh
source "$SCRIPT_DIR/../lib/picker-common.sh"

host="github.com"

case "${1:-}" in
  --list)
    if [ -s "$GIT_ACCOUNT_PICKER_OWNERS_FILE" ]; then
      awk '{ printf "%-30s %s\n", $1, $2 }' "$GIT_ACCOUNT_PICKER_OWNERS_FILE"
    else
      echo "No accounts remembered yet."
    fi
    exit 0
    ;;
  --forget)
    owner="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$owner" ]; then
      echo "Usage: git-switch-account.sh --forget OWNER" >&2
      exit 1
    fi
    forget_account "$owner"
    echo "Forgot the remembered account for $owner."
    exit 0
    ;;
  "") ;;
  *)
    cat >&2 <<'USAGE'
Usage:
  git-switch-account.sh                 pick an account
  git-switch-account.sh --list          show remembered owner -> account
  git-switch-account.sh --forget OWNER  stop using a remembered account
USAGE
    exit 1
    ;;
esac

# Linux desktop launcher (no terminal): the native window switches, adds and
# removes accounts itself. Falls through to the dialogs below if it can't
# run (e.g. GTK 4 for Python isn't installed).
if [ "$(os_kind)" = "linux" ] && ! in_terminal && linux_ui_available; then
  python3 "$PICKER_LINUX_UI" --mode manage --icon "$PICKER_GUI_DIR/icon.png" && exit 0
fi

if ! ensure_gh_installed; then
  exit 1
fi

accounts=()
read_lines accounts < <(ensure_gh_login "$host")

if [ "${#accounts[@]}" -eq 0 ]; then
  echo "Still no GitHub account configured for $host. Finish signing in and try again." >&2
  exit 1
fi

# Always show the list, even with one account, so "Add account..." is
# reachable from the shortcut.
chosen="$(PICKER_ALWAYS_ASK=1 pick_account "$host" "${accounts[@]}")"
# Cancelled (pick_account already said so): nothing to switch.
[ -n "$chosen" ] || exit 0
gh auth switch --hostname "$host" --user "$chosen" >/dev/null
echo "Switched active GitHub account to: $chosen"

if ! active_credential_is_valid "$host"; then
  echo "That account's credential is expired/revoked — opening browser to sign in again..." >&2
  open_browser_login "$host"
fi
mark_validated "$host"

# Run inside a github.com clone: remember this account for the repo's owner.
if remember_enabled; then
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if repo_owner="$(owner_from_remote_url "$remote_url")"; then
    remember_account "$repo_owner" "$chosen"
    echo "Will use $chosen for $repo_owner from now on (undo: git-switch-account.sh --forget $repo_owner)."
  fi
fi

case "$(os_kind)" in
  macos)
    osascript -e "display notification \"Switched to $chosen\" with title \"GitHub Account Picker\"" >/dev/null 2>&1 || true
    ;;
  linux)
    command -v notify-send >/dev/null 2>&1 && notify-send "GitHub Account Picker" "Switched to $chosen" || true
    ;;
esac

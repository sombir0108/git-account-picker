#!/usr/bin/env bash
# Standalone account switcher: prompts you to pick a `gh`-authenticated
# GitHub account and makes it the active one, independent of any git
# operation. This is what the desktop shortcut launches, and it can also
# be run directly from a terminal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/picker-common.sh
source "$SCRIPT_DIR/../lib/picker-common.sh"

host="github.com"

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

case "$(os_kind)" in
  macos)
    osascript -e "display notification \"Switched to $chosen\" with title \"GitHub Account Picker\"" >/dev/null 2>&1 || true
    ;;
  linux)
    command -v notify-send >/dev/null 2>&1 && notify-send "GitHub Account Picker" "Switched to $chosen" || true
    ;;
esac

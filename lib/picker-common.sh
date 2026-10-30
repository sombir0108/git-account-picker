#!/usr/bin/env bash
# Shared account-picking logic used by both:
#   - bin/git-credential-account-picker.sh (git credential helper)
#   - bin/git-switch-account.sh        (standalone / desktop shortcut)
#
# Meant to be sourced, not executed directly.

PICKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICKER_GUI_DIR="$(cd "$PICKER_LIB_DIR/../gui" && pwd)"

os_kind() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Darwin*) echo "macos" ;;
    *) echo "linux" ;;
  esac
}

# Labels of the extra entries in the terminal menu and popups.
PICKER_ADD_LABEL="Add account..."
PICKER_REMOVE_LABEL="Remove account..."
PICKER_REMOVE_NOTE="It is removed from this list and git stops using it. Your GitHub account itself is not deleted, and you can add it back with Add account..."

# True when a person is at a terminal. Checks stderr, not stdout: git pipes
# a credential helper's stdout, and callers capture ours with $(...), so
# stdout is never a terminal here even in a plain shell. IDEs and GUI git
# clients pipe stderr too, so they still get a popup. GIT_TERMINAL_PROMPT=0
# (set by tools that must never block on terminal input) forces the popup.
in_terminal() {
  [ "${GIT_TERMINAL_PROMPT:-1}" != "0" ] && [ -t 2 ] && [ -r /dev/tty ]
}

has_tty() {
  in_terminal && { exec 3<>/dev/tty; } 2>/dev/null
}

# Reads stdin into the array named $1, one element per line. Stands in for
# `mapfile -t`, which macOS's built-in bash 3.2 doesn't have.
read_lines() {
  local _line
  eval "$1=()"
  while IFS= read -r _line; do
    eval "$1+=(\"\$_line\")"
  done
}

list_gh_accounts() {
  local host="$1"
  gh auth status --hostname "$host" 2>&1 | sed -n 's/.*Logged in to [^ ]* account \([^ ]*\).*/\1/p'
}

# Prints the account at 1-based position $1 of the remaining arguments, or
# nothing when $1 isn't one of the listed numbers.
nth_account() {
  local n="$1"; shift
  case "$n" in ""|*[!0-9]*) return 0 ;; esac
  [ "$n" -ge 1 ] && [ "$n" -le "$#" ] || return 0
  eval "printf '%s' \"\${$n}\""
}

# Every prompt below prints one of: an account name, "__ADD__",
# "__REMOVE__:<account>" (removal already confirmed), "__AGAIN__" (removal
# declined: show the list again), nothing (cancelled), or "__NONE__" (no
# way to show a prompt here).

prompt_cli() {
  local host="$1"; shift
  local accounts=("$@")
  {
    echo ""
    echo "Choose GitHub account for $host:"
    local i=1
    for a in "${accounts[@]}"; do echo "  $i) $a"; i=$((i + 1)); done
    echo "  a) $PICKER_ADD_LABEL"
    echo "  r) $PICKER_REMOVE_LABEL"
    printf "Account [1-%d, a to add, r to remove, Enter to cancel]: " "${#accounts[@]}"
  } >&3
  local choice result=""
  read -r choice <&3 || choice=""
  case "$choice" in
    a|A) result="__ADD__" ;;
    r|R)
      local which target ans
      printf "Remove which account [1-%d]: " "${#accounts[@]}" >&3
      read -r which <&3 || which=""
      target="$(nth_account "$which" "${accounts[@]}")"
      result="__AGAIN__"
      if [ -n "$target" ]; then
        printf "%s\nSign out of '%s' on this computer? [y/N]: " "$PICKER_REMOVE_NOTE" "$target" >&3
        read -r ans <&3 || ans=""
        case "$ans" in y|Y|yes|Yes) result="__REMOVE__:$target" ;; esac
      fi
      ;;
    # Anything other than a listed number (including just Enter) cancels.
    *) result="$(nth_account "$choice" "${accounts[@]}")" ;;
  esac
  exec 3>&- 2>/dev/null || true
  printf '%s' "$result"
}

prompt_gui_windows() {
  local host="$1"; shift
  local accounts=("$@")
  local joined
  joined=$(IFS=,; echo "${accounts[*]}")
  local ps_path
  ps_path="$(cygpath -w "$PICKER_GUI_DIR/picker-gui.ps1" 2>/dev/null || echo "$PICKER_GUI_DIR/picker-gui.ps1")"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_path" -HostName "$host" -Accounts "$joined" 2>/dev/null | tr -d '\r'
}

# Builds an AppleScript list literal from the arguments.
applescript_list() {
  local list="" a
  for a in "$@"; do
    if [ -z "$list" ]; then list="\"$a\""; else list="$list, \"$a\""; fi
  done
  printf '{%s}' "$list"
}

# The native macOS window (gui/mac/AccountPicker.swift), which install.sh
# builds into the app. Without it the plain osascript dialogs are used.
PICKER_MAC_BIN="${GIT_ACCOUNT_PICKER_MAC_BIN:-$HOME/Applications/Switch GitHub Account.app/Contents/MacOS/AccountPicker}"

prompt_gui_macos() {
  local host="$1"; shift
  local accounts=("$@")
  if [ -x "$PICKER_MAC_BIN" ]; then
    # Adding and removing happen inside the window; it prints the chosen
    # account, or nothing when cancelled.
    local joined out
    joined=$(IFS=,; echo "${accounts[*]}")
    if out="$("$PICKER_MAC_BIN" --mode choose --host "$host" --accounts "$joined" \
        --active "$(gh config get -h "$host" user 2>/dev/null)" 2>/dev/null)"; then
      printf '%s' "$out"
      return
    fi
  fi
  local result
  # Cancel makes `choose from list` print "false"; osascript itself failing
  # (e.g. no GUI session over SSH) means no popup could be shown.
  result="$(osascript -e "choose from list $(applescript_list "${accounts[@]}" "$PICKER_ADD_LABEL" "$PICKER_REMOVE_LABEL") with prompt \"Choose GitHub account for $host:\" with title \"GitHub Account Picker\"" 2>/dev/null)" \
    || { printf '__NONE__'; return; }
  if [ "$result" = "$PICKER_ADD_LABEL" ]; then
    printf '__ADD__'
  elif [ "$result" = "$PICKER_REMOVE_LABEL" ]; then
    local target answer
    target="$(osascript -e "choose from list $(applescript_list "${accounts[@]}") with prompt \"Remove which account?\" with title \"Remove account\"" 2>/dev/null || true)"
    if [ -z "$target" ] || [ "$target" = "false" ]; then printf '__AGAIN__'; return; fi
    answer="$(osascript -e "display dialog \"Sign out of '$target' on this computer?\" & return & return & \"$PICKER_REMOVE_NOTE\" with title \"Remove account\" buttons {\"Cancel\", \"Remove\"} default button \"Cancel\" with icon caution" 2>/dev/null || true)"
    case "$answer" in
      *"button returned:Remove"*) printf '__REMOVE__:%s' "$target" ;;
      *) printf '__AGAIN__' ;;
    esac
  elif [ "$result" != "false" ]; then
    printf '%s' "$result"
  fi
}

prompt_gui_linux() {
  local host="$1"; shift
  local accounts=("$@")
  local sel="" tool
  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    printf '__NONE__'
    return
  elif command -v zenity >/dev/null 2>&1; then
    tool=zenity
    sel="$(zenity --list --title="GitHub Account Picker" \
      --text="Choose GitHub account for $host:" \
      --column="Account" "${accounts[@]}" "$PICKER_ADD_LABEL" "$PICKER_REMOVE_LABEL" \
      --height=300 --width=400 2>/dev/null || true)"
  elif command -v kdialog >/dev/null 2>&1; then
    tool=kdialog
    # kdialog --menu prints the chosen item's tag, so tag each item with the
    # account name itself.
    local args=()
    for a in "${accounts[@]}"; do args+=("$a" "$a"); done
    args+=("__ADD__" "$PICKER_ADD_LABEL" "__REMOVE__" "$PICKER_REMOVE_LABEL")
    sel="$(kdialog --title "GitHub Account Picker" --menu "Choose GitHub account for $host:" "${args[@]}" 2>/dev/null || true)"
  else
    printf '__NONE__'
    return
  fi

  if [ "$sel" = "$PICKER_ADD_LABEL" ] || [ "$sel" = "__ADD__" ]; then
    printf '__ADD__'
  elif [ "$sel" = "$PICKER_REMOVE_LABEL" ] || [ "$sel" = "__REMOVE__" ]; then
    local target="" question
    if [ "$tool" = zenity ]; then
      target="$(zenity --list --title="Remove account" --text="Remove which account?" \
        --column="Account" "${accounts[@]}" --height=300 --width=400 2>/dev/null || true)"
      question="Sign out of '$target' on this computer?

$PICKER_REMOVE_NOTE"
      [ -n "$target" ] && zenity --question --title="Remove account" --text="$question" \
        --ok-label="Remove" --cancel-label="Cancel" 2>/dev/null \
        && { printf '__REMOVE__:%s' "$target"; return; }
    else
      local args=()
      for a in "${accounts[@]}"; do args+=("$a" "$a"); done
      target="$(kdialog --title "Remove account" --menu "Remove which account?" "${args[@]}" 2>/dev/null || true)"
      question="Sign out of '$target' on this computer?

$PICKER_REMOVE_NOTE"
      [ -n "$target" ] && kdialog --title "Remove account" --warningyesno "$question" \
        --yes-label "Remove" --no-label "Cancel" 2>/dev/null \
        && { printf '__REMOVE__:%s' "$target"; return; }
    fi
    printf '__AGAIN__'
  else
    printf '%s' "$sel"
  fi
}

confirm_install_gh() {
  if in_terminal; then
    local ans
    {
      echo ""
      echo "GitHub CLI ('gh') is required but was not found."
      printf "Install it now? [y/N]: "
    } > /dev/tty
    read -r ans < /dev/tty || ans="n"
    case "$ans" in
      y|Y|yes|Yes) return 0 ;;
      *) return 1 ;;
    esac
  fi

  case "$(os_kind)" in
    windows)
      command -v powershell.exe >/dev/null 2>&1 || return 1
      local res
      res="$(powershell.exe -NoProfile -Command '
        Add-Type -AssemblyName System.Windows.Forms
        $r = [System.Windows.Forms.MessageBox]::Show("GitHub CLI (gh) is required but was not found. Install it now?", "git-account-picker", "YesNo", "Question")
        Write-Output $r
      ' 2>/dev/null | tr -d '\r')"
      [ "$res" = "Yes" ]
      ;;
    macos)
      local res
      res="$(osascript -e 'display dialog "GitHub CLI (gh) is required but was not found. Install it now?" with title "git-account-picker" buttons {"No", "Yes"} default button "Yes"' 2>/dev/null || echo "button returned:No")"
      case "$res" in *"button returned:Yes"*) return 0 ;; *) return 1 ;; esac
      ;;
    linux)
      command -v zenity >/dev/null 2>&1 || return 1
      zenity --question --title="git-account-picker" --text="GitHub CLI (gh) is required but was not found. Install it now?" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

install_gh() {
  case "$(os_kind)" in
    windows)
      if command -v winget.exe >/dev/null 2>&1; then
        winget.exe install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
      elif command -v choco.exe >/dev/null 2>&1; then
        choco.exe install gh -y
      else
        echo "No supported package manager (winget/choco) found. Install manually: https://cli.github.com/" >&2
        return 1
      fi
      ;;
    macos)
      if command -v brew >/dev/null 2>&1; then
        brew install gh
      else
        echo "Homebrew not found. Install manually: https://cli.github.com/" >&2
        return 1
      fi
      ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        (type -p wget >/dev/null || (sudo apt-get update && sudo apt-get install -y wget)) \
          && sudo mkdir -p -m 755 /etc/apt/keyrings \
          && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
          && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
          && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages/stable/deb stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
          && sudo apt-get update \
          && sudo apt-get install -y gh
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y 'dnf-command(config-manager)' \
          && sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo \
          && sudo dnf install -y gh
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm gh
      else
        echo "No supported package manager found. Install manually: https://cli.github.com/" >&2
        return 1
      fi
      ;;
  esac
}

ensure_gh_installed() {
  if command -v gh >/dev/null 2>&1; then
    return 0
  fi

  if confirm_install_gh; then
    echo "Installing GitHub CLI..." >&2
    if install_gh && command -v gh >/dev/null 2>&1; then
      return 0
    fi
    echo "GitHub CLI installation failed. Install manually: https://cli.github.com/" >&2
    return 1
  fi

  echo "GitHub CLI ('gh') is required. Install manually: https://cli.github.com/" >&2
  return 1
}

# GitHub's device sign-in page, where gh's one-time code is entered.
PICKER_DEVICE_URL="https://github.com/login/device"

open_device_page() {
  case "$(os_kind)" in
    macos) open "$PICKER_DEVICE_URL" >/dev/null 2>&1 || true ;;
    windows) powershell.exe -NoProfile -Command "Start-Process '$PICKER_DEVICE_URL'" >/dev/null 2>&1 || true ;;
    linux) { xdg-open "$PICKER_DEVICE_URL" >/dev/null 2>&1 & } ;;
  esac
}

copy_to_clipboard() {
  case "$(os_kind)" in
    macos) printf '%s' "$1" | pbcopy 2>/dev/null || true ;;
    windows) printf '%s' "$1" | clip.exe 2>/dev/null || true ;;
    linux)
      if command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy 2>/dev/null || true
      elif command -v xclip >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard 2>/dev/null || true
      elif command -v xsel >/dev/null 2>&1; then printf '%s' "$1" | xsel -b 2>/dev/null || true
      fi
      ;;
  esac
}

# Shows the one-time code in a dialog and waits until the user clicks Done.
show_login_code() {
  local code="$1"
  local msg="Your browser is opening GitHub's sign-in page ($PICKER_DEVICE_URL).

Enter this code there:  $code
(It's already copied, so you can just paste it.)

Sign in as the account you want to add, approve, then click Done."
  case "$(os_kind)" in
    macos)
      osascript -e 'on run argv' \
        -e 'display dialog (item 1 of argv) with title "Add GitHub account" buttons {"Done"} default button "Done"' \
        -e 'end run' "$msg" >/dev/null 2>&1 || true
      ;;
    windows)
      local ps_path
      ps_path="$(cygpath -w "$PICKER_GUI_DIR/login-code.ps1" 2>/dev/null || echo "$PICKER_GUI_DIR/login-code.ps1")"
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_path" -Code "$code" >/dev/null 2>&1 || true
      ;;
    linux)
      if command -v zenity >/dev/null 2>&1; then
        zenity --info --title="Add GitHub account" --text="$msg" 2>/dev/null || true
      elif command -v kdialog >/dev/null 2>&1; then
        kdialog --title "Add GitHub account" --msgbox "$msg" 2>/dev/null || true
      fi
      ;;
  esac
}

# Prints the one-time code from gh's sign-in output (file $1). Newer gh
# prints "One-time code (ABCD-1234) copied to clipboard", older "First copy
# your one-time code: ABCD-1234".
login_code_from() {
  sed -nE 's/.*code[^A-Z0-9]*([A-Z0-9]{4}-[A-Z0-9]{4}).*/\1/p' "$1" 2>/dev/null | head -n 1
}

# Browser sign-in for a new (or expired) account.
#
# gh always runs with its input not on a terminal, so it asks nothing:
# its "Authenticate Git with your GitHub credentials?" question would, on
# yes (the default), replace this tool's credential helper, and its
# prompts break in macOS Terminal ("unexpected escape sequence from
# terminal"). Instead gh prints a one-time code and waits; this opens the
# page to enter it on and shows the code (in the terminal, or in a dialog
# when there is none) until the sign-in finishes.
open_browser_login() {
  local host="$1"
  # `workflow` scope up front: without it GitHub rejects pushes that touch
  # .github/workflows files, and gh does not request it by default.
  local args=(auth login --hostname "$host" --git-protocol https --web --scopes workflow)

  if in_terminal; then
    echo "Opening GitHub's sign-in page in your browser. Enter the one-time code shown below there, then approve." >/dev/tty
    open_device_page
    gh "${args[@]}" </dev/null >/dev/tty 2>&1 || true
    return
  fi

  # macOS: the native window runs the sign-in and shows the code itself.
  if [ "$(os_kind)" = "macos" ] && [ -x "$PICKER_MAC_BIN" ]; then
    "$PICKER_MAC_BIN" --mode login --host "$host" >/dev/null 2>&1 && return
  fi

  local log pid code="" i=0
  log="$(mktemp)"
  gh "${args[@]}" </dev/null >"$log" 2>&1 &
  pid=$!
  while [ "$i" -lt 40 ]; do
    code="$(login_code_from "$log")"
    [ -n "$code" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
    i=$((i + 1))
  done

  if [ -n "$code" ]; then
    copy_to_clipboard "$code"
    open_device_page
    show_login_code "$code"
  else
    kill "$pid" 2>/dev/null || true
    echo "git-account-picker: couldn't start the GitHub sign-in:" >&2
    cat "$log" >&2
  fi
  wait "$pid" 2>/dev/null || true
  rm -f "$log"
}

# Ensures at least one gh-authenticated account exists for $host, opening a
# browser sign-in flow (in the current terminal if attached, otherwise a
# spawned terminal window) when none is found. Prints the resulting account
# list (possibly still empty) to stdout, one per line.
ensure_gh_login() {
  local host="$1"
  local accounts
  read_lines accounts < <(list_gh_accounts "$host")

  if [ "${#accounts[@]}" -eq 0 ]; then
    echo "No GitHub account configured for $host — opening browser to sign in..." >&2
    open_browser_login "$host"
    read_lines accounts < <(list_gh_accounts "$host")
  fi

  # Guarded: bash 3.2 treats "${accounts[@]}" of an empty array as unset.
  [ "${#accounts[@]}" -eq 0 ] || printf '%s\n' "${accounts[@]}"
}

# --- Expired / revoked / SSO-blocked token detection -----------------------
#
# git only calls the credential helper's `erase` hook on an HTTP 401. Some
# real-world failure modes never produce that: gh's locally-cached token can
# look fine to gh but be dead server-side (revoked, expired, org SSO
# re-authorization required — the last one is a 403, which git does NOT
# treat as a credential rejection at all). Left unhandled, git operations
# just fail with no prompt, silently.
#
# So `get` proactively checks the *active* account against the real API —
# throttled to once per GIT_ACCOUNT_PICKER_VALIDATE_TTL seconds (default 60) per host
# so this doesn't turn back into a network round trip on every single poll.

GIT_ACCOUNT_PICKER_CACHE_DIR="${GIT_ACCOUNT_PICKER_CACHE_DIR:-$HOME/.cache/git-account-picker}"

needs_validation() {
  local host="$1"
  local ttl="${GIT_ACCOUNT_PICKER_VALIDATE_TTL:-60}"
  local marker="$GIT_ACCOUNT_PICKER_CACHE_DIR/last-validated-$host"
  [ -f "$marker" ] || return 0
  local now last
  now="$(date +%s 2>/dev/null || echo 0)"
  last="$(cat "$marker" 2>/dev/null || echo 0)"
  [ "$(( now - last ))" -ge "$ttl" ]
}

mark_validated() {
  local host="$1"
  mkdir -p "$GIT_ACCOUNT_PICKER_CACHE_DIR" 2>/dev/null || true
  date +%s > "$GIT_ACCOUNT_PICKER_CACHE_DIR/last-validated-$host" 2>/dev/null || true
}

active_credential_is_valid() {
  local host="$1"
  gh api user --hostname "$host" >/dev/null 2>&1
}

# The active account's token is dead. Prompt to pick an account (this may
# just be "pick the same one again" if there's only one), switch to it, and
# if THAT one is also dead, fall back to a fresh browser sign-in instead of
# leaving the user with a still-broken credential.
#
# When the repo owner is known ($2, from `erase`), the account picked here
# is remembered for that owner (see use_remembered_account).
handle_invalid_credential() {
  local host="$1" owner="${2:-}"

  echo "GitHub credential for $host looks expired, revoked, or blocked (e.g. org SSO re-authorization) — asking you to re-authenticate..." >&2

  local accounts
  read_lines accounts < <(ensure_gh_login "$host")
  [ "${#accounts[@]}" -gt 0 ] || return

  local chosen
  chosen="$(pick_account "$host" "${accounts[@]}")"
  # Nothing chosen (cancelled, or no way to ask): leave things as they are.
  [ -n "$chosen" ] || return 0
  gh auth switch --hostname "$host" --user "$chosen" >/dev/null 2>&1 || true

  if [ -n "$owner" ] && remember_enabled; then
    remember_account "$owner" "$chosen"
    echo "git-account-picker: will use '$chosen' for $owner from now on (undo: git-switch-account.sh --forget $owner)." >&2
  fi

  if ! active_credential_is_valid "$host"; then
    echo "That account's credential is invalid too — opening browser to sign in again..." >&2
    open_browser_login "$host"
  fi
}

# Called from `get`. Silent and near-free when the active credential is
# still fine (the common case); only prompts when it's actually dead.
ensure_valid_credential() {
  local host="$1"

  needs_validation "$host" || return 0

  if active_credential_is_valid "$host"; then
    mark_validated "$host"
    return 0
  fi

  handle_invalid_credential "$host"
  mark_validated "$host"
}

# Prints the account gh currently uses for $host (empty if none).
active_account() {
  local host="$1"
  gh auth status --hostname "$host" 2>&1 | awk '
    / account / { for (i = 1; i < NF; i++) if ($i == "account") name = $(i + 1) }
    /Active account: true/ { print name; exit }'
}

# Shows the terminal menu or the popup once. Prints the chosen account name,
# "__ADD__" when "Add account..." was chosen, nothing when cancelled, or
# "__NONE__" when neither a terminal nor a popup is available.
prompt_once() {
  local host="$1"; shift

  if has_tty; then
    prompt_cli "$host" "$@"
    return
  fi

  case "$(os_kind)" in
    windows)
      if command -v powershell.exe >/dev/null 2>&1; then
        prompt_gui_windows "$host" "$@"
      else
        printf '__NONE__'
      fi
      ;;
    macos) prompt_gui_macos "$host" "$@" ;;
    linux) prompt_gui_linux "$host" "$@" ;;
  esac
}

# Prints the account to use for $host, or nothing when the user cancelled
# or could not be asked; callers then keep the active account. With one
# account it is used without asking, unless PICKER_ALWAYS_ASK=1 (the
# desktop shortcut sets it so "Add account..." stays reachable).
pick_account() {
  local host="$1"; shift
  local accounts=("$@")

  if [ "${#accounts[@]}" -le 1 ] && [ "${PICKER_ALWAYS_ASK:-0}" != "1" ]; then
    printf '%s' "${accounts[0]:-}"
    return
  fi

  local picked
  picked="$(prompt_once "$host" "${accounts[@]}")"
  # "Add account..." or "Remove account..." chosen: do it, refresh the list,
  # and ask again so the change shows straight away.
  while :; do
    case "$picked" in
      __ADD__) open_browser_login "$host" >&2 ;;
      __REMOVE__:*) remove_account "$host" "${picked#__REMOVE__:}" ;;
      __AGAIN__) ;;
      *) break ;;
    esac
    read_lines accounts < <(list_gh_accounts "$host")
    if [ "${#accounts[@]}" -eq 0 ]; then
      echo "git-account-picker: no GitHub accounts are signed in on this computer any more. Add one with the desktop shortcut or 'gh auth login'." >&2
      return 0
    fi
    picked="$(prompt_once "$host" "${accounts[@]}")"
  done

  # Never fall back to an arbitrary account silently: say what happened and
  # leave the active account alone.
  local active
  if [ "$picked" = "__NONE__" ]; then
    active="$(active_account "$host")"
    local hint=""
    [ "$(os_kind)" = "linux" ] && hint="install zenity or kdialog for a popup, or "
    echo "git-account-picker: can't show the account picker here (no terminal or popup available). Keeping the active $host account '${active:-none}'. To switch, ${hint}run git-switch-account.sh in a terminal." >&2
    picked=""
  elif [ -z "$picked" ]; then
    active="$(active_account "$host")"
    echo "git-account-picker: no account chosen. Keeping the active $host account '${active:-none}'." >&2
  fi
  printf '%s' "$picked"
}

# --- Remembering which account goes with which owner ------------------------
#
# After you pick an account for a repo owner (a user or organization, e.g.
# the "my-company" in github.com/my-company/repo), `get` switches to that
# account automatically next time, so mixing personal and work repos stops
# prompting. Needs git to send the repo path to the helper, which install.sh
# turns on with credential.https://github.com.useHttpPath. Stored as
# "owner account" lines; GIT_ACCOUNT_PICKER_REMEMBER=0 turns it off.

GIT_ACCOUNT_PICKER_CONFIG_DIR="${GIT_ACCOUNT_PICKER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/git-account-picker}"
GIT_ACCOUNT_PICKER_OWNERS_FILE="$GIT_ACCOUNT_PICKER_CONFIG_DIR/owners"

remember_enabled() {
  [ "${GIT_ACCOUNT_PICKER_REMEMBER:-1}" != "0" ]
}

# Prints the lowercased owner from a credential path like "Owner/repo.git",
# or fails when there isn't a valid one.
owner_from_path() {
  local owner="${1%%/*}"
  case "$owner" in
    ""|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  [ "$owner" != "$1" ] || return 1
  printf '%s' "$owner" | tr '[:upper:]' '[:lower:]'
}

# Prints the lowercased owner of a github.com remote URL (https or ssh), or
# fails when the URL isn't one.
owner_from_remote_url() {
  local path
  case "$1" in
    https://github.com/*) path="${1#https://github.com/}" ;;
    git@github.com:*) path="${1#git@github.com:}" ;;
    ssh://git@github.com/*) path="${1#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  owner_from_path "$path"
}

remembered_account() {
  local owner="$1"
  [ -f "$GIT_ACCOUNT_PICKER_OWNERS_FILE" ] || return 0
  awk -v o="$owner" '$1 == o { print $2; exit }' "$GIT_ACCOUNT_PICKER_OWNERS_FILE"
}

forget_account() {
  local owner="$1" file="$GIT_ACCOUNT_PICKER_OWNERS_FILE"
  [ -f "$file" ] || return 0
  awk -v o="$owner" '$1 != o' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Forgets every owner remembered for $1, e.g. once that account is removed.
forget_owners_of() {
  local account="$1" file="$GIT_ACCOUNT_PICKER_OWNERS_FILE"
  [ -f "$file" ] || return 0
  awk -v a="$account" '$2 != a' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# "Remove account...": signs the account out of gh on this computer (the
# GitHub account itself is untouched) and forgets owners remembered for it.
remove_account() {
  local host="$1" account="$2"
  if gh auth logout --hostname "$host" --user "$account" >/dev/null 2>&1; then
    forget_owners_of "$account"
    echo "git-account-picker: signed out of '$account' on this computer. The GitHub account itself is not deleted." >&2
  else
    echo "git-account-picker: couldn't sign out of '$account'." >&2
  fi
}

remember_account() {
  local owner="$1" account="$2"
  mkdir -p "$GIT_ACCOUNT_PICKER_CONFIG_DIR" 2>/dev/null || return 0
  forget_account "$owner"
  echo "$owner $account" >> "$GIT_ACCOUNT_PICKER_OWNERS_FILE"
}

# Called from `store`, which git sends after the server accepted a
# credential: remember the account that just worked for this owner. So
# switching once by any means (desktop shortcut included) is enough, and
# private repos are learned too, even though a wrong account there gets
# "not found" rather than a rejection that would reach `erase`.
remember_working_account() {
  local owner="$1" account="$2"
  [ -n "$owner" ] && remember_enabled || return 0
  case "$account" in
    ""|*[!A-Za-z0-9-]*) return 0 ;;
  esac
  [ "$(remembered_account "$owner")" != "$account" ] || return 0
  remember_account "$owner" "$account"
  echo "git-account-picker: will use '$account' for $owner from now on (undo: git-switch-account.sh --forget $owner)." >&2
}

# Called from `get`. When an account is remembered for this owner and isn't
# the active one, switch to it. Costs nothing for owners with no remembered
# account; otherwise one local `gh config get` (no network).
use_remembered_account() {
  local host="$1" owner="$2"
  [ -n "$owner" ] && remember_enabled || return 0
  local wanted active
  wanted="$(remembered_account "$owner")"
  [ -n "$wanted" ] || return 0
  active="$(gh config get -h "$host" user 2>/dev/null || true)"
  [ "$wanted" != "$active" ] || return 0
  if gh auth switch --hostname "$host" --user "$wanted" >/dev/null 2>&1; then
    echo "git-account-picker: switched to '$wanted' for $owner (remembered)." >&2
    # Check the newly active account on this request, not up to a minute later.
    rm -f "$GIT_ACCOUNT_PICKER_CACHE_DIR/last-validated-$host" 2>/dev/null || true
  else
    echo "git-account-picker: '$wanted' is remembered for $owner but isn't signed in any more; forgetting it." >&2
    forget_account "$owner"
  fi
}

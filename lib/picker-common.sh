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

has_tty() {
  [ -t 1 ] && { exec 3<>/dev/tty; } 2>/dev/null
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

prompt_cli() {
  local host="$1"; shift
  local accounts=("$@")
  {
    echo ""
    echo "Choose GitHub account for $host:"
    local i=1
    for a in "${accounts[@]}"; do echo "  $i) $a"; i=$((i + 1)); done
    printf "Account [1-%d]: " "${#accounts[@]}"
  } >&3
  local choice
  read -r choice <&3 || choice=1
  exec 3>&- 2>/dev/null || true
  local idx=$((choice - 1))
  if [ "$idx" -ge 0 ] 2>/dev/null && [ "$idx" -lt "${#accounts[@]}" ] 2>/dev/null; then
    printf '%s' "${accounts[$idx]}"
  else
    printf '%s' "${accounts[0]}"
  fi
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

prompt_gui_macos() {
  local host="$1"; shift
  local accounts=("$@")
  local list=""
  for a in "${accounts[@]}"; do
    if [ -z "$list" ]; then list="\"$a\""; else list="$list, \"$a\""; fi
  done
  local result
  result="$(osascript -e "choose from list {$list} with prompt \"Choose GitHub account for $host:\" with title \"GitHub Account Picker\"" 2>/dev/null || echo false)"
  if [ "$result" = "false" ] || [ -z "$result" ]; then
    printf '%s' "${accounts[0]}"
  else
    printf '%s' "$result"
  fi
}

prompt_gui_linux() {
  local host="$1"; shift
  local accounts=("$@")
  if command -v zenity >/dev/null 2>&1; then
    zenity --list --title="GitHub Account Picker" \
      --text="Choose GitHub account for $host:" \
      --column="Account" "${accounts[@]}" --height=300 --width=400 2>/dev/null \
      || printf '%s' "${accounts[0]}"
  elif command -v kdialog >/dev/null 2>&1; then
    local args=() i=0
    for a in "${accounts[@]}"; do args+=("$i" "$a"); i=$((i + 1)); done
    local sel
    sel="$(kdialog --title "GitHub Account Picker" --menu "Choose GitHub account for $host:" "${args[@]}" 2>/dev/null || true)"
    if [ -n "$sel" ]; then printf '%s' "$sel"; else printf '%s' "${accounts[0]}"; fi
  else
    printf '%s' "${accounts[0]}"
  fi
}

confirm_install_gh() {
  if [ -t 1 ] && [ -r /dev/tty ]; then
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

open_browser_login() {
  local host="$1"
  # `workflow` scope up front: without it GitHub rejects pushes that touch
  # .github/workflows files, and gh does not request it by default.
  local login_cmd="gh auth login --hostname $host --git-protocol https --web --scopes workflow"

  if [ -t 1 ] && [ -r /dev/tty ]; then
    eval "$login_cmd" < /dev/tty > /dev/tty 2>&1 || true
    return
  fi

  case "$(os_kind)" in
    windows)
      command -v powershell.exe >/dev/null 2>&1 || return
      powershell.exe -NoProfile -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-Command','$login_cmd' -Wait" >/dev/null 2>&1 || true
      ;;
    macos)
      osascript -e "tell application \"Terminal\" to do script \"$login_cmd\"" >/dev/null 2>&1 || true
      ;;
    linux)
      local term
      for term in x-terminal-emulator gnome-terminal konsole xterm; do
        if command -v "$term" >/dev/null 2>&1; then
          "$term" -e "bash -c '$login_cmd; read -p \"Press Enter to close\"'" >/dev/null 2>&1 &
          wait $! 2>/dev/null || true
          break
        fi
      done
      ;;
  esac
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
handle_invalid_credential() {
  local host="$1"

  echo "GitHub credential for $host looks expired, revoked, or blocked (e.g. org SSO re-authorization) — asking you to re-authenticate..." >&2

  local accounts
  read_lines accounts < <(ensure_gh_login "$host")
  [ "${#accounts[@]}" -gt 0 ] || return

  local chosen
  chosen="$(pick_account "$host" "${accounts[@]}")"
  [ -n "$chosen" ] && gh auth switch --hostname "$host" --user "$chosen" >/dev/null 2>&1 || true

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

pick_account() {
  local host="$1"; shift
  local accounts=("$@")

  if [ "${#accounts[@]}" -le 1 ]; then
    printf '%s' "${accounts[0]:-}"
    return
  fi

  if has_tty; then
    prompt_cli "$host" "${accounts[@]}"
    return
  fi

  case "$(os_kind)" in
    windows)
      if command -v powershell.exe >/dev/null 2>&1; then
        local picked
        picked="$(prompt_gui_windows "$host" "${accounts[@]}")"
        # "Add account..." clicked: run the browser sign-in, refresh the
        # list, and ask again so the new account can be picked right away.
        while [ "$picked" = "__ADD__" ]; do
          open_browser_login "$host" >&2
          read_lines accounts < <(list_gh_accounts "$host")
          picked="$(prompt_gui_windows "$host" "${accounts[@]}")"
        done
        printf '%s' "$picked"
      else
        printf '%s' "${accounts[0]}"
      fi
      ;;
    macos) prompt_gui_macos "$host" "${accounts[@]}" ;;
    linux) prompt_gui_linux "$host" "${accounts[@]}" ;;
  esac
}

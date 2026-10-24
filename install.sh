#!/usr/bin/env bash
# Installs git-account-picker and wires it up as the git credential helper
# for github.com / gist.github.com.
#
# Usage:
#   ./install.sh [install-dir]      (default install-dir: ~/.git-account-picker)
set -euo pipefail

INSTALL_DIR="${1:-$HOME/.git-account-picker}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git not found on PATH." >&2
  exit 1
fi

# shellcheck source=lib/picker-common.sh
source "$SRC_DIR/lib/picker-common.sh"

if ! ensure_gh_installed; then
  echo "Continuing install without GitHub CLI — the picker will prompt to install it later too." >&2
fi

echo "Installing git-account-picker to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/gui" "$INSTALL_DIR/lib"
cp "$SRC_DIR/bin/git-credential-account-picker.sh" "$INSTALL_DIR/bin/"
cp "$SRC_DIR/bin/git-switch-account.sh" "$INSTALL_DIR/bin/"
cp "$SRC_DIR/lib/picker-common.sh" "$INSTALL_DIR/lib/"
cp "$SRC_DIR/gui/picker-gui.ps1" "$INSTALL_DIR/gui/"
cp "$SRC_DIR/gui/switch-account.ps1" "$INSTALL_DIR/gui/"
cp "$SRC_DIR/gui/create-desktop-shortcut.ps1" "$INSTALL_DIR/gui/"
chmod +x "$INSTALL_DIR/bin/git-credential-account-picker.sh" "$INSTALL_DIR/bin/git-switch-account.sh"

for host in github.com gist.github.com; do
  git config --global --unset "credential.https://$host.username" 2>/dev/null || true
  git config --global --unset-all "credential.https://$host.helper" 2>/dev/null || true
  git config --global --add "credential.https://$host.helper" ""
  git config --global --add "credential.https://$host.helper" "!bash '$INSTALL_DIR/bin/git-credential-account-picker.sh'"
done
# Send the repo path (owner/repo) to the helper so it can remember which
# account each owner uses.
git config --global "credential.https://github.com.useHttpPath" true

shortcut_msg="(no desktop shortcut created)"
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v powershell.exe >/dev/null 2>&1; then
      switch_ps1_win="$(cygpath -w "$INSTALL_DIR/gui/switch-account.ps1" 2>/dev/null || echo "$INSTALL_DIR/gui/switch-account.ps1")"
      create_shortcut_win="$(cygpath -w "$INSTALL_DIR/gui/create-desktop-shortcut.ps1" 2>/dev/null || echo "$INSTALL_DIR/gui/create-desktop-shortcut.ps1")"
      shortcut_path="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$create_shortcut_win" -SwitchScriptPath "$switch_ps1_win" 2>/dev/null | tr -d '\r')"
      [ -n "$shortcut_path" ] && shortcut_msg="Desktop shortcut created: $shortcut_path"
    fi
    ;;
  Darwin*)
    desktop="$HOME/Desktop"
    mkdir -p "$desktop"
    cat > "$desktop/Switch GitHub Account.command" <<CMD
#!/usr/bin/env bash
"$INSTALL_DIR/bin/git-switch-account.sh"
CMD
    chmod +x "$desktop/Switch GitHub Account.command"
    shortcut_msg="Desktop shortcut created: $desktop/Switch GitHub Account.command"
    ;;
  *)
    desktop="$HOME/Desktop"
    mkdir -p "$desktop"
    cat > "$desktop/switch-github-account.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Switch GitHub Account
Comment=Switch the active GitHub CLI/git account
Exec=bash "$INSTALL_DIR/bin/git-switch-account.sh"
Terminal=false
Categories=Utility;
DESK
    chmod +x "$desktop/switch-github-account.desktop"
    shortcut_msg="Desktop shortcut created: $desktop/switch-github-account.desktop"
    ;;
esac

cat <<EOF

Done. $shortcut_msg

1. Log in every GitHub account you want to switch between:
     gh auth login

2. git operations against github.com/gist.github.com stay silent and use
   whichever account is currently active — no prompt on every command.
   You'll only be asked to pick an account when there's an actual problem:
   a request gets rejected for the wrong account (git retries right after
   you pick), or the active account's token turns out to be expired,
   revoked, or blocked by org SSO re-authorization (checked against the
   real API, throttled to once a minute so it stays fast).

3. Double-click the desktop shortcut any time to switch the active account
   manually, without waiting for a failure.

To remove this setup later, run: ./uninstall.sh "$INSTALL_DIR"
EOF

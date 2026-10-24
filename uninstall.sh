#!/usr/bin/env bash
# Reverses install.sh: removes the git config overrides and the installed
# copy of the scripts. Leaves your global credential.helper (e.g. Git
# Credential Manager) and any `gh auth login` sessions untouched.
#
# Usage:
#   ./uninstall.sh [install-dir]      (default install-dir: ~/.git-account-picker)
set -euo pipefail

INSTALL_DIR="${1:-$HOME/.git-account-picker}"

for host in github.com gist.github.com; do
  git config --global --unset-all "credential.https://$host.helper" 2>/dev/null || true
done
git config --global --unset "credential.https://github.com.useHttpPath" 2>/dev/null || true

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -Command '
        $p = Join-Path ([Environment]::GetFolderPath("Desktop")) "Switch GitHub Account.lnk"
        if (Test-Path $p) { Remove-Item $p -Force }
      ' >/dev/null 2>&1 || true
    fi
    ;;
  Darwin*) rm -f "$HOME/Desktop/Switch GitHub Account.command" ;;
  *) rm -f "$HOME/Desktop/switch-github-account.desktop" ;;
esac

rm -rf "$INSTALL_DIR"

echo "Uninstalled git-account-picker, reset the github.com/gist.github.com credential.helper overrides, and removed the desktop shortcut."

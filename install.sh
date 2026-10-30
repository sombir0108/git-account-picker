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
cp "$SRC_DIR/gui/picker-ui.ps1" "$INSTALL_DIR/gui/"
cp "$SRC_DIR/gui/login-code.ps1" "$INSTALL_DIR/gui/"
cp "$SRC_DIR/gui/switch-account.ps1" "$INSTALL_DIR/gui/"
cp "$SRC_DIR/gui/create-desktop-shortcut.ps1" "$INSTALL_DIR/gui/"
cp "$SRC_DIR/gui/icon.ico" "$SRC_DIR/gui/icon.png" "$INSTALL_DIR/gui/"
# Keep the uninstallers with the installed copy (people who used the
# one-line install have no other copy), plus a marker so they know this
# folder is an installed copy that is safe to delete.
cp "$SRC_DIR/uninstall.sh" "$SRC_DIR/uninstall-windows.ps1" "$INSTALL_DIR/"
echo "Installed by git-account-picker; removed by uninstall.sh." > "$INSTALL_DIR/.git-account-picker-install"
chmod +x "$INSTALL_DIR/bin/git-credential-account-picker.sh" "$INSTALL_DIR/bin/git-switch-account.sh" "$INSTALL_DIR/uninstall.sh"

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
    # A real app in ~/Applications, so it shows up in Launchpad, Spotlight
    # and Finder and can be kept in the Dock.
    app="$HOME/Applications/Switch GitHub Account.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    # The app's window (gui/mac/AccountPicker.swift) is built here with the
    # Swift compiler from the Xcode Command Line Tools, which git on macOS
    # already needs. Without them, or if the build fails, the app runs the
    # switcher script with the standard macOS dialogs instead.
    exe="switch-github-account"
    if [ "${GIT_ACCOUNT_PICKER_NO_NATIVE:-0}" = "1" ]; then
      echo "GIT_ACCOUNT_PICKER_NO_NATIVE=1: the app uses the standard macOS dialogs."
    elif xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; then
      echo "Building the macOS app window (this can take a minute)..."
      if swiftc -O -parse-as-library "$SRC_DIR/gui/mac/AccountPicker.swift" \
          -o "$app/Contents/MacOS/AccountPicker" >/dev/null 2>&1; then
        exe="AccountPicker"
      else
        echo "  Couldn't build it; the app will use the standard macOS dialogs." >&2
        rm -f "$app/Contents/MacOS/AccountPicker"
      fi
    else
      echo "Xcode Command Line Tools not found, so the app uses the standard macOS dialogs."
      echo "  For the full window, run 'xcode-select --install', then this installer again."
    fi
    if [ "$exe" = "switch-github-account" ]; then
      # Apps opened from Finder get a minimal PATH without Homebrew, where gh
      # usually lives, so add the usual places first.
      cat > "$app/Contents/MacOS/switch-github-account" <<APP
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"
exec /bin/bash "$INSTALL_DIR/bin/git-switch-account.sh"
APP
      chmod +x "$app/Contents/MacOS/switch-github-account"
    fi
    # The SwiftUI window needs macOS 12; the script fallback runs on older ones.
    minos="10.13"
    [ "$exe" = "AccountPicker" ] && minos="12.0"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Switch GitHub Account</string>
  <key>CFBundleDisplayName</key><string>Switch GitHub Account</string>
  <key>CFBundleIdentifier</key><string>io.github.sombirverma.git-account-picker</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>$minos</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    # App icon from gui/icon.png, with the tools built into macOS.
    if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
      iconset="$(mktemp -d)/icon.iconset"
      mkdir -p "$iconset"
      for size in 16 32 128 256; do
        sips -z "$size" "$size" "$INSTALL_DIR/gui/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null 2>&1 || true
        sips -z $((size * 2)) $((size * 2)) "$INSTALL_DIR/gui/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
      done
      iconutil -c icns "$iconset" -o "$app/Contents/Resources/icon.icns" 2>/dev/null || true
      rm -rf "$(dirname "$iconset")"
    fi
    # Tell Finder/Launchpad about the (re)built app.
    touch "$app"
    lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$lsregister" ] && "$lsregister" -f "$app" >/dev/null 2>&1 || true

    # Desktop shortcut: a link to the app, so it shows the app's icon. It
    # replaces the plain .command script earlier versions put there.
    desktop="$HOME/Desktop"
    mkdir -p "$desktop"
    rm -f "$desktop/Switch GitHub Account.command"
    rm -rf "$desktop/Switch GitHub Account.app"
    ln -s "$app" "$desktop/Switch GitHub Account.app"
    shortcut_msg="App created: $app
   (find it in Launchpad or Spotlight - search \"Switch GitHub\" - and drag it to the Dock to keep it there).
   Desktop shortcut created: $desktop/Switch GitHub Account"
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
Icon=$INSTALL_DIR/gui/icon.png
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

To remove this setup later, run: "$INSTALL_DIR/uninstall.sh"
(on Windows you can also run uninstall-windows.ps1 from that folder)
EOF

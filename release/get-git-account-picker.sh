#!/usr/bin/env bash
# One-line macOS / Linux install for git-account-picker, attached to every
# GitHub release. Downloads that release's git-account-picker.tar.gz to a
# temporary folder, runs install.sh from it, then cleans up.
#
#   curl -fsSL https://github.com/sombirverma/git-account-picker/releases/latest/download/get-git-account-picker.sh | bash
#
# The release workflow replaces __VERSION__ with the release tag, so this
# always installs the release it came with. Arguments are passed on to
# install.sh (e.g. a different install directory).
set -euo pipefail

repo="sombirverma/git-account-picker"
version="__VERSION__"
case "$version" in
  __*) base="https://github.com/$repo/releases/latest/download"; label="(latest)" ;;
  *) base="https://github.com/$repo/releases/download/$version"; label="$version" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading git-account-picker $label..."
curl -fsSL "$base/git-account-picker.tar.gz" | tar -xz -C "$tmp"
bash "$tmp/git-account-picker/install.sh" "$@"

#!/usr/bin/env bash
# git credential helper for github.com / gist.github.com.
#
# Deliberately does NOT prompt on every credential request just because
# git/IDEs call `get` constantly (status polling, background fetches,
# etc.) — that makes the picker pop up far more than the user actually
# wants to be asked. It only prompts when there's an actual problem:
#
#   - `erase`: the hook git calls after an HTTP 401 (server rejected the
#     credential — wrong account for this repo). git retries `get` right
#     after `erase` within the same operation, so switching accounts here
#     is enough to make the retry succeed with no extra step.
#   - `get`: additionally does a throttled (default: once per 60s per
#     host) liveness check of the *active* account against the real API.
#     This catches failure modes that never hit `erase` at all — a token
#     that's expired, revoked, or blocked by org SSO re-authorization
#     (that last one is a 403, which git does not treat as a credential
#     rejection) — which would otherwise fail silently with no prompt.
#
# Prompt strategy (shared by all of the above, and by
# bin/git-switch-account.sh for manual switching):
#   - If a real terminal (tty) is attached (plain shell, most CLI git usage)
#     -> numbered menu on that terminal.
#   - Otherwise (IDEs, GUI git clients spawning git without a tty)
#     -> native GUI popup: PowerShell/WinForms on Windows, `osascript` on
#        macOS, `zenity`/`kdialog` on Linux.
#
# Requires: git, the GitHub CLI (`gh`), and at least one `gh auth login`.
set -euo pipefail

op="${1:-}"
input="$(cat)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/picker-common.sh
source "$SCRIPT_DIR/../lib/picker-common.sh"

host="$(printf '%s\n' "$input" | sed -n 's/^host=//p' | tr -d '\r')"

# Repo owner (user or organization) for remembering which account it uses.
# Only sent when credential.useHttpPath is on, which install.sh sets for
# github.com; gist paths are gist IDs, not owners.
owner=""
if [ "$host" = "github.com" ]; then
  path="$(printf '%s\n' "$input" | sed -n 's/^path=//p' | tr -d '\r')"
  owner="$(owner_from_path "$path" || true)"
fi

if [ "$host" = "github.com" ] || [ "$host" = "gist.github.com" ]; then
  if [ "$op" = "erase" ]; then
    if ensure_gh_installed; then
      handle_invalid_credential "github.com" "$owner"
    fi
  elif [ "$op" = "get" ]; then
    if ensure_gh_installed; then
      use_remembered_account "github.com" "$owner"
      ensure_valid_credential "github.com"
    fi
  fi
fi

printf '%s' "$input" | gh auth git-credential "$op"

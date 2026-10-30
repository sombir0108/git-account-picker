# Standalone account switcher launched by the "Switch GitHub Account"
# desktop shortcut. Ensures the GitHub CLI is installed, ensures at least
# one account is signed in (opening a browser flow if not), lists
# gh-authenticated accounts and shows the popup from picker-ui.ps1, which
# switches, adds and removes accounts in place until it is closed.
. (Join-Path $PSScriptRoot "picker-ui.ps1")

# `workflow` scope up front: without it GitHub rejects pushes that touch
# .github/workflows files, and gh does not request it by default.
$loginArgs = "auth login --hostname github.com --git-protocol https --web --scopes workflow"

function Get-GhAccounts([string]$HostName) {
  $accounts = @()
  $statusOutput = & gh auth status --hostname $HostName 2>&1
  foreach ($line in $statusOutput) {
    if ($line -match "Logged in to \S+ account (\S+)") {
      $accounts += $Matches[1]
    }
  }
  return $accounts
}

function Invoke-BrowserLogin {
  # Spawned in its own console so gh can show its one-time code and wait.
  Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile", "-Command", "gh $loginArgs"
  ) -Wait
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  $install = Show-PickerDialog -Kind "info" -Heading "GitHub CLI is needed" `
    -Message "The picker uses the GitHub CLI (gh) to sign in and switch accounts, and it isn't installed. Install it now?" `
    -Buttons "Not now", "Install"
  if ($install -ne "Install") {
    [void](Show-PickerDialog -Kind "warning" -Heading "GitHub CLI is needed" `
        -Message "Install it from https://cli.github.com/ and open the picker again.")
    exit 1
  }

  $installed = $false
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
    $installed = $true
  }
  elseif (Get-Command choco -ErrorAction SilentlyContinue) {
    choco install gh -y
    $installed = $true
  }

  if (-not $installed -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    [void](Show-PickerDialog -Kind "warning" -Heading "Couldn't install the GitHub CLI" `
        -Message "Installing failed, or neither winget nor choco is available. Install it from https://cli.github.com/ and open the picker again.")
    exit 1
  }
}

$hostName = "github.com"
$accounts = Get-GhAccounts -HostName $hostName

if ($accounts.Count -eq 0) {
  [void](Show-PickerDialog -Kind "info" -Heading "Sign in to GitHub" `
      -Message "No GitHub account is set up on this computer yet. Press OK to sign in in your browser.")
  Invoke-BrowserLogin
  $accounts = Get-GhAccounts -HostName $hostName
}

if ($accounts.Count -eq 0) {
  [void](Show-PickerDialog -Kind "warning" -Heading "Still no GitHub account" `
      -Message "Finish signing in in the browser, then open the picker again.")
  exit 1
}

# The window stays open: switching, adding and removing happen in place and
# it reports how each went, until the user closes it.
$onSwitch = {
  param($target)
  & gh auth switch --hostname $hostName --user $target *> $null
  if ($LASTEXITCODE -ne 0) {
    return @{ Kind = "error"; Message = "Couldn't switch to $target. Try removing it and adding it again." }
  }
  & gh api user --hostname $hostName *> $null
  if ($LASTEXITCODE -ne 0) {
    Invoke-BrowserLogin
    return @{ Kind = "warning"; Message = "$target's sign-in had expired, so the browser sign-in was opened. Once that's done, git uses $target." }
  }
  return @{ Kind = "success"; Message = "Switched. git now uses $target." }
}
$onAdd = {
  Invoke-BrowserLogin
  return Get-GhAccounts -HostName $hostName
}
$onRemove = {
  param($target)
  & gh auth logout --hostname $hostName --user $target *> $null
  return Get-GhAccounts -HostName $hostName
}

Show-AccountPicker -Accounts $accounts -HostName $hostName `
  -Subtitle "Switch the account git uses for github.com" `
  -OnSwitch $onSwitch -OnAdd $onAdd -OnRemove $onRemove

# Standalone account switcher launched by the "Switch GitHub Account"
# desktop shortcut. Ensures the GitHub CLI is installed, ensures at least
# one account is signed in (opening a browser flow if not), lists
# gh-authenticated accounts, prompts via the popup in picker-ui.ps1 (with
# Add account and Remove buttons), then makes the chosen one active.
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
  $install = [System.Windows.Forms.MessageBox]::Show(
    "GitHub CLI (gh) is required but was not found. Install it now?",
    "git-account-picker", 'YesNo', 'Question')
  if ($install -ne [System.Windows.Forms.DialogResult]::Yes) {
    [System.Windows.Forms.MessageBox]::Show(
      "GitHub CLI is required. Install manually from https://cli.github.com/",
      "git-account-picker", 'OK', 'Warning') | Out-Null
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
    [System.Windows.Forms.MessageBox]::Show(
      "GitHub CLI installation failed or no supported package manager (winget/choco) was found. Install manually from https://cli.github.com/",
      "git-account-picker", 'OK', 'Error') | Out-Null
    exit 1
  }
}

$hostName = "github.com"
$accounts = Get-GhAccounts -HostName $hostName

if ($accounts.Count -eq 0) {
  [System.Windows.Forms.MessageBox]::Show(
    "No GitHub account is configured yet. Click OK to sign in via your browser.",
    "git-account-picker", 'OK', 'Information') | Out-Null
  Invoke-BrowserLogin
  $accounts = Get-GhAccounts -HostName $hostName
}

if ($accounts.Count -eq 0) {
  [System.Windows.Forms.MessageBox]::Show(
    "Still no GitHub account configured. Finish signing in and try again.",
    "git-account-picker", 'OK', 'Warning') | Out-Null
  exit 1
}

# Always show the list (even with one account) so "Add account..." is
# reachable; loop so a freshly added or removed account shows up straight
# away.
$chosen = $null
while ($true) {
  $picked = Show-AccountPicker -Accounts $accounts -HostName $hostName
  if ($picked -eq "__ADD__") {
    Invoke-BrowserLogin
    $accounts = Get-GhAccounts -HostName $hostName
    continue
  }
  if ($picked -like "__REMOVE__:*") {
    $target = $picked.Substring("__REMOVE__:".Length)
    & gh auth logout --hostname $hostName --user $target *> $null
    $accounts = Get-GhAccounts -HostName $hostName
    continue
  }
  $chosen = $picked
  break
}
if (-not $chosen) { exit 0 }

& gh auth switch --hostname $hostName --user $chosen | Out-Null

& gh api user --hostname $hostName *> $null
if ($LASTEXITCODE -ne 0) {
  [System.Windows.Forms.MessageBox]::Show(
    "Switched to `"$chosen`", but that account's credential is expired or revoked. Opening browser to sign in again...",
    "GitHub Account Picker", 'OK', 'Warning') | Out-Null
  Invoke-BrowserLogin
}
else {
  [System.Windows.Forms.MessageBox]::Show(
    "Active GitHub account switched to `"$chosen`".",
    "GitHub Account Picker", 'OK', 'Information') | Out-Null
}

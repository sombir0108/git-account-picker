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

# Browser sign-in. gh runs with its input redirected so it asks nothing:
# its "Authenticate Git with your GitHub credentials?" question would, on
# yes (the default), replace this tool's credential helper. It prints a
# one-time code instead; we open the sign-in page and show the code until
# the user is done, then wait for gh to finish.
function Invoke-BrowserLogin {
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gap-login-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $in = Join-Path $tmp "in"; $out = Join-Path $tmp "out"; $err = Join-Path $tmp "err"
  Set-Content -Path $in -Value ""
  try {
    $p = Start-Process -FilePath "gh" -ArgumentList $loginArgs -NoNewWindow -PassThru `
      -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err
    $code = $null
    for ($i = 0; $i -lt 40 -and -not $code; $i++) {
      $text = (Get-Content $out, $err -Raw -ErrorAction SilentlyContinue) -join "`n"
      # Newer gh: "One-time code (ABCD-1234) copied"; older: "one-time code: ABCD-1234".
      if ($text -match 'code[^A-Z0-9]*([A-Z0-9]{4}-[A-Z0-9]{4})') { $code = $Matches[1]; break }
      if ($p.HasExited) { break }
      Start-Sleep -Milliseconds 500
    }
    if (-not $code) {
      if (-not $p.HasExited) { $p.Kill() }
      [void](Show-PickerDialog -Kind "warning" -Heading "Couldn't start the GitHub sign-in" `
          -Message "The GitHub CLI didn't start a browser sign-in. Try again, or run 'gh auth login' in a terminal.")
      return
    }
    try { Set-Clipboard -Value $code } catch { }
    Start-Process "https://github.com/login/device"
    [void](Show-PickerDialog -Title "Add GitHub account" -Kind "info" `
        -Heading "Enter this code on GitHub:  $code" `
        -Message "Your browser is opening GitHub's sign-in page (github.com/login/device). The code is already copied, so you can just paste it there. Sign in as the account you want to add, approve, then click Done." `
        -Buttons "Done")
    $p.WaitForExit()
  }
  finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
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

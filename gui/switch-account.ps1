# Standalone account switcher launched by the "Switch GitHub Account"
# desktop shortcut. Ensures the GitHub CLI is installed, ensures at least
# one account is signed in (opening a browser flow if not), lists
# gh-authenticated accounts, prompts via a WinForms popup (with an
# "Add account..." button), then makes the chosen one active.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

# Returns the chosen account name, "__ADD__" for "Add account...",
# "__REMOVE__:<account>" once removing an account is confirmed, or $null.
function Show-AccountPicker([string[]]$Accounts) {
  $form = New-Object System.Windows.Forms.Form
  $form.Text = "GitHub Account Picker"
  $form.Width = 420
  $form.Height = 220
  $form.StartPosition = "CenterScreen"
  $form.TopMost = $true
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $iconPath = Join-Path $PSScriptRoot "icon.ico"
  if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon $iconPath }

  $label = New-Object System.Windows.Forms.Label
  $label.Text = "Choose active GitHub account:"
  $label.AutoSize = $true
  $label.Top = 15
  $label.Left = 15
  $form.Controls.Add($label)

  $listBox = New-Object System.Windows.Forms.ListBox
  $listBox.Top = 40
  $listBox.Left = 15
  $listBox.Width = 375
  $listBox.Height = 100
  foreach ($a in $Accounts) { [void]$listBox.Items.Add($a) }
  if ($listBox.Items.Count -gt 0) { $listBox.SelectedIndex = 0 }
  $form.Controls.Add($listBox)

  $addButton = New-Object System.Windows.Forms.Button
  $addButton.Text = "Add account..."
  $addButton.Top = 150
  $addButton.Left = 15
  $addButton.Width = 100
  $addButton.DialogResult = [System.Windows.Forms.DialogResult]::Retry
  $form.Controls.Add($addButton)

  $removeButton = New-Object System.Windows.Forms.Button
  $removeButton.Text = "Remove..."
  $removeButton.Top = 150
  $removeButton.Left = 121
  $removeButton.Width = 80
  $removeButton.DialogResult = [System.Windows.Forms.DialogResult]::Abort
  $form.Controls.Add($removeButton)

  $okButton = New-Object System.Windows.Forms.Button
  $okButton.Text = "Switch"
  $okButton.Top = 150
  $okButton.Left = 234
  $okButton.Width = 75
  $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $form.Controls.Add($okButton)
  $form.AcceptButton = $okButton

  # With every account removed, only "Add account..." and Cancel make sense.
  if ($listBox.Items.Count -eq 0) {
    $removeButton.Enabled = $false
    $okButton.Enabled = $false
  }

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = "Cancel"
  $cancelButton.Top = 150
  $cancelButton.Left = 315
  $cancelButton.Width = 75
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $form.Controls.Add($cancelButton)
  $form.CancelButton = $cancelButton

  # Loop so answering "No" to the remove confirmation goes back to the list.
  while ($true) {
    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::Abort -and $listBox.SelectedItem) {
      $target = [string]$listBox.SelectedItem
      $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Sign out of `"$target`" on this computer?`n`nIt is removed from this list and git stops using it. Your GitHub account itself is not deleted, and you can add it back with Add account...",
        "Remove account", 'YesNo', 'Warning', 'Button2')
      if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) { return "__REMOVE__:$target" }
      continue
    }
    if ($result -eq [System.Windows.Forms.DialogResult]::Retry) { return "__ADD__" }
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $listBox.SelectedItem) {
      return [string]$listBox.SelectedItem
    }
    return $null
  }
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
  $picked = Show-AccountPicker -Accounts $accounts
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

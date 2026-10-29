param(
  [Parameter(Mandatory = $true)][string]$HostName,
  [Parameter(Mandatory = $true)][string]$Accounts
)

# Prints the chosen account name, "__ADD__" when the user clicked
# "Add account..." (the caller then runs the browser sign-in and re-asks),
# "__REMOVE__:<account>" when the user confirmed removing an account (the
# caller signs it out and re-asks), or nothing when the popup was cancelled.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$accountList = $Accounts -split ','

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
$label.Text = "Choose GitHub account for ${HostName}:"
$label.AutoSize = $true
$label.Top = 15
$label.Left = 15
$form.Controls.Add($label)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Top = 40
$listBox.Left = 15
$listBox.Width = 375
$listBox.Height = 100
foreach ($a in $accountList) { [void]$listBox.Items.Add($a) }
$listBox.SelectedIndex = 0
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
$okButton.Text = "OK"
$okButton.Top = 150
$okButton.Left = 234
$okButton.Width = 75
$okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($okButton)
$form.AcceptButton = $okButton

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
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
      Write-Output "__REMOVE__:$target"
      break
    }
    continue
  }
  if ($result -eq [System.Windows.Forms.DialogResult]::Retry) {
    Write-Output "__ADD__"
  }
  elseif ($result -eq [System.Windows.Forms.DialogResult]::OK -and $listBox.SelectedItem) {
    Write-Output $listBox.SelectedItem
  }
  # Cancelled or closed: print nothing so the caller keeps the active account.
  break
}

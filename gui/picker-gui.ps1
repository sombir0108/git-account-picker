param(
  [Parameter(Mandatory = $true)][string]$HostName,
  [Parameter(Mandatory = $true)][string]$Accounts
)

# Prints the chosen account name, "__ADD__" when the user clicked
# "Add account" (the caller then runs the browser sign-in and re-asks),
# "__REMOVE__:<account>" when the user confirmed removing an account (the
# caller signs it out and re-asks), or nothing when the popup was cancelled.
. (Join-Path $PSScriptRoot "picker-ui.ps1")

$picked = Show-AccountPicker -Accounts ($Accounts -split ',') -HostName $HostName `
  -Subtitle "Choose the account git uses for $HostName"
# Cancelled or closed: print nothing so the caller keeps the active account.
if ($picked) { Write-Output $picked }

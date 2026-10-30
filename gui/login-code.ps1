param(
  [Parameter(Mandatory = $true)][string]$Code
)

# Shows gh's one-time sign-in code in the picker's style and waits until
# the user clicks Done. Used by open_browser_login in lib/picker-common.sh.
. (Join-Path $PSScriptRoot "picker-ui.ps1")

[void](Show-PickerDialog -Title "Add GitHub account" -Kind "info" `
    -Heading "Enter this code on GitHub:  $Code" `
    -Message "Your browser is opening GitHub's sign-in page (github.com/login/device). The code is already copied, so you can just paste it there. Sign in as the account you want to add, approve, then click Done." `
    -Buttons "Done")

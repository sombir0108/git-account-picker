# Smoke test for gui/picker-ui.ps1 under Windows PowerShell 5.1: builds the
# popup in both themes without showing it (catches runtime errors the
# parser can't), and checks the remembered UI settings round-trip.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\picker-ui-smoke.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$env:GIT_ACCOUNT_PICKER_CONFIG_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ("picker-ui-test-" + [guid]::NewGuid())
. (Join-Path $repo "gui\picker-ui.ps1")

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "ok   - $name" }
  else { Write-Host "FAIL - $name (expected '$expected', got '$actual')"; $script:failed++ }
}

foreach ($theme in "light", "dark") {
  $env:GIT_ACCOUNT_PICKER_THEME = $theme
  $out = @(Show-AccountPicker -Accounts "personal-account", "work-account" -ActiveAccount "work-account" -BuildOnly)
  Check "builds the $theme popup without printing anything" 0 $out.Count
}
$out = @(Show-AccountPicker -Accounts @() -BuildOnly)
Check "builds with no accounts left" 0 $out.Count
$out = @(Show-AccountPicker -Accounts "personal-account", "work-account" -ActiveAccount "work-account" -BuildOnly `
    -OnSwitch { @{ Kind = "success"; Message = "ok" } } -OnAdd { @() } -OnRemove { @() })
Check "builds the stay-open popup (desktop shortcut) without printing anything" 0 $out.Count

$s = Get-PickerUiSettings
Check "always on top is on by default" $true $s.TopMost
Check "opacity is 100% by default" 100 $s.Opacity
Save-PickerUiSettings @{ TopMost = $false; Opacity = 70 }
$s = Get-PickerUiSettings
Check "always on top setting is remembered" $false $s.TopMost
Check "opacity setting is remembered" 70 $s.Opacity
Set-Content (Join-Path $env:GIT_ACCOUNT_PICKER_CONFIG_DIR "ui-settings") "opacity=5"
Check "opacity below 40% is raised to 40%" 40 (Get-PickerUiSettings).Opacity

Remove-Item -Recurse -Force $env:GIT_ACCOUNT_PICKER_CONFIG_DIR
if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host "all passed"

# One-line Windows install for git-account-picker, attached to every
# GitHub release. Downloads that release's git-account-picker.zip to a
# temporary folder, runs install-windows.ps1 from it, then cleans up.
#
#   irm https://github.com/sombirverma/git-account-picker/releases/latest/download/get-git-account-picker.ps1 | iex
#
# The release workflow replaces __VERSION__ with the release tag, so this
# always installs the release it came with.
& {
  $ErrorActionPreference = "Stop"
  $repo = "sombirverma/git-account-picker"
  $version = "__VERSION__"
  $base = if ($version -like "__*") { "https://github.com/$repo/releases/latest/download" }
          else { "https://github.com/$repo/releases/download/$version" }

  # Windows PowerShell 5.1 may default to old TLS versions GitHub refuses.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("git-account-picker-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp "git-account-picker.zip"
    Write-Host "Downloading git-account-picker $(if ($version -like '__*') { '(latest)' } else { $version })..."
    Invoke-WebRequest "$base/git-account-picker.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp
    Get-ChildItem -Path $tmp -Recurse -File | Unblock-File
    & (Join-Path $tmp "git-account-picker\install-windows.ps1")
  }
  finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

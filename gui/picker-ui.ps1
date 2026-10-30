# The Windows account picker popup, shared by picker-gui.ps1 (prompts from
# git / IDEs) and switch-account.ps1 (the desktop shortcut). Dot-source it,
# then call Show-AccountPicker.
#
# Follows the Windows light/dark app theme, is DPI aware, and has an
# "Always on top" switch and an opacity slider at the bottom. Those two
# settings are remembered in <config dir>/ui-settings.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("PickerNative" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PickerNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
"@
}
# Sharp text on high-DPI screens; sizes below are scaled by hand with S.
[void][PickerNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Settings ------------------------------------------------------------------

function Get-PickerConfigDir {
  if ($env:GIT_ACCOUNT_PICKER_CONFIG_DIR) { return $env:GIT_ACCOUNT_PICKER_CONFIG_DIR }
  $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $env:USERPROFILE ".config" }
  return Join-Path $base "git-account-picker"
}

function Get-PickerUiSettings {
  $settings = @{ TopMost = $true; Opacity = 100 }
  $file = Join-Path (Get-PickerConfigDir) "ui-settings"
  if (Test-Path $file) {
    foreach ($line in Get-Content $file) {
      if ($line -match '^topmost=(true|false)$') { $settings.TopMost = ($Matches[1] -eq 'true') }
      if ($line -match '^opacity=(\d+)$') { $settings.Opacity = [Math]::Min(100, [Math]::Max(40, [int]$Matches[1])) }
    }
  }
  return $settings
}

function Save-PickerUiSettings($settings) {
  $dir = Get-PickerConfigDir
  try {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -Path (Join-Path $dir "ui-settings") -Value @(
      "topmost=$($settings.TopMost.ToString().ToLower())",
      "opacity=$($settings.Opacity)"
    )
  }
  catch { }
}

# --- Theme ---------------------------------------------------------------------

# Follows the Windows app theme; GIT_ACCOUNT_PICKER_THEME=light|dark overrides.
function Test-WindowsDarkMode {
  if ($env:GIT_ACCOUNT_PICKER_THEME -eq "dark") { return $true }
  if ($env:GIT_ACCOUNT_PICKER_THEME -eq "light") { return $false }
  try {
    $v = Get-ItemPropertyValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" -ErrorAction Stop
    return ($v -eq 0)
  }
  catch { return $false }
}

function Get-PickerTheme([bool]$Dark) {
  $c = { param($hex) [System.Drawing.ColorTranslator]::FromHtml($hex) }
  if ($Dark) {
    return @{
      Dark = $true; Back = & $c "#0D1117"; Surface = & $c "#161B22"; Border = & $c "#30363D"
      Text = & $c "#E6EDF3"; Muted = & $c "#8D96A0"; Selected = & $c "#1C2D41"; SelectedEdge = & $c "#388BFD"
      Hover = & $c "#1C2128"; Primary = & $c "#238636"; PrimaryText = & $c "#FFFFFF"; Green = & $c "#3FB950"
      Danger = & $c "#F85149"; Track = & $c "#30363D"; Accent = & $c "#388BFD"
    }
  }
  return @{
    Dark = $false; Back = & $c "#FFFFFF"; Surface = & $c "#F6F8FA"; Border = & $c "#D0D7DE"
    Text = & $c "#1F2328"; Muted = & $c "#656D76"; Selected = & $c "#DDF4FF"; SelectedEdge = & $c "#0969DA"
    Hover = & $c "#F3F4F6"; Primary = & $c "#1F883D"; PrimaryText = & $c "#FFFFFF"; Green = & $c "#1A7F37"
    Danger = & $c "#CF222E"; Track = & $c "#D0D7DE"; Accent = & $c "#0969DA"
  }
}

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = [Math]::Max(1, $r * 2)
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# Avatar colour by position in the list, so neighbours never share one.
function Get-AvatarColor([int]$index) {
  $palette = "#0969DA", "#8250DF", "#BC4C00", "#1A7F37", "#BF3989", "#1B7C83", "#9A6700", "#CF222E"
  return [System.Drawing.ColorTranslator]::FromHtml($palette[$index % $palette.Count])
}

# --- The popup -----------------------------------------------------------------

# Shows the popup. Returns the chosen account name, "__ADD__" for "Add
# account", "__REMOVE__:<account>" once removing an account is confirmed,
# or $null when cancelled. -BuildOnly builds the popup and closes it again
# without showing it (used by the automatic checks).
#
# Building and showing happen in this one function on purpose: the event
# handlers below use its local variables and helper functions, which only
# exist while it is running.
function Show-AccountPicker {
  param(
    [string[]]$Accounts = @(),
    [string]$Subtitle = "Choose the account git uses for github.com",
    [string]$PrimaryText = "Switch",
    [string]$ActiveAccount = "",
    [string]$HostName = "github.com",
    [switch]$BuildOnly
  )
  if (-not $ActiveAccount -and -not $BuildOnly -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $ActiveAccount = [string](& gh config get -h $HostName user 2>$null)
  }

  $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  $scale = $g0.DpiX / 96.0
  $g0.Dispose()
  function S([double]$n) { [int][Math]::Round($n * $scale) }

  # Layout (in 96-dpi units): the list fits its accounts, up to 5 rows,
  # then scrolls; everything below moves with it.
  $rows = [Math]::Min(5, [Math]::Max(1, @($Accounts).Count))
  $listH = $rows * 56 + 4
  $btnY = 76 + $listH + 14
  $divY = $btnY + 50
  $footY = $divY + 20

  $t = Get-PickerTheme (Test-WindowsDarkMode)
  $settings = Get-PickerUiSettings
  $font = New-Object System.Drawing.Font "Segoe UI", 9.75
  $fontBold = New-Object System.Drawing.Font "Segoe UI Semibold", 10.5
  $fontTitle = New-Object System.Drawing.Font "Segoe UI Semibold", 13
  $fontSmall = New-Object System.Drawing.Font "Segoe UI", 8.5

  $form = New-Object System.Windows.Forms.Form
  $form.Text = "GitHub Account Picker"
  $form.AutoScaleMode = 'None'
  $form.ClientSize = New-Object System.Drawing.Size (S 440), (S ($footY + 42))
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = 'FixedSingle'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.BackColor = $t.Back
  $form.ForeColor = $t.Text
  $form.Font = $font
  $form.KeyPreview = $true
  $form.TopMost = $settings.TopMost
  $form.Opacity = $settings.Opacity / 100.0
  $iconPath = Join-Path $PSScriptRoot "icon.ico"
  if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon $iconPath }
  $form.Add_HandleCreated({
      param($s, $e)
      # Dark title bar to match (Windows 10 20H1+ / 11), and rounded corners on 11.
      $on = if ($t.Dark) { 1 } else { 0 }
      [void][PickerNative]::DwmSetWindowAttribute($s.Handle, 20, [ref]$on, 4)
      $round = 2
      [void][PickerNative]::DwmSetWindowAttribute($s.Handle, 33, [ref]$round, 4)
    })

  # Header: icon, title, subtitle.
  $logo = New-Object System.Windows.Forms.PictureBox
  $logo.Location = New-Object System.Drawing.Point (S 20), (S 18)
  $logo.Size = New-Object System.Drawing.Size (S 40), (S 40)
  $logo.SizeMode = 'Zoom'
  $pngPath = Join-Path $PSScriptRoot "icon.png"
  if (Test-Path $pngPath) { $logo.Image = [System.Drawing.Image]::FromFile($pngPath) }
  $form.Controls.Add($logo)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = "GitHub accounts"
  $title.Font = $fontTitle
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point (S 70), (S 15)
  $form.Controls.Add($title)

  $sub = New-Object System.Windows.Forms.Label
  $sub.Text = $Subtitle
  $sub.ForeColor = $t.Muted
  $sub.AutoSize = $true
  $sub.Location = New-Object System.Drawing.Point (S 71), (S 42)
  $form.Controls.Add($sub)

  # Account list: one row per account with an initial "avatar".
  $list = New-Object System.Windows.Forms.ListBox
  $list.Location = New-Object System.Drawing.Point (S 20), (S 76)
  $list.Size = New-Object System.Drawing.Size (S 400), (S $listH)
  $list.BorderStyle = 'None'
  $list.BackColor = $t.Back
  $list.ForeColor = $t.Text
  $list.DrawMode = 'OwnerDrawFixed'
  $list.ItemHeight = S 56
  $list.IntegralHeight = $false
  foreach ($a in $Accounts) { [void]$list.Items.Add($a) }
  $start = if ($Accounts) { [Array]::IndexOf([string[]]$Accounts, $ActiveAccount) } else { -1 }
  if ($list.Items.Count -gt 0) { $list.SelectedIndex = [Math]::Max(0, $start) }
  $state = @{ Hover = -1 }
  $list.Add_DrawItem({
      param($s, $e)
      if ($e.Index -lt 0) { return }
      $gr = $e.Graphics
      $gr.SmoothingMode = 'AntiAlias'
      $gr.TextRenderingHint = 'ClearTypeGridFit'
      $name = [string]$s.Items[$e.Index]
      $b = $e.Bounds
      $gr.FillRectangle((New-Object System.Drawing.SolidBrush $t.Back), $b)
      $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
      $card = New-RoundedPath ($b.X + 1) ($b.Y + (S 3)) ($b.Width - 3) ($b.Height - (S 6)) (S 8)
      if ($selected) {
        $gr.FillPath((New-Object System.Drawing.SolidBrush $t.Selected), $card)
        $gr.DrawPath((New-Object System.Drawing.Pen $t.SelectedEdge, ([Math]::Max(1, (S 1.5)))), $card)
      }
      elseif ($e.Index -eq $state.Hover) {
        $gr.FillPath((New-Object System.Drawing.SolidBrush $t.Hover), $card)
      }
      # Avatar: coloured circle with the first letter.
      $av = S 34
      $ax = $b.X + (S 12); $ay = $b.Y + [int](($b.Height - $av) / 2)
      $gr.FillEllipse((New-Object System.Drawing.SolidBrush (Get-AvatarColor $e.Index)), $ax, $ay, $av, $av)
      $fmt = New-Object System.Drawing.StringFormat
      $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
      $initial = $name.Substring(0, 1).ToUpper()
      $gr.DrawString($initial, $fontBold, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF $ax, $ay, $av, $av), $fmt)
      # Name, and whether it's the account git uses right now.
      $tx = $ax + $av + (S 12)
      $gr.DrawString($name, $fontBold, (New-Object System.Drawing.SolidBrush $t.Text), $tx, $b.Y + (S 9))
      if ($name -eq $ActiveAccount) {
        $dot = S 7
        $gr.FillEllipse((New-Object System.Drawing.SolidBrush $t.Green), $tx + 1, $b.Y + (S 36), $dot, $dot)
        $gr.DrawString("Active now", $fontSmall, (New-Object System.Drawing.SolidBrush $t.Green), $tx + $dot + (S 4), $b.Y + (S 31))
      }
      else {
        $gr.DrawString("Signed in", $fontSmall, (New-Object System.Drawing.SolidBrush $t.Muted), $tx, $b.Y + (S 31))
      }
    })
  $list.Add_MouseMove({
      param($s, $e)
      $i = $s.IndexFromPoint($e.Location)
      if ($i -ne $state.Hover) { $state.Hover = $i; $s.Invalidate() }
    })
  $list.Add_MouseLeave({ param($s, $e) $state.Hover = -1; $s.Invalidate() })
  $list.Add_SelectedIndexChanged({ param($s, $e) $s.Invalidate() })
  $form.Controls.Add($list)

  # Buttons.
  function New-FlatButton([string]$text, [int]$x, [int]$w, $back, $fore, $border) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderColor = $border
    $btn.FlatAppearance.BorderSize = 1
    $btn.BackColor = $back
    $btn.ForeColor = $fore
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Location = New-Object System.Drawing.Point $x, (S $btnY)
    $btn.Size = New-Object System.Drawing.Size $w, (S 34)
    $btn.UseVisualStyleBackColor = $false
    return $btn
  }
  $add = New-FlatButton "+  Add account" (S 20) (S 120) $t.Surface $t.Text $t.Border
  $add.DialogResult = [System.Windows.Forms.DialogResult]::Retry
  $remove = New-FlatButton "Remove..." (S 148) (S 90) $t.Surface $t.Danger $t.Border
  $remove.DialogResult = [System.Windows.Forms.DialogResult]::Abort
  $cancel = New-FlatButton "Cancel" (S 246) (S 80) $t.Surface $t.Text $t.Border
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $ok = New-FlatButton $PrimaryText (S 334) (S 86) $t.Primary $t.PrimaryText $t.Primary
  $ok.Font = $fontBold
  $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $form.Controls.AddRange(@($add, $remove, $cancel, $ok))
  $form.AcceptButton = $ok
  $form.CancelButton = $cancel
  if ($list.Items.Count -eq 0) { $ok.Enabled = $false; $remove.Enabled = $false }
  $list.Add_DoubleClick({ if ($list.SelectedItem) { $form.DialogResult = [System.Windows.Forms.DialogResult]::OK } })

  # Footer: divider, "Always on top" switch, opacity slider.
  $divider = New-Object System.Windows.Forms.Panel
  $divider.BackColor = $t.Border
  $divider.Location = New-Object System.Drawing.Point 0, (S $divY)
  $divider.Size = New-Object System.Drawing.Size (S 440), 1
  $form.Controls.Add($divider)

  $toggle = New-Object System.Windows.Forms.Panel
  $toggle.Location = New-Object System.Drawing.Point (S 20), (S $footY)
  $toggle.Size = New-Object System.Drawing.Size (S 38), (S 22)
  $toggle.Cursor = [System.Windows.Forms.Cursors]::Hand
  $toggle.BackColor = $t.Back
  $toggle.Add_Paint({
      param($s, $e)
      $gr = $e.Graphics
      $gr.SmoothingMode = 'AntiAlias'
      $w = $s.Width - 1; $h = $s.Height - 1
      $pill = New-RoundedPath 0 0 $w $h ($h / 2)
      $fill = if ($form.TopMost) { $t.Accent } else { $t.Track }
      $gr.FillPath((New-Object System.Drawing.SolidBrush $fill), $pill)
      $k = $h - (S 6)
      $kx = if ($form.TopMost) { $w - $k - (S 3) } else { S 3 }
      $gr.FillEllipse([System.Drawing.Brushes]::White, $kx, (S 3), $k, $k)
    })
  $toggleLabel = New-Object System.Windows.Forms.Label
  $toggleLabel.Text = "Always on top"
  $toggleLabel.AutoSize = $true
  $toggleLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
  $toggleLabel.Location = New-Object System.Drawing.Point (S 64), (S ($footY + 1))
  $flipTopMost = {
    $form.TopMost = -not $form.TopMost
    $settings.TopMost = $form.TopMost
    Save-PickerUiSettings $settings
    $toggle.Invalidate()
  }
  $toggle.Add_Click($flipTopMost)
  $toggleLabel.Add_Click($flipTopMost)
  $form.Controls.AddRange(@($toggle, $toggleLabel))

  $opLabel = New-Object System.Windows.Forms.Label
  $opLabel.Text = "Opacity"
  $opLabel.ForeColor = $t.Muted
  $opLabel.AutoSize = $true
  $opLabel.Location = New-Object System.Drawing.Point (S 210), (S ($footY + 1))

  $slider = New-Object System.Windows.Forms.Panel
  $slider.Location = New-Object System.Drawing.Point (S 268), (S ($footY - 2))
  $slider.Size = New-Object System.Drawing.Size (S 112), (S 26)
  $slider.Cursor = [System.Windows.Forms.Cursors]::Hand
  $slider.BackColor = $t.Back
  $pct = New-Object System.Windows.Forms.Label
  $pct.Text = "$($settings.Opacity)%"
  $pct.AutoSize = $true
  $pct.Location = New-Object System.Drawing.Point (S 386), (S ($footY + 1))

  # Opacity runs 40-100%; lower would make the popup too hard to find.
  $setOpacity = {
    param([int]$value)
    $value = [Math]::Min(100, [Math]::Max(40, $value))
    if ($value -eq $settings.Opacity) { return }
    $settings.Opacity = $value
    $form.Opacity = $value / 100.0
    $pct.Text = "$value%"
    $slider.Invalidate()
  }
  $fromMouse = {
    param($x)
    $knob = S 16
    $span = $slider.Width - $knob
    $ratio = [Math]::Min(1.0, [Math]::Max(0.0, ($x - $knob / 2) / $span))
    & $setOpacity ([int][Math]::Round(40 + 60 * $ratio))
  }
  $slider.Add_Paint({
      param($s, $e)
      $gr = $e.Graphics
      $gr.SmoothingMode = 'AntiAlias'
      $knob = S 16
      $span = $s.Width - $knob
      $cy = $s.Height / 2
      $kx = $span * ($settings.Opacity - 40) / 60.0
      $line = S 4
      $gr.FillPath((New-Object System.Drawing.SolidBrush $t.Track), (New-RoundedPath ($knob / 2) ($cy - $line / 2) $span $line ($line / 2)))
      if ($kx -gt 0) {
        $gr.FillPath((New-Object System.Drawing.SolidBrush $t.Accent), (New-RoundedPath ($knob / 2) ($cy - $line / 2) $kx $line ($line / 2)))
      }
      $gr.FillEllipse((New-Object System.Drawing.SolidBrush $t.Accent), $kx, $cy - $knob / 2, $knob, $knob)
      $inner = S 6
      $gr.FillEllipse([System.Drawing.Brushes]::White, $kx + ($knob - $inner) / 2, $cy - $inner / 2, $inner, $inner)
    })
  $slider.Add_MouseDown({ param($s, $e) & $fromMouse $e.X })
  $slider.Add_MouseMove({ param($s, $e) if ($e.Button -eq 'Left') { & $fromMouse $e.X } })
  $slider.Add_MouseUp({ Save-PickerUiSettings $settings })
  $form.Controls.AddRange(@($opLabel, $slider, $pct))

  try {
    if ($BuildOnly) { return }
    # Loop so answering "No" to the remove confirmation goes back to the list.
    while ($true) {
      $result = $form.ShowDialog()
      if ($result -eq [System.Windows.Forms.DialogResult]::Abort -and $list.SelectedItem) {
        $target = [string]$list.SelectedItem
        $confirm = [System.Windows.Forms.MessageBox]::Show($form,
          "Sign out of `"$target`" on this computer?`n`nIt is removed from this list and git stops using it. Your GitHub account itself is not deleted, and you can add it back with Add account.",
          "Remove account", 'YesNo', 'Warning', 'Button2')
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) { return "__REMOVE__:$target" }
        continue
      }
      if ($result -eq [System.Windows.Forms.DialogResult]::Retry) { return "__ADD__" }
      if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedItem) {
        return [string]$list.SelectedItem
      }
      return
    }
  }
  finally {
    if (-not $BuildOnly) { Save-PickerUiSettings $settings }
    $form.Dispose()
  }
}

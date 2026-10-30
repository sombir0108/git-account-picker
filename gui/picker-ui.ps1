# The Windows account picker popup, shared by picker-gui.ps1 (prompts from
# git / IDEs) and switch-account.ps1 (the desktop shortcut). Dot-source it,
# then call Show-AccountPicker, or Show-PickerDialog for a styled message.
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
# Sharp text on high-DPI screens; sizes below are in 96-dpi units scaled by S.
[void][PickerNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$PickerScale = $g0.DpiX / 96.0
$g0.Dispose()
function S([double]$n) { [int][Math]::Round($n * $PickerScale) }

$PickerFont = New-Object System.Drawing.Font "Segoe UI", 9.75
$PickerFontBold = New-Object System.Drawing.Font "Segoe UI Semibold", 10.5
$PickerFontTitle = New-Object System.Drawing.Font "Segoe UI Semibold", 13
$PickerFontSmall = New-Object System.Drawing.Font "Segoe UI", 8.5

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

function Get-PickerTheme {
  $c = { param($hex) [System.Drawing.ColorTranslator]::FromHtml($hex) }
  if (Test-WindowsDarkMode) {
    return @{
      Dark = $true; Back = & $c "#0D1117"; Surface = & $c "#161B22"; Border = & $c "#30363D"
      Text = & $c "#E6EDF3"; Muted = & $c "#8D96A0"; Selected = & $c "#1C2D41"; SelectedEdge = & $c "#388BFD"
      Hover = & $c "#1C2128"; Primary = & $c "#238636"; PrimaryText = & $c "#FFFFFF"; Green = & $c "#3FB950"
      Danger = & $c "#F85149"; DangerFill = & $c "#DA3633"; Track = & $c "#30363D"; Accent = & $c "#388BFD"
      SuccessBg = & $c "#12261E"; SuccessFg = & $c "#3FB950"; WarnBg = & $c "#272115"; WarnFg = & $c "#D29922"
      InfoBg = & $c "#121D2F"; InfoFg = & $c "#58A6FF"
    }
  }
  return @{
    Dark = $false; Back = & $c "#FFFFFF"; Surface = & $c "#F6F8FA"; Border = & $c "#D0D7DE"
    Text = & $c "#1F2328"; Muted = & $c "#656D76"; Selected = & $c "#DDF4FF"; SelectedEdge = & $c "#0969DA"
    Hover = & $c "#F3F4F6"; Primary = & $c "#1F883D"; PrimaryText = & $c "#FFFFFF"; Green = & $c "#1A7F37"
    Danger = & $c "#CF222E"; DangerFill = & $c "#CF222E"; Track = & $c "#D0D7DE"; Accent = & $c "#0969DA"
    SuccessBg = & $c "#DAFBE1"; SuccessFg = & $c "#1A7F37"; WarnBg = & $c "#FFF8C5"; WarnFg = & $c "#9A6700"
    InfoBg = & $c "#DDF4FF"; InfoFg = & $c "#0969DA"
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

# A form with the theme, icon, title bar colour and remembered settings.
function New-PickerForm($t, [string]$title, [int]$width, [int]$height) {
  $form = New-Object System.Windows.Forms.Form
  $form.Text = $title
  $form.AutoScaleMode = 'None'
  $form.ClientSize = New-Object System.Drawing.Size (S $width), (S $height)
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = 'FixedSingle'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.ShowInTaskbar = $true
  $form.BackColor = $t.Back
  $form.ForeColor = $t.Text
  $form.Font = $PickerFont
  $form.KeyPreview = $true
  $iconPath = Join-Path $PSScriptRoot "icon.ico"
  if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon $iconPath }
  $form.Add_HandleCreated({
      param($s, $e)
      # Dark title bar to match (Windows 10 20H1+ / 11), rounded corners on 11.
      $on = [int]($s.BackColor.GetBrightness() -lt 0.5)
      [void][PickerNative]::DwmSetWindowAttribute($s.Handle, 20, [ref]$on, 4)
      $round = 2
      [void][PickerNative]::DwmSetWindowAttribute($s.Handle, 33, [ref]$round, 4)
    })
  return $form
}

function New-PickerButton($t, [string]$text, [string]$style, [int]$x, [int]$y, [int]$w) {
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $text
  $btn.FlatStyle = 'Flat'
  $btn.FlatAppearance.BorderSize = 1
  $btn.UseVisualStyleBackColor = $false
  $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
  $btn.Location = New-Object System.Drawing.Point (S $x), (S $y)
  $btn.Size = New-Object System.Drawing.Size (S $w), (S 34)
  switch ($style) {
    "primary" { $btn.BackColor = $t.Primary; $btn.ForeColor = $t.PrimaryText; $btn.FlatAppearance.BorderColor = $t.Primary; $btn.Font = $PickerFontBold }
    "danger" { $btn.BackColor = $t.DangerFill; $btn.ForeColor = [System.Drawing.Color]::White; $btn.FlatAppearance.BorderColor = $t.DangerFill; $btn.Font = $PickerFontBold }
    "danger-outline" { $btn.BackColor = $t.Surface; $btn.ForeColor = $t.Danger; $btn.FlatAppearance.BorderColor = $t.Border }
    default { $btn.BackColor = $t.Surface; $btn.ForeColor = $t.Text; $btn.FlatAppearance.BorderColor = $t.Border }
  }
  return $btn
}

# --- Styled message / question ---------------------------------------------------

# Replaces MessageBox with the picker's look. -Buttons lists the button
# labels left to right; the last one is the main action. Returns the label
# clicked, or nothing when the window was closed. -Kind: info, success,
# warning or danger (danger makes the main button red).
function Show-PickerDialog {
  param(
    [string]$Title = "GitHub Account Picker",
    [string]$Heading,
    [string]$Message,
    [string[]]$Buttons = @("OK"),
    [string]$Kind = "info",
    $Owner = $null
  )
  $t = Get-PickerTheme
  $settings = Get-PickerUiSettings
  $form = New-PickerForm $t $Title 420 170
  $form.TopMost = $settings.TopMost

  $accent = switch ($Kind) { "success" { $t.SuccessFg } "warning" { $t.WarnFg } "danger" { $t.Danger } default { $t.InfoFg } }
  $glyph = switch ($Kind) { "success" { [string][char]0x2713 } "warning" { "!" } "danger" { "!" } default { "i" } }
  $badge = New-Object System.Windows.Forms.Panel
  $badge.Location = New-Object System.Drawing.Point (S 22), (S 22)
  $badge.Size = New-Object System.Drawing.Size (S 32), (S 32)
  $badge.BackColor = $t.Back
  $badge.Add_Paint({
      param($s, $e)
      $e.Graphics.SmoothingMode = 'AntiAlias'
      $e.Graphics.FillEllipse((New-Object System.Drawing.SolidBrush $accent), 0, 0, $s.Width - 1, $s.Height - 1)
      $fmt = New-Object System.Drawing.StringFormat
      $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
      $e.Graphics.DrawString($glyph, $PickerFontBold, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, $s.Width, $s.Height), $fmt)
    })
  $form.Controls.Add($badge)

  $head = New-Object System.Windows.Forms.Label
  $head.Text = $Heading
  $head.Font = $PickerFontBold
  $head.AutoSize = $true
  $head.Location = New-Object System.Drawing.Point (S 68), (S 20)
  $form.Controls.Add($head)

  $msg = New-Object System.Windows.Forms.Label
  $msg.Text = $Message
  $msg.ForeColor = $t.Muted
  $msg.Location = New-Object System.Drawing.Point (S 68), (S 46)
  $msg.MaximumSize = New-Object System.Drawing.Size (S 330), 0
  $msg.AutoSize = $true
  $form.Controls.Add($msg)
  $msgBottom = 46 + [Math]::Ceiling($msg.PreferredHeight / $PickerScale)
  $btnY = [Math]::Max(80, $msgBottom + 18)
  $form.ClientSize = New-Object System.Drawing.Size (S 420), (S ($btnY + 52))

  $x = 400
  $result = @{ Clicked = $null }
  for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {
    $label = $Buttons[$i]
    $w = [Math]::Max(80, [int]($label.Length * 8 + 28))
    $x -= $w
    $style = if ($i -eq $Buttons.Count - 1) { if ($Kind -eq "danger") { "danger" } else { "primary" } } else { "secondary" }
    $b = New-PickerButton $t $label $style $x $btnY $w
    $b.Tag = $label
    $b.Add_Click({ param($s, $e) $result.Clicked = $s.Tag; $form.Close() })
    $form.Controls.Add($b)
    if ($i -eq $Buttons.Count - 1) { $form.AcceptButton = $b }
    $x -= 8
  }
  $form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.Close() } })

  try {
    if ($Owner) { [void]$form.ShowDialog($Owner) } else { [void]$form.ShowDialog() }
  }
  finally { $form.Dispose() }
  if ($result.Clicked) { return $result.Clicked }
}

# --- The account picker ------------------------------------------------------------

# Shows the account picker.
#
# Choose-and-close (git / IDE prompts): returns the chosen account name,
# "__ADD__" for "Add account", "__REMOVE__:<account>" once removing an
# account is confirmed, or nothing when cancelled.
#
# Stay-open (the desktop shortcut): pass -OnSwitch, -OnAdd and -OnRemove.
# The window then switches, adds and removes in place, says how it went in
# a message strip, and only closes when the user closes it. Returns nothing.
#   -OnSwitch { param($account) ... return @{ Kind = "success"|"warning"; Message = "..." } }
#   -OnAdd    { ... return <accounts after signing in> }
#   -OnRemove { param($account) ... return <accounts after signing out> }
#
# -BuildOnly builds the window and closes it again without showing it (used
# by the automatic checks). Building and showing happen in this one
# function on purpose: the event handlers use its local variables, which
# only exist while it is running.
function Show-AccountPicker {
  param(
    [string[]]$Accounts = @(),
    [string]$Subtitle = "Choose the account git uses for github.com",
    [string]$ActiveAccount = "",
    [string]$HostName = "github.com",
    [scriptblock]$OnSwitch,
    [scriptblock]$OnAdd,
    [scriptblock]$OnRemove,
    [switch]$BuildOnly
  )
  if (-not $ActiveAccount -and -not $BuildOnly -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $ActiveAccount = [string](& gh config get -h $HostName user 2>$null)
  }
  $stay = [bool]$OnSwitch
  $t = Get-PickerTheme
  $settings = Get-PickerUiSettings
  $state = @{ Hover = -1; Active = $ActiveAccount; BannerKind = "info"; BannerText = "" }

  $form = New-PickerForm $t "GitHub Account Picker" 440 430
  $form.TopMost = $settings.TopMost
  $form.Opacity = $settings.Opacity / 100.0

  # Header: icon, title, subtitle.
  $logo = New-Object System.Windows.Forms.PictureBox
  $logo.Location = New-Object System.Drawing.Point (S 20), (S 18)
  $logo.Size = New-Object System.Drawing.Size (S 40), (S 40)
  $logo.SizeMode = 'Zoom'
  $pngPath = Join-Path $PSScriptRoot "icon.png"
  if (Test-Path $pngPath) { $logo.Image = [System.Drawing.Image]::FromFile($pngPath) }
  $title = New-Object System.Windows.Forms.Label
  $title.Text = "GitHub accounts"
  $title.Font = $PickerFontTitle
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point (S 70), (S 15)
  $sub = New-Object System.Windows.Forms.Label
  $sub.Text = $Subtitle
  $sub.ForeColor = $t.Muted
  $sub.AutoSize = $true
  $sub.Location = New-Object System.Drawing.Point (S 71), (S 42)
  $form.Controls.AddRange(@($logo, $title, $sub))

  # Account list: one row per account with an initial "avatar".
  $list = New-Object System.Windows.Forms.ListBox
  $list.Location = New-Object System.Drawing.Point (S 20), (S 76)
  $list.BorderStyle = 'None'
  $list.BackColor = $t.Back
  $list.ForeColor = $t.Text
  $list.DrawMode = 'OwnerDrawFixed'
  $list.ItemHeight = S 56
  $list.IntegralHeight = $false
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
      $gr.DrawString($name.Substring(0, 1).ToUpper(), $PickerFontBold, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF $ax, $ay, $av, $av), $fmt)
      # Name, and whether it's the account git uses right now.
      $tx = $ax + $av + (S 12)
      $gr.DrawString($name, $PickerFontBold, (New-Object System.Drawing.SolidBrush $t.Text), $tx, $b.Y + (S 9))
      if ($name -eq $state.Active) {
        $dot = S 7
        $gr.FillEllipse((New-Object System.Drawing.SolidBrush $t.Green), $tx + 1, $b.Y + (S 36), $dot, $dot)
        $gr.DrawString("Active now", $PickerFontSmall, (New-Object System.Drawing.SolidBrush $t.Green), $tx + $dot + (S 4), $b.Y + (S 31))
      }
      else {
        $gr.DrawString("Signed in", $PickerFontSmall, (New-Object System.Drawing.SolidBrush $t.Muted), $tx, $b.Y + (S 31))
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

  # Message strip (stay-open mode): says what just happened.
  $banner = New-Object System.Windows.Forms.Panel
  $banner.BackColor = $t.Back
  $banner.Visible = $stay
  $banner.Add_Paint({
      param($s, $e)
      if (-not $state.BannerText) { return }
      $gr = $e.Graphics
      $gr.SmoothingMode = 'AntiAlias'
      $bg, $fg = switch ($state.BannerKind) {
        "success" { $t.SuccessBg, $t.SuccessFg }
        "warning" { $t.WarnBg, $t.WarnFg }
        default { $t.InfoBg, $t.InfoFg }
      }
      $gr.FillPath((New-Object System.Drawing.SolidBrush $bg), (New-RoundedPath 0 0 ($s.Width - 1) ($s.Height - 1) (S 8)))
      $d = S 18
      $cy = ($s.Height - $d) / 2
      $gr.FillEllipse((New-Object System.Drawing.SolidBrush $fg), (S 12), $cy, $d, $d)
      $glyph = switch ($state.BannerKind) { "success" { [string][char]0x2713 } "warning" { "!" } default { "i" } }
      $fmt = New-Object System.Drawing.StringFormat
      $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
      $gr.DrawString($glyph, $PickerFontSmall, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF (S 12), $cy, $d, $d), $fmt)
      $textRect = New-Object System.Drawing.Rectangle (S 40), 0, ($s.Width - (S 50)), $s.Height
      [System.Windows.Forms.TextRenderer]::DrawText($gr, $state.BannerText, $PickerFont, $textRect, $fg,
        [System.Windows.Forms.TextFormatFlags]'VerticalCenter, WordBreak, EndEllipsis')
    })
  $form.Controls.Add($banner)
  $say = {
    param([string]$kind, [string]$text)
    $state.BannerKind = $kind
    $state.BannerText = $text
    $banner.Invalidate()
    $form.Refresh()
  }

  # Buttons. Stay-open mode handles them in place; otherwise each one closes
  # the window with its answer.
  $add = New-PickerButton $t "+  Add account" "secondary" 20 0 120
  $remove = New-PickerButton $t "Remove..." "danger-outline" 148 0 90
  $cancel = New-PickerButton $t ($(if ($stay) { "Close" } else { "Cancel" })) "secondary" 246 0 80
  $ok = New-PickerButton $t "Switch" "primary" 334 0 86
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  if (-not $stay) {
    $add.DialogResult = [System.Windows.Forms.DialogResult]::Retry
    $remove.DialogResult = [System.Windows.Forms.DialogResult]::Abort
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  }
  $form.Controls.AddRange(@($add, $remove, $cancel, $ok))
  $form.AcceptButton = $ok
  $form.CancelButton = $cancel
  $list.Add_DoubleClick({ if ($list.SelectedItem) { $ok.PerformClick() } })

  # Footer: divider, "Always on top" switch, opacity slider.
  $divider = New-Object System.Windows.Forms.Panel
  $divider.BackColor = $t.Border
  $divider.Size = New-Object System.Drawing.Size (S 440), 1

  $toggle = New-Object System.Windows.Forms.Panel
  $toggle.Size = New-Object System.Drawing.Size (S 38), (S 22)
  $toggle.Cursor = [System.Windows.Forms.Cursors]::Hand
  $toggle.BackColor = $t.Back
  $toggle.Add_Paint({
      param($s, $e)
      $gr = $e.Graphics
      $gr.SmoothingMode = 'AntiAlias'
      $w = $s.Width - 1; $h = $s.Height - 1
      $fill = if ($form.TopMost) { $t.Accent } else { $t.Track }
      $gr.FillPath((New-Object System.Drawing.SolidBrush $fill), (New-RoundedPath 0 0 $w $h ($h / 2)))
      $k = $h - (S 6)
      $kx = if ($form.TopMost) { $w - $k - (S 3) } else { S 3 }
      $gr.FillEllipse([System.Drawing.Brushes]::White, $kx, (S 3), $k, $k)
    })
  $toggleLabel = New-Object System.Windows.Forms.Label
  $toggleLabel.Text = "Always on top"
  $toggleLabel.AutoSize = $true
  $toggleLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
  $flipTopMost = {
    $form.TopMost = -not $form.TopMost
    $settings.TopMost = $form.TopMost
    Save-PickerUiSettings $settings
    $toggle.Invalidate()
  }
  $toggle.Add_Click($flipTopMost)
  $toggleLabel.Add_Click($flipTopMost)

  $opLabel = New-Object System.Windows.Forms.Label
  $opLabel.Text = "Opacity"
  $opLabel.ForeColor = $t.Muted
  $opLabel.AutoSize = $true
  $slider = New-Object System.Windows.Forms.Panel
  $slider.Size = New-Object System.Drawing.Size (S 112), (S 26)
  $slider.Cursor = [System.Windows.Forms.Cursors]::Hand
  $slider.BackColor = $t.Back
  $pct = New-Object System.Windows.Forms.Label
  $pct.Text = "$($settings.Opacity)%"
  $pct.AutoSize = $true

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
    $ratio = [Math]::Min(1.0, [Math]::Max(0.0, ($x - $knob / 2) / ($slider.Width - $knob)))
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
  $form.Controls.AddRange(@($divider, $toggle, $toggleLabel, $opLabel, $slider, $pct))

  # Layout (96-dpi units): the list fits its accounts, up to 5 rows, then
  # scrolls; everything below moves with it. Re-run after adding/removing.
  $layout = {
    $rows = [Math]::Min(5, [Math]::Max(1, $list.Items.Count))
    $listH = $rows * 56 + 4
    $list.Size = New-Object System.Drawing.Size (S 400), (S $listH)
    $y = 76 + $listH + 10
    if ($stay) {
      $banner.Location = New-Object System.Drawing.Point (S 20), (S $y)
      $banner.Size = New-Object System.Drawing.Size (S 400), (S 44)
      $y += 54
    }
    foreach ($b in $add, $remove, $cancel, $ok) { $b.Top = S ($y + 4) }
    $divY = $y + 4 + 34 + 16
    $divider.Location = New-Object System.Drawing.Point 0, (S $divY)
    $footY = $divY + 20
    $toggle.Location = New-Object System.Drawing.Point (S 20), (S $footY)
    $toggleLabel.Location = New-Object System.Drawing.Point (S 64), (S ($footY + 1))
    $opLabel.Location = New-Object System.Drawing.Point (S 210), (S ($footY + 1))
    $slider.Location = New-Object System.Drawing.Point (S 268), (S ($footY - 2))
    $pct.Location = New-Object System.Drawing.Point (S 386), (S ($footY + 1))
    $form.ClientSize = New-Object System.Drawing.Size (S 440), (S ($footY + 42))
  }
  $fill = {
    param([string[]]$names, [string]$select)
    $list.Items.Clear()
    foreach ($a in @($names)) { if ($a) { [void]$list.Items.Add($a) } }
    $want = if ($select) { $select } else { $state.Active }
    $i = $list.Items.IndexOf($want)
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = [Math]::Max(0, $i) }
    $ok.Enabled = $list.Items.Count -gt 0
    $remove.Enabled = $list.Items.Count -gt 0
    & $layout
  }
  & $fill $Accounts

  if ($stay) {
    if ($state.Active) { & $say "info" "git is using $($state.Active) right now. Pick an account and press Switch." }
    else { & $say "info" "Pick an account and press Switch." }

    $ok.Add_Click({
        $target = [string]$list.SelectedItem
        if (-not $target) { return }
        if ($target -eq $state.Active) { & $say "info" "$target is already the active account."; return }
        & $say "info" "Switching to $target..."
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try { $r = & $OnSwitch $target }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        if ($r.Kind -ne "error") { $state.Active = $target }
        & $say ($(if ($r.Kind -eq "error") { "warning" } else { $r.Kind })) $r.Message
        $list.Invalidate()
      })
    $add.Add_Click({
        & $say "info" "Finish signing in in the browser window that opened. This list updates when you're done."
        $before = @($list.Items | ForEach-Object { [string]$_ })
        $after = @(& $OnAdd)
        $new = @($after | Where-Object { $before -notcontains $_ })
        if ($new.Count -gt 0) {
          & $fill $after $new[0]
          & $say "success" "Added $($new[0]). Press Switch to start using it."
        }
        else {
          & $fill $after
          & $say "warning" "No new account was added. If the browser used an account that's already here, sign out of GitHub there or use a private window, then try again."
        }
      })
    $remove.Add_Click({
        $target = [string]$list.SelectedItem
        if (-not $target) { return }
        $answer = Show-PickerDialog -Title "Remove account" -Kind "danger" -Owner $form `
          -Heading "Sign out of $target on this computer?" `
          -Message "It is removed from this list and git stops using it. Your GitHub account itself is not deleted, and you can add it back with Add account." `
          -Buttons "Cancel", "Remove"
        if ($answer -ne "Remove") { return }
        $after = @(& $OnRemove $target)
        if ($state.Active -eq $target) { $state.Active = [string](& gh config get -h $HostName user 2>$null) }
        & $fill $after
        if ($list.Items.Count -eq 0) { & $say "warning" "Signed out of $target. No accounts are left; use Add account to sign in." }
        else { & $say "success" "Signed out of $target on this computer." }
      })
  }

  try {
    if ($BuildOnly) { return }
    if ($stay) { [void]$form.ShowDialog(); return }
    # Choose-and-close: loop so answering "Cancel" to the remove
    # confirmation goes back to the list.
    while ($true) {
      $result = $form.ShowDialog()
      if ($result -eq [System.Windows.Forms.DialogResult]::Abort -and $list.SelectedItem) {
        $target = [string]$list.SelectedItem
        $answer = Show-PickerDialog -Title "Remove account" -Kind "danger" `
          -Heading "Sign out of $target on this computer?" `
          -Message "It is removed from this list and git stops using it. Your GitHub account itself is not deleted, and you can add it back with Add account." `
          -Buttons "Cancel", "Remove"
        if ($answer -eq "Remove") { return "__REMOVE__:$target" }
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

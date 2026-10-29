# Draws the app icon (two people = your accounts, with a green "switch"
# badge) and writes:
#   gui/icon.ico  - Windows shortcut and popup icon (16 to 256 px)
#   gui/icon.png  - 256 px, used by the Linux desktop launcher
#
# Only needed when changing the icon; the generated files are committed.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-icon.ps1
Add-Type -AssemblyName System.Drawing

$repo = Split-Path -Parent $PSScriptRoot
$gui = Join-Path $repo "gui"

function New-RoundedRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# A person: round head plus rounded shoulders, centred on $cx, scaled by $s.
function Draw-Person($g, $brush, [single]$cx, [single]$top, [single]$s) {
  $head = 0.30 * $s
  $g.FillEllipse($brush, $cx - $head / 2, $top, $head, $head)
  $bodyW = 0.56 * $s
  $bodyTop = $top + $head + 0.04 * $s
  $body = New-RoundedRect ($cx - $bodyW / 2) $bodyTop $bodyW (0.40 * $s) (0.20 * $s)
  $g.FillPath($brush, $body)
}

# Two arrows pointing opposite ways, centred on ($cx, $cy), size $s.
function Draw-SwapArrows($g, $pen, [single]$cx, [single]$cy, [single]$s) {
  $h = $s * 0.30; $w = $s * 0.62; $a = $s * 0.18
  $l = $cx - $w / 2; $r = $cx + $w / 2
  $y1 = $cy - $h / 2; $y2 = $cy + $h / 2
  $g.DrawLine($pen, $l, $y1, $r, $y1)
  $g.DrawLine($pen, $r, $y1, $r - $a, $y1 - $a)
  $g.DrawLine($pen, $r, $y1, $r - $a, $y1 + $a)
  $g.DrawLine($pen, $r, $y2, $l, $y2)
  $g.DrawLine($pen, $l, $y2, $l + $a, $y2 - $a)
  $g.DrawLine($pen, $l, $y2, $l + $a, $y2 + $a)
}

function New-IconBitmap([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $S = [single]$size

  # Dark tile (GitHub's dark grey).
  $tile = New-RoundedRect 0 0 ($S - 0.5) ($S - 0.5) ($S * 0.20)
  $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 36, 41, 47))), $tile)

  # Back person (grey) and front person (white): two accounts.
  $grey = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 139, 148, 158))
  $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
  Draw-Person $g $grey ($S * 0.37) ($S * 0.10) ($S * 0.60)
  # Outline the front person in tile colour so the two read as separate.
  $outline = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 36, 41, 47))
  Draw-Person $g $outline ($S * 0.60) ($S * 0.19) ($S * 0.68)
  Draw-Person $g $white ($S * 0.60) ($S * 0.22) ($S * 0.60)

  # Green switch badge, bottom right (skipped at 16 px where it would be mush).
  if ($size -ge 24) {
    $b = $S * 0.40; $bx = $S - $b - $S * 0.02; $by = $S - $b - $S * 0.02
    $g.FillEllipse($outline, $bx - $S * 0.03, $by - $S * 0.03, $b + $S * 0.06, $b + $S * 0.06)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 45, 164, 78))), $bx, $by, $b, $b)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([Math]::Max(1.5, $S * 0.045))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    Draw-SwapArrows $g $pen ($bx + $b / 2) ($by + $b / 2) $b
  }
  $g.Dispose()
  return $bmp
}

# Classic DIB (BMP) entry for small sizes: what System.Drawing.Icon and old
# Windows shell code read most reliably. 32-bit BGRA, bottom-up, plus mask.
function Get-DibBytes($bmp) {
  $n = $bmp.Width
  $ms = New-Object System.IO.MemoryStream
  $w = New-Object System.IO.BinaryWriter $ms
  $w.Write([int]40); $w.Write([int]$n); $w.Write([int]($n * 2))
  $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]0)
  $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
  for ($y = $n - 1; $y -ge 0; $y--) {
    for ($x = 0; $x -lt $n; $x++) {
      $c = $bmp.GetPixel($x, $y)
      $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
    }
  }
  $maskRow = [int]([Math]::Ceiling($n / 32.0) * 4)
  $w.Write((New-Object byte[] ($maskRow * $n)))
  $w.Flush()
  return $ms.ToArray()
}

function Get-PngBytes($bmp) {
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  return $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 256
$images = @()
foreach ($s in $sizes) {
  $bmp = New-IconBitmap $s
  if ($s -ge 256) { $data = Get-PngBytes $bmp } else { $data = Get-DibBytes $bmp }
  if ($s -eq 256) { $bmp.Save((Join-Path $gui "icon.png"), [System.Drawing.Imaging.ImageFormat]::Png) }
  $bmp.Dispose()
  $images += , @($s, $data)
}

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
  $s = $img[0]; $len = $img[1].Length
  $dim = if ($s -ge 256) { 0 } else { $s }
  $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$len); $w.Write([int]$offset)
  $offset += $len
}
foreach ($img in $images) { $w.Write([byte[]]$img[1]) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $gui "icon.ico"), $out.ToArray())
Write-Output "Wrote gui\icon.ico ($($sizes -join ', ') px) and gui\icon.png"

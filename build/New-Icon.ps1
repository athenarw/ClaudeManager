<#
.SYNOPSIS
  Generates ClaudeManager.ico: three small Claude-style sunbursts on a purple rounded square.

.DESCRIPTION
  Every size (16..256) is drawn separately from vector code - small sizes use fewer, thicker
  rays so they stay legible instead of being blurry downscales. Frames <= 64 px are stored as
  classic 32-bit DIBs, larger ones as PNG.

.EXAMPLE
  powershell -File build\New-Icon.ps1
  powershell -File build\New-Icon.ps1 -Preview C:\temp\preview.png
#>
param(
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeManager.ico'),
    [string]$Preview
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$D = 'System.Drawing'
function Color([int]$a, [int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

function New-RoundedPath([System.Drawing.RectangleF]$r, [single]$rad) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $rad * 2
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# One sunburst: rays of uneven length around a hub, rounded ends.
function Add-Burst($g, [double]$cx, [double]$cy, [double]$R, [int]$n, [double]$penW, $color) {
    $lens = @(1.00, 0.64, 0.90, 0.72, 1.00, 0.60, 0.94, 0.68, 0.98, 0.62, 0.86, 0.74)
    $jit  = @(0, 3, -2, 4, 0, -3, 2, -4, 1, 3, -2, 2)
    $pen = New-Object System.Drawing.Pen($color, [single]$penW)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    for ($i = 0; $i -lt $n; $i++) {
        if ($n -le 8) {
            $len = $R * $(if ($i % 2 -eq 0) { 1.0 } else { 0.74 }); $jd = 0
        } else {
            $idx = [int][math]::Floor($i * 12 / $n); $len = $R * $lens[$idx]; $jd = $jit[$idx]
        }
        $ang = [math]::PI * 2 * $i / $n + $jd * [math]::PI / 180 - [math]::PI / 2
        $g.DrawLine($pen, [single]$cx, [single]$cy, [single]($cx + [math]::Cos($ang) * $len), [single]($cy + [math]::Sin($ang) * $len))
    }
    $pen.Dispose()
    $b = New-Object System.Drawing.SolidBrush($color)
    $hub = 0.21 * $R
    $g.FillEllipse($b, [single]($cx - $hub), [single]($cy - $hub), [single](2 * $hub), [single](2 * $hub))
    $b.Dispose()
}

function New-IconBitmap([int]$Size) {
    $ss = 8; $big = $Size * $ss
    $bmp = New-Object System.Drawing.Bitmap($big, $big, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    # purple rounded square, light top-left to deep bottom-right
    $m = 0.02 * $big
    $rect = New-Object System.Drawing.RectangleF([single]$m, [single]$m, [single]($big - 2 * $m), [single]($big - 2 * $m))
    $path = New-RoundedPath $rect ([single](0.225 * $big))
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (Color 255 152 106 238), (Color 255 84 46 166), 52.0)
    $g.FillPath($lg, $path)
    $lg.Dispose(); $path.Dispose()

    # three bursts in a triangle
    $coral = Color 255 243 144 104
    $tiny  = $Size -le 24
    $n     = if ($Size -le 32) { 8 } else { 12 }
    $R     = $(if ($tiny) { 0.215 } else { 0.19 }) * $big
    $penW  = $R * $(if ($tiny) { 0.40 } elseif ($Size -le 32) { 0.32 } else { 0.21 })
    $centers = @(@(0.50, 0.275), @(0.275, 0.685), @(0.725, 0.685))
    foreach ($c in $centers) { Add-Burst $g ($c[0] * $big) ($c[1] * $big) $R $n $penW $coral }
    $g.Dispose()

    # downsample
    $out = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g2 = [System.Drawing.Graphics]::FromImage($out)
    $g2.InterpolationMode = 'HighQualityBicubic'; $g2.PixelOffsetMode = 'HighQuality'; $g2.CompositingQuality = 'HighQuality'
    $g2.Clear([System.Drawing.Color]::Transparent)
    $g2.DrawImage($bmp, 0, 0, $Size, $Size)
    $g2.Dispose(); $bmp.Dispose()
    return $out
}

function Get-PngBytes($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()
}

function Get-DibBytes($bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($d.Stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($d)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]40); $bw.Write([int]$w); $bw.Write([int]($h * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]($w * $h * 4)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($raw, $y * $d.Stride, $w * 4) }       # bottom-up pixel rows
    $mask = New-Object byte[] ((([int][math]::Ceiling($w / 32.0)) * 4) * $h)            # AND mask: all opaque
    $bw.Write($mask)
    $bw.Flush()
    return , $ms.ToArray()
}

# ---- build every size
$sizes = 16, 24, 32, 48, 64, 128, 256
$bitmaps = @{}; $frames = @()
foreach ($s in $sizes) {
    $b = New-IconBitmap $s
    $bitmaps[$s] = $b
    $bytes = if ($s -ge 128) { Get-PngBytes $b } else { Get-DibBytes $b }
    $frames += , @($s, $bytes)
}

# ---- write the .ico
$fs = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $s = $f[0]; $len = $f[1].Length
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]$len); $bw.Write([int]$offset)
    $offset += $len
}
foreach ($f in $frames) { $bw.Write($f[1]) }
$bw.Flush(); $fs.Close()
'Wrote {0} ({1:N0} bytes, sizes: {2})' -f $Out, (Get-Item $Out).Length, ($sizes -join ', ')

# ---- optional preview sheet: all sizes on dark and light, plus 16/32 px enlarged (nearest-neighbour)
if ($Preview) {
    $W = 980; $H = 640
    $sheet = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.Clear((Color 255 245 245 245))
    $dark = New-Object System.Drawing.SolidBrush((Color 255 30 30 30))
    $g.FillRectangle($dark, 0, 0, $W, $H / 2)
    foreach ($strip in 0, 1) {
        $y0 = $strip * ($H / 2); $x = 20
        foreach ($s in 256, 128, 64, 48, 32, 24, 16) {
            $g.DrawImage($bitmaps[$s], $x, [int]($y0 + 20 + (256 - $s) / 2), $s, $s)
            $x += $s + 18
        }
        $g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half'
        $g.DrawImage($bitmaps[16], $x + 10, [int]($y0 + 24), 128, 128)
        $g.DrawImage($bitmaps[32], $x + 10, [int]($y0 + 160), 128, 128)
        $g.InterpolationMode = 'Default'; $g.PixelOffsetMode = 'Default'
    }
    $g.Dispose()
    $sheet.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png)
    'Preview: ' + $Preview
}

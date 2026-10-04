<#
.SYNOPSIS
    生成 DanmuFloat 的应用图标（深底 + 字母 D + 内嵌弹幕条）。

.DESCRIPTION
    全部用 GDI+ 按固定几何坐标绘制，纯色平涂：圆角深色底、粗体几何字母 D（计数区镂空）、
    计数区内嵌三条长短不一的亮青色弹幕条。不含渐变、外发光、玻璃高光，因此在 48px 下
    不会糊成一团。legacy 尺寸从 1024 基准图逐级折半缩放得出，避免一次性大比例缩放的锯齿；
    自适应前景按矢量坐标在目标尺寸上直接绘制。

    产物：
      assets/icon/app_icon.png                              1024x1024 主图（设计源文件）
      android/app/src/main/res/mipmap-*/ic_launcher.png     48/72/96/144/192（Android 8 以下的 legacy 图标）
      android/app/src/main/res/mipmap-*/ic_launcher_foreground.png
                                                            108/162/216/324/432（自适应图标前景，透明底）

    自适应图标的前景只含字母 D 与弹幕条，底色由 res/values/colors.xml 的
    ic_launcher_background 提供，遮罩与圆角由启动器负责；对应的
    mipmap-anydpi-v26/ic_launcher.xml、ic_launcher_round.xml 为静态资源，不由本脚本生成。

.EXAMPLE
    ./scripts/generate-icon.ps1
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Windows PowerShell 5.1 在 param 默认值里取不到 $PSScriptRoot，故在脚本体内解析
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

# ---------------------------------------------------------------------------
# 设计常量：均以 1024x1024 画布为基准，缩放到各密度时等比换算
# ---------------------------------------------------------------------------
$Base        = 1024

# 深色圆角底
$PlateInset  = 32
$PlateSize   = $Base - 2 * $PlateInset
$PlateRadius = 216
$PlateColor  = [System.Drawing.Color]::FromArgb(255, 16, 19, 25)     # #101319

# 字母 D：外轮廓与计数区同圆心、同笔画粗细（130px），保证环宽处处均匀
$DLeft         = 252
$DTop          = 182
$DBottom       = 842
$DArcCenterX   = 442
$DOuterR       = 330
$CounterLeft   = 382
$CounterTop    = 312
$CounterBottom = 712
$CounterArcR   = 200
$RingColor     = [System.Drawing.Color]::FromArgb(255, 232, 236, 244)  # #E8ECF4

# 弹幕条：左对齐、长短不一，末端参差形成弹幕节奏
$BarColor    = [System.Drawing.Color]::FromArgb(255, 47, 224, 196)   # #2FE0C4
$BarX        = 406
$BarY        = @(338, 470, 602)
$BarW        = @(160, 214, 132)
$BarH        = 84
$BarR        = 42

# 各密度启动图标尺寸（legacy，Android 8 以下）
$Densities   = [ordered]@{
    'mipmap-mdpi'    = 48
    'mipmap-hdpi'    = 72
    'mipmap-xhdpi'   = 96
    'mipmap-xxhdpi'  = 144
    'mipmap-xxxhdpi' = 192
}

# 自适应图标（Android 8+）：108dp 画布，仅前景在这里生成，底色由 colors.xml 提供
$AdaptiveCanvasRatio = 0.714   # 1024 设计稿映射到 108dp 画布的比例，D 约占可见区（72dp）的 69%
$AdaptiveDensities   = [ordered]@{
    'mipmap-mdpi'    = 108
    'mipmap-hdpi'    = 162
    'mipmap-xhdpi'   = 216
    'mipmap-xxhdpi'  = 324
    'mipmap-xxxhdpi' = 432
}

# ---------------------------------------------------------------------------
# 绘制辅助
# ---------------------------------------------------------------------------
function New-RoundedRectPath {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)

    $d = $R * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc([float]$X, [float]$Y, [float]$d, [float]$d, [float]180, [float]90)
    $path.AddArc([float]($X + $W - $d), [float]$Y, [float]$d, [float]$d, [float]270, [float]90)
    $path.AddArc([float]($X + $W - $d), [float]($Y + $H - $d), [float]$d, [float]$d, [float]0, [float]90)
    $path.AddArc([float]$X, [float]($Y + $H - $d), [float]$d, [float]$d, [float]90, [float]90)
    $path.CloseFigure()
    return $path
}

function Draw-Mark {
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.Brush]$RingBrush,
        [System.Drawing.Brush]$BarBrush
    )

    # 字母 D：外轮廓与计数区同圆心，按奇偶规则相减成等宽环
    $outer = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        $r2 = $DOuterR * 2
        $outer.AddLine([float]$DLeft, [float]$DTop, [float]$DArcCenterX, [float]$DTop)
        $outer.AddArc([float]($DArcCenterX - $DOuterR), [float]$DTop, [float]$r2, [float]$r2, [float]270, [float]180)
        $outer.AddLine([float]$DArcCenterX, [float]$DBottom, [float]$DLeft, [float]$DBottom)
        $outer.CloseFigure()

        $counter = New-Object System.Drawing.Drawing2D.GraphicsPath
        try {
            $c2 = $CounterArcR * 2
            $counter.AddLine([float]$CounterLeft, [float]$CounterTop, [float]$DArcCenterX, [float]$CounterTop)
            $counter.AddArc([float]($DArcCenterX - $CounterArcR), [float]$CounterTop, [float]$c2, [float]$c2, [float]270, [float]180)
            $counter.AddLine([float]$DArcCenterX, [float]$CounterBottom, [float]$CounterLeft, [float]$CounterBottom)
            $counter.CloseFigure()

            $ringPath = New-Object System.Drawing.Drawing2D.GraphicsPath
            try {
                # Alternate：子路径重叠区按奇偶规则挖空，计数区自然成为镂空
                $ringPath.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate
                $ringPath.AddPath($outer, $false)
                $ringPath.AddPath($counter, $false)
                $Graphics.FillPath($RingBrush, $ringPath)
            }
            finally { $ringPath.Dispose() }
        }
        finally { $counter.Dispose() }
    }
    finally { $outer.Dispose() }

    # 弹幕条：左对齐、长短不一，末端参差形成弹幕节奏
    for ($i = 0; $i -lt $BarW.Count; $i++) {
        $bar = New-RoundedRectPath -X $BarX -Y $BarY[$i] -W $BarW[$i] -H $BarH -R $BarR
        try { $Graphics.FillPath($BarBrush, $bar) } finally { $bar.Dispose() }
    }
}

function New-ScaledBitmap {
    param([System.Drawing.Bitmap]$Source, [int]$Size)

    $dst = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    try {
        # SourceCopy 保留圆角外的透明像素，避免与画布做 alpha 混合后发白
        $g.CompositingMode    = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
        $g.DrawImage($Source, $rect)
    }
    finally {
        $g.Dispose()
    }
    return $dst
}

function Resize-ToSize {
    param([System.Drawing.Bitmap]$Source, [int]$Size)

    # 逐级折半，避免一次性大比例缩放丢细节
    $cur = $Source
    $ownsCur = $false
    while ([Math]::Floor($cur.Width / 2) -ge $Size) {
        $next = New-ScaledBitmap -Source $cur -Size ([int][Math]::Floor($cur.Width / 2))
        if ($ownsCur) { $cur.Dispose() }
        $cur = $next
        $ownsCur = $true
    }
    if ($cur.Width -ne $Size) {
        $next = New-ScaledBitmap -Source $cur -Size $Size
        if ($ownsCur) { $cur.Dispose() }
        $cur = $next
        $ownsCur = $true
    }
    return $cur
}

function Save-Png {
    param([System.Drawing.Bitmap]$Bitmap, [string]$Path)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
}

# ---------------------------------------------------------------------------
# 绘制 1024 基准图
# ---------------------------------------------------------------------------
$master = New-Object System.Drawing.Bitmap($Base, $Base, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($master)
try {
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $plateBrush = New-Object System.Drawing.SolidBrush($PlateColor)
    $ringBrush  = New-Object System.Drawing.SolidBrush($RingColor)
    $barBrush   = New-Object System.Drawing.SolidBrush($BarColor)
    try {
        # 1) 深色圆角底
        $plate = New-RoundedRectPath -X $PlateInset -Y $PlateInset -W $PlateSize -H $PlateSize -R $PlateRadius
        try { $g.FillPath($plateBrush, $plate) } finally { $plate.Dispose() }

        # 2) 字母 D 与弹幕条
        Draw-Mark -Graphics $g -RingBrush $ringBrush -BarBrush $barBrush
    }
    finally {
        $plateBrush.Dispose(); $ringBrush.Dispose(); $barBrush.Dispose()
    }
}
finally {
    $g.Dispose()
}

# ---------------------------------------------------------------------------
# 输出主图与各密度启动图标
# ---------------------------------------------------------------------------
try {
    $masterPath = Join-Path $ProjectRoot 'assets/icon/app_icon.png'
    Save-Png -Bitmap $master -Path $masterPath
    Write-Host ("主图      {0}" -f $masterPath)

    $resRoot = Join-Path $ProjectRoot 'android/app/src/main/res'
    foreach ($name in $Densities.Keys) {
        $size = $Densities[$name]
        $scaled = Resize-ToSize -Source $master -Size $size
        try {
            $outPath = Join-Path $resRoot ("{0}/ic_launcher.png" -f $name)
            Save-Png -Bitmap $scaled -Path $outPath
            Write-Host ("{0,-16} {1,4}px  {2}" -f $name, $size, $outPath)
        }
        finally {
            if (-not [object]::ReferenceEquals($scaled, $master)) { $scaled.Dispose() }
        }
    }

    # 自适应图标前景：透明底，D 与弹幕条按 $AdaptiveCanvasRatio 居中缩放，
    # 每组按 108dp 画布居中，外层留白由启动器遮罩裁切
    $fgRingBrush = New-Object System.Drawing.SolidBrush($RingColor)
    $fgBarBrush  = New-Object System.Drawing.SolidBrush($BarColor)
    try {
        foreach ($name in $AdaptiveDensities.Keys) {
            $size = $AdaptiveDensities[$name]
            $fg = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $fgG = [System.Drawing.Graphics]::FromImage($fg)
                try {
                    $fgG.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                    $fgG.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $fgG.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $fgG.Clear([System.Drawing.Color]::Transparent)

                    # Prepend 语义下先写的 Translate 后生效：等价于「先缩放、再平移」
                    $scale  = $size * $AdaptiveCanvasRatio / $Base
                    $offset = ($size - $Base * $scale) / 2
                    $fgG.TranslateTransform([float]$offset, [float]$offset)
                    $fgG.ScaleTransform([float]$scale, [float]$scale)
                    Draw-Mark -Graphics $fgG -RingBrush $fgRingBrush -BarBrush $fgBarBrush
                }
                finally { $fgG.Dispose() }

                $outPath = Join-Path $resRoot ("{0}/ic_launcher_foreground.png" -f $name)
                Save-Png -Bitmap $fg -Path $outPath
                Write-Host ("{0,-16} {1,4}px  {2}" -f $name, $size, $outPath)
            }
            finally { $fg.Dispose() }
        }
    }
    finally {
        $fgRingBrush.Dispose(); $fgBarBrush.Dispose()
    }
}
finally {
    $master.Dispose()
}

Write-Host '图标生成完成。'
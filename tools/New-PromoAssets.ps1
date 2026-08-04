[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'assets'
}
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

function New-Color {
    param(
        [int]$Red,
        [int]$Green,
        [int]$Blue,
        [int]$Alpha = 255
    )
    [System.Drawing.Color]::FromArgb($Alpha, $Red, $Green, $Blue)
}

function New-Font {
    param(
        [string]$Family,
        [single]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    New-Object System.Drawing.Font($Family, $Size, $Style, [System.Drawing.GraphicsUnit]::Pixel)
}

function New-RoundedPath {
    param(
        [single]$X,
        [single]$Y,
        [single]$Width,
        [single]$Height,
        [single]$Radius
    )
    $diameter = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
    $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
    $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    $path
}

function Fill-RoundedRectangle {
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.Brush]$Brush,
        [single]$X,
        [single]$Y,
        [single]$Width,
        [single]$Height,
        [single]$Radius
    )
    $path = New-RoundedPath -X $X -Y $Y -Width $Width -Height $Height -Radius $Radius
    try { $Graphics.FillPath($Brush, $path) } finally { $path.Dispose() }
}

function Draw-RoundedRectangle {
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.Pen]$Pen,
        [single]$X,
        [single]$Y,
        [single]$Width,
        [single]$Height,
        [single]$Radius
    )
    $path = New-RoundedPath -X $X -Y $Y -Width $Width -Height $Height -Radius $Radius
    try { $Graphics.DrawPath($Pen, $path) } finally { $path.Dispose() }
}

function Draw-Text {
    param(
        [System.Drawing.Graphics]$Graphics,
        [string]$Text,
        [System.Drawing.Font]$Font,
        [System.Drawing.Brush]$Brush,
        [single]$X,
        [single]$Y,
        [single]$Width,
        [single]$Height,
        [System.Drawing.StringAlignment]$Alignment = [System.Drawing.StringAlignment]::Near,
        [System.Drawing.StringAlignment]$LineAlignment = [System.Drawing.StringAlignment]::Near
    )
    $format = New-Object System.Drawing.StringFormat
    try {
        $format.Alignment = $Alignment
        $format.LineAlignment = $LineAlignment
        $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $format.FormatFlags = [System.Drawing.StringFormatFlags]::LineLimit
        $textBounds = [System.Drawing.RectangleF]::new($X, $Y, $Width, $Height)
        $Graphics.DrawString($Text, $Font, $Brush, $textBounds, $format)
    }
    finally {
        $format.Dispose()
    }
}

function Draw-Arrow {
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.Color]$Color,
        [single]$X1,
        [single]$Y1,
        [single]$X2,
        [single]$Y2,
        [single]$Width = 4
    )
    $pen = New-Object System.Drawing.Pen($Color, $Width)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    try {
        $lineEndX = [single]($X2 - 14)
        $Graphics.DrawLine($pen, $X1, $Y1, $lineEndX, $Y2)
        $points = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new($X2, $Y2),
            [System.Drawing.PointF]::new([single]($X2 - 18), [single]($Y2 - 10)),
            [System.Drawing.PointF]::new([single]($X2 - 18), [single]($Y2 + 10))
        )
        $Graphics.FillPolygon($brush, $points)
    }
    finally {
        $pen.Dispose()
        $brush.Dispose()
    }
}

function Initialize-Graphics {
    param([System.Drawing.Bitmap]$Bitmap)
    $graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics
}

function Add-Backdrop {
    param(
        [System.Drawing.Graphics]$Graphics,
        [int]$Width,
        [int]$Height
    )
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
    $background = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        (New-Color 6 14 28),
        (New-Color 12 38 53),
        18
    )
    $glowA = New-Object System.Drawing.SolidBrush((New-Color 28 211 203 38))
    $glowB = New-Object System.Drawing.SolidBrush((New-Color 113 237 157 24))
    $gridPen = New-Object System.Drawing.Pen((New-Color 255 255 255 12), 1)
    try {
        $Graphics.FillRectangle($background, $rect)
        $Graphics.FillEllipse($glowA, $Width - 520, -210, 680, 680)
        $Graphics.FillEllipse($glowB, -260, $Height - 330, 520, 520)
        for ($x = 0; $x -lt $Width; $x += 80) { $Graphics.DrawLine($gridPen, $x, 0, $x, $Height) }
        for ($y = 0; $y -lt $Height; $y += 80) { $Graphics.DrawLine($gridPen, 0, $y, $Width, $y) }
    }
    finally {
        $background.Dispose()
        $glowA.Dispose()
        $glowB.Dispose()
        $gridPen.Dispose()
    }
}

function New-SocialPreview {
    param([string]$Path)
    $bitmap = New-Object System.Drawing.Bitmap(1280, 640, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $graphics = Initialize-Graphics -Bitmap $bitmap
    $resources = New-Object System.Collections.ArrayList
    try {
        Add-Backdrop -Graphics $graphics -Width 1280 -Height 640

        $white = New-Object System.Drawing.SolidBrush((New-Color 245 250 255)); [void]$resources.Add($white)
        $muted = New-Object System.Drawing.SolidBrush((New-Color 173 193 211)); [void]$resources.Add($muted)
        $cyan = New-Object System.Drawing.SolidBrush((New-Color 43 221 211)); [void]$resources.Add($cyan)
        $green = New-Object System.Drawing.SolidBrush((New-Color 119 239 166)); [void]$resources.Add($green)
        $panel = New-Object System.Drawing.SolidBrush((New-Color 15 31 48 232)); [void]$resources.Add($panel)
        $panelSoft = New-Object System.Drawing.SolidBrush((New-Color 31 55 73 210)); [void]$resources.Add($panelSoft)
        $pill = New-Object System.Drawing.SolidBrush((New-Color 43 221 211 34)); [void]$resources.Add($pill)
        $border = New-Object System.Drawing.Pen((New-Color 104 232 216 115), 2); [void]$resources.Add($border)
        $borderSoft = New-Object System.Drawing.Pen((New-Color 255 255 255 36), 2); [void]$resources.Add($borderSoft)

        $fontPill = New-Font -Family 'Segoe UI' -Size 18 -Style Bold; [void]$resources.Add($fontPill)
        $fontBrand = New-Font -Family 'Segoe UI' -Size 55 -Style Bold; [void]$resources.Add($fontBrand)
        $fontTagline = New-Font -Family 'Microsoft YaHei UI' -Size 33 -Style Bold; [void]$resources.Add($fontTagline)
        $fontSub = New-Font -Family 'Microsoft YaHei UI' -Size 20; [void]$resources.Add($fontSub)
        $fontCardTitle = New-Font -Family 'Microsoft YaHei UI' -Size 22 -Style Bold; [void]$resources.Add($fontCardTitle)
        $fontCardMono = New-Font -Family 'Consolas' -Size 23 -Style Bold; [void]$resources.Add($fontCardMono)
        $fontSmall = New-Font -Family 'Segoe UI' -Size 16; [void]$resources.Add($fontSmall)
        $fontStatus = New-Font -Family 'Consolas' -Size 17 -Style Bold; [void]$resources.Add($fontStatus)

        Fill-RoundedRectangle -Graphics $graphics -Brush $pill -X 58 -Y 48 -Width 330 -Height 42 -Radius 21
        Draw-Text -Graphics $graphics -Text 'OPEN SOURCE  ·  WINDOWS 11' -Font $fontPill -Brush $cyan -X 74 -Y 55 -Width 305 -Height 30

        Draw-Text -Graphics $graphics -Text 'Codex Proxy' -Font $fontBrand -Brush $white -X 58 -Y 117 -Width 570 -Height 70
        Draw-Text -Graphics $graphics -Text 'Guardian' -Font $fontBrand -Brush $green -X 58 -Y 177 -Width 540 -Height 75
        Draw-Text -Graphics $graphics -Text '减少代理未继承导致的反复重连' -Font $fontTagline -Brush $white -X 60 -Y 282 -Width 610 -Height 55
        Draw-Text -Graphics $graphics -Text '自动发现  ·  实际验证  ·  安全切换代理' -Font $fontSub -Brush $muted -X 61 -Y 348 -Width 590 -Height 40

        Fill-RoundedRectangle -Graphics $graphics -Brush $panelSoft -X 58 -Y 430 -Width 162 -Height 46 -Radius 15
        Fill-RoundedRectangle -Graphics $graphics -Brush $panelSoft -X 232 -Y 430 -Width 164 -Height 46 -Radius 15
        Fill-RoundedRectangle -Graphics $graphics -Brush $panelSoft -X 408 -Y 430 -Width 196 -Height 46 -Radius 15
        Draw-Text -Graphics $graphics -Text 'Safe 默认' -Font $fontSub -Brush $white -X 58 -Y 435 -Width 162 -Height 34 -Alignment Center
        Draw-Text -Graphics $graphics -Text '静默自启' -Font $fontSub -Brush $white -X 232 -Y 435 -Width 164 -Height 34 -Alignment Center
        Draw-Text -Graphics $graphics -Text '不改系统代理' -Font $fontSub -Brush $white -X 408 -Y 435 -Width 196 -Height 34 -Alignment Center
        Draw-Text -Graphics $graphics -Text 'github.com/CH-ZHOU-0512/codex-proxy-guardian' -Font $fontSmall -Brush $muted -X 60 -Y 560 -Width 590 -Height 28

        Fill-RoundedRectangle -Graphics $graphics -Brush $panel -X 706 -Y 72 -Width 510 -Height 500 -Radius 32
        Draw-RoundedRectangle -Graphics $graphics -Pen $borderSoft -X 706 -Y 72 -Width 510 -Height 500 -Radius 32

        Fill-RoundedRectangle -Graphics $graphics -Brush $panelSoft -X 738 -Y 130 -Width 205 -Height 126 -Radius 22
        Draw-RoundedRectangle -Graphics $graphics -Pen $borderSoft -X 738 -Y 130 -Width 205 -Height 126 -Radius 22
        Draw-Text -Graphics $graphics -Text '代理端口变化' -Font $fontCardTitle -Brush $white -X 748 -Y 151 -Width 185 -Height 34 -Alignment Center
        Draw-Text -Graphics $graphics -Text '7890 → 7891' -Font $fontCardMono -Brush $cyan -X 748 -Y 199 -Width 185 -Height 34 -Alignment Center

        Draw-Arrow -Graphics $graphics -Color (New-Color 43 221 211) -X1 950 -Y1 193 -X2 1005 -Y2 193 -Width 4

        $shield = New-Object System.Drawing.SolidBrush((New-Color 119 239 166 45)); [void]$resources.Add($shield)
        $shieldPen = New-Object System.Drawing.Pen((New-Color 119 239 166), 4); [void]$resources.Add($shieldPen)
        $shieldPoints = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new(1044, 131),
            [System.Drawing.PointF]::new(1100, 150),
            [System.Drawing.PointF]::new(1094, 211),
            [System.Drawing.PointF]::new(1044, 248),
            [System.Drawing.PointF]::new(994, 211),
            [System.Drawing.PointF]::new(988, 150)
        )
        $graphics.FillPolygon($shield, $shieldPoints)
        $graphics.DrawPolygon($shieldPen, $shieldPoints)
        $checkPen = New-Object System.Drawing.Pen((New-Color 119 239 166), 8); [void]$resources.Add($checkPen)
        $checkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $checkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $graphics.DrawLines($checkPen, [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new(1019, 190),
            [System.Drawing.PointF]::new(1038, 208),
            [System.Drawing.PointF]::new(1072, 169)
        ))
        Draw-Text -Graphics $graphics -Text 'TCP + HTTPS' -Font $fontStatus -Brush $green -X 977 -Y 266 -Width 136 -Height 30 -Alignment Center

        Draw-Arrow -Graphics $graphics -Color (New-Color 119 239 166) -X1 1044 -Y1 310 -X2 1044 -Y2 348 -Width 4

        Fill-RoundedRectangle -Graphics $graphics -Brush $panelSoft -X 810 -Y 364 -Width 350 -Height 150 -Radius 22
        Draw-RoundedRectangle -Graphics $graphics -Pen $border -X 810 -Y 364 -Width 350 -Height 150 -Radius 22
        Draw-Text -Graphics $graphics -Text 'CODEX' -Font $fontCardMono -Brush $white -X 838 -Y 391 -Width 115 -Height 38
        Draw-Text -Graphics $graphics -Text '代理已同步' -Font $fontCardTitle -Brush $muted -X 970 -Y 392 -Width 158 -Height 38 -Alignment Far
        Draw-Text -Graphics $graphics -Text 'Ready' -Font $fontStatus -Brush $green -X 838 -Y 453 -Width 110 -Height 28
        Draw-Text -Graphics $graphics -Text 'TrafficObserved' -Font $fontStatus -Brush $cyan -X 970 -Y 453 -Width 160 -Height 28 -Alignment Far

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        foreach ($resource in $resources) { $resource.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function New-WorkflowGraphic {
    param([string]$Path)
    $bitmap = New-Object System.Drawing.Bitmap(1600, 900, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $graphics = Initialize-Graphics -Bitmap $bitmap
    $resources = New-Object System.Collections.ArrayList
    try {
        Add-Backdrop -Graphics $graphics -Width 1600 -Height 900

        $white = New-Object System.Drawing.SolidBrush((New-Color 245 250 255)); [void]$resources.Add($white)
        $muted = New-Object System.Drawing.SolidBrush((New-Color 174 194 211)); [void]$resources.Add($muted)
        $cyan = New-Object System.Drawing.SolidBrush((New-Color 43 221 211)); [void]$resources.Add($cyan)
        $green = New-Object System.Drawing.SolidBrush((New-Color 119 239 166)); [void]$resources.Add($green)
        $red = New-Object System.Drawing.SolidBrush((New-Color 255 124 124)); [void]$resources.Add($red)
        $panel = New-Object System.Drawing.SolidBrush((New-Color 14 30 47 235)); [void]$resources.Add($panel)
        $panelSoft = New-Object System.Drawing.SolidBrush((New-Color 30 54 72 220)); [void]$resources.Add($panelSoft)
        $border = New-Object System.Drawing.Pen((New-Color 255 255 255 38), 2); [void]$resources.Add($border)

        $fontTitle = New-Font -Family 'Microsoft YaHei UI' -Size 44 -Style Bold; [void]$resources.Add($fontTitle)
        $fontSub = New-Font -Family 'Microsoft YaHei UI' -Size 23; [void]$resources.Add($fontSub)
        $fontLabel = New-Font -Family 'Microsoft YaHei UI' -Size 21 -Style Bold; [void]$resources.Add($fontLabel)
        $fontStage = New-Font -Family 'Microsoft YaHei UI' -Size 28 -Style Bold; [void]$resources.Add($fontStage)
        $fontBody = New-Font -Family 'Microsoft YaHei UI' -Size 19; [void]$resources.Add($fontBody)
        $fontMono = New-Font -Family 'Consolas' -Size 18 -Style Bold; [void]$resources.Add($fontMono)
        $fontFooter = New-Font -Family 'Microsoft YaHei UI' -Size 20 -Style Bold; [void]$resources.Add($fontFooter)

        Draw-Text -Graphics $graphics -Text '它解决的不是“有没有代理”，而是“Codex 有没有跟上代理”' -Font $fontTitle -Brush $white -X 70 -Y 58 -Width 1460 -Height 70 -Alignment Center
        Draw-Text -Graphics $graphics -Text '从端口变化到实际生效，所有关键步骤都有验证与保护' -Font $fontSub -Brush $muted -X 130 -Y 138 -Width 1340 -Height 45 -Alignment Center

        Fill-RoundedRectangle -Graphics $graphics -Brush $panel -X 80 -Y 220 -Width 1440 -Height 160 -Radius 28
        Draw-RoundedRectangle -Graphics $graphics -Pen $border -X 80 -Y 220 -Width 1440 -Height 160 -Radius 28
        Draw-Text -Graphics $graphics -Text '常见情况' -Font $fontLabel -Brush $red -X 112 -Y 245 -Width 130 -Height 36
        Draw-Text -Graphics $graphics -Text '代理端口变化' -Font $fontStage -Brush $white -X 280 -Y 250 -Width 220 -Height 45 -Alignment Center
        Draw-Arrow -Graphics $graphics -Color (New-Color 255 124 124) -X1 510 -Y1 275 -X2 620 -Y2 275 -Width 4
        Draw-Text -Graphics $graphics -Text 'Codex 仍用旧端口' -Font $fontStage -Brush $white -X 630 -Y 250 -Width 280 -Height 45 -Alignment Center
        Draw-Arrow -Graphics $graphics -Color (New-Color 255 124 124) -X1 920 -Y1 275 -X2 1030 -Y2 275 -Width 4
        Draw-Text -Graphics $graphics -Text '代理未继承 / 旧端口' -Font $fontStage -Brush $red -X 1045 -Y 250 -Width 290 -Height 45 -Alignment Center
        Draw-Text -Graphics $graphics -Text '浏览器能联网，不等于已经运行的 Codex 自动拿到了同一个代理。' -Font $fontBody -Brush $muted -X 280 -Y 316 -Width 1055 -Height 34 -Alignment Center

        $cards = @(
            @{ X = 80; Number = '01'; Title = '发现'; Body = "系统代理`n代理环境变量`n常见代理程序监听端口"; Status = 'Candidates' },
            @{ X = 450; Number = '02'; Title = '验证'; Body = "TCP 监听检查`n多个 HTTPS 测试目标`n达到成功数量要求"; Status = 'ValidatedProxy' },
            @{ X = 820; Number = '03'; Title = '稳定'; Body = "稳定采样与防抖`n重启冷却与频率限制`n异常时自动熔断"; Status = 'Safe / Circuit' },
            @{ X = 1190; Number = '04'; Title = '生效'; Body = "为 Codex 配置当前代理`n观察真实进程连接`n输出渐进式证据"; Status = 'TrafficObserved' }
        )
        foreach ($card in $cards) {
            Fill-RoundedRectangle -Graphics $graphics -Brush $panel -X $card.X -Y 430 -Width 330 -Height 330 -Radius 26
            Draw-RoundedRectangle -Graphics $graphics -Pen $border -X $card.X -Y 430 -Width 330 -Height 330 -Radius 26
            Fill-RoundedRectangle -Graphics $graphics -Brush $panelSoft -X ($card.X + 28) -Y 458 -Width 62 -Height 40 -Radius 14
            Draw-Text -Graphics $graphics -Text $card.Number -Font $fontMono -Brush $cyan -X ($card.X + 28) -Y 465 -Width 62 -Height 28 -Alignment Center
            Draw-Text -Graphics $graphics -Text $card.Title -Font $fontStage -Brush $white -X ($card.X + 110) -Y 458 -Width 170 -Height 44
            Draw-Text -Graphics $graphics -Text $card.Body -Font $fontBody -Brush $muted -X ($card.X + 28) -Y 530 -Width 274 -Height 120 -Alignment Center -LineAlignment Center
            Fill-RoundedRectangle -Graphics $graphics -Brush $panelSoft -X ($card.X + 28) -Y 684 -Width 274 -Height 46 -Radius 14
            Draw-Text -Graphics $graphics -Text $card.Status -Font $fontMono -Brush $green -X ($card.X + 34) -Y 693 -Width 262 -Height 28 -Alignment Center
        }
        Draw-Arrow -Graphics $graphics -Color (New-Color 43 221 211) -X1 417 -Y1 595 -X2 445 -Y2 595 -Width 4
        Draw-Arrow -Graphics $graphics -Color (New-Color 43 221 211) -X1 787 -Y1 595 -X2 815 -Y2 595 -Width 4
        Draw-Arrow -Graphics $graphics -Color (New-Color 43 221 211) -X1 1157 -Y1 595 -X2 1185 -Y2 595 -Width 4

        Fill-RoundedRectangle -Graphics $graphics -Brush $panelSoft -X 180 -Y 810 -Width 1240 -Height 55 -Radius 18
        Draw-Text -Graphics $graphics -Text '不修改系统代理   ·   不写永久环境变量   ·   默认 Safe 模式   ·   只在验证稳定后受控重启' -Font $fontFooter -Brush $white -X 205 -Y 821 -Width 1190 -Height 34 -Alignment Center

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        foreach ($resource in $resources) { $resource.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$socialPath = Join-Path $outputRoot 'social-preview.png'
$workflowPath = Join-Path $outputRoot 'how-it-works.png'
New-SocialPreview -Path $socialPath
New-WorkflowGraphic -Path $workflowPath

@(
    [pscustomobject]@{ Name = 'SocialPreview'; Path = $socialPath; Width = 1280; Height = 640 },
    [pscustomobject]@{ Name = 'Workflow'; Path = $workflowPath; Width = 1600; Height = 900 }
)

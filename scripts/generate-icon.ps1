$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RoundedRectanglePath {
    param(
        [System.Drawing.RectangleF]$Rectangle,
        [float]$Radius
    )

    $diameter = $Radius * 2
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rectangle.X, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

$destination = Join-Path $PSScriptRoot '..\Resources\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$bitmap = [System.Drawing.Bitmap]::new(1024, 1024)

try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::FromArgb(255, 6, 26, 51))

        $back = [System.Drawing.RectangleF]::new(454, 112, 390, 650)
        $front = [System.Drawing.RectangleF]::new(180, 300, 410, 660)
        $backPath = New-RoundedRectanglePath -Rectangle $back -Radius 62
        $frontPath = New-RoundedRectanglePath -Rectangle $front -Radius 62

        try {
            $backFill = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 9, 62, 105))
            $frontFill = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 0, 92, 126))
            $whitePen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 38)
            $cyanPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 45, 226, 230), 38)
            $wavePen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 30)
            $dotBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 45, 226, 230))

            try {
                $whitePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
                $cyanPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
                $wavePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $wavePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

                $graphics.FillPath($backFill, $backPath)
                $graphics.DrawPath($whitePen, $backPath)
                $graphics.FillPath($frontFill, $frontPath)
                $graphics.DrawPath($cyanPen, $frontPath)

                $graphics.FillEllipse($dotBrush, 302, 679, 62, 62)
                $graphics.DrawArc($wavePen, 286, 583, 160, 160, 275, 80)
                $graphics.DrawArc($wavePen, 260, 530, 260, 260, 275, 80)
                $graphics.DrawArc($wavePen, 234, 477, 360, 360, 275, 80)
            }
            finally {
                $backFill.Dispose()
                $frontFill.Dispose()
                $whitePen.Dispose()
                $cyanPen.Dispose()
                $wavePen.Dispose()
                $dotBrush.Dispose()
            }
        }
        finally {
            $backPath.Dispose()
            $frontPath.Dispose()
        }
    }
    finally {
        $graphics.Dispose()
    }

    $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $bitmap.Dispose()
}

Write-Output "Generated $destination"

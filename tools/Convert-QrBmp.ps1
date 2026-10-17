# Convert installer\mobile\*.png (from Make-MobileQr.py) to 24-bit .bmp for the Inno Setup page.
Add-Type -AssemblyName System.Drawing
$dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'installer\mobile'
foreach ($p in Get-ChildItem $dir -Filter '*.png') {
    $img = [Drawing.Image]::FromFile($p.FullName)
    $bmp = New-Object Drawing.Bitmap $img.Width, $img.Height, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::White)
    $g.InterpolationMode = 'NearestNeighbor'; $g.DrawImage($img, 0, 0, $img.Width, $img.Height); $g.Dispose()
    $out = [IO.Path]::ChangeExtension($p.FullName, '.bmp')
    $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Bmp); $bmp.Dispose(); $img.Dispose()
    Write-Host "$($p.Name) -> $(Split-Path $out -Leaf) ($($bmp.Width)x$($bmp.Height))"
}

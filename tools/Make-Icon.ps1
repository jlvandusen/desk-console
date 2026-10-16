param([string]$Out)
# Desk Console icon: three monitors on a dark rounded tile, PNG-in-ICO at 256/48/32/16.
Add-Type -AssemblyName System.Drawing
function Draw([int]$s) {
    $b = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    $k = $s / 256.0
    function RR($x, $y, $w, $h, $r) {
        $p = New-Object Drawing.Drawing2D.GraphicsPath
        $p.AddArc($x, $y, $r, $r, 180, 90); $p.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
        $p.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90); $p.AddArc($x, $y + $h - $r, $r, $r, 90, 90); $p.CloseFigure(); $p
    }
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 28, 34, 44))), (RR (4*$k) (4*$k) (248*$k) (248*$k) (56*$k)))
    $azure = [Drawing.Color]::FromArgb(255, 47, 123, 214); $white = [Drawing.Color]::White
    $pen = New-Object Drawing.Pen $white, ([Math]::Max(1.0, 7*$k))
    # side monitors
    foreach ($x in 18, 158) {
        $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 30, 85, 150))), $x*$k, 92*$k, 80*$k, 58*$k)
        $g.DrawRectangle($pen, $x*$k, 92*$k, 80*$k, 58*$k)
    }
    # centre monitor + stand
    $g.FillRectangle((New-Object Drawing.SolidBrush $azure), 58*$k, 62*$k, 140*$k, 96*$k)
    $g.DrawRectangle($pen, 58*$k, 62*$k, 140*$k, 96*$k)
    $g.FillRectangle((New-Object Drawing.SolidBrush $white), 118*$k, 158*$k, 20*$k, 26*$k)
    $g.FillRectangle((New-Object Drawing.SolidBrush $white), 88*$k, 184*$k, 80*$k, 10*$k)
    # cursor arrow on the centre screen
    if ($s -ge 32) {
        $pts = @((New-Object Drawing.PointF (112*$k), (80*$k)), (New-Object Drawing.PointF (112*$k), (138*$k)),
                 (New-Object Drawing.PointF (126*$k), (125*$k)), (New-Object Drawing.PointF (136*$k), (146*$k)),
                 (New-Object Drawing.PointF (145*$k), (141*$k)), (New-Object Drawing.PointF (135*$k), (121*$k)),
                 (New-Object Drawing.PointF (153*$k), (120*$k)))
        $g.FillPolygon((New-Object Drawing.SolidBrush $white), [Drawing.PointF[]]$pts)
    }
    $g.Dispose()
    $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose(); , $ms.ToArray()
}
$sizes = 256, 48, 32, 16
$pngs = $sizes | ForEach-Object { , (Draw $_) }
$ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$off = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $d = [byte]($sizes[$i] % 256)
    $w.Write($d); $w.Write($d); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$off)
    $off += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
[IO.File]::WriteAllBytes($Out, $ms.ToArray())
[IO.File]::WriteAllBytes(($Out -replace '\.ico$', '_preview.png'), $pngs[0])

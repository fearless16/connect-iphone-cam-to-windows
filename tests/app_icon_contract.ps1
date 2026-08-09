param([Parameter(Mandatory = $true)][string]$IconPath)

Add-Type -AssemblyName System.Drawing
$icon = [System.Drawing.Bitmap]::FromFile($IconPath)
try {
    if ($icon.Width -ne 1024 -or $icon.Height -ne 1024) {
        throw "App icon must be 1024x1024; got $($icon.Width)x$($icon.Height)."
    }
    for ($y = 0; $y -lt $icon.Height; $y++) {
        for ($x = 0; $x -lt $icon.Width; $x++) {
            if ($icon.GetPixel($x, $y).A -ne 255) {
                throw "App icon has transparency at $x,$y."
            }
        }
    }
} finally {
    $icon.Dispose()
}

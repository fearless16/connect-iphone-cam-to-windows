[CmdletBinding()]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dll = Join-Path $root 'IPhoneCameraStreamSource.dll'
$controller = Join-Path $root 'IPhoneCameraVcamController.exe'

if (-not (Test-Path -LiteralPath $dll) -or -not (Test-Path -LiteralPath $controller)) {
    throw 'Keep INSTALL-OBS.ps1 beside IPhoneCameraStreamSource.dll and IPhoneCameraVcamController.exe.'
}

$systemRegsvr = Join-Path $env:WINDIR 'System32\regsvr32.exe'
if ($Remove) {
    & $systemRegsvr /u $dll
    if ($LASTEXITCODE -ne 0) { throw "regsvr32 unregister failed: $LASTEXITCODE" }
    & $controller --remove
    if ($LASTEXITCODE -ne 0) { throw "virtual-camera removal failed: $LASTEXITCODE" }
    Write-Host 'iPhone Camera Stream removed.'
    exit 0
}

# Registration must be elevated: Windows Frame Server cannot load a per-user
# COM source. Start this script with "Run with PowerShell as Administrator".
& $systemRegsvr $dll
if ($LASTEXITCODE -ne 0) { throw "regsvr32 registration failed: $LASTEXITCODE" }
& $controller
if ($LASTEXITCODE -ne 0) { throw "virtual-camera registration failed: $LASTEXITCODE" }
Write-Host 'Registered iPhone Camera Stream. Add it in OBS as a Video Capture Device.'

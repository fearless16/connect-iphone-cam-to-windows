[CmdletBinding()]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script with PowerShell as Administrator. The Windows Frame Server requires machine-wide COM and virtual-camera registration.'
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dll = Join-Path $root 'IPhoneCameraStreamSource.dll'
$controller = Join-Path $root 'IPhoneCameraVcamController.exe'

if (-not (Test-Path -LiteralPath $dll) -or -not (Test-Path -LiteralPath $controller)) {
    throw 'Keep INSTALL-OBS.ps1 beside IPhoneCameraStreamSource.dll and IPhoneCameraVcamController.exe.'
}

$systemRegsvr = Join-Path $env:WINDIR 'System32\regsvr32.exe'
$sourceClsid = '{6A3939D4-C839-4CC3-A9C7-B0372E3680B3}'
$sourceRegistration = "HKLM:\Software\Classes\CLSID\$sourceClsid\InprocServer32"
function Test-SourceRegistration {
    if (-not (Test-Path -LiteralPath $sourceRegistration)) { return $false }
    return (Get-ItemProperty -LiteralPath $sourceRegistration).'(default)' -eq $dll
}

if ($Remove) {
    & $systemRegsvr /u $dll
    if (Test-SourceRegistration) { throw 'regsvr32 unregister did not remove the source COM registration.' }
    & $controller --remove
    if ($LASTEXITCODE -ne 0) { throw "virtual-camera removal failed: $LASTEXITCODE" }
    Write-Host 'iPhone Camera Stream removed.'
    exit 0
}

# Registration must be elevated: Windows Frame Server cannot load a per-user
# COM source. The controller creates an AllUsers virtual camera in this same
# elevation context so it is visible to the normal OBS user.
& $systemRegsvr $dll
# regsvr32 can leave LASTEXITCODE unset for its GUI invocation in PowerShell 7.
# Verify the machine-wide COM entry instead of treating an unset value as a failure.
if (-not (Test-SourceRegistration)) { throw "regsvr32 did not create the source COM registration (exit: $LASTEXITCODE)." }
& $controller
if ($LASTEXITCODE -ne 0) { throw "virtual-camera registration failed: $LASTEXITCODE" }
Write-Host 'Registered iPhone Camera Stream. Add it in OBS as a Video Capture Device.'

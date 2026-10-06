# One-time setup so the panel's "Update now" button works on this computer.
# Right-click this file and choose "Run with PowerShell", or run:
#   powershell -ExecutionPolicy Bypass -File updater\install-windows.ps1
#
# It tells Chrome that the IRF Minutes extension is allowed to run
# updater\irf_updater.bat, which is what pulls the new files.

$ErrorActionPreference = "Stop"

$ExtensionId = "mmibabdnhomcdfpmhfchijiociknhibo"
$HostName = "com.irf.minutes.updater"

$updaterDir = $PSScriptRoot
$batPath = Join-Path $updaterDir "irf_updater.bat"
$manifestPath = Join-Path $updaterDir "$HostName.json"

if (-not (Test-Path $batPath)) {
  throw "Can't find $batPath. Run this script from inside the extension folder."
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "git isn't installed, or isn't on PATH. Install Git for Windows first."
}
if (-not ((Get-Command py -ErrorAction SilentlyContinue) -or (Get-Command python -ErrorAction SilentlyContinue))) {
  throw "Python 3 isn't installed, or isn't on PATH. Install it from python.org first."
}

@{
  name           = $HostName
  description    = "IRF Minutes updater"
  path           = $batPath
  type           = "stdio"
  allowed_origins = @("chrome-extension://$ExtensionId/")
} | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

foreach ($browserKey in @("Google\Chrome", "Microsoft\Edge")) {
  $key = "HKCU:\Software\$browserKey\NativeMessagingHosts\$HostName"
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name "(Default)" -Value $manifestPath
}

Write-Host "Done. Restart Chrome, then the Update now button will work." -ForegroundColor Green

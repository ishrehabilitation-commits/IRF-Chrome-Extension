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
# Run the helper exactly the way Chrome will. This catches the Windows
# "python" placeholder that only opens the Microsoft Store, which passes a
# simple "is python on PATH" test but can't run anything.
$check = & $batPath --check 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $check -notmatch "^OK") {
  Write-Host $check.Trim()
  throw ("The updater couldn't run on this computer. If the message above mentions Python or the Microsoft Store, " +
    "install Python 3 from python.org (tick 'Add python.exe to PATH'), then run this installer again. " +
    "More detail is in $(Join-Path $updaterDir 'updater.log').")
}
Write-Host $check.Trim()

# Chrome reads this file; write it as plain UTF-8 without a byte-order mark.
$manifest = @{
  name            = $HostName
  description     = "IRF Minutes updater"
  path            = $batPath
  type            = "stdio"
  allowed_origins = @("chrome-extension://$ExtensionId/")
} | ConvertTo-Json
[System.IO.File]::WriteAllText($manifestPath, $manifest, (New-Object System.Text.UTF8Encoding $false))

foreach ($browserKey in @("Google\Chrome", "Microsoft\Edge")) {
  $key = "HKCU:\Software\$browserKey\NativeMessagingHosts\$HostName"
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name "(Default)" -Value $manifestPath
}

Write-Host "Done. Restart Chrome, then the Update now button will work." -ForegroundColor Green

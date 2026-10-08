# One-time setup so the panel's "Update now" button works on this computer.
# Right-click this file and choose "Run with PowerShell", or run:
#   powershell -ExecutionPolicy Bypass -File updater\install-windows.ps1
#
# It tells Chrome that the IRF Minutes extension is allowed to run
# updater\irf_updater.bat, which is what pulls the new files.

$ErrorActionPreference = "Stop"

$ExtensionId = "mmibabdnhomcdfpmhfchijiociknhibo"
$HostName = "com.irf.minutes.updater"
$RepoUrl = "https://github.com/ishrehabilitation-commits/IRF-Chrome-Extension.git"

$updaterDir = $PSScriptRoot
$batPath = Join-Path $updaterDir "irf_updater.bat"
$manifestPath = Join-Path $updaterDir "$HostName.json"

if (-not (Test-Path $batPath)) {
  throw "Can't find $batPath. Run this script from inside the extension folder."
}
function Update-Path {
  # A fresh install changes PATH in the registry, not in this window.
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
    [Environment]::GetEnvironmentVariable("Path", "User")
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw ("git isn't installed, and winget isn't available to install it. " +
      "Install Git for Windows from https://git-scm.com/download/win, then run this again.")
  }
  $answer = Read-Host "Git isn't installed on this computer. Install it now with winget? [Y/n]"
  if ($answer -match "^\s*n") {
    throw "Git is needed for the Update now button. Install Git for Windows, then run this again."
  }
  winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
  Update-Path
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw ("Git didn't install, or this window can't see it yet. " +
      "Close PowerShell, open a new window, and run this again.")
  }
  Write-Host "Git installed." -ForegroundColor Green
}

# A folder downloaded as a ZIP from GitHub has no git history, so Update now
# couldn't update it. Link it to GitHub in place, so Chrome can keep loading
# this same folder.
$repoDir = Split-Path -Parent $updaterDir
if (-not (Test-Path (Join-Path $repoDir ".git"))) {
  Write-Host "This folder isn't linked to GitHub yet (it looks like a ZIP download). Linking it now..."
  git -C $repoDir init -q
  git -C $repoDir remote add origin $RepoUrl
  git -C $repoDir fetch -q origin main
  if ($LASTEXITCODE -ne 0) { throw "Couldn't download from $RepoUrl. Check the network and run this again." }
  # Point the folder at GitHub's main without touching any files yet.
  git -C $repoDir reset -q origin/main
  git -C $repoDir branch -q -M main
  git -C $repoDir branch -q -u origin/main
  $changed = git -C $repoDir status --porcelain --untracked-files=no
  if ($changed) {
    Write-Host ($changed -join "`n")
    $answer = Read-Host ("These files differ from GitHub's latest version, usually because the ZIP " +
      "is older. Update them to GitHub's version now? [Y/n]")
    if ($answer -match "^\s*n") {
      Write-Host ("Kept them. Update now won't run until they match GitHub; run " +
        "'git checkout -- .' in this folder when you're ready.") -ForegroundColor Yellow
    } else {
      git -C $repoDir checkout -q -- .
    }
  }
  Write-Host "Linked to GitHub." -ForegroundColor Green
}
# Run the helper exactly the way Chrome will, so a problem shows up now
# rather than as a vague error in the panel later. It changes nothing.
$check = & $batPath --check 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $check -notmatch "^OK") {
  Write-Host $check.Trim()
  throw ("The updater couldn't run on this computer; the message above says why. " +
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

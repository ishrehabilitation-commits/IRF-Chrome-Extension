<# : IRF Minutes setup for Windows. Double-click this file.
@echo off
rem The lines above and below are a batch file that runs the PowerShell part
rem of this same file, so one file can be copied anywhere (a network share,
rem a USB stick) and double-clicked. PowerShell skips this block as a comment.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command "iex ([System.IO.File]::ReadAllText('%~f0'))"
exit /b %errorlevel%
: end of the batch part #>

# What this does, in order:
#   1. Checks Chrome and Edge are closed, and offers to close them.
#   2. Asks where to put the extension, and which Chrome and Edge profiles
#      to open it in.
#   3. Installs Git with winget if it's missing.
#   4. Clones the extension from GitHub, or updates an existing copy.
#   5. Registers the Update now helper (updater\install-windows.ps1).
#   6. Offers to open the browser on the extensions page and WellSky.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Title = "IRF Minutes setup"
$RepoUrl = "https://github.com/ishrehabilitation-commits/IRF-Chrome-Extension.git"
$ExtensionId = "mmibabdnhomcdfpmhfchijiociknhibo"
$WellSkyUrl = "https://woodlake.specialtycare.wellsky.com/Interactant/"
$DefaultFolder = Join-Path $env:USERPROFILE "IRF-Chrome-Extension"

$Browsers = @(
  [pscustomobject]@{
    Name = "Google Chrome"; Exe = "chrome.exe"; Process = "chrome"; ExtensionsPage = "chrome://extensions"
    UserData = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    Fallbacks = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
      "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
  },
  [pscustomobject]@{
    Name = "Microsoft Edge"; Exe = "msedge.exe"; Process = "msedge"; ExtensionsPage = "edge://extensions"
    UserData = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
    Fallbacks = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
  }
)

function Show-Message([string]$Text, [string]$Buttons = "OK", [string]$Icon = "Information") {
  return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}

function Write-Step([string]$Text) {
  Write-Host ""
  Write-Host "== $Text" -ForegroundColor Cyan
}

# Where the browser is installed: the App Paths registry entry first, then
# the usual install folders.
function Find-BrowserExe($Browser) {
  foreach ($root in @("HKLM:", "HKCU:")) {
    $key = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($Browser.Exe)"
    try {
      $path = (Get-ItemProperty -Path $key -ErrorAction Stop)."(default)"
      if ($path -and (Test-Path $path)) { return $path.Trim('"') }
    } catch { }
  }
  foreach ($path in $Browser.Fallbacks) {
    if ($path -and (Test-Path $path)) { return $path }
  }
  return $null
}

# The browser's profiles, with the names people see, Default first.
function Get-Profiles($Browser) {
  $list = @()
  $localState = Join-Path $Browser.UserData "Local State"
  if (Test-Path $localState) {
    try {
      $cache = ([System.IO.File]::ReadAllText($localState) | ConvertFrom-Json).profile.info_cache
      foreach ($p in $cache.PSObject.Properties) {
        $list += [pscustomobject]@{ Dir = $p.Name; Name = $p.Value.name }
      }
    } catch { }
  }
  if ($list.Count -eq 0 -and (Test-Path $Browser.UserData)) {
    foreach ($d in Get-ChildItem $Browser.UserData -Directory) {
      if ($d.Name -eq "Default" -or $d.Name -like "Profile *") {
        $list += [pscustomobject]@{ Dir = $d.Name; Name = $d.Name }
      }
    }
  }
  if ($list.Count -eq 0) { $list += [pscustomobject]@{ Dir = "Default"; Name = "Default" } }
  return @($list | Sort-Object @{ Expression = { if ($_.Dir -eq "Default") { 0 } else { 1 } } }, Dir)
}

# True when this profile already has the extension loaded.
function Test-ExtensionLoaded($Browser, [string]$ProfileDir) {
  foreach ($file in @("Secure Preferences", "Preferences")) {
    $path = Join-Path (Join-Path $Browser.UserData $ProfileDir) $file
    try {
      if ((Test-Path $path) -and ([System.IO.File]::ReadAllText($path) -match $ExtensionId)) { return $true }
    } catch { }
  }
  return $false
}

function Update-Path {
  # A fresh install changes PATH in the registry, not in this window.
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
    [Environment]::GetEnvironmentVariable("Path", "User")
}

# --- 1. Browsers closed? ---------------------------------------------------
function Confirm-BrowsersClosed {
  $open = @(Get-Process -Name chrome, msedge -ErrorAction SilentlyContinue)
  if ($open.Count -eq 0) { return }
  $names = @($open | ForEach-Object { if ($_.Name -eq "chrome") { "Chrome" } else { "Edge" } } | Sort-Object -Unique) -join " and "
  $answer = Show-Message ("$names is open. Setup works best with it closed.`n`n" +
    "Yes: close it for me. Save any work in open pages first.`n" +
    "No: carry on with it open.`n" +
    "Cancel: stop setup.") "YesNoCancel" "Question"
  if ($answer -eq "Cancel") { exit 0 }
  if ($answer -eq "Yes") {
    foreach ($p in $open) { try { $p.CloseMainWindow() | Out-Null } catch { } }
    Start-Sleep -Seconds 3
    Get-Process -Name chrome, msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

# --- 2. Choices --------------------------------------------------------------
function Show-SetupForm {
  $form = New-Object System.Windows.Forms.Form
  $form.Text = $Title
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = "FixedDialog"
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.ClientSize = New-Object System.Drawing.Size(520, 330)
  $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = "Install the extension in this folder:"
  $label.SetBounds(16, 14, 480, 20)
  $form.Controls.Add($label)

  $folderBox = New-Object System.Windows.Forms.TextBox
  $folderBox.Text = $DefaultFolder
  $folderBox.SetBounds(16, 36, 400, 24)
  $form.Controls.Add($folderBox)

  $browse = New-Object System.Windows.Forms.Button
  $browse.Text = "Browse..."
  $browse.SetBounds(424, 35, 80, 26)
  $browse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose where to put the IRF Minutes extension. A new IRF-Chrome-Extension folder is made inside it."
    if ($dialog.ShowDialog() -eq "OK") { $folderBox.Text = Join-Path $dialog.SelectedPath "IRF-Chrome-Extension" }
  })
  $form.Controls.Add($browse)

  $rows = @()
  $top = 76
  foreach ($b in $Browsers) {
    $exe = Find-BrowserExe $b
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $b.Name
    $group.SetBounds(16, $top, 488, 92)
    $form.Controls.Add($group)

    $check = New-Object System.Windows.Forms.CheckBox
    $check.SetBounds(12, 20, 460, 22)
    $group.Controls.Add($check)

    $profileLabel = New-Object System.Windows.Forms.Label
    $profileLabel.Text = "Profile:"
    $profileLabel.SetBounds(30, 54, 50, 20)
    $group.Controls.Add($profileLabel)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = "DropDownList"
    $combo.SetBounds(84, 51, 388, 24)
    $group.Controls.Add($combo)

    $profiles = @()
    if ($exe) {
      $check.Text = "Use with $($b.Name) ($exe)"
      $check.Checked = ($b.Process -eq "chrome")
      $profiles = Get-Profiles $b
      foreach ($p in $profiles) {
        $text = if ($p.Name -and $p.Name -ne $p.Dir) { "$($p.Name)  ($($p.Dir))" } else { $p.Dir }
        [void]$combo.Items.Add($text)
      }
      $combo.SelectedIndex = 0
    } else {
      $check.Text = "$($b.Name) isn't installed on this computer"
      $check.Enabled = $false
      $combo.Enabled = $false
    }
    $rows += [pscustomobject]@{ Browser = $b; Exe = $exe; Check = $check; Combo = $combo; Profiles = $profiles }
    $top += 104
  }

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = "Install"
  $ok.SetBounds(332, 292, 84, 28)
  $ok.DialogResult = "OK"
  $form.AcceptButton = $ok
  $form.Controls.Add($ok)

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = "Cancel"
  $cancel.SetBounds(420, 292, 84, 28)
  $cancel.DialogResult = "Cancel"
  $form.CancelButton = $cancel
  $form.Controls.Add($cancel)

  $form.Topmost = $true
  if ($form.ShowDialog() -ne "OK") { exit 0 }

  $chosen = @()
  foreach ($r in $rows) {
    if ($r.Exe -and $r.Check.Checked) {
      $chosen += [pscustomobject]@{ Browser = $r.Browser; Exe = $r.Exe; Profile = $r.Profiles[$r.Combo.SelectedIndex].Dir }
    }
  }
  return [pscustomobject]@{ Folder = $folderBox.Text.Trim(); Browsers = $chosen }
}

# --- 3. Git -------------------------------------------------------------------
function Install-GitIfMissing {
  Write-Step "Checking for Git"
  if (Get-Command git -ErrorAction SilentlyContinue) { Write-Host "Git is installed."; return }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw ("Git isn't installed, and winget isn't available to install it. " +
      "Install Git for Windows from https://git-scm.com/download/win, then run setup again.")
  }
  Write-Host "Installing Git with winget. Approve the Windows prompt if one appears."
  winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
  Update-Path
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git didn't install, or this window can't see it yet. Run setup again; it will skip what's already done."
  }
  Write-Host "Git installed." -ForegroundColor Green
}

# --- 4. The extension's files ---------------------------------------------------
function Get-Extension([string]$Folder) {
  Write-Step "Getting the extension from GitHub"
  if (Test-Path (Join-Path $Folder ".git")) {
    Write-Host "$Folder is already set up; bringing it up to date."
    git -C $Folder pull --ff-only
    if ($LASTEXITCODE -ne 0) {
      Write-Host "Couldn't update it (see above), so it stays as it is. Update now in the panel will say why." -ForegroundColor Yellow
    }
    return
  }
  if ((Test-Path $Folder) -and @(Get-ChildItem -Force $Folder).Count -gt 0) {
    throw "$Folder already has other files in it. Pick an empty or new folder, then run setup again."
  }
  git clone $RepoUrl $Folder
  if ($LASTEXITCODE -ne 0) { throw "Couldn't download the extension from GitHub. Check the network, then run setup again." }
}

# --- 5. Update now helper ---------------------------------------------------------
function Register-Updater([string]$Folder) {
  Write-Step "Setting up the Update now button"
  $script = Join-Path $Folder "updater\install-windows.ps1"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoPause
  if ($LASTEXITCODE -ne 0) { throw "The Update now setup failed; the message above says why." }
}

# --- 6. Open the browser ----------------------------------------------------------
function Open-Browsers([string]$Folder, $Chosen) {
  $needsLoading = @($Chosen | Where-Object { -not (Test-ExtensionLoaded $_.Browser $_.Profile) })
  $text = "Setup is done.`n`nOpen the browser now"
  if ($needsLoading.Count -gt 0) { $text += " so you can add the extension" }
  $text += " and go to WellSky?"
  if ((Show-Message $text "YesNo" "Question") -ne "Yes") { return }

  foreach ($c in $Chosen) {
    $launchArgs = @("--profile-directory=`"$($c.Profile)`"")
    if ($needsLoading -contains $c) { $launchArgs += $c.Browser.ExtensionsPage }
    $launchArgs += $WellSkyUrl
    Start-Process -FilePath $c.Exe -ArgumentList $launchArgs
  }

  if ($needsLoading.Count -gt 0) {
    Set-Clipboard -Value $Folder
    Show-Message ("Browsers no longer let setup add an extension for you, so this last part is by hand. " +
      "On the extensions page that just opened:`n`n" +
      "1. Turn on Developer mode.`n" +
      "2. Click Load unpacked.`n" +
      "3. Paste this folder (it's already copied) and click Select Folder:`n   $Folder`n" +
      "4. Click the puzzle-piece icon in the toolbar and pin IRF Minutes.`n`n" +
      "You only do this once per profile. After that, Update now keeps it current.") | Out-Null
  }
}

# --- Run ----------------------------------------------------------------------------
try {
  Write-Host "IRF Minutes setup" -ForegroundColor Cyan
  Confirm-BrowsersClosed
  $choice = Show-SetupForm
  if (-not $choice.Folder) { throw "No folder was chosen." }
  if ($choice.Browsers.Count -eq 0) { throw "Pick at least one browser." }

  Install-GitIfMissing
  Get-Extension $choice.Folder
  Register-Updater $choice.Folder

  Write-Host ""
  Write-Host "All done." -ForegroundColor Green
  Open-Browsers $choice.Folder $choice.Browsers
} catch {
  Write-Host ""
  Write-Host "Setup failed: $($_.Exception.Message)" -ForegroundColor Red
  Show-Message "Setup failed:`n`n$($_.Exception.Message)`n`nThe setup window has more detail." "OK" "Error" | Out-Null
  Write-Host ""
  Read-Host "Press Enter to close this window" | Out-Null
  exit 1
}

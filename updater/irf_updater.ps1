# Native messaging host for the IRF Minutes extension, Windows version.
#
# Chrome extensions can't run git, so the panel's "Update now" button asks
# this script to do it. It is the PowerShell twin of irf_updater.py, so
# Windows PCs need only git, not Python. It lives inside the extension folder,
# so the repository to update is simply its parent directory.
#
# Protocol: each message is a 4-byte little-endian length followed by that many
# bytes of JSON, on stdin and stdout. Nothing else may be written to stdout.
#
# Every run appends to updater\updater.log. By hand:
#   updater\irf_updater.bat --check   (Python-free sanity check, changes nothing)
#   updater\irf_updater.bat --test    (a real update, outside Chrome)
#
# Written for Windows PowerShell 5.1, which every Windows 10/11 PC has.

$ErrorActionPreference = "Stop"

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $Here
$Log = Join-Path $Here "updater.log"
$Branch = "main"
$TimeoutMs = 120000

function Write-Log([string]$Text) {
  try {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    [System.IO.File]::AppendAllText($Log, "$stamp  $Text`r`n")
  } catch {
    # Logging must never be the reason an update fails.
  }
}

function Read-Exactly([System.IO.Stream]$Stream, [int]$Count) {
  $buffer = New-Object byte[] $Count
  $read = 0
  while ($read -lt $Count) {
    $n = $Stream.Read($buffer, $read, $Count - $read)
    if ($n -le 0) { return $null }
    $read += $n
  }
  return ,$buffer
}

function Read-Message {
  $stdin = [Console]::OpenStandardInput()
  $header = Read-Exactly $stdin 4
  if ($null -eq $header) { return $null }
  $length = [BitConverter]::ToUInt32($header, 0)
  $body = Read-Exactly $stdin ([int]$length)
  if ($null -eq $body) { return $null }
  return [System.Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json
}

function Send-Message($Payload) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress))
  $stdout = [Console]::OpenStandardOutput()
  $stdout.Write([BitConverter]::GetBytes([uint32]$bytes.Length), 0, 4)
  $stdout.Write($bytes, 0, $bytes.Length)
  $stdout.Flush()
}

# Runs git with its output captured, so none of it can leak onto stdout.
function Invoke-Git([string[]]$GitArgs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "git"
  $psi.Arguments = (@("-C", "`"$Repo`"") + $GitArgs) -join " "
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::Start($psi)
  $outTask = $process.StandardOutput.ReadToEndAsync()
  $errTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutMs)) {
    try { $process.Kill() } catch { }
    Write-Log "git $($GitArgs -join ' ') -> timed out"
    return @{ Code = -1; Output = "git took too long to respond." }
  }
  $output = ($errTask.Result + $outTask.Result).Trim()
  Write-Log "git $($GitArgs -join ' ') -> exit $($process.ExitCode) $output"
  return @{ Code = $process.ExitCode; Output = $output }
}

function Get-Version {
  try {
    $manifest = [System.IO.File]::ReadAllText((Join-Path $Repo "manifest.json")) | ConvertFrom-Json
    return $manifest.version
  } catch {
    return $null
  }
}

# Turn the noisier git failures into something a user can act on.
function Get-Explanation([string]$Output) {
  if ($Output -match "local changes|would be overwritten") {
    return "this folder has edits that aren't on GitHub. Run 'git checkout -- .' in the extension folder to drop them, then try again."
  }
  if ($Output -match "not possible to fast-forward|diverging") {
    return "this folder has commits that aren't on GitHub, so it can't fast-forward. Someone needs to sort the branch out by hand."
  }
  if ($Output -match "(?i)could not read|authentication") {
    return "git couldn't reach GitHub. Check the network, or whether sign-in is needed."
  }
  if ($Output.Length -gt 300) { return $Output.Substring(0, 300) }
  return $Output
}

# Bring the folder up to date with origin/main, without discarding work.
function Invoke-Update {
  $before = Get-Version
  try {
    # A merge only refuses edits it would overwrite, so check first: an
    # edited or stale file would otherwise survive a "successful" update.
    $status = Invoke-Git @("diff", "--name-only", "HEAD")
    $changed = @($status.Output -split "\r?\n" | Where-Object { $_.Trim() })
    if ($status.Code -eq 0 -and $changed.Count -gt 0) {
      $names = ($changed | Select-Object -First 5) -join ", "
      if ($changed.Count -gt 5) { $names += " and others" }
      return [ordered]@{ ok = $false; before = $before; error = "these files don't match GitHub: $names. Run 'git checkout -- .' in the extension folder to replace them with GitHub's version, then try again." }
    }
    foreach ($step in @(@("fetch", "origin", $Branch), @("merge", "--ff-only", "origin/$Branch"))) {
      $result = Invoke-Git $step
      if ($result.Code -ne 0) {
        return [ordered]@{ ok = $false; before = $before; error = (Get-Explanation $result.Output) }
      }
    }
  } catch {
    return [ordered]@{ ok = $false; before = $before; error = "couldn't run git ($($_.Exception.Message)). Is Git installed and on PATH?" }
  }
  return [ordered]@{ ok = $true; before = $before; after = (Get-Version) }
}

try {
  Write-Log "started: PowerShell $($PSVersionTable.PSVersion), repo $Repo"

  if ($args -contains "--check") {
    # What the installer runs: proves PowerShell starts and git can see this
    # folder, without changing anything.
    $ok = $false
    try {
      $result = Invoke-Git @("rev-parse", "--is-inside-work-tree")
      $ok = ($result.Code -eq 0 -and $result.Output -eq "true")
      $detail = if ($ok) { "git sees the extension folder" } else { Get-Explanation $result.Output }
    } catch {
      $detail = "couldn't run git ($($_.Exception.Message)). Is Git installed and on PATH?"
    }
    $label = if ($ok) { "OK" } else { "PROBLEM" }
    [Console]::Out.WriteLine("${label}: PowerShell $($PSVersionTable.PSVersion), $detail")
    exit $(if ($ok) { 0 } else { 1 })
  }

  if ($args -contains "--test") {
    $result = Invoke-Update
    Write-Log "test result: $($result | ConvertTo-Json -Compress)"
    [Console]::Out.WriteLine(($result | ConvertTo-Json))
    exit 0
  }

  $message = Read-Message
  Write-Log "received: $($message | ConvertTo-Json -Compress)"
  if ($null -eq $message) { exit 0 }
  if ($message.action -eq "update") {
    $result = Invoke-Update
  } else {
    $result = [ordered]@{ ok = $false; error = "Unknown action." }
  }
  Write-Log "result: $($result | ConvertTo-Json -Compress)"
  Send-Message $result
} catch {
  Write-Log "crashed: $($_ | Out-String)"
  exit 1
}

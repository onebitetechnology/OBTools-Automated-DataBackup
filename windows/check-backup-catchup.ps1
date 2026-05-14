param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,
  [Parameter(Mandatory = $true)]
  [string]$StatusPath,
  [Parameter(Mandatory = $true)]
  [string]$ScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-Json([string]$Path) {
  Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Get-NormalizedDayOfWeek($Schedule) {
  $validDays = @("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")
  if ($Schedule -and $null -ne $Schedule.PSObject.Properties["dayOfWeek"] -and $validDays -contains [string]$Schedule.dayOfWeek) {
    return [string]$Schedule.dayOfWeek
  }

  return "Monday"
}

function Get-MostRecentScheduledTime($Schedule) {
  $frequency = if ($Schedule -and $Schedule.frequency) { [string]$Schedule.frequency } else { "weekly" }
  $timeValue = if ($Schedule -and $Schedule.time) { [string]$Schedule.time } else { "18:30" }
  $time = [DateTime]::ParseExact($timeValue, "HH:mm", $null)
  $now = Get-Date

  if ($frequency -eq "daily") {
    $candidate = $now.Date.AddHours($time.Hour).AddMinutes($time.Minute)
    if ($candidate -gt $now) {
      $candidate = $candidate.AddDays(-1)
    }
    return $candidate
  }

  $targetDay = [System.Enum]::Parse([System.DayOfWeek], (Get-NormalizedDayOfWeek $Schedule))
  $daysSince = ([int]$now.DayOfWeek - [int]$targetDay + 7) % 7
  $candidate = $now.Date.AddDays(-$daysSince).AddHours($time.Hour).AddMinutes($time.Minute)
  if ($candidate -gt $now) {
    $candidate = $candidate.AddDays(-7)
  }

  return $candidate
}

function Test-BackupIsDue($Schedule, $Status) {
  if (-not $Schedule -or -not $Schedule.enabled) {
    return $false
  }

  $mostRecentScheduledTime = Get-MostRecentScheduledTime $Schedule
  if (-not $Status.lastBackupAt -or $Status.lastBackupResult -ne "success") {
    return $true
  }

  try {
    $lastBackup = [DateTime]::Parse([string]$Status.lastBackupAt)
  } catch {
    return $true
  }

  return $lastBackup -lt $mostRecentScheduledTime
}

$config = Read-Json $ConfigPath
$status = Read-Json $StatusPath
$schedule = if ($config.schedule) { $config.schedule } else { [PSCustomObject]@{
  enabled = $true
  frequency = "weekly"
  dayOfWeek = "Monday"
  time = "18:30"
} }

if (-not (Test-BackupIsDue $schedule $status)) {
  Write-Output "No missed DataSafe backup is due."
  exit 0
}

$backupScript = Join-Path $ScriptRoot "backup-engine.ps1"
Write-Output "A scheduled DataSafe backup was missed. Running catch-up backup now."
& powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $backupScript -ConfigPath $ConfigPath -StatusPath $StatusPath
exit $LASTEXITCODE

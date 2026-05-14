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

function Remove-TaskIfExists([string]$TaskName) {
  $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
  }
}

function Get-NormalizedDayOfWeek($Schedule) {
  $validDays = @("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")
  if ($Schedule -and $null -ne $Schedule.PSObject.Properties["dayOfWeek"] -and $validDays -contains [string]$Schedule.dayOfWeek) {
    return [string]$Schedule.dayOfWeek
  }

  return "Monday"
}

$config = Read-Json $ConfigPath
$schedule = if ($config.schedule) { $config.schedule } else { [PSCustomObject]@{
  enabled = $true
  frequency = "weekly"
  time = "18:30"
} }
$reminders = if ($config.reminders) { $config.reminders } else { [PSCustomObject]@{
  enabled = $true
  staleDays = 7
} }
$backupScript = Join-Path $ScriptRoot "backup-engine.ps1"
$reminderScript = Join-Path $ScriptRoot "check-reminders.ps1"
$catchUpScript = Join-Path $ScriptRoot "check-backup-catchup.ps1"
$time = [DateTime]::ParseExact($schedule.time, "HH:mm", $null)
$backupDay = Get-NormalizedDayOfWeek $schedule

$backupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$backupScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""
$reminderAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$reminderScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""
$catchUpAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$catchUpScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`" -ScriptRoot `"$ScriptRoot`""
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 12)

if ($schedule.frequency -eq "weekly") {
  $backupTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $backupDay -At $time
} else {
  $backupTrigger = New-ScheduledTaskTrigger -Daily -At $time
}

$reminderTrigger = New-ScheduledTaskTrigger -Daily -At 09:00
$catchUpTriggers = @(
  New-ScheduledTaskTrigger -AtStartup,
  New-ScheduledTaskTrigger -AtLogOn
)

$messages = New-Object System.Collections.Generic.List[string]

if ($schedule.enabled) {
  Register-ScheduledTask -TaskName "OneBiteBackupRun" -Action $backupAction -Trigger $backupTrigger -Settings $taskSettings -Force | Out-Null
  Register-ScheduledTask -TaskName "OneBiteBackupCatchUp" -Action $catchUpAction -Trigger $catchUpTriggers -Settings $taskSettings -Force | Out-Null
  $scheduleLabel = if ($schedule.frequency -eq "weekly") { "weekly on $backupDay" } else { "daily" }
  $messages.Add("Scheduled backup task installed or updated for $scheduleLabel at $($schedule.time).")
  $messages.Add("Missed-backup catch-up task installed or updated for startup and sign-in.")
} else {
  Remove-TaskIfExists "OneBiteBackupRun"
  Remove-TaskIfExists "OneBiteBackupCatchUp"
  $messages.Add("Scheduled backup task removed because automatic backups are disabled.")
  $messages.Add("Missed-backup catch-up task removed because automatic backups are disabled.")
}

if ($reminders.enabled) {
  Register-ScheduledTask -TaskName "OneBiteBackupReminder" -Action $reminderAction -Trigger $reminderTrigger -Settings $taskSettings -Force | Out-Null
  $messages.Add("Reminder notification task installed or updated.")
} else {
  Remove-TaskIfExists "OneBiteBackupReminder"
  $messages.Add("Reminder notification task removed because reminders are disabled.")
}

Write-Output ($messages -join " ")

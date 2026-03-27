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
$time = [DateTime]::ParseExact($schedule.time, "HH:mm", $null)

$backupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$backupScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""
$reminderAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$reminderScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""

if ($schedule.frequency -eq "weekly") {
  $backupTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At $time
} else {
  $backupTrigger = New-ScheduledTaskTrigger -Daily -At $time
}

$reminderTrigger = New-ScheduledTaskTrigger -Daily -At 09:00

$messages = New-Object System.Collections.Generic.List[string]

if ($schedule.enabled) {
  Register-ScheduledTask -TaskName "OneBiteBackupRun" -Action $backupAction -Trigger $backupTrigger -Force | Out-Null
  $messages.Add("Scheduled backup task installed or updated.")
} else {
  Remove-TaskIfExists "OneBiteBackupRun"
  $messages.Add("Scheduled backup task removed because automatic backups are disabled.")
}

if ($reminders.enabled) {
  Register-ScheduledTask -TaskName "OneBiteBackupReminder" -Action $reminderAction -Trigger $reminderTrigger -Force | Out-Null
  $messages.Add("Reminder notification task installed or updated.")
} else {
  Remove-TaskIfExists "OneBiteBackupReminder"
  $messages.Add("Reminder notification task removed because reminders are disabled.")
}

Write-Output ($messages -join " ")

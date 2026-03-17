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

$config = Read-Json $ConfigPath
$backupScript = Join-Path $ScriptRoot "backup-engine.ps1"
$reminderScript = Join-Path $ScriptRoot "check-reminders.ps1"
$time = [DateTime]::ParseExact($config.schedule.time, "HH:mm", $null)

$backupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$backupScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""
$reminderAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$reminderScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""

if ($config.schedule.frequency -eq "weekly") {
  $backupTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At $time
} else {
  $backupTrigger = New-ScheduledTaskTrigger -Daily -At $time
}

$reminderTrigger = New-ScheduledTaskTrigger -Daily -At 09:00

Register-ScheduledTask -TaskName "OneBiteBackupRun" -Action $backupAction -Trigger $backupTrigger -Force | Out-Null
Register-ScheduledTask -TaskName "OneBiteBackupReminder" -Action $reminderAction -Trigger $reminderTrigger -Force | Out-Null

Write-Output "Windows scheduled tasks installed or updated."

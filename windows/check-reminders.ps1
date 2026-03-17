param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,
  [Parameter(Mandatory = $true)]
  [string]$StatusPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-Json([string]$Path) {
  Get-Content -Raw -Path $Path | ConvertFrom-Json
}

$config = Read-Json $ConfigPath
$status = Read-Json $StatusPath

if (-not $config.reminders.enabled) {
  Write-Output "Reminders are disabled."
  exit 0
}

if (-not $status.lastBackupAt) {
  $shell = New-Object -ComObject WScript.Shell
  $shell.Popup("One Bite Technology Backup Companion has not completed its first backup yet.", 15, "Backup Reminder", 48) | Out-Null
  Write-Output "Reminder shown for missing first backup."
  exit 0
}

$last = [DateTime]::Parse($status.lastBackupAt)
$age = ((Get-Date) - $last).TotalDays
if ($age -ge [double]$config.reminders.staleDays) {
  $shell = New-Object -ComObject WScript.Shell
  $message = "Last backup was $([math]::Floor($age)) day(s) ago. Connect the backup drive and run Backup Companion."
  $shell.Popup($message, 20, "Backup Reminder", 48) | Out-Null
  Write-Output "Stale backup reminder shown."
  exit 0
}

Write-Output "Backup is within the reminder threshold."

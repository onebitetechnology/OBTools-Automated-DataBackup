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

$taskHelpersPath = Join-Path $ScriptRoot "DataSafe.ScheduledTasks.ps1"
. $taskHelpersPath

function Read-Json([string]$Path) {
  Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Remove-TaskIfExists([string]$TaskName) {
  $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
  }
}

function Get-FriendlyTaskError([string]$TaskName, $ErrorRecord) {
  $raw = if ($ErrorRecord -and $ErrorRecord.Exception -and $ErrorRecord.Exception.Message) { $ErrorRecord.Exception.Message } else { "$ErrorRecord" }
  if ($raw -match "Access is denied" -or $raw -match "PermissionDenied") {
    return "Windows would not allow DataSafe to update $TaskName for this user. Scheduled backups may still work, but if this message keeps appearing, contact One Bite Technology so we can reset the Windows task."
  }

  return "Windows could not update $TaskName. If this message keeps appearing, contact One Bite Technology. $raw"
}

function Register-TaskWithMessage(
  [string]$TaskName,
  $Action,
  $Trigger,
  $Settings,
  $Principal,
  [bool]$Required
) {
  try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null
    return $null
  } catch {
    $friendly = Get-FriendlyTaskError $TaskName $_
    if ($Required) {
      throw $friendly
    }

    return $friendly
  }
}

function Get-NormalizedDayOfWeek($Schedule) {
  $validDays = @("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")
  if ($Schedule -and $null -ne $Schedule.PSObject.Properties["dayOfWeek"] -and ($validDays -contains [string]$Schedule.dayOfWeek)) {
    return [string]$Schedule.dayOfWeek
  }

  return "Monday"
}

function Test-IsAdministrator {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
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
$integrityScript = Join-Path $ScriptRoot "verify-backup-integrity.ps1"
$cloudHealthScript = Join-Path $ScriptRoot "check-cloud-health.ps1"
$time = [DateTime]::ParseExact($schedule.time, "HH:mm", $null)
$backupDay = Get-NormalizedDayOfWeek $schedule

$backupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$backupScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""
$reminderAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$reminderScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""
$catchUpAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$catchUpScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`" -ScriptRoot `"$ScriptRoot`""
$integrityAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$integrityScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`""
$cloudHealthAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$cloudHealthScript`" -ConfigPath `"$ConfigPath`" -StatusPath `"$StatusPath`" -Notify"
$taskExecutionLimit = New-TimeSpan -Hours 12
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit $taskExecutionLimit
$taskUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited

if ($schedule.frequency -eq "weekly") {
  $backupTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $backupDay -At $time
} else {
  $backupTrigger = New-ScheduledTaskTrigger -Daily -At $time
}

$reminderTrigger = New-ScheduledTaskTrigger -Daily -At 09:00
$integrityTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 11:00
$cloudHealthTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 10:30
$catchUpLogonTrigger = New-DataSafeCatchUpLogonTrigger -TaskUser $taskUser
$includeStartupCatchUp = Test-IsAdministrator
$catchUpTriggers = @($catchUpLogonTrigger)
if ($includeStartupCatchUp) {
  $catchUpStartupTrigger = New-ScheduledTaskTrigger -AtStartup
  $catchUpTriggers = @($catchUpStartupTrigger, $catchUpLogonTrigger)
}

$messages = New-Object System.Collections.Generic.List[string]

if ($schedule.enabled) {
  Register-TaskWithMessage -TaskName "OneBiteBackupRun" -Action $backupAction -Trigger $backupTrigger -Settings $taskSettings -Principal $taskPrincipal -Required $true | Out-Null
  $catchUpWarning = Register-TaskWithMessage -TaskName "OneBiteBackupCatchUp" -Action $catchUpAction -Trigger $catchUpTriggers -Settings $taskSettings -Principal $taskPrincipal -Required $false
  $integrityWarning = Register-TaskWithMessage -TaskName "OneBiteBackupIntegrity" -Action $integrityAction -Trigger $integrityTrigger -Settings $taskSettings -Principal $taskPrincipal -Required $false
  $scheduleLabel = if ($schedule.frequency -eq "weekly") { "weekly on $backupDay" } else { "daily" }
  $messages.Add("Scheduled backup task installed or updated for $scheduleLabel at $($schedule.time).")
  if ($catchUpWarning) {
    $messages.Add($catchUpWarning)
  } else {
    if ($includeStartupCatchUp) {
      $messages.Add("Missed-backup catch-up task installed or updated for startup and sign-in.")
    } else {
      $messages.Add("Missed-backup catch-up task installed or updated for sign-in.")
    }
  }
  if ($integrityWarning) {
    $messages.Add($integrityWarning)
  } else {
    $messages.Add("Weekly checksum verification task installed or updated for Sunday at 11:00.")
  }
} else {
  Remove-TaskIfExists "OneBiteBackupRun"
  Remove-TaskIfExists "OneBiteBackupCatchUp"
  Remove-TaskIfExists "OneBiteBackupIntegrity"
  $messages.Add("Scheduled backup task removed because automatic backups are disabled.")
  $messages.Add("Missed-backup catch-up task removed because automatic backups are disabled.")
  $messages.Add("Weekly checksum verification task removed because automatic backups are disabled.")
}

if ($reminders.enabled) {
  $reminderWarning = Register-TaskWithMessage -TaskName "OneBiteBackupReminder" -Action $reminderAction -Trigger $reminderTrigger -Settings $taskSettings -Principal $taskPrincipal -Required $false
  if ($reminderWarning) {
    $messages.Add($reminderWarning)
  } else {
    $messages.Add("Reminder notification task installed or updated.")
  }
} else {
  Remove-TaskIfExists "OneBiteBackupReminder"
  $messages.Add("Reminder notification task removed because reminders are disabled.")
}

$cloudCheck = if ($config.cloudCheck) { $config.cloudCheck } else { [PSCustomObject]@{ enabled = $true } }
if ($cloudCheck.enabled) {
  $cloudWarning = Register-TaskWithMessage -TaskName "OneBiteBackupCloudHealth" -Action $cloudHealthAction -Trigger $cloudHealthTrigger -Settings $taskSettings -Principal $taskPrincipal -Required $false
  if ($cloudWarning) {
    $messages.Add($cloudWarning)
  } else {
    $messages.Add("Weekly OneDrive configuration review task installed or updated for Sunday at 10:30.")
  }
} else {
  Remove-TaskIfExists "OneBiteBackupCloudHealth"
  $messages.Add("Weekly OneDrive configuration review task removed because cloud checks are disabled.")
}

Write-Output ($messages -join " ")

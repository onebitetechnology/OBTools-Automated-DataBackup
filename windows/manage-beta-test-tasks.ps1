param(
  [Parameter(Mandatory=$true)][ValidateSet('Inspect','Pause')][string]$Action,
  [Parameter(Mandatory=$true)][string]$ConfigPath,
  [Parameter(Mandatory=$true)][string]$StatusPath,
  [Parameter(Mandatory=$true)][string]$ScriptRoot,
  [switch]$Confirmed
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DataSafe.Safety.ps1')

# These exact fingerprints match the legacy installer's five root tasks. No
# task is adopted by name alone, and no worker process is ever terminated.
$workers=[ordered]@{
  OneBiteBackupRun='backup-engine.ps1'; OneBiteBackupCatchUp='check-backup-catchup.ps1'
  OneBiteBackupReminder='check-reminders.ps1'; OneBiteBackupIntegrity='verify-backup-integrity.ps1'
  OneBiteBackupCloudHealth='check-cloud-health.ps1'
}
$warnings=New-Object 'System.Collections.Generic.List[string]'
$errorsByTask=@{}
foreach ($name in $workers.Keys) { $errorsByTask[$name]=[PSCustomObject]@{disableError=$null;removalError=$null} }

function Test-OwnedBetaTask($Task,[string]$Name) {
  try {
    if ([string]$Task.TaskPath -cne '\' -or [string]$Task.TaskName -ine $Name) { return $false }
    $principal=[string]$Task.Principal.UserId
    if ([string]::IsNullOrWhiteSpace($principal)) { return $false }
    $sid = if ($principal -match '^S-\d-') {
      (New-Object Security.Principal.SecurityIdentifier($principal)).Value
    } else {
      # Bare local, qualified and SID spellings are accepted only if Windows
      # resolves them to the exact current SID. Never compare name suffixes.
      (New-Object Security.Principal.NTAccount($principal)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    if ($sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { return $false }
    $actions=@($Task.Actions)
    if ($actions.Count -ne 1 -or [string]$actions[0].Execute -ine 'wscript.exe') { return $false }
    $expected='//B //NoLogo "{0}" "{1}" -ConfigPath "{2}" -StatusPath "{3}"' -f (Join-Path $ScriptRoot 'DataSafeTaskRunner.vbs'),(Join-Path $ScriptRoot $workers[$Name]),$ConfigPath,$StatusPath
    if ($Name -eq 'OneBiteBackupCatchUp') { $expected+=' -ScriptRoot "'+$ScriptRoot+'"' }
    if ($Name -eq 'OneBiteBackupCloudHealth') { $expected+=' -Notify' }
    return ([string]$actions[0].Arguments -ieq $expected)
  } catch { return $false }
}

function Read-BetaTaskState {
  $found=@(); $queryError=$null
  try {
    # Successful scoped enumeration can positively prove absence. A same-name task
    # outside the installer's root path is foreign, not evidence of absence.
    # A query/permission failure is never silently reinterpreted as absence.
    # Wildcard enumeration returns an empty successful result when no managed
    # names exist; unrelated protected Windows tasks need not be enumerated.
    $found=@(Get-ScheduledTask -TaskName 'OneBiteBackup*' -ErrorAction Stop)
  } catch { $queryError=$_.Exception.Message }
  foreach ($name in $workers.Keys) {
    $record=[PSCustomObject]@{
      name=$name; ownership='unknown'; state='unknown'; running=$null; enabled=$null; absent=$false
      queryError=$queryError; disableError=$errorsByTask[$name].disableError; removalError=$errorsByTask[$name].removalError
    }
    if ($null -eq $queryError) {
      $matches=@($found | Where-Object { [string]$_.TaskName -ieq $name })
      if ($matches.Count -eq 0) {
        $record.ownership='absent'; $record.state='absent'; $record.absent=$true; $record.running=$false; $record.enabled=$false
      } elseif ($matches.Count -eq 1) {
        $task=$matches[0]
        $record.ownership=if (Test-OwnedBetaTask $task $name) {'owned'} else {'foreign'}
        $record.state=[string](Get-DataSafeProperty $task 'State' 'unknown')
        $record.running=($record.state -in @('Running','Queued'))
        $record.enabled=Get-DataSafeProperty (Get-DataSafeProperty $task 'Settings') 'Enabled'
        if ($record.state -notin @('Running','Queued','Ready','Disabled') -or $record.enabled -isnot [bool]) {
          $record.queryError='Task state or enablement could not be determined.'
        }
      } else { $record.queryError='Multiple matching task names were returned.' }
    }
    $record
  }
}

$handle=$null; $lockPath=$StatusPath+'.lock'; $confirmedPaused=$false; $records=@()
try {
  if ($Action -eq 'Pause' -and $Confirmed) { $handle=Acquire-DataSafeOperationLock $lockPath }
  $records=@(Read-BetaTaskState)
  if ($Action -eq 'Pause' -and -not $Confirmed) {
    $warnings.Add('Confirm Use manual testing before pausing automation.')
  } elseif ($Action -eq 'Pause') {
    foreach ($record in $records) {
      if ($record.ownership -ne 'owned' -or $record.queryError) { continue }
      $current=@(Read-BetaTaskState | Where-Object {$_.name -eq $record.name})[0]
      if ($current.ownership -ne 'owned' -or $current.queryError) { continue }
      try { Disable-ScheduledTask -TaskName $record.name -TaskPath '\' -ErrorAction Stop | Out-Null }
      catch { $errorsByTask[$record.name].disableError=$_.Exception.Message }
    }
    # Recheck after disabling: a trigger may have fired during the transition,
    # or the task's ownership/action may have changed. Neither permits removal.
    $records=@(Read-BetaTaskState)
    $blocked=@($records | Where-Object {$_.queryError -or $_.running -or $_.ownership -in @('foreign','unknown') -or $_.disableError -or ($_.ownership -eq 'owned' -and $_.enabled)})
    if ($blocked.Count -eq 0) {
      foreach ($record in $records) {
        if ($record.ownership -ne 'owned') { continue }
        $fresh=@(Read-BetaTaskState)
        $unsafe=@($fresh | Where-Object {$_.queryError -or $_.running -or $_.ownership -in @('foreign','unknown') -or $_.disableError -or ($_.ownership -eq 'owned' -and $_.enabled)})
        if ($unsafe.Count -gt 0) { break }
        $current=@($fresh | Where-Object {$_.name -eq $record.name})[0]
        if ($current.absent) { continue }
        try { Unregister-ScheduledTask -TaskName $record.name -TaskPath '\' -Confirm:$false -ErrorAction Stop | Out-Null }
        catch { $errorsByTask[$record.name].removalError=$_.Exception.Message }
      }
      $records=@(Read-BetaTaskState)
      $confirmedPaused=(@($records | Where-Object {-not $_.absent -or $_.queryError -or $_.disableError -or $_.removalError}).Count -eq 0)
    }
    if (-not $confirmedPaused) { $warnings.Add('Automation pause is incomplete. Wait for running tasks to finish and resolve task ownership, access or removal errors before enrolling. No process was stopped.') }
  }
} catch {
  $warnings.Add($_.Exception.Message)
  if ($records.Count -eq 0) {
    foreach ($name in $workers.Keys) {
      $records+=@([PSCustomObject]@{name=$name;ownership='unknown';state='unknown';running=$null;enabled=$null;absent=$false;queryError=$_.Exception.Message;disableError=$null;removalError=$null})
    }
  }
} finally {
  if ($null -ne $handle) { Release-DataSafeOperationLock $handle $lockPath }
}
foreach ($record in $records) {
  if ($record.queryError) { $warnings.Add($record.name+': '+$record.queryError) }
  if ($record.ownership -eq 'foreign') { $warnings.Add($record.name+': current ownership is not verified; no further task changes are permitted.') }
}
$result=[ordered]@{confirmedPaused=$confirmedPaused;tasks=@($records);warnings=@($warnings.ToArray())}
Write-Output ('__OB_RESULT__:'+(ConvertTo-Json $result -Depth 8 -Compress))

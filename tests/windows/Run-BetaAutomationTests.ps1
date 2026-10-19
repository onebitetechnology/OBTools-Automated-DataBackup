param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'), [string]$Case = '')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$global:BetaAutomationpasses=0; $global:BetaAutomationfailures=New-Object 'System.Collections.Generic.List[string]'
function Assert-True($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Test-Case([string]$Name,[scriptblock]$Body) {
  if ($Case -and $Name -notmatch $Case) { return }
  try { Reset-Fakes; & $Body; $global:BetaAutomationpasses++; Write-Host "PASS: $Name" }
  catch { $global:BetaAutomationfailures.Add("$Name : $($_.Exception.Message)") }
}
$ownedRoot=Join-Path ([IO.Path]::GetTempPath()) ('datasafe-beta-tasks-'+[guid]::NewGuid().ToString('N'))
$bin=Join-Path $ownedRoot 'scripts with spaces'; $null=[IO.Directory]::CreateDirectory($bin)
Copy-Item -Path (Join-Path $WindowsRoot '*.ps1') -Destination $bin
$configPath=Join-Path $ownedRoot 'config with spaces.json'; $statusPath=Join-Path $ownedRoot 'status with spaces.json'
. (Join-Path $bin 'DataSafe.Safety.ps1')
$workers=[ordered]@{OneBiteBackupRun='backup-engine.ps1';OneBiteBackupCatchUp='check-backup-catchup.ps1';OneBiteBackupReminder='check-reminders.ps1';OneBiteBackupIntegrity='verify-backup-integrity.ps1';OneBiteBackupCloudHealth='check-cloud-health.ps1'}
$currentIdentity=[Security.Principal.WindowsIdentity]::GetCurrent()
function Reset-Fakes {
  $global:BetaAutomationtasks=@{}; $global:BetaAutomationmutations=New-Object 'System.Collections.Generic.List[string]'
  $global:BetaAutomationlaunches=New-Object 'System.Collections.Generic.List[string]'; $global:BetaAutomationregistered=@{}
  $global:BetaAutomationqueryDenied=$false; $global:BetaAutomationremoveDenied=''; $global:BetaAutomationdisableDenied=''; $global:BetaAutomationretainTask=''; $global:BetaAutomationqueryCount=0
  $global:BetaAutomationdeniedAfterRemoval=$false; $global:BetaAutomationrunningAfterDisable=''; $global:BetaAutomationreplaceAfterDisable=''
  $global:BetaAutomationreplaceDuringRemoval=$false; $global:BetaAutomationrequireLock=$false
  $global:BetaAutomationrequireScoped=$false
  $global:BetaAutomationreplaceDuringDisable=$false
  $global:BetaAutomationconfig=[PSCustomObject]@{
    destination=[PSCustomObject]@{backupFormatVersion=1;mode='letter';driveLetter='Z';baseFolder='Legacy'}
    schedule=[PSCustomObject]@{enabled=$true;frequency='weekly';dayOfWeek='Monday';time='18:30'}
    reminders=[PSCustomObject]@{enabled=$true;staleDays=7};cloudCheck=[PSCustomObject]@{enabled=$true}
  }
  Write-DataSafeJson $configPath $global:BetaAutomationconfig
  Write-DataSafeJson $statusPath ([PSCustomObject]@{lastBackupAt=$null;destinationStatus='unchanged';sentinel='unchanged'})
}
function Add-OwnedTasks([string]$Principal=$currentIdentity.Name) {
  foreach ($name in $workers.Keys) {
    $arguments='//B //NoLogo "{0}" "{1}" -ConfigPath "{2}" -StatusPath "{3}"' -f (Join-Path $bin 'DataSafeTaskRunner.vbs'),(Join-Path $bin $workers[$name]),$configPath,$statusPath
    if ($name -eq 'OneBiteBackupCatchUp') { $arguments+=' -ScriptRoot "'+$bin+'"' }
    if ($name -eq 'OneBiteBackupCloudHealth') { $arguments+=' -Notify' }
    $global:BetaAutomationtasks[$name]=[PSCustomObject]@{TaskName=$name;TaskPath='\';State='Ready';Settings=[PSCustomObject]@{Enabled=$true};Principal=[PSCustomObject]@{UserId=$Principal};Actions=@([PSCustomObject]@{Execute='wscript.exe';Arguments=$arguments})}
  }
}
# Every Task Scheduler and process-launch boundary is replaced in this process.
function Get-ScheduledTask {
  [CmdletBinding()]param([string]$TaskName='*',[string]$TaskPath='*')
  Assert-MutationLock
  if ($global:BetaAutomationrequireScoped -and $TaskName -ne 'OneBiteBackup*') { throw 'Unrelated protected task query denied' }
  $global:BetaAutomationqueryCount++
  if ($global:BetaAutomationqueryDenied -or ($global:BetaAutomationdeniedAfterRemoval -and $global:BetaAutomationmutations.Count -gt 5)) { throw 'fixture query access denied' }
  @($global:BetaAutomationtasks.Values | Where-Object {$_.TaskPath -like $TaskPath -and $_.TaskName -like $TaskName})
}
function Disable-ScheduledTask {
  [CmdletBinding()]param([string]$TaskName,[string]$TaskPath)
  Assert-MutationLock
  Assert-True ($TaskPath -ceq '\') 'Disable must target the exact installer task path.'
  $global:BetaAutomationmutations.Add('disable:'+ $TaskName)
  if ($TaskName -eq $global:BetaAutomationdisableDenied) { throw 'fixture disable denied' }
  $global:BetaAutomationtasks[$TaskName].Settings.Enabled=$false
  if ($TaskName -eq $global:BetaAutomationrunningAfterDisable) { $global:BetaAutomationtasks[$TaskName].State='Running' }
  if ($TaskName -eq $global:BetaAutomationreplaceAfterDisable) { $global:BetaAutomationtasks[$TaskName].Actions[0].Arguments+=' -foreign' }
  if ($global:BetaAutomationreplaceDuringDisable -and $TaskName -eq 'OneBiteBackupRun') { $global:BetaAutomationtasks.OneBiteBackupReminder.Actions[0].Arguments+=' -foreign' }
}
function Unregister-ScheduledTask {
  [CmdletBinding(SupportsShouldProcess)]param([string]$TaskName,[string]$TaskPath='\')
  Assert-MutationLock
  Assert-True ($TaskPath -ceq '\') 'Removal must target the exact installer task path.'
  $global:BetaAutomationmutations.Add('remove:'+ $TaskName)
  if ($TaskName -eq $global:BetaAutomationremoveDenied) { throw 'fixture remove denied' }
  if ($TaskName -ne $global:BetaAutomationretainTask) { $global:BetaAutomationtasks.Remove($TaskName) }
  if ($global:BetaAutomationreplaceDuringRemoval -and $TaskName -eq 'OneBiteBackupRun') { $global:BetaAutomationtasks.OneBiteBackupReminder.Actions[0].Arguments+=' -foreign' }
}
function Assert-MutationLock {
  if (-not $global:BetaAutomationrequireLock) {return}
  Assert-True ([IO.File]::Exists($statusPath+'.lock')) 'Task boundary called before creating status-operation lock.'
  $probe=$null
  try { $probe=[IO.File]::Open($statusPath+'.lock',[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
  catch { return }
  finally {if ($null -ne $probe) {$probe.Dispose()}}
  throw 'Task boundary called without holding the status-operation lock.'
}
function Register-ScheduledTask {
  [CmdletBinding()]param([string]$TaskName,$Action,$Trigger,$Settings,$Principal,[switch]$Force)
  $global:BetaAutomationmutations.Add('register:'+ $TaskName); $global:BetaAutomationregistered[$TaskName]=[PSCustomObject]@{Action=$Action;Settings=$Settings;Principal=$Principal;Trigger=$Trigger}
}
function New-ScheduledTaskAction { param($Execute,$Argument); [PSCustomObject]@{Execute=$Execute;Arguments=$Argument} }
function New-ScheduledTaskSettingsSet { param([switch]$Hidden,[switch]$StartWhenAvailable,[switch]$WakeToRun,$MultipleInstances,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$ExecutionTimeLimit); [PSCustomObject]@{Hidden=$Hidden.IsPresent} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); [PSCustomObject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
function New-ScheduledTaskTrigger { param([switch]$Weekly,[switch]$Daily,[switch]$AtStartup,[switch]$AtLogOn,$DaysOfWeek,$At,$User); [PSCustomObject]@{User=$User} }
function Start-ScheduledTask { throw 'Unexpected task start' }
function Stop-ScheduledTask { throw 'Unexpected task stop' }
function Set-ScheduledTask { throw 'Unexpected task change' }
function Get-ScheduledTaskInfo { throw 'Unexpected task info query' }
function Start-Process { $global:BetaAutomationlaunches.Add('Start-Process'); throw 'Unexpected process start' }
function powershell.exe { $global:BetaAutomationlaunches.Add('powershell.exe'); $global:LASTEXITCODE=0 }
function pwsh.exe { $global:BetaAutomationlaunches.Add('pwsh.exe'); throw 'Unexpected process start' }
function wscript.exe { $global:BetaAutomationlaunches.Add('wscript.exe'); throw 'Unexpected process start' }
function Get-Volume { throw 'Unexpected storage scan' }
function Invoke-Pause([string]$Action='Pause',[switch]$Confirmed) {
  $global:BetaAutomationrequireLock=($Action -eq 'Pause' -and $Confirmed)
  $output=@(& (Join-Path $bin 'manage-beta-test-tasks.ps1') -Action $Action -ConfigPath $configPath -StatusPath $statusPath -ScriptRoot $bin -Confirmed:$Confirmed)
  $markers=@($output | Where-Object {"$_" -like '__OB_RESULT__:*'})
  Assert-True ($markers.Count -eq 1) 'Expected one structured pause result.'
  return ($markers[0].Substring('__OB_RESULT__:'.Length) | ConvertFrom-Json)
}
try {
  Test-Case 'InspectNeverMutates' {
    Add-OwnedTasks; $before=[IO.File]::ReadAllText($statusPath); $r=Invoke-Pause Inspect
    Assert-True (-not $r.confirmedPaused -and $global:BetaAutomationmutations.Count -eq 0 -and $r.tasks.Count -eq 5) 'Inspect mutated tasks or claimed pause.'
    Assert-True ([IO.File]::ReadAllText($statusPath) -ceq $before -and -not [IO.File]::Exists($statusPath+'.lock')) 'Inspect touched status or acquired lock.'
  }
  Test-Case 'PauseRequiresConfirmation' {
    Add-OwnedTasks; $r=Invoke-Pause
    Assert-True (-not $r.confirmedPaused -and $global:BetaAutomationmutations.Count -eq 0) 'Unconfirmed pause changed tasks.'
  }
  Test-Case 'AllOwnedTasksAbsent' {
    Add-OwnedTasks; $r=Invoke-Pause -Confirmed
    Assert-True ($r.confirmedPaused -and $global:BetaAutomationtasks.Count -eq 0 -and $global:BetaAutomationmutations.Count -eq 10) 'Owned tasks were not disabled then removed.'
    Assert-True (@($r.tasks | Where-Object {-not $_.absent}).Count -eq 0) 'Result did not positively confirm absence.'
    Assert-True ($global:BetaAutomationqueryCount -ge 2) 'Pause did not requery tasks.'
    Assert-True (@($global:BetaAutomationmutations | Select-Object -First 5 | Where-Object {$_ -notlike 'disable:*'}).Count -eq 0) 'Removal started before all future triggers were disabled.'
  }
  Test-Case 'AlreadyAbsentNeedsSuccessfulQueryAndConfirmation' {
    $r=Invoke-Pause Inspect; Assert-True (-not $r.confirmedPaused) 'Inspect authorized enrollment.'
    $r=Invoke-Pause -Confirmed; Assert-True ($r.confirmedPaused -and $global:BetaAutomationmutations.Count -eq 0) 'Successfully observed absence was not confirmed.'
  }
  Test-Case 'QueryDeniedIsNotAbsent' {
    $global:BetaAutomationqueryDenied=$true; $r=Invoke-Pause -Confirmed
    Assert-True (-not $r.confirmedPaused -and @($r.tasks | Where-Object {$_.absent}).Count -eq 0 -and $global:BetaAutomationmutations.Count -eq 0) 'Denied query was mistaken for absence.'
    Assert-True (@($r.tasks | Where-Object {$_.queryError}).Count -eq 5) 'Query errors missing from task records.'
  }
  Test-Case 'ScopedQueriesIgnoreUnrelatedProtectedTasks' {
    Add-OwnedTasks; $global:BetaAutomationrequireScoped=$true; $r=Invoke-Pause -Confirmed
    Assert-True $r.confirmedPaused 'Unrelated protected OS tasks blocked managed-task absence confirmation.'
  }
  Test-Case 'DuplicateManagedNameBlocksEnrollment' {
    Add-OwnedTasks
    $global:BetaAutomationtasks.Duplicate=[PSCustomObject]@{TaskName='OneBiteBackupRun';TaskPath='\foreign\';State='Ready';Settings=[PSCustomObject]@{Enabled=$true};Principal=[PSCustomObject]@{UserId=$currentIdentity.Name};Actions=@()}
    $r=Invoke-Pause -Confirmed
    Assert-True (-not $r.confirmedPaused -and -not $global:BetaAutomationmutations.Contains('remove:OneBiteBackupRun') -and -not $global:BetaAutomationmutations.Contains('disable:OneBiteBackupRun')) 'Ambiguous managed name was adopted or modified.'
    Assert-True (@($r.tasks | Where-Object {$_.name -eq 'OneBiteBackupRun' -and $_.queryError}).Count -eq 1) 'Duplicate task ambiguity was hidden.'
  }
  Test-Case 'PrincipalOwnershipUsesExactResolvedSid' {
    foreach ($principal in @($currentIdentity.Name,$env:USERNAME,$currentIdentity.User.Value)) {
      Reset-Fakes; Add-OwnedTasks $principal; $r=Invoke-Pause -Confirmed
      Assert-True ($r.confirmedPaused -and $global:BetaAutomationtasks.Count -eq 0) "Legitimate resolved principal rejected: $principal"
    }
  }
  Test-Case 'ForeignTaskNeverRemoved' {
    foreach ($kind in @('principal','unresolvable','suffix','action','config','status','extra-action','path','host')) {
      Reset-Fakes; Add-OwnedTasks; $task=$global:BetaAutomationtasks.OneBiteBackupRun
      switch ($kind) {
        principal { $task.Principal.UserId='S-1-5-18' }
        unresolvable { $task.Principal.UserId='datasafe-unresolvable-'+[guid]::NewGuid().ToString('N') }
        suffix { $task.Principal.UserId='foreign-domain\'+$env:USERNAME }
        action { $task.Actions[0].Arguments+=' -foreign' }
        config { $task.Actions[0].Arguments=$task.Actions[0].Arguments.Replace($configPath,$configPath+'.foreign') }
        status { $task.Actions[0].Arguments=$task.Actions[0].Arguments.Replace($statusPath,$statusPath+'.foreign') }
        extra-action { $task.Actions+=@([PSCustomObject]@{Execute='cmd.exe';Arguments='/c noop'}) }
        path { $task.TaskPath='\foreign\' }
        host { $task.Actions[0].Execute='cmd.exe' }
      }
      $r=Invoke-Pause -Confirmed
      Assert-True (-not $r.confirmedPaused -and -not $global:BetaAutomationmutations.Contains('remove:OneBiteBackupRun') -and -not $global:BetaAutomationmutations.Contains('disable:OneBiteBackupRun')) "Foreign $kind task modified/accepted."
    }
  }
  Test-Case 'PartialRemovalBlocksEnrollment' {
    foreach ($mode in @('denied','retained','query-after-removal','disable-denied')) {
      Reset-Fakes; Add-OwnedTasks
      switch ($mode) { denied {$global:BetaAutomationremoveDenied='OneBiteBackupReminder'} retained {$global:BetaAutomationretainTask='OneBiteBackupReminder'} query-after-removal {$global:BetaAutomationdeniedAfterRemoval=$true} disable-denied {$global:BetaAutomationdisableDenied='OneBiteBackupReminder'} }
      $r=Invoke-Pause -Confirmed
      Assert-True (-not $r.confirmedPaused -and $r.warnings.Count -gt 0) "Partial $mode pause authorized enrollment."
      if ($mode -eq 'denied') { Assert-True (@($r.tasks | Where-Object {$_.removalError}).Count -gt 0) 'Removal error was discarded.' }
    }
  }
  Test-Case 'RunningTaskBlocksEnrollment' {
    foreach ($race in @($false,$true)) {
      Reset-Fakes; Add-OwnedTasks
      if ($race) {$global:BetaAutomationrunningAfterDisable='OneBiteBackupRun'} else {$global:BetaAutomationtasks.OneBiteBackupRun.State='Running'}
      $r=Invoke-Pause -Confirmed
      Assert-True (-not $r.confirmedPaused -and @($global:BetaAutomationmutations | Where-Object {$_ -like 'remove:*'}).Count -eq 0) 'Running task was removed or pause confirmed.'
      Assert-True (@($r.tasks | Where-Object {$_.running}).Count -gt 0) 'Running task state was hidden.'
    }
  }
  Test-Case 'OwnershipRecheckedAfterDisable' {
    Add-OwnedTasks; $global:BetaAutomationreplaceAfterDisable='OneBiteBackupRun'; $r=Invoke-Pause -Confirmed
    Assert-True (-not $r.confirmedPaused -and -not $global:BetaAutomationmutations.Contains('remove:OneBiteBackupRun')) 'Replacement foreign task removed.'
  }
  Test-Case 'OwnershipRecheckedBeforeEachDisable' {
    Add-OwnedTasks; $global:BetaAutomationreplaceDuringDisable=$true; $r=Invoke-Pause -Confirmed
    Assert-True (-not $r.confirmedPaused -and -not $global:BetaAutomationmutations.Contains('disable:OneBiteBackupReminder')) 'Task replaced during disable loop was modified.'
  }
  Test-Case 'OwnershipRecheckedBeforeEachRemoval' {
    Add-OwnedTasks; $global:BetaAutomationreplaceDuringRemoval=$true; $r=Invoke-Pause -Confirmed
    Assert-True (-not $r.confirmedPaused -and -not $global:BetaAutomationmutations.Contains('remove:OneBiteBackupReminder')) 'Task replaced during pause was removed.'
  }
  Test-Case 'UnknownTaskStateBlocksEnrollment' {
    Add-OwnedTasks; $global:BetaAutomationtasks.OneBiteBackupRun.State='Unknown'; $r=Invoke-Pause -Confirmed
    Assert-True (-not $r.confirmedPaused -and -not $global:BetaAutomationmutations.Contains('remove:OneBiteBackupRun')) 'Unknown runtime state was treated as stopped.'
  }
  Test-Case 'TransitionLockBusyBlocksPause' {
    Add-OwnedTasks; $handle=Acquire-DataSafeOperationLock ($statusPath+'.lock')
    try { $r=Invoke-Pause -Confirmed } finally {Release-DataSafeOperationLock $handle ($statusPath+'.lock')}
    Assert-True (-not $r.confirmedPaused -and $global:BetaAutomationmutations.Count -eq 0) 'Busy transition changed tasks.'
  }
  Test-Case 'EveryBackgroundEntryPointRefusesV2' {
    $global:BetaAutomationconfig.destination.backupFormatVersion=2; Write-DataSafeJson $configPath $global:BetaAutomationconfig
    foreach ($name in @('install-scheduled-backup.ps1','check-backup-catchup.ps1','check-reminders.ps1','verify-backup-integrity.ps1','check-cloud-health.ps1')) {
      $before=[IO.File]::ReadAllText($statusPath); $parameters=@{ConfigPath=$configPath;StatusPath=$statusPath}
      if ($name -in @('install-scheduled-backup.ps1','check-backup-catchup.ps1')) {$parameters.ScriptRoot=$bin}
      $output=@(& (Join-Path $bin $name) @parameters)
      Assert-True (@($output | Where-Object {"$_" -like '__OB_RESULT__:*'}).Count -eq 1) "$name lacks explicit skipped result."
      $r=($output | Where-Object {"$_" -like '__OB_RESULT__:*'}).Substring('__OB_RESULT__:'.Length) | ConvertFrom-Json
      Assert-True ($r.outcome -eq 'skipped' -and $r.backupFormatVersion -eq 2) "$name did not refuse v2."
      Assert-True ([IO.File]::ReadAllText($statusPath) -ceq $before -and $global:BetaAutomationlaunches.Count -eq 0 -and $global:BetaAutomationmutations.Count -eq 0) "$name changed status or launched work."
      # A missing status file also proves the guard precedes legacy status access.
      [IO.File]::Move($statusPath,$statusPath+'.saved')
      try {$null=& (Join-Path $bin $name) @parameters} finally {[IO.File]::Move($statusPath+'.saved',$statusPath)}
    }
  }
  Test-Case 'ExplicitPolicyAndRootCompatibility' {
    . (Join-Path $bin 'DataSafe.AppIntegration.ps1')
    Assert-True (-not (Test-DataSafeManualBetaConfig ([PSCustomObject]@{incrementalFormatVersion=2}))) 'Root flag enrolled app beta.'
    Assert-True (-not (Test-DataSafeManualBetaConfig ([PSCustomObject]@{incrementalFormatVersion=2;destination=[PSCustomObject]@{backupFormatVersion=1}}))) 'Root overrode explicit legacy.'
    foreach ($bad in @('{"destination":[]}', '{"destination":null}', '{"destination":{"backupFormatVersion":"2"}}')) {
      $threw=$false; try {$null=Test-DataSafeManualBetaConfig ($bad | ConvertFrom-Json)} catch {$threw=$true}
      Assert-True $threw 'Malformed policy was allowed to fall through to legacy.'
    }
  }
  Test-Case 'MalformedPolicyGuardsBeforeStatusAndTaskWrites' {
    foreach ($bad in @('{"destination":[]}', '{"destination":null}', '{"destination":{"backupFormatVersion":"2"}}', '{"destination":{"backupFormatVersion":3}}')) {
      [IO.File]::WriteAllText($configPath,$bad)
      foreach ($name in @('install-scheduled-backup.ps1','check-backup-catchup.ps1','check-reminders.ps1','verify-backup-integrity.ps1','check-cloud-health.ps1')) {
        $before=[IO.File]::ReadAllText($statusPath); $parameters=@{ConfigPath=$configPath;StatusPath=$statusPath}
        if ($name -in @('install-scheduled-backup.ps1','check-backup-catchup.ps1')) {$parameters.ScriptRoot=$bin}
        $threw=$false; try {$null=& (Join-Path $bin $name) @parameters} catch {$threw=$true}
        Assert-True ($threw -and [IO.File]::ReadAllText($statusPath) -ceq $before -and $global:BetaAutomationmutations.Count -eq 0 -and $global:BetaAutomationlaunches.Count -eq 0) "$name accepted malformed policy or performed work."
      }
    }
  }
  Test-Case 'LegacyActionsUnchanged' {
    & (Join-Path $bin 'install-scheduled-backup.ps1') -ConfigPath $configPath -StatusPath $statusPath -ScriptRoot $bin | Out-Null
    Assert-True ($global:BetaAutomationregistered.Count -eq 5) 'Legacy automation registration changed.'
    Add-OwnedTasks
    foreach ($name in $workers.Keys) {
      Assert-True ($global:BetaAutomationregistered[$name].Action.Execute -eq 'wscript.exe' -and $global:BetaAutomationregistered[$name].Action.Arguments -ceq $global:BetaAutomationtasks[$name].Actions[0].Arguments -and $global:BetaAutomationregistered[$name].Settings.Hidden) 'Legacy launcher arguments or hidden enablement changed.'
    }
    $global:BetaAutomationconfig.schedule.enabled=$false; $global:BetaAutomationconfig.reminders.enabled=$false; $global:BetaAutomationconfig.cloudCheck.enabled=$false; Write-DataSafeJson $configPath $global:BetaAutomationconfig
    $global:BetaAutomationmutations.Clear(); & (Join-Path $bin 'install-scheduled-backup.ps1') -ConfigPath $configPath -StatusPath $statusPath -ScriptRoot $bin | Out-Null
    Assert-True ($global:BetaAutomationtasks.Count -eq 0 -and @($global:BetaAutomationmutations | Where-Object {$_ -like 'register:*'}).Count -eq 0) 'Legacy disabled choices did not remove tasks.'
  }
  Test-Case 'LegacyCatchupStillLaunches' {
    & (Join-Path $bin 'check-backup-catchup.ps1') -ConfigPath $configPath -StatusPath $statusPath -ScriptRoot $bin | Out-Null
    Assert-True ($global:BetaAutomationlaunches.Count -eq 1) 'Legacy missed-backup launch changed.'
  }
} finally {
  $absolute=[IO.Path]::GetFullPath($ownedRoot)
  if ([IO.Path]::GetDirectoryName($absolute).TrimEnd('\') -ine [IO.Path]::GetTempPath().TrimEnd('\') -or [IO.Path]::GetFileName($absolute) -cnotmatch '^datasafe-beta-tasks-[0-9a-f]{32}$') { throw 'Unsafe cleanup target' }
  Assert-DataSafeNoReparsePath $absolute; Remove-DataSafeDirectoryTree $absolute
}
foreach ($failure in $global:BetaAutomationfailures) {Write-Host "FAIL: $failure"}
Write-Host "$global:BetaAutomationpasses passed; $($global:BetaAutomationfailures.Count) failed."
if ($global:BetaAutomationfailures.Count) {exit 1}

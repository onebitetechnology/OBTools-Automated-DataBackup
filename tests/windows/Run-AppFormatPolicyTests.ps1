param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'), [string]$CasePattern = '.')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $WindowsRoot 'DataSafe.Transaction.ps1')
$ownedRoot = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-app-format-' + [guid]::NewGuid().ToString('N'))
Ensure-DataSafeDirectory $ownedRoot
$passes=0; $failures=New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock]$Action) { $thrown=$false; try { & $Action } catch { $thrown=$true }; Assert-True $thrown 'Expected policy refusal.' }
function Test-Case([string]$Name,[scriptblock]$Action) {
  if ($Name -notmatch $CasePattern) { return }
  try { & $Action; $script:passes++; Write-Host "PASS: $Name" }
  catch { $script:failures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL: $Name : $($_.Exception.Message)" }
}
function Write-File([string]$Path,[string]$Text) { Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Path)); [IO.File]::WriteAllText($Path,$Text) }
function New-Fixture {
  $root=Join-Path $ownedRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $root
  $drive=Join-Path $root drive; Ensure-DataSafeDirectory $drive
  $source=Join-Path $root source
  foreach ($name in @('a','b','c','d')) { Write-File (Join-Path $source "$name.txt") "original-$name" }
  $config=[PSCustomObject]@{ computerName='App Format Test'; installId=[guid]::NewGuid().ToString('D')
    destination=[PSCustomObject]@{ id=[guid]::NewGuid().ToString('D');mode='letter';driveLetter='unused';baseFolder='Legacy';backupFormatVersion=2;volumeUniqueId='fixture-volume';manualBetaConfirmedAt='2026-10-19T01:02:03.000Z' }
    jobs=@([PSCustomObject]@{id='docs';name='Docs';type='folder';path=$source;enabled=$true;relativeDestination=@('Docs')}) }
  $bin=Join-Path $root windows; Ensure-DataSafeDirectory $bin
  foreach ($name in @('backup-engine.ps1','DataSafe.Repository.ps1','DataSafe.Manifest.ps1','DataSafe.IncrementalPlan.ps1','DataSafe.Transaction.ps1','DataSafe.AppIntegration.ps1')) {
    [IO.File]::Copy((Join-Path $WindowsRoot $name),(Join-Path $bin $name))
  }
  Write-File (Join-Path $bin 'DataSafe.Safety.ps1') ([IO.File]::ReadAllText((Join-Path $WindowsRoot 'DataSafe.Safety.ps1'))+"`nfunction Resolve-DataSafeDestination(`$Destination) { return '$($drive.Replace("'","''"))' }`n")
  # Only the copied fixture replaces the external volume resolver; production
  # has no injection parameter, environment override or bypass.
  $app=Join-Path $bin 'DataSafe.AppIntegration.ps1'
  Write-File $app ([IO.File]::ReadAllText($app)+"`nfunction Get-DataSafeAppVolumeUniqueId([string]`$ResolvedPath) { return 'fixture-volume' }`n")
  $f=[PSCustomObject]@{Root=$root;Drive=$drive;Source=$source;Bin=$bin;Config=$config;ConfigPath=(Join-Path $root config.json);StatusPath=(Join-Path $root status.json);OperationId=[guid]::NewGuid().ToString('D')}
  Write-DataSafeJson $f.StatusPath ([PSCustomObject]@{lastBackupAt='2026-01-01T00:00:00Z';lastBackupResult='success';lastBackupMessage='previous committed';destinationStatus='Connected';recentSnapshots=@()})
  return $f
}
function Invoke-Worker($Fixture,[int]$ExpectedExit=0,[string]$Extra='manual',[switch]$Legacy) {
  Write-DataSafeJson $Fixture.ConfigPath $Fixture.Config
  $out=Join-Path $Fixture.Root out.txt; $err=Join-Path $Fixture.Root err.txt
  $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -StatusPath "{2}"' -f (Join-Path $Fixture.Bin 'backup-engine.ps1'),$Fixture.ConfigPath,$Fixture.StatusPath
  if ($Extra -eq 'manual') { $args+=' -ManualBetaRun -AppOperationId '+$Fixture.OperationId } else { $args+=' '+$Extra }
  $p=Start-Process (Get-Process -Id $PID).Path -WindowStyle Hidden -ArgumentList $args -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  Assert-True ($p.ExitCode -eq $ExpectedExit) "Worker exit $($p.ExitCode), expected $ExpectedExit : $([IO.File]::ReadAllText($err))"
  $lines=@([IO.File]::ReadAllLines($out)); $results=@($lines | Where-Object { $_.StartsWith('__OB_RESULT__:') })
  if ($Legacy) {
    Assert-True ($results.Count -eq 0) 'Ordinary legacy call unexpectedly entered v2 app protocol.'
    return Read-DataSafeJson $Fixture.StatusPath
  }
  Assert-True ($results.Count -eq 1) 'Expected one fresh app result marker.'
  $r=$results[0].Substring(14) | ConvertFrom-Json
  Assert-True ($r.schema -ceq 'datasafe.app-backup-result' -and $r.formatVersion -eq 1 -and $r.backupFormatVersion -eq 2) 'Incorrect result schema.'
  $expectedDestinationId=$null
  $rawDestination=$Fixture.Config.PSObject.Properties['destination'].Value
  if ($rawDestination -is [PSCustomObject] -and $null -ne $rawDestination.PSObject.Properties['id'] -and $rawDestination.id -is [string]) { $expectedDestinationId=$rawDestination.id }
  Assert-True ($r.destinationId -ceq $expectedDestinationId) 'Uncorrelated or malformed destination identity.'
  if ($Extra -eq 'manual') { Assert-True ($r.operationId -ceq $Fixture.OperationId) 'Uncorrelated operation.' }
  return $r
}
function Get-ByteTree([string]$Path) {
  return (@(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
    $relative=$_.FullName.Substring($Path.Length)
    if ($_.PSIsContainer) { 'D '+$relative } else { 'F '+$relative+' '+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
  }) -join "`n")
}
function Invoke-RawConfigWorker($Fixture,[string]$Extra='') {
  $out=Join-Path $Fixture.Root raw-out.txt; $err=Join-Path $Fixture.Root raw-err.txt
  $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -StatusPath "{2}" {3}' -f (Join-Path $Fixture.Bin 'backup-engine.ps1'),$Fixture.ConfigPath,$Fixture.StatusPath,$Extra
  $p=Start-Process (Get-Process -Id $PID).Path -WindowStyle Hidden -ArgumentList $args -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  return [PSCustomObject]@{ExitCode=$p.ExitCode;Output=[IO.File]::ReadAllText($out);Error=[IO.File]::ReadAllText($err)}
}
try {
  Test-Case 'OrdinaryUnreadableConfigHonorsHeldStatusLease' {
    foreach ($kind in @('missing','malformed')) {
      $f=New-Fixture
      if ($kind -eq 'malformed') { Write-File $f.ConfigPath '{not-json' }
      $before=[IO.File]::ReadAllText($f.StatusPath); $beforeTree=Get-ByteTree $f.Drive
      $handle=Acquire-DataSafeOperationLock ($f.StatusPath+'.lock')
      try { $r=Invoke-RawConfigWorker $f }
      finally { Release-DataSafeOperationLock $handle ($f.StatusPath+'.lock') }
      Assert-True ($r.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($r.Error) -and $r.Output -match 'already running') "Ordinary $kind config failure bypassed existing busy behavior: exit=$($r.ExitCode), $($r.Error)"
      Assert-True ([IO.File]::ReadAllText($f.StatusPath) -ceq $before) "Ordinary $kind config failure rewrote status owned by another operation."
      Assert-True ((Get-ByteTree $f.Drive) -ceq $beforeTree -and -not [IO.File]::Exists((Join-Path $f.Root 'incremental-computer-id.json'))) 'Preflight failure wrote backup metadata.'
    }
  }
  Test-Case 'OrdinaryUnreadableConfigAcquiresLeaseBeforeFailureReport' {
    foreach ($kind in @('missing','malformed')) {
      $f=New-Fixture
      if ($kind -eq 'malformed') { Write-File $f.ConfigPath '{not-json' }
      $safety=Join-Path $f.Bin 'DataSafe.Safety.ps1'; $acquired=Join-Path $f.Root 'lease-acquired.txt'
      $observer=@'
$script:originalFixtureAcquire=${function:Acquire-DataSafeOperationLock}
function Acquire-DataSafeOperationLock([string]$LockPath) {
  $handle=& $script:originalFixtureAcquire $LockPath
  [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($LockPath)) 'lease-acquired.txt'),'acquired')
  return $handle
}
'@
      Write-File $safety ([IO.File]::ReadAllText($safety)+"`n"+$observer)
      $r=Invoke-RawConfigWorker $f
      Assert-True ($r.ExitCode -eq 1 -and [IO.File]::Exists($acquired)) "Ordinary $kind config failure did not arbitrate the status lease."
      Assert-True ((Read-DataSafeJson $f.StatusPath).lastBackupResult -ceq 'error') 'Unlocked failure was not reported after safely acquiring lease.'
      Assert-True (-not [IO.File]::Exists(($f.StatusPath+'.lock')) -and (Get-ByteTree $f.Drive) -ceq '') 'Failure leaked status lease or wrote backup data.'
    }
  }
  Test-Case 'AppUnreadableConfigStillBlocksBeforeStatusLease' {
    foreach ($kind in @('missing','malformed')) {
      foreach ($held in @($true,$false)) {
        $f=New-Fixture
        if ($kind -eq 'malformed') { Write-File $f.ConfigPath '{not-json' }
        $before=[IO.File]::ReadAllText($f.StatusPath); $handle=$null
        if ($held) { $handle=Acquire-DataSafeOperationLock ($f.StatusPath+'.lock') }
        try { $r=Invoke-RawConfigWorker $f ('-ManualBetaRun -AppOperationId '+$f.OperationId) }
        finally { if ($null -ne $handle) { Release-DataSafeOperationLock $handle ($f.StatusPath+'.lock') } }
        $markers=@($r.Output -split '\r?\n' | Where-Object {$_.StartsWith('__OB_RESULT__:')})
        Assert-True ($r.ExitCode -eq 1 -and $markers.Count -eq 1) 'Unreadable app config did not return blocked protocol result.'
        $result=$markers[0].Substring('__OB_RESULT__:'.Length) | ConvertFrom-Json
        Assert-True ($result.outcome -ceq 'blocked' -and $result.operationId -ceq $f.OperationId -and [IO.File]::ReadAllText($f.StatusPath) -ceq $before) 'App preflight failure acquired busy status or rewrote prior status.'
        Assert-True (-not [IO.File]::Exists(($f.StatusPath+'.lock')) -and (Get-ByteTree $f.Drive) -ceq '') 'App preflight acquired status lease or wrote backup content.'
      }
    }
  }
  Test-Case 'FormatDefaultsPrecedenceAndStrictTypes' {
    . (Join-Path $WindowsRoot 'DataSafe.AppIntegration.ps1')
    Assert-True ((Get-DataSafeBackupFormat ([PSCustomObject]@{destination=[PSCustomObject]@{}})) -eq 1) 'Absent format not legacy.'
    Assert-True ((Get-DataSafeBackupFormat ([PSCustomObject]@{incrementalFormatVersion=2;destination=[PSCustomObject]@{backupFormatVersion=1}})) -eq 1) 'Explicit legacy lost precedence.'
    Assert-True ((Get-DataSafeBackupFormat ([PSCustomObject]@{incrementalFormatVersion=2;destination=[PSCustomObject]@{}})) -eq 2) 'Internal flag not preserved.'
    foreach ($value in @('2',0,3,$null,$true,@(2),[PSCustomObject]@{})) {
      Assert-Throws { Get-DataSafeBackupFormat ([PSCustomObject]@{destination=[PSCustomObject]@{backupFormatVersion=$value}}) }
      Assert-Throws { Get-DataSafeBackupFormat ([PSCustomObject]@{incrementalFormatVersion=$value;destination=[PSCustomObject]@{}}) }
    }
  }
  Test-Case 'WrongVolumeBeforeWrites' {
    $f=New-Fixture; Write-File (Join-Path $f.Drive 'untouched.txt') 'untouched'
    $before=Get-ByteTree $f.Drive; $f.Config.destination.volumeUniqueId='another-volume'
    $r=Invoke-Worker $f 1
    Assert-True ($r.outcome -ceq 'blocked' -and $null -eq $r.transactionId -and $null -eq $r.committedAt) 'Wrong-volume outcome not safely blocked.'
    Assert-True ((Get-ByteTree $f.Drive) -ceq $before) 'Wrong volume wrote destination bytes.'
    Assert-True (-not [IO.File]::Exists((Join-Path $f.Root 'incremental-computer-id.json'))) 'Wrong volume created identity.'
  }
  Test-Case 'MalformedDestinationContainersRejectedWithFallbackParity' {
    . (Join-Path $WindowsRoot 'DataSafe.AppIntegration.ps1')
    foreach ($json in @('{"destination":[]}', '{"destination":[{}]}', '{"destination":[{"backupFormatVersion":2}]}',
        '{"destination":null}', '{"destination":"F:"}', '{"destination":2}', '{"destination":true}')) {
      $config=$json | ConvertFrom-Json
      Assert-Throws { Get-DataSafeBackupFormat $config }
      $config | Add-Member incrementalFormatVersion 2
      Assert-Throws { Get-DataSafeBackupFormat $config }
      Assert-Throws { Assert-DataSafeAppDestination $config 'fixture-volume' $true }
    }
    Assert-True ((Get-DataSafeBackupFormat ([PSCustomObject]@{})) -eq 1) 'Absent destination did not retain legacy fallback.'
    Assert-True ((Get-DataSafeBackupFormat ([PSCustomObject]@{incrementalFormatVersion=2})) -eq 2) 'Absent destination hid root fallback.'
  }
  Test-Case 'MalformedDestinationContainerBeforeWrites' {
    $f=New-Fixture; $f.Config.destination=@($f.Config.destination)
    $before=[IO.File]::ReadAllText($f.StatusPath); $r=Invoke-Worker $f 1
    Assert-True ($r.outcome -ceq 'blocked' -and $null -eq $r.destinationId) 'Malformed container was treated as enrolled destination.'
    Assert-True ([IO.File]::ReadAllText($f.StatusPath) -ceq $before) 'Malformed destination overwrote committed status.'
    Assert-True ((Get-ByteTree $f.Drive) -ceq '') 'Malformed destination wrote backup content.'
  }
  Test-Case 'LegacyFormatRejectsV2AppRequestBeforeLockOrWrites' {
    foreach ($format in @('absent','explicit-legacy')) {
      foreach ($held in @($true,$false)) {
        $f=New-Fixture
        if ($format -eq 'absent') { $f.Config.destination.PSObject.Properties.Remove('backupFormatVersion') }
        else { $f.Config.destination.backupFormatVersion=1; $f.Config | Add-Member incrementalFormatVersion 2 }
        $before=[IO.File]::ReadAllText($f.StatusPath); $beforeTree=Get-ByteTree $f.Drive
        $handle=$null
        if ($held) { $handle=Acquire-DataSafeOperationLock ($f.StatusPath+'.lock') }
        try { $r=Invoke-Worker $f 1 ('-ManualBetaRun -AppOperationId '+$f.OperationId+' -AllowNewDestination') }
        finally { if ($null -ne $handle) { Release-DataSafeOperationLock $handle ($f.StatusPath+'.lock') } }
        Assert-True ($r.outcome -ceq 'blocked' -and $r.operationId -ceq $f.OperationId -and $null -eq $r.transactionId -and $null -eq $r.committedAt) 'Legacy app request entered success/busy/failure execution.'
        Assert-True ([IO.File]::ReadAllText($f.StatusPath) -ceq $before) 'V2 app request changed prior legacy status.'
        Assert-True ((Get-ByteTree $f.Drive) -ceq $beforeTree) 'V2 app request created legacy snapshot/destination metadata.'
        Assert-True (-not [IO.File]::Exists((Join-Path $f.Root 'incremental-computer-id.json'))) 'V2 app request created identity on legacy selection.'
        if (-not $held) { Assert-True (-not [IO.File]::Exists(($f.StatusPath+'.lock'))) 'Rejected protocol request acquired status lock.' }
      }
    }
  }
  Test-Case 'OrdinaryLegacyCallsStillCommitWithoutAppProtocol' {
    foreach ($format in @('absent','explicit-legacy')) {
      $f=New-Fixture
      if ($format -eq 'absent') { $f.Config.destination.PSObject.Properties.Remove('backupFormatVersion') }
      else { $f.Config.destination.backupFormatVersion=1; $f.Config | Add-Member incrementalFormatVersion 2 }
      $s=Invoke-Worker $f 0 '-AllowNewDestination' -Legacy
      Assert-True ($s.lastBackupResult -ceq 'success') 'Ordinary legacy worker was blocked.'
      $snapshots=@(Get-DataSafeCompletedSnapshots (Join-Path $f.Drive 'Legacy/snapshots'))
      Assert-True ($snapshots.Count -eq 1) 'Ordinary legacy invocation lost its completed snapshot.'
      Assert-True ([IO.File]::ReadAllText((Join-Path $snapshots[0].FullName 'Docs/a.txt')) -ceq 'original-a') 'Ordinary legacy content changed.'
      Assert-True (-not [IO.Directory]::Exists((Join-Path $f.Drive 'DataSafe Backups'))) 'Ordinary legacy invocation created v2 repository.'
    }
  }
  Test-Case 'EitherV2AppSwitchRejectsLegacyBeforeUuidOrLockHandling' {
    foreach ($request in @('operation-only','manual-only')) {
      $f=New-Fixture; $f.Config.destination.backupFormatVersion=1
      $before=[IO.File]::ReadAllText($f.StatusPath)
      $extra=if ($request -eq 'operation-only') { '-AppOperationId '+$f.OperationId } else { '-ManualBetaRun' }
      $r=Invoke-Worker $f 1 $extra
      Assert-True ($r.outcome -ceq 'blocked' -and $r.message -match 'effective backup format 2') 'Single v2 switch did not enforce format before execution.'
      if ($request -eq 'operation-only') { Assert-True ($r.operationId -ceq $f.OperationId) 'Single-switch request lost available operation correlation.' }
      else { Assert-True ($null -eq $r.operationId) 'Missing operation UUID was manufactured.' }
      Assert-True ([IO.File]::ReadAllText($f.StatusPath) -ceq $before -and (Get-ByteTree $f.Drive) -ceq '') 'Single v2 switch wrote legacy state.'
      Assert-True (-not [IO.File]::Exists(($f.StatusPath+'.lock'))) 'Single-switch rejection acquired status lock.'
    }
  }
  Test-Case 'ExplicitV2RequiresManualConfirmation' {
    foreach ($mode in @('confirmation','switch','operation','invalid-operation','binding','invalid-date','binding-array','confirmation-array','id-array')) {
      $f=New-Fixture; $extra='manual'
      if ($mode -eq 'confirmation') { $f.Config.destination.PSObject.Properties.Remove('manualBetaConfirmedAt') }
      if ($mode -eq 'switch') { $extra='-AppOperationId '+$f.OperationId }
      if ($mode -eq 'operation') { $extra='-ManualBetaRun' }
      if ($mode -eq 'invalid-operation') { $extra='-ManualBetaRun -AppOperationId invalid' }
      if ($mode -eq 'binding') { $f.Config.destination.volumeUniqueId='' }
      if ($mode -eq 'invalid-date') { $f.Config.destination.manualBetaConfirmedAt='2026-02-30T00:00:00Z' }
      if ($mode -eq 'binding-array') { $f.Config.destination.volumeUniqueId=@('fixture-volume') }
      if ($mode -eq 'confirmation-array') { $f.Config.destination.manualBetaConfirmedAt=@('2026-10-19T01:02:03.000Z') }
      if ($mode -eq 'id-array') { $f.Config.destination.id=@($f.Config.destination.id) }
      $before=[IO.File]::ReadAllText($f.StatusPath); $r=Invoke-Worker $f 1 $extra
      Assert-True ($r.outcome -ceq 'blocked') "Missing $mode not blocked."
      Assert-True ([IO.File]::ReadAllText($f.StatusPath) -ceq $before) 'Nonmanual/invalid enrollment overwrote committed status.'
      Assert-True ((Get-ByteTree $f.Drive) -ceq '') 'Invalid enrollment created repository.'
    }
  }
  Test-Case 'VolumeRecheckedImmediatelyBeforeMetadataWrites' {
    $f=New-Fixture; $library=Join-Path $f.Bin 'DataSafe.AppIntegration.ps1'
    $resolver=@'
$script:fixtureVolumeReads=0
function Get-DataSafeAppVolumeUniqueId([string]$ResolvedPath) {
  $script:fixtureVolumeReads++
  if ($script:fixtureVolumeReads -eq 1) { return 'fixture-volume' }
  return 'replacement-volume'
}
'@
    Write-File $library ([IO.File]::ReadAllText($library)+"`n"+$resolver)
    $before=Get-ByteTree $f.Drive; $r=Invoke-Worker $f 1
    Assert-True ($r.outcome -notin @('committed','committed-with-warning') -and $r.message -match 'volume identity') 'Reused drive letter was not rechecked.'
    Assert-True ((Get-ByteTree $f.Drive) -ceq $before) 'Second volume check allowed destination writes.'
    Assert-True (-not [IO.File]::Exists((Join-Path $f.Root 'incremental-computer-id.json'))) 'Second volume check allowed local identity creation.'
  }
  Test-Case 'InternalFlagCompatibility' {
    $f=New-Fixture; $f.Config.destination.PSObject.Properties.Remove('backupFormatVersion'); $f.Config.destination.PSObject.Properties.Remove('volumeUniqueId'); $f.Config.destination.PSObject.Properties.Remove('manualBetaConfirmedAt'); $f.Config | Add-Member incrementalFormatVersion 2
    $r=Invoke-Worker $f
    Assert-True ($r.outcome -ceq 'committed') 'Root compatibility did not commit.'
  }
  Test-Case 'BusyIsFreshNonSuccess' {
    $f=New-Fixture; $handle=Acquire-DataSafeOperationLock ($f.StatusPath+'.lock')
    try { $before=[IO.File]::ReadAllText($f.StatusPath); $r=Invoke-Worker $f }
    finally { Release-DataSafeOperationLock $handle ($f.StatusPath+'.lock') }
    Assert-True ($r.outcome -ceq 'busy' -and $null -eq $r.transactionId -and $null -eq $r.committedAt) 'Busy imported prior success.'
    Assert-True ([IO.File]::ReadAllText($f.StatusPath) -ceq $before) 'Busy overwrote committed status.'
  }
  Test-Case 'InvalidFormatAndMergedPublicBeforeRepository' {
    foreach ($kind in @('format','public')) {
      $f=New-Fixture
      if ($kind -eq 'format') { $f.Config.destination.backupFormatVersion='2' } else { $f.Config.jobs[0] | Add-Member includePublicFolder Desktop }
      $r=Invoke-Worker $f 1
      $want=if ($kind -eq 'format') { 'blocked' } else { 'failed' }
      Assert-True ($r.outcome -ceq $want -and $null -eq $r.committedAt) 'Invalid plan claimed success.'
      Assert-True ((Get-ByteTree $f.Drive) -ceq '') 'Invalid plan created repository.'
    }
  }
  Test-Case 'CommittedUnchangedAndFailedAreCorrelated' {
    $f=New-Fixture; $r=Invoke-Worker $f
    Assert-True ($r.outcome -ceq 'committed' -and $r.copyBytes -eq 40 -and $r.scanCounts.files -eq 4 -and $null -ne $r.transactionId) 'First app backup did not report real counts.'
    $paths=@(Get-ChildItem -LiteralPath (Join-Path $f.Drive 'DataSafe Backups') -Recurse -Filter a.txt)
    Assert-True ($paths.Count -eq 1 -and [IO.File]::ReadAllText($paths[0].FullName) -ceq 'original-a') 'Latest bytes missing.'
    $progress=@([IO.File]::ReadAllLines((Join-Path $f.Root out.txt)) | Where-Object { $_.StartsWith('__OB_PROGRESS__:') })
    Assert-True ($progress.Count -gt 0) 'App worker emitted no progress.'
    foreach ($line in $progress) {
      $p=$line.Substring(16) | ConvertFrom-Json
      Assert-True ($p.operationId -ceq $f.OperationId -and $p.destinationId -ceq $f.Config.destination.id -and $p.backupFormatVersion -eq 2) 'Progress correlation missing.'
    }
    $f.OperationId=[guid]::NewGuid().ToString('D'); $r=Invoke-Worker $f
    Assert-True ($r.outcome -ceq 'committed' -and $r.copyBytes -eq 0) 'Unchanged run copied content.'
    $last=(Read-DataSafeJson $f.StatusPath).lastBackupAt
    $f.Config.jobs[0].path=Join-Path $f.Root missing; $f.OperationId=[guid]::NewGuid().ToString('D'); $r=Invoke-Worker $f 1
    Assert-True ($r.outcome -ceq 'failed' -and $null -eq $r.committedAt) 'Failure imported prior commit.'
    Assert-True ((Read-DataSafeJson $f.StatusPath).lastBackupAt -ceq $last) 'Failed attempt replaced committed status time.'
  }
  Test-Case 'CommittedWarningRetainsRecoveryDetails' {
    $f=New-Fixture; $library=Join-Path $f.Bin 'DataSafe.Transaction.ps1'
    $fault=@'
$script:fixtureJournalWriter=${function:Write-DataSafeTransactionJournal}
function Write-DataSafeTransactionJournal($Transaction,[string]$Path,[switch]$CreateOnly) {
  if ($Transaction.state -ceq 'committed') { throw 'fixture finalization unavailable' }
  & $script:fixtureJournalWriter $Transaction $Path -CreateOnly:$CreateOnly
}
'@
    Write-File $library ([IO.File]::ReadAllText($library)+"`n"+$fault)
    $r=Invoke-Worker $f
    Assert-True ($r.outcome -ceq 'committed-with-warning' -and $r.recoveryAction -ceq 'committed') 'Post-pointer finalization was not saved-with-attention.'
    Assert-True (@($r.warnings | Where-Object { $_.Code -ceq 'JournalFinalizationFailed' }).Count -eq 1) 'Structured recovery warning discarded.'
    $repos=@([IO.Directory]::GetDirectories((Join-Path $f.Drive 'DataSafe Backups'))); $repo=Read-DataSafeRepository $repos[0]
    Assert-True ((Read-DataSafeCurrentPointer $repo).transactionId -ceq $r.transactionId) 'Warning result lost real commit authority.'
    Assert-True ($null -eq $r.committedAt) 'Unavailable actual commit time was manufactured.'
  }
  Test-Case 'RollbackIsNotANewCommit' {
    $f=New-Fixture; $null=Invoke-Worker $f; $last=(Read-DataSafeJson $f.StatusPath).lastBackupAt
    $repos=@([IO.Directory]::GetDirectories((Join-Path $f.Drive 'DataSafe Backups'))); $repo=Read-DataSafeRepository $repos[0]
    $pointer=Read-DataSafeCurrentPointer $repo; $old=Read-DataSafeManifest (Join-Path $repo.MetadataRoot $pointer.manifestPath)
    Write-File (Join-Path $f.Source a.txt) 'not-staged'
    $current=New-DataSafeSourceManifest @([PSCustomObject]@{id='docs';path=$f.Source;relativeDestination=@('Docs')})
    $plan=New-DataSafeIncrementalPlan $repo $old $current (Get-DataSafeDestinationCapabilities $repo.Root) (Get-DataSafeFreeBytes $repo.Root)
    $tx=New-DataSafeTransaction $repo $plan; $owner=Get-DataSafeTransactionOwner $tx
    Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath); $owner.Handle=$null
    $f.Config.jobs[0].path=Join-Path $f.Root missing; $r=Invoke-Worker $f 1
    Assert-True ($r.outcome -ceq 'failed' -and $r.recoveryAction -ceq 'rolledBack' -and $null -eq $r.committedAt) 'Rollback became a new app commit.'
    Assert-True ((Read-DataSafeCurrentPointer $repo).transactionId -ceq $pointer.transactionId) 'Rollback changed prior pointer.'
    Assert-True ((Read-DataSafeJson $f.StatusPath).lastBackupAt -ceq $last) 'Rollback changed prior committed time.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $repo.LatestRoot 'Docs/a.txt')) -ceq 'original-a') 'Rollback changed original latest bytes.'
  }
} finally {
  $absolute=[IO.Path]::GetFullPath($ownedRoot)
  Assert-True ($absolute -match ('^'+[regex]::Escape([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\'))+'\\datasafe-app-format-[a-f0-9]{32}$')) 'Unsafe fixture cleanup.'
  Assert-DataSafeNoReparsePath $absolute; Remove-DataSafeDirectoryTree $absolute
}
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
Write-Host "$passes passed; $($failures.Count) failed."
if ($failures.Count) { exit 1 }

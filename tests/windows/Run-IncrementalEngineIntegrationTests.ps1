param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'), [string]$CasePattern = '.')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $WindowsRoot 'DataSafe.Transaction.ps1')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-engine-tests-' + [guid]::NewGuid().ToString('N'))
Ensure-DataSafeDirectory $tempRoot
$passes = 0; $failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Action) {
  if ($Name -notmatch $CasePattern) { return }
  try { & $Action; $script:passes++; Write-Host "PASS: $Name" }
  catch { $script:failures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL: $Name : $($_.Exception.Message)" }
}
function Write-File([string]$Path, [string]$Text) {
  Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Path))
  [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $Path), $Text)
}
function New-Fixture([bool]$Incremental = $true) {
  $root = Join-Path $tempRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $root
  $drive = Join-Path $root drive; Ensure-DataSafeDirectory $drive
  $source = Join-Path $root source
  foreach ($name in @('a','b','c','d')) { Write-File (Join-Path $source "$name.txt") "original-$name" }
  $config = [PSCustomObject]@{
    computerName='Engine Test PC'; installId=[guid]::NewGuid().ToString('D'); destinationId=[guid]::NewGuid().ToString('D')
    destination=[PSCustomObject]@{mode='letter'; driveLetter='unused'; baseFolder='Legacy Backup';id=[guid]::NewGuid().ToString('D')}
    jobs=@([PSCustomObject]@{id='docs';name='Documents';type='folder';path=$source;enabled=$true;relativeDestination=@('Personal','Documents')})
  }
  if ($Incremental) { $config | Add-Member incrementalFormatVersion 2 }
  $status = [PSCustomObject]@{lastBackupAt=$null;lastBackupResult=$null;lastBackupMessage='';destinationStatus='Unknown';recentSnapshots=@()}
  $bin=Join-Path $root windows; Ensure-DataSafeDirectory $bin
  foreach ($file in @('backup-engine.ps1','DataSafe.Repository.ps1','DataSafe.Manifest.ps1','DataSafe.IncrementalPlan.ps1','DataSafe.Transaction.ps1')) {
    [IO.File]::Copy((Join-Path $WindowsRoot $file),(Join-Path $bin $file))
  }
  # Only replace the destination-resolution boundary. The real worker, drive
  # capability/free-space providers, scan, staging, hashing and apply all run.
  $safety=[IO.File]::ReadAllText((Join-Path $WindowsRoot 'DataSafe.Safety.ps1'))
  $safety += "`nfunction Resolve-DataSafeDestination(`$Destination) { return '$($drive.Replace("'","''"))' }`n"
  Write-File (Join-Path $bin 'DataSafe.Safety.ps1') $safety
  $f=[PSCustomObject]@{Root=$root;Drive=$drive;Source=$source;Config=$config;ConfigPath=(Join-Path $root config.json);StatusPath=(Join-Path $root status.json);Bin=$bin;Status=$status}
  Write-DataSafeJson $f.StatusPath $status
  return $f
}
function Invoke-Worker($Fixture, [int]$ExpectedExit=0) {
  Write-DataSafeJson $Fixture.ConfigPath $Fixture.Config
  $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
  $out=Join-Path $Fixture.Root out.txt; $err=Join-Path $Fixture.Root err.txt
  $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -StatusPath "{2}" -AllowNewDestination' -f (Join-Path $Fixture.Bin 'backup-engine.ps1'),$Fixture.ConfigPath,$Fixture.StatusPath
  $p=Start-Process $ps -WindowStyle Hidden -ArgumentList $args -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  $Fixture.Status=Read-DataSafeJson $Fixture.StatusPath
  Assert-True ($p.ExitCode -eq $ExpectedExit) "Worker exit $($p.ExitCode), expected $ExpectedExit : $([IO.File]::ReadAllText($err))"
  return $Fixture.Status
}
function Get-Repository($Fixture) {
  $roots=@([IO.Directory]::GetDirectories((Join-Path $Fixture.Drive 'DataSafe Backups')))
  Assert-True ($roots.Count -eq 1) 'Worker did not create one isolated repository.'
  return Read-DataSafeRepository $roots[0]
}
function Assert-Status($Status) {
  foreach ($name in @('backupFormatVersion','scanCounts','copyBytes','historyCounts','transactionId','recoveryAction')) {
    Assert-True ($null -ne $Status.PSObject.Properties[$name]) "Missing structured status $name"
  }
  Assert-True ($Status.backupFormatVersion -eq 2) 'Internal v2 field did not route to v2.'
}
try {
  Test-Case 'v2 first unchanged changed deleted and structured status' {
    $f=New-Fixture; $s=Invoke-Worker $f; Assert-Status $s
    $repo=Get-Repository $f; $latest=Join-Path $repo.LatestRoot 'Personal/Documents'
    Assert-True ([IO.File]::ReadAllText((Join-Path $latest a.txt)) -ceq 'original-a') 'Latest is not ordinary complete content.'
    Assert-True (@(Get-DataSafeFileEntries $repo.LatestRoot).Count -eq 4) 'First backup incomplete.'
    $s=Invoke-Worker $f; Assert-Status $s
    Assert-True ($s.copyBytes -eq 0) 'Unchanged backup copied user bytes.'
    Write-File (Join-Path $f.Source a.txt) 'changed-a-longer'
    $s=Invoke-Worker $f; Assert-True ($s.copyBytes -eq 16) 'Changed copy accounting incorrect.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $latest a.txt)) -ceq 'changed-a-longer') 'Change not published.'
    $history=@(Get-DataSafeFileEntries $repo.HistoryRoot)
    Assert-True ($history.Count -eq 1 -and [IO.File]::ReadAllText($history[0].FullName) -ceq 'original-a') 'Prior ordinary file missing.'
    [IO.File]::Delete((Join-Path $f.Source b.txt))
    $s=Invoke-Worker $f
    Assert-True (-not (Test-DataSafeFile (Join-Path $latest b.txt))) 'Deleted file remains latest.'
    Assert-True (@(Get-DataSafeFileEntries $repo.LatestRoot).Count -eq 3) 'Deletion harmed complete latest.'
    Assert-True (@(Get-DataSafeFileEntries $repo.HistoryRoot).Count -eq 2) 'Deleted ordinary history missing.'
    Assert-True (-not (Test-DataSafeDirectory (Join-Path $f.Drive 'Legacy Backup/snapshots'))) 'v2 touched legacy snapshots.'
  }
  Test-Case 'no field retains legacy snapshot layout' {
    $f=New-Fixture $false; $s=Invoke-Worker $f
    $snapshots=@(Get-DataSafeCompletedSnapshots (Join-Path $f.Drive 'Legacy Backup/snapshots'))
    Assert-True ($snapshots.Count -eq 1) 'Legacy snapshot not published.'
    Assert-True (Test-DataSafeFile (Join-Path $snapshots[0].FullName 'Personal/Documents/a.txt')) 'Legacy destination changed.'
    Assert-True (-not (Test-DataSafeDirectory (Join-Path $f.Drive 'DataSafe Backups'))) 'Legacy routed to incremental.'
  }
  Test-Case 'merged public configuration refuses before apply' {
    $f=New-Fixture; $f.Config.jobs[0] | Add-Member includePublicFolder Desktop
    $s=Invoke-Worker $f 1
    Assert-True ($s.lastBackupMessage -match 'merged.*Public') 'Missing explicit merged Public refusal.'
    Assert-True (-not (Test-DataSafeDirectory (Join-Path $f.Drive 'DataSafe Backups'))) 'Public refusal created repository.'
  }
  Test-Case 'suspicious deletions and missing source preserve committed pointer' {
    $f=New-Fixture; $null=Invoke-Worker $f; $repo=Get-Repository $f
    $pointerPath=Join-Path $repo.MetadataRoot current-manifest.json; $before=[IO.File]::ReadAllText($pointerPath)
    foreach ($name in @('a','b')) { [IO.File]::Delete((Join-Path $f.Source "$name.txt")) }
    $s=Invoke-Worker $f 1
    Assert-True ($s.lastBackupMessage -match 'deletion review') 'Suspicious deletion not refused.'
    Assert-True ([IO.File]::ReadAllText($pointerPath) -ceq $before) 'Deletion review changed pointer.'
    $f.Config.jobs[0].path=Join-Path $f.Root missing
    $s=Invoke-Worker $f 1
    Assert-True ([IO.File]::ReadAllText($pointerPath) -ceq $before) 'Missing source changed pointer.'
    Assert-Status $s
  }
  Test-Case 'Chromium cache excluded before locked bytes are scanned' {
    $f=New-Fixture; $browser=Join-Path $f.Root 'Google/Chrome/User Data'
    Write-File (Join-Path $browser 'Default/Bookmarks') 'bookmarks'
    Write-File (Join-Path $browser 'Unrelated/Cache/keep') 'not-a-browser-profile-cache'
    Write-File (Join-Path $browser 'System Volume Information/ignored') 'excluded-system-data'
    $cache=Join-Path $browser 'Default/Cache/locked'; Write-File $cache 'excluded-cache'
    $f.Config.jobs[0].path=$browser
    $handle=[IO.File]::Open($cache,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $null=Invoke-Worker $f } finally { $handle.Dispose() }
    $repo=Get-Repository $f
    Assert-True (Test-DataSafeFile (Join-Path $repo.LatestRoot 'Personal/Documents/Default/Bookmarks')) 'Browser user data omitted.'
    Assert-True (-not (Test-DataSafeDirectory (Join-Path $repo.LatestRoot 'Personal/Documents/Default/Cache'))) 'Browser cache copied.'
    Assert-True (Test-DataSafeFile (Join-Path $repo.LatestRoot 'Personal/Documents/Unrelated/Cache/keep')) 'Unrelated Cache data omitted.'
    Assert-True (-not (Test-DataSafeDirectory (Join-Path $repo.LatestRoot 'Personal/Documents/System Volume Information'))) 'System data copied.'
  }
  Test-Case 'unfinished prepared transaction recovers before unavailable-source scan' {
    $f=New-Fixture; $null=Invoke-Worker $f; $repo=Get-Repository $f
    $pointer=Read-DataSafeCurrentPointer $repo
    $old=Read-DataSafeManifest (Join-Path $repo.MetadataRoot $pointer.manifestPath)
    Write-File (Join-Path $f.Source a.txt) 'prepared-recovery-value'
    $job=[PSCustomObject]@{id='docs';path=$f.Source;relativeDestination=@('Personal','Documents')}
    $current=New-DataSafeSourceManifest @($job)
    $plan=New-DataSafeIncrementalPlan $repo $old $current (Get-DataSafeDestinationCapabilities $repo.Root) (Get-DataSafeFreeBytes $repo.Root)
    $tx=New-DataSafeTransaction $repo $plan; $null=Stage-DataSafeTransaction $tx
    $owner=Get-DataSafeTransactionOwner $tx
    Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath); $owner.Handle=$null
    $f.Config.jobs[0].path=Join-Path $f.Root missing
    $s=Invoke-Worker $f 1
    Assert-True ($s.recoveryAction -ceq 'committed') 'Prepared transaction did not recover before scan.'
    Assert-True ((Read-DataSafeCurrentPointer $repo).transactionId -ceq $tx.transactionId) 'Recovery did not establish pointer authority.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $repo.LatestRoot 'Personal/Documents/a.txt')) -ceq 'prepared-recovery-value') 'Recovery lost prepared ordinary content.'
  }
  foreach ($prefix in @('transaction','datasafe')) {
    foreach ($contents in @('partial','complete')) {
      Test-Case "worker recovers canonical interrupted journal beside $contents $prefix writer temporary" {
        $f=New-Fixture; $null=Invoke-Worker $f; $repo=Get-Repository $f
        $pointer=Read-DataSafeCurrentPointer $repo
        $old=Read-DataSafeManifest (Join-Path $repo.MetadataRoot $pointer.manifestPath)
        Write-File (Join-Path $f.Source a.txt) 'canonical-recovered-value'
        $job=[PSCustomObject]@{id='docs';path=$f.Source;relativeDestination=@('Personal','Documents')}
        $current=New-DataSafeSourceManifest @($job)
        $plan=New-DataSafeIncrementalPlan $repo $old $current (Get-DataSafeDestinationCapabilities $repo.Root) (Get-DataSafeFreeBytes $repo.Root)
        $tx=New-DataSafeTransaction $repo $plan; $null=Stage-DataSafeTransaction $tx
        $owner=Get-DataSafeTransactionOwner $tx
        $stopped=$false
        try { $null=Invoke-DataSafeTransaction $tx { param($c) if ($c.Phase -ceq 'archive-filesystem') { throw 'fixture interrupted archive' } } }
        catch { if ($_.Exception.Message -notmatch 'fixture interrupted archive') { throw }; $stopped=$true }
        finally { if ($null -ne $owner.Handle) { Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath); $owner.Handle=$null } }
        Assert-True $stopped 'Interrupted applying boundary was not reached.'
        $journal=Join-Path $repo.TransactionRoot ($tx.transactionId+'.json')
        $text=[IO.File]::ReadAllText($journal)
        if ($contents -ceq 'partial') { $text=$text.Substring(0,[int]($text.Length/2)) }
        # Exact writer names and abandoned bytes model termination before rename;
        # recovery itself runs in the actual fresh worker process.
        $temporary=Join-Path $repo.TransactionRoot ('.'+$prefix+'-'+[guid]::NewGuid().ToString('N')+'.tmp')
        Write-File $temporary $text; $temporaryHash=Get-DataSafeSha256 $temporary
        $f.Config.jobs[0].path=Join-Path $f.Root missing
        $s=Invoke-Worker $f 1
        Assert-True ($s.recoveryAction -ceq 'committed') 'Writer temporary prevented canonical recovery before unavailable-source scan.'
        Assert-True ((Read-DataSafeCurrentPointer $repo).transactionId -ceq $tx.transactionId) 'Temporary replaced canonical commit authority.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $repo.LatestRoot 'Personal/Documents/a.txt')) -ceq 'canonical-recovered-value') 'Canonical recovery did not restore Latest.'
        Assert-True ((Get-DataSafeSha256 $temporary) -ceq $temporaryHash) 'Unpublished temporary evidence was modified/deleted.'
        Assert-True (@($s.warnings | Where-Object { $_.Code -ceq 'UnpublishedJournalTemporary' -and $_.Message.Contains($temporary) }).Count -eq 1) 'Temporary evidence not reported after recovery.'
        $f.Config.jobs[0].path=$f.Source; $s=Invoke-Worker $f
        Assert-True ($s.lastBackupResult -ceq 'warning' -and $s.copyBytes -eq 0) 'Retained temporary warning disappeared on normal backup.'
        Assert-True ((Get-DataSafeSha256 $temporary) -ceq $temporaryHash) 'Later backup removed unpublished evidence.'
      }
    }
  }
  Test-Case 'worker recovers actual writer temporary after process termination bypasses finally' {
    $f=New-Fixture; $null=Invoke-Worker $f; $repo=Get-Repository $f
    Write-File (Join-Path $f.Source a.txt) 'terminated-writer-value'
    $library=Join-Path $f.Bin 'DataSafe.Transaction.ps1'; $original=[IO.File]::ReadAllText($library)
    # Stop only the owned child, after its real writer has created/read back a
    # complete unpublished journal, after the old file moved out of Latest.
    $termination=@'
$script:fixtureDocumentReader=${function:Read-DataSafeTransactionDocument}
function Read-DataSafeTransactionDocument([string]$Path,[string]$ExpectedPath) {
  $document=& $script:fixtureDocumentReader $Path $ExpectedPath
  if ([IO.Path]::GetFileName($Path) -match '^\.transaction-[0-9a-f]{32}\.tmp$' -and $document.state -ceq 'applying' -and
      @($document.operations | Where-Object { $_.archiveState -ceq 'done' }).Count -gt 0) { [Environment]::Exit(73) }
  return $document
}
'@
    Write-File $library ($original+"`n"+$termination)
    $null=Invoke-Worker $f 73
    Write-File $library $original
    $temporary=@([IO.Directory]::GetFiles($repo.TransactionRoot,'.transaction-*.tmp'))
    Assert-True ($temporary.Count -eq 1) 'True process exit did not retain the actual writer temporary.'
    $hash=Get-DataSafeSha256 $temporary[0]
    Assert-True (-not (Test-DataSafeFile (Join-Path $repo.LatestRoot 'Personal/Documents/a.txt'))) 'Termination did not leave interrupted Latest.'
    $s=Invoke-Worker $f
    Assert-True ($s.recoveryAction -ceq 'committed' -and $s.lastBackupResult -ceq 'warning') 'Actual terminated writer blocked recovery/warning.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $repo.LatestRoot 'Personal/Documents/a.txt')) -ceq 'terminated-writer-value') 'Terminated writer lost ordinary new bytes.'
    Assert-True ((Get-DataSafeSha256 $temporary[0]) -ceq $hash) 'Actual writer temporary evidence was discarded.'
  }
  foreach ($entry in @('unknown.txt','.transaction-not-a-uuid.tmp','.datasafe-0123456789abcdef0123456789abcdef.tmp.extra','temporary-directory')) {
    Test-Case "worker conservatively rejects unknown transaction entry $entry" {
      $f=New-Fixture; $null=Invoke-Worker $f; $repo=Get-Repository $f
      $pointerPath=Join-Path $repo.MetadataRoot current-manifest.json; $before=[IO.File]::ReadAllText($pointerPath)
      $name=if ($entry -ceq 'temporary-directory') { '.transaction-'+[guid]::NewGuid().ToString('N')+'.tmp' } else { $entry }
      $path=Join-Path $repo.TransactionRoot $name
      if ($entry -ceq 'temporary-directory') { Ensure-DataSafeDirectory $path } else { Write-File $path 'unrecognized-evidence' }
      $s=Invoke-Worker $f 1
      Assert-True ([IO.File]::ReadAllText($pointerPath) -ceq $before) 'Unknown transaction entry permitted pointer publication.'
      Assert-True ((Test-DataSafeFile $path) -or (Test-DataSafeDirectory $path)) 'Unknown evidence removed.'
      Assert-True ($s.lastBackupMessage -match 'transaction|journal') 'Unknown transaction entry lacked diagnostic.'
    }
  }
  Test-Case 'post-pointer finalization warning retains authority and prevents another transaction' {
    $f=New-Fixture; $null=Invoke-Worker $f; $repo=Get-Repository $f
    $pointer=Read-DataSafeCurrentPointer $repo
    $old=Read-DataSafeManifest (Join-Path $repo.MetadataRoot $pointer.manifestPath)
    Write-File (Join-Path $f.Source a.txt) 'post-pointer-authority'
    $job=[PSCustomObject]@{id='docs';path=$f.Source;relativeDestination=@('Personal','Documents')}
    $current=New-DataSafeSourceManifest @($job)
    $plan=New-DataSafeIncrementalPlan $repo $old $current (Get-DataSafeDestinationCapabilities $repo.Root) (Get-DataSafeFreeBytes $repo.Root)
    $tx=New-DataSafeTransaction $repo $plan; $null=Stage-DataSafeTransaction $tx
    $owner=Get-DataSafeTransactionOwner $tx
    try { $null=Invoke-DataSafeTransaction $tx { param($c) if ($c.Phase -ceq 'pointer') { throw 'fixture post-pointer stop' } } }
    catch { Assert-True ($_.Exception.Message -match 'fixture post-pointer stop') $_.Exception.Message }
    finally { if ($null -ne $owner.Handle) { Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath); $owner.Handle=$null } }
    $library=Join-Path $f.Bin 'DataSafe.Transaction.ps1'
    $text=[IO.File]::ReadAllText($library)
    $fault=@'
$script:fixtureWriter = ${function:Write-DataSafeTransactionJournal}
function Write-DataSafeTransactionJournal($Transaction, [string]$Path, [switch]$CreateOnly) {
  if ($Transaction.state -ceq 'committed') { throw 'fixture finalization unavailable' }
  & $script:fixtureWriter $Transaction $Path -CreateOnly:$CreateOnly
}
'@
    Write-File $library ($text + "`n" + $fault)
    $count=@([IO.Directory]::GetFiles($repo.TransactionRoot)).Count
    $before=[IO.File]::ReadAllText((Join-Path $repo.MetadataRoot current-manifest.json))
    $s=Invoke-Worker $f
    Assert-Status $s
    Assert-True ($s.lastBackupResult -ceq 'warning' -and $s.lastBackupMessage -match 'JournalFinalizationFailed') 'Committed finalization warning was erased.'
    Assert-True ($s.warnings[0].Code -ceq 'JournalFinalizationFailed') 'Structured finalization warning missing.'
    Assert-True (@([IO.Directory]::GetFiles($repo.TransactionRoot)).Count -eq $count) 'New transaction started over unresolved journal.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $repo.MetadataRoot current-manifest.json)) -ceq $before) 'Warning changed committed pointer.'
    Write-File $library $text
    $s=Invoke-Worker $f
    Assert-True ($s.lastBackupResult -ceq 'success' -and $s.recoveryAction -ceq 'committed') 'Later recovery did not retry finalization.'
  }
  Test-Case 'live post-pointer finalization failure reports committed warning' {
    $f=New-Fixture
    $library=Join-Path $f.Bin 'DataSafe.Transaction.ps1'
    $fault=@'
$script:fixtureWriter = ${function:Write-DataSafeTransactionJournal}
function Write-DataSafeTransactionJournal($Transaction, [string]$Path, [switch]$CreateOnly) {
  if ($Transaction.state -ceq 'committed') { throw 'fixture live finalization unavailable' }
  & $script:fixtureWriter $Transaction $Path -CreateOnly:$CreateOnly
}
'@
    Write-File $library ([IO.File]::ReadAllText($library) + "`n" + $fault)
    $s=Invoke-Worker $f
    Assert-True ($s.lastBackupResult -ceq 'warning' -and $s.lastBackupMessage -match 'JournalFinalizationFailed') 'Live committed warning lost.'
    $repo=Get-Repository $f
    Assert-True ((Read-DataSafeCurrentPointer $repo).transactionId -ceq $s.transactionId) 'Live pointer lost authority.'
  }
  Test-Case 'committed staging file substitution retains warning and blocks new transaction' {
    $f=New-Fixture; $null=Invoke-Worker $f; $repo=Get-Repository $f
    $pointer=Read-DataSafeCurrentPointer $repo
    $staging=Join-Path $repo.StagingRoot $pointer.transactionId
    Write-File $staging 'unowned-staging-file'
    $count=@([IO.Directory]::GetFiles($repo.TransactionRoot)).Count
    $s=Invoke-Worker $f
    Assert-True ($s.lastBackupResult -ceq 'warning' -and $s.lastBackupMessage -match 'StagingCleanupFailed') 'Retained staging evidence warning lost.'
    Assert-True (@([IO.Directory]::GetFiles($repo.TransactionRoot)).Count -eq $count) 'New transaction started despite unresolved staging evidence.'
    Assert-True ([IO.File]::ReadAllText($staging) -ceq 'unowned-staging-file') 'Unowned staging evidence mutated.'
    Assert-True ((Read-DataSafeCurrentPointer $repo).transactionId -ceq $pointer.transactionId) 'New pointer published over retained evidence.'
  }
  Test-Case 'worker owns no popup or tray notification API' {
    foreach ($name in @('backup-engine.ps1','check-reminders.ps1','check-cloud-health.ps1','verify-backup-integrity.ps1')) {
      $text=[IO.File]::ReadAllText((Join-Path $WindowsRoot $name))
      Assert-True ($text -notmatch 'WScript\.Shell|System\.Windows\.Forms\.NotifyIcon|ShowBalloonTip\(|\.Popup\(') "Interactive API in $name"
    }
  }
} finally { Remove-DataSafeDirectoryTree $tempRoot }
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
Write-Host "$passes passed; $($failures.Count) failed."
if ($failures.Count) { exit 1 }

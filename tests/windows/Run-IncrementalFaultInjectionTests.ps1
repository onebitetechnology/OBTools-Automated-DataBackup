param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'), [string]$CasePattern = '.')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $WindowsRoot 'DataSafe.Transaction.ps1')
$passes = 0; $failures = New-Object 'System.Collections.Generic.List[string]'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-fault-tests-' + [guid]::NewGuid().ToString('N'))
Ensure-DataSafeDirectory $tempRoot
$script:fixtureImages = @{}
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '.') {
  try { & $Action | Out-Null } catch {
    if ($_.Exception -is [Management.Automation.CommandNotFoundException]) { throw }
    Assert-True ($_.Exception.Message -match $Pattern) $_.Exception.Message; return
  }
  throw 'Expected rejection.'
}
function Write-File([string]$Path, [string]$Text) {
  Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Path))
  [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $Path), $Text)
}
function Close-TestOwners {
  foreach ($owner in @($script:DataSafeTransactionOwners.Values)) {
    if ($null -ne $owner.Handle) {
      Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath)
      $owner.Handle = $null
    }
  }
}
function Test-Case([string]$Name, [scriptblock]$Action) {
  if ($Name -notmatch $CasePattern) { return }
  try { & $Action; $script:passes++; Write-Host "PASS: $Name" }
  catch { $script:failures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL: $Name : $($_.Exception.Message)" }
  finally { Close-TestOwners }
}
function New-Plan($Repo, $Old, $New) {
  $cap = Get-DataSafeFilesystemCapabilities NTFS; $cap | Add-Member TotalBytes ([long]20GB)
  $p = New-DataSafeIncrementalPlan $Repo $Old $New $cap 100GB
  Assert-True ($p.BlockingErrors.Count -eq 0 -and -not $p.DeletionReviewRequired) 'Fixture plan blocked.'
  return $p
}
function Copy-FixtureTree([string]$From, [string]$To) {
  # Test-only disposable image copy, preserving times/flags exactly. No links
  # exist in these fixtures, and no production filesystem operation is mocked.
  Ensure-DataSafeDirectory $To
  foreach ($file in [IO.Directory]::GetFiles($From)) {
    if ([IO.Path]::GetFileName($file) -eq 'operation.lock') { continue }
    $target = Join-Path $To ([IO.Path]::GetFileName($file))
    [IO.File]::Copy($file, $target)
    [IO.File]::SetLastWriteTimeUtc($target, [IO.File]::GetLastWriteTimeUtc($file))
    [IO.File]::SetAttributes($target, [IO.File]::GetAttributes($file))
  }
  foreach ($dir in [IO.Directory]::GetDirectories($From)) { Copy-FixtureTree $dir (Join-Path $To ([IO.Path]::GetFileName($dir))) }
  [IO.Directory]::SetLastWriteTimeUtc($To, [IO.Directory]::GetLastWriteTimeUtc($From))
  [IO.File]::SetAttributes($To, [IO.File]::GetAttributes($From))
}
function New-Fixture([switch]$Initial, [string]$Transition = '') {
  $key = "$Initial/$Transition"
  if ($script:fixtureImages.ContainsKey($key)) {
    Close-TestOwners
    $image = $script:fixtureImages[$key]; $f = $image.Fixture
    Assert-True ($f.Root.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar)) 'Unsafe fixture reset target.'
    Remove-DataSafeDirectoryTree $f.Root
    Copy-FixtureTree $image.Path $f.Root
    $f.Tx = Read-DataSafeTransaction $f.Path
    $lock = Join-Path $f.Repo.MetadataRoot operation.lock
    $handle = Acquire-DataSafeOperationLock (ConvertTo-DataSafeExtendedPath $lock)
    $ownerKey = Get-DataSafeTransactionOwnerKey $f.Repo.Root $f.Repo.ComputerId $f.Tx.transactionId
    $script:DataSafeTransactionOwners[$ownerKey] = [PSCustomObject]@{ Transaction=$f.Tx; Repository=$f.Repo; Path=$f.Path; LockPath=$lock; Handle=$handle; Json=(ConvertTo-Json $f.Tx -Depth 32 -Compress) }
    return $f
  }
  $root = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
  Ensure-DataSafeDirectory $root
  $repo = Initialize-DataSafeRepository $root 'Fault PC' ([guid]::NewGuid().ToString('D'))
  $source = Join-Path $root source
  foreach ($name in @('a.txt','b.txt','c.txt','keep1')) { Write-File (Join-Path $source $name) ('old-' + $name) }
  if ($Transition -eq 'directory-file') { Write-File (Join-Path $source 'node/child') 'child' }
  if ($Transition -eq 'file-directory') { Write-File (Join-Path $source node) 'old-node' }
  $job = [PSCustomObject]@{ id='docs'; path=$source; name='Documents' }
  $old = $null
  if (-not $Initial) {
    $old = New-DataSafeSourceManifest @($job)
    # Fixture setup materializes a committed baseline directly. Actual initial
    # transaction behavior is independently exercised by the initial-backup case.
    foreach ($entry in $old.entries) {
      $target = Join-Path $repo.Root $entry.versionLocation
      if ($entry.entryType -eq 'directory') { Ensure-DataSafeDirectory $target }
      else { Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($target)); [IO.File]::Copy((Join-Path $source $entry.relativePath), $target) }
    }
    foreach ($entry in @($old.entries | Sort-Object @{Expression={ $_.relativePath.Length }; Descending=$true})) { Set-DataSafeTransactionMetadata (Join-Path $repo.Root $entry.versionLocation) $entry }
    $baseId = [guid]::NewGuid().ToString('D')
    $basePath = Write-DataSafeManifest $repo $old $baseId
    Write-DataSafeAtomicJson (Join-Path $repo.MetadataRoot 'current-manifest.json') ([PSCustomObject]@{ schema='datasafe.current-manifest'; formatVersion=1; transactionId=$baseId; manifestPath=('manifests/'+$baseId+'.json'); sha256=(Get-DataSafeSha256 $basePath) })
    Write-File (Join-Path $source a.txt) 'replacement-content'
    [IO.File]::SetLastWriteTimeUtc((Join-Path $source b.txt), [datetime]'2020-01-01T00:00:00Z')
    [IO.File]::Delete((Join-Path $source c.txt))
    Write-File (Join-Path $source 'new-文書.txt') 'new-content'
    Ensure-DataSafeDirectory (Join-Path $source empty)
    if ($Transition -eq 'directory-file') { Remove-DataSafeDirectoryTree (Join-Path $source node); Write-File (Join-Path $source node) 'new-node' }
    if ($Transition -eq 'file-directory') { [IO.File]::Delete((Join-Path $source node)); Write-File (Join-Path $source 'node/child') 'new-child' }
  }
  $new = New-DataSafeSourceManifest @($job) $old
  $tx = New-DataSafeTransaction $repo (New-Plan $repo $old $new)
  $null = Stage-DataSafeTransaction $tx
  $f = [PSCustomObject]@{ Root=$root; Repo=$repo; Source=$source; Old=$old; New=$new; Tx=$tx; Path=(Join-Path $repo.TransactionRoot ($tx.transactionId+'.json')); Pointer=(Join-Path $repo.MetadataRoot 'current-manifest.json') }
  $imagePath = Join-Path $tempRoot ('image-' + [guid]::NewGuid().ToString('N'))
  Copy-FixtureTree $root $imagePath
  $script:fixtureImages[$key] = [PSCustomObject]@{ Fixture=$f; Path=$imagePath }
  return $f
}
function Assert-New($f) {
  foreach ($entry in $f.New.entries) {
    $path = Join-Path $f.Repo.Root $entry.versionLocation
    if ($entry.entryType -eq 'file') { Assert-True ((Get-DataSafeSha256 $path) -ceq $entry.sha256) "Wrong new file: $path" }
    else { Assert-True (Test-DataSafeDirectory $path) "Missing new directory: $path" }
  }
  Assert-True (-not (Test-DataSafeFile (Join-Path $f.Repo.LatestRoot 'Documents/c.txt'))) 'Deleted file remains.'
  Assert-True (-not (Test-DataSafeFile (Join-Path $f.Repo.MetadataRoot operation.lock))) 'Terminal lock remains.'
}
try {
  Test-Case 'destination timestamp verification accepts only fixed media tolerance without hash weakening' {
    $f=New-Fixture -Initial; $null=Invoke-DataSafeTransaction $f.Tx
    $entry=$f.New.entries[0]; $path=Join-Path $f.Repo.Root $entry.versionLocation
    $expected=[datetime]::ParseExact($entry.modifiedUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    foreach ($row in @(@{Ticks=[long]0;Delta=[long]1},@{Ticks=[long]100000;Delta=[long]100000},@{Ticks=[long]20000000;Delta=[long]20000000})) {
      [IO.File]::SetLastWriteTimeUtc($path,$expected.AddTicks($row.Delta))
      $actual=Test-DataSafeTransactionObject $path $entry -Metadata -TimestampToleranceTicks $row.Ticks
      Assert-True ($actual -eq ($row.Delta -le $row.Ticks)) 'Wrong destination tolerance boundary.'
      [IO.File]::SetLastWriteTimeUtc($path,$expected.AddTicks($row.Ticks+1))
      Assert-True (-not (Test-DataSafeTransactionObject $path $entry -Metadata -TimestampToleranceTicks $row.Ticks)) 'Excess destination drift accepted.'
    }
    Write-File $path 'bad'
    Assert-True (-not (Test-DataSafeTransactionObject $path $entry -Metadata -TimestampToleranceTicks 20000000)) 'Timestamp tolerance weakened content hash.'
  }
  Test-Case 'initial backup commits verified pointer and unchanged run copies no content' {
    $f = New-Fixture -Initial; $result = Invoke-DataSafeTransaction $f.Tx
    Assert-True ($result.FinalState -ceq 'committed') 'Initial not committed.'
    $p = Read-DataSafeCurrentPointer $f.Repo
    Assert-True ($p.transactionId -ceq $f.Tx.transactionId -and $p.manifestPath -ceq ('manifests/'+$f.Tx.transactionId+'.json')) 'Pointer identity wrong.'
    $unchanged = New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.New $f.New)
    $null = Stage-DataSafeTransaction $unchanged
    Assert-True ($unchanged.operations.Count -eq 0 -and $unchanged.stageBytes -eq 0) 'Unchanged content staged.'
    Assert-True ((Invoke-DataSafeTransaction $unchanged).FinalState -ceq 'committed') 'Unchanged failed.'
  }
  foreach ($transition in @('','directory-file','file-directory')) {
    Test-Case "mixed apply ordinary history and dependency ordering $transition" {
      $f = New-Fixture -Transition $transition; $null = Invoke-DataSafeTransaction $f.Tx; Assert-New $f
      foreach ($op in $f.Tx.operations) {
        if ($op.oldEntry -and $op.oldEntry.entryType -eq 'file' -and $op.kind -in @('replace','delete')) {
          Assert-True ((Get-DataSafeSha256 $op.historyPath) -ceq $op.oldEntry.sha256) 'Old ordinary history lost.'
        }
        if ($op.kind -eq 'metadata') { Assert-True ($null -eq $op.historyPath) 'Metadata duplicated content.' }
        if ($null -ne $op.historyPath -and $op.oldEntry.entryType -eq 'directory') { Assert-True (Test-DataSafeTransactionObject $op.historyPath $op.oldEntry -Metadata) 'Empty archived directory metadata lost.' }
      }
      Assert-Throws { Undo-DataSafeTransaction $f.Tx } 'commit|live|owner'
      Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Terminal recovery failed.'
    }
  }
  foreach ($damage in @('edited','missing','metadata','staged','applying')) {
    Test-Case "preapply rejects $damage before any history mutation" {
      $f = New-Fixture
      $target = Join-Path $f.Repo.LatestRoot 'Documents/keep1'
      if ($damage -eq 'edited') { Write-File $target 'unknown' }
      if ($damage -eq 'missing') { [IO.File]::Delete($target) }
      if ($damage -eq 'metadata') { [IO.File]::SetLastWriteTimeUtc($target, [datetime]'2010-01-01Z') }
      if ($damage -eq 'staged') { Write-File @($f.Tx.operations | Where-Object stagedPath)[0].stagedPath 'bad' }
      if ($damage -eq 'applying') { Set-DataSafeTransactionState $f.Tx applying; Write-File $target 'unknown' }
      $before = [IO.File]::ReadAllText($f.Pointer)
      Assert-Throws { Invoke-DataSafeTransaction $f.Tx } 'verif|hash|missing|metadata|snapshot|match'
      Assert-True ([IO.Directory]::GetFileSystemEntries($f.Repo.HistoryRoot).Count -eq 0) 'Archived before validation.'
      Assert-True ([IO.File]::ReadAllText($f.Pointer) -ceq $before) 'Pointer changed on failed validation.'
    }
  }
  Test-Case 'fault every durable boundary reconciles filesystem journal gaps idempotently' {
    $probe = New-Fixture; $script:boundaries = New-Object 'System.Collections.Generic.List[string]'
    $null = Invoke-DataSafeTransaction $probe.Tx { param($context) $script:boundaries.Add($context.Phase) }
    Assert-True ($script:boundaries.Contains('pointer') -and $script:boundaries.Contains('archive-filesystem') -and $script:boundaries.Contains('promote-filesystem')) 'Missing fault boundaries.'
    for ($fault = 1; $fault -le $script:boundaries.Count; $fault++) {
      $f = New-Fixture; $script:at = 0; $script:failAt = $fault
      Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($context) $script:at++; if ($script:at -eq $script:failAt) { throw 'injected crash' } } } 'injected crash'
      Close-TestOwners # Simulate process death; disk read must explicitly reacquire authority.
      $r = Recover-DataSafeTransaction $f.Repo $f.Path
      Assert-True ($r.FinalState -ceq 'committed') "Fault $fault failed forward recovery."
      Assert-New $f
      Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Repeat recovery changed state.'
    }
    Write-Host "Boundaries checked: $($script:boundaries.Count)"
  }
  foreach ($damage in @('missing','corrupt')) {
    Test-Case "recovery rolls back when remaining staging $damage" {
      $f = New-Fixture; $before = [IO.File]::ReadAllText($f.Pointer)
      Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -eq 'archive-filesystem') { throw 'crash' } } } crash
      $op = @($f.Tx.operations | Where-Object stagedPath)[-1]
      if ($damage -eq 'missing') { [IO.File]::Delete($op.stagedPath) } else { Write-File $op.stagedPath 'bad' }
      Close-TestOwners
      $r = Recover-DataSafeTransaction $f.Repo $f.Path
      Assert-True ($r.FinalState -ceq 'rolledBack' -and [IO.File]::ReadAllText($f.Pointer) -ceq $before) 'Did not preserve old pointer.'
      foreach ($e in $f.Old.entries | Where-Object entryType -eq file) { Assert-True ((Get-DataSafeSha256 (Join-Path $f.Repo.Root $e.versionLocation)) -ceq $e.sha256) 'Rollback file lost.' }
      Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'rolledBack') 'Rollback not idempotent.'
    }
  }
  Test-Case 'unknown promoted content blocks recovery without overwrite or evidence deletion' {
    $f = New-Fixture
    Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -eq 'promote-filesystem') { throw 'crash' } } } crash
    Write-File (Join-Path $f.Repo.LatestRoot 'Documents/a.txt') 'unknown-content'
    Close-TestOwners
    Assert-Throws { Recover-DataSafeTransaction $f.Repo $f.Path } 'blocked|unknown|verif|match'
    Assert-True ([IO.File]::ReadAllText((Join-Path $f.Repo.LatestRoot 'Documents/a.txt')) -ceq 'unknown-content') 'Unknown content overwritten.'
  }
  Test-Case 'recovery concurrent owner and detached apply reject' {
    $f = New-Fixture; $detached = Read-DataSafeTransaction $f.Path
    Assert-Throws { Invoke-DataSafeTransaction $detached } 'live|owner'
    Assert-Throws { Recover-DataSafeTransaction $f.Repo $f.Path } 'already running'
    $null = Undo-DataSafeTransaction $f.Tx
    Assert-True (-not (Test-DataSafeFile (Join-Path $f.Repo.MetadataRoot operation.lock))) 'Undo lock remains.'
  }
  Test-Case 'history collision after staging never overwrites' {
    $f = New-Fixture; $history = Join-Path $f.Repo.HistoryRoot $f.Tx.displayHistoryFolder
    Write-File (Join-Path $history unknown) 'occupied'
    Assert-Throws { Invoke-DataSafeTransaction $f.Tx } 'occupied|collision'
    Assert-True ([IO.File]::ReadAllText((Join-Path $history unknown)) -ceq 'occupied') 'History overwritten.'
  }
  Test-Case 'strict pointer rejects duplicate keys path escape hash and unknown fields' {
    $f = New-Fixture; $text = [IO.File]::ReadAllText($f.Pointer)
    foreach ($bad in @(
      ($text -replace '"schema"\s*:', '"Schema":"bad","schema":'),
      ($text -replace 'manifests/', '../'),
      ($text -replace '"sha256"\s*:\s*"[A-F0-9]+"', '"sha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'),
      ($text -replace '"schema"\s*:', '"unknown":1,"schema":')
    )) {
      Assert-True ($bad -cne $text) 'Pointer mutation failed.'
      Write-File $f.Pointer $bad
      Assert-Throws { Invoke-DataSafeTransaction $f.Tx } 'pointer|duplicate|schema|hash|path'
    }
    Write-File $f.Pointer $text
  }
  Test-Case 'destination relocation stages identical bytes and archives the old ordinary path' {
    $f = New-Fixture -Initial; $null = Invoke-DataSafeTransaction $f.Tx
    $job = [PSCustomObject]@{ id='docs'; path=$f.Source; name='Relocated' }
    $script:hashCalls = 0
    $current = New-DataSafeSourceManifest @($job) $f.New { param($path) $script:hashCalls++; Get-DataSafeSha256 $path }
    Assert-True ($script:hashCalls -eq 0) 'Relocation disabled unchanged-source hash reuse.'
    $tx = New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.New $current)
    Assert-True (@($tx.operations | Where-Object { $_.kind -ne 'replace' -or $null -eq $_.stagedPath }).Count -eq 0) 'Relocation did not require staging.'
    $null = Stage-DataSafeTransaction $tx; $null = Invoke-DataSafeTransaction $tx
    Assert-True (-not (Test-DataSafeDirectory (Join-Path $f.Repo.LatestRoot Documents))) 'Old destination remains in latest.'
    foreach ($op in $tx.operations) {
      Assert-True ((Get-DataSafeSha256 $op.historyPath) -ceq $op.expectedOldSha256 -and (Get-DataSafeSha256 $op.currentPath) -ceq $op.expectedNewSha256) 'Relocation lost old/new ordinary copies.'
    }
  }
  Test-Case 'partial identical-byte relocation rolls back using old and new path identity' {
    $f=New-Fixture -Initial; $null=Invoke-DataSafeTransaction $f.Tx
    $job=[PSCustomObject]@{id='docs';path=$f.Source;name='Relocated'}
    $current=New-DataSafeSourceManifest @($job) $f.New
    $tx=New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.New $current)
    $null=Stage-DataSafeTransaction $tx
    Assert-Throws { Invoke-DataSafeTransaction $tx { param($c) if ($c.Phase -eq 'promote-filesystem') { throw 'relocation crash' } } } 'relocation crash'
    [IO.File]::Delete(@($tx.operations | Where-Object { $_.stagedPath -and (Test-DataSafeFile $_.stagedPath) })[-1].stagedPath)
    Close-TestOwners
    $path=Join-Path $f.Repo.TransactionRoot ($tx.transactionId+'.json')
    Assert-True ((Recover-DataSafeTransaction $f.Repo $path).FinalState -ceq 'rolledBack') 'Partial relocation did not roll back.'
    Assert-True (-not (Test-DataSafeDirectory (Join-Path $f.Repo.LatestRoot Relocated))) 'Relocation rollback left new content.'
    foreach ($entry in $f.New.entries) { Assert-True (Test-DataSafeTransactionObject (Join-Path $f.Repo.Root $entry.versionLocation) $entry -Metadata) 'Old relocation baseline lost.' }
  }
  Test-Case 'durable journal failure after a move preserves old pointer and recovers' {
    $f = New-Fixture; $before = [IO.File]::ReadAllText($f.Pointer)
    $originalWriter = ${function:Write-DataSafeTransactionJournal}
    try {
      function Write-DataSafeTransactionJournal($Transaction, [string]$Path, [switch]$CreateOnly) {
        if ($Transaction.state -eq 'applying' -and @($Transaction.operations | Where-Object archiveState -eq done).Count) { throw 'injected disk full journal failure' }
        & $originalWriter $Transaction $Path -CreateOnly:$CreateOnly
      }
      Assert-Throws { Invoke-DataSafeTransaction $f.Tx } 'injected disk full'
    } finally { ${function:Write-DataSafeTransactionJournal} = $originalWriter }
    Assert-True ([IO.File]::ReadAllText($f.Pointer) -ceq $before) 'Journal failure published pointer.'
    Close-TestOwners
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Journal-write recovery failed.'
    Assert-New $f
  }
  Test-Case 'pointer publication failure preserves old authority until verified roll-forward' {
    $f = New-Fixture; $before = [IO.File]::ReadAllText($f.Pointer)
    $originalAtomic = ${function:Write-DataSafeAtomicJson}
    try {
      function Write-DataSafeAtomicJson([string]$Path, $Value, [switch]$CreateOnly) {
        if ($Path.EndsWith('current-manifest.json')) { throw 'injected pointer disk full' }
        & $originalAtomic $Path $Value -CreateOnly:$CreateOnly
      }
      Assert-Throws { Invoke-DataSafeTransaction $f.Tx } 'injected pointer disk full'
    } finally { ${function:Write-DataSafeAtomicJson} = $originalAtomic }
    Assert-True ([IO.File]::ReadAllText($f.Pointer) -ceq $before) 'Failed pointer published.'
    Close-TestOwners
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Pointer recovery failed.'
    Assert-New $f
  }
  Test-Case 'initial missing staging rolls back to empty latest without a pointer' {
    $f = New-Fixture -Initial
    Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -eq 'applying') { throw 'crash' } } } crash
    [IO.File]::Delete($f.Tx.operations[-1].stagedPath); Close-TestOwners
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'rolledBack') 'Initial rollback failed.'
    Assert-True (-not (Test-DataSafeFile $f.Pointer) -and [IO.Directory]::GetFileSystemEntries($f.Repo.LatestRoot).Count -eq 0) 'Initial rollback left current content.'
  }
  Test-Case 'metadata-only run creates no duplicate content and preserves attributes and time' {
    $f = New-Fixture -Initial; $null = Invoke-DataSafeTransaction $f.Tx
    $path = Join-Path $f.Source a.txt
    [IO.File]::SetLastWriteTimeUtc($path, [datetime]'2018-01-01Z')
    [IO.File]::SetAttributes($path, [IO.FileAttributes]::ReadOnly)
    $job = [PSCustomObject]@{ id='docs'; path=$f.Source; name='Documents' }
    $current = New-DataSafeSourceManifest @($job) $f.New
    $tx = New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.New $current)
    Assert-True ($tx.stageBytes -eq 0 -and $tx.operations.Count -eq 1 -and $tx.operations[0].kind -ceq 'metadata') 'Metadata run staged duplicate content.'
    $null = Stage-DataSafeTransaction $tx; $null = Invoke-DataSafeTransaction $tx
    Assert-True ([IO.Directory]::GetFileSystemEntries($f.Repo.HistoryRoot).Count -eq 0 -and (Test-DataSafeTransactionObject $tx.operations[0].currentPath $tx.operations[0].newEntry -Metadata)) 'Metadata/history incorrect.'
  }
  Test-Case 'post-pointer corruption blocks rather than undoing durable commit authority' {
    $f = New-Fixture
    Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -eq 'pointer') { throw 'crash' } } } crash
    $published = [IO.File]::ReadAllText($f.Pointer)
    Write-File (Join-Path $f.Repo.LatestRoot 'Documents/a.txt') 'unknown-postcommit'
    Close-TestOwners
    Assert-Throws { Recover-DataSafeTransaction $f.Repo $f.Path } 'verif|blocked'
    Assert-True ([IO.File]::ReadAllText($f.Pointer) -ceq $published) 'Recovery undid durable pointer.'
  }
  Test-Case 'cleanup failure is a structured warning after durable success' {
    $f = New-Fixture; $originalRemove = ${function:Remove-DataSafeDirectoryTree}
    try {
      function Remove-DataSafeDirectoryTree([string]$Path) {
        if ($Path -like '*\.datasafe\staging\*') { throw 'injected cleanup unavailable' }
        & $originalRemove $Path
      }
      $r = Invoke-DataSafeTransaction $f.Tx
    } finally { ${function:Remove-DataSafeDirectoryTree} = $originalRemove }
    Assert-True ($r.FinalState -ceq 'committed' -and $r.Warnings.Count -eq 1 -and $r.Warnings[0].Code -ceq 'StagingCleanupFailed') 'Cleanup erased success or warning.'
    Assert-New $f
  }
  Test-Case 'terminal cleanup preserves unknown staging content with a structured warning' {
    $f=New-Fixture
    $unknown=Join-Path (Join-Path $f.Repo.StagingRoot $f.Tx.transactionId) 'unknown-user-file.txt'
    Write-File $unknown 'preserve-unknown'
    $result=Invoke-DataSafeTransaction $f.Tx
    Assert-True ($result.FinalState -ceq 'committed' -and (Test-DataSafeFile $unknown)) 'Cleanup deleted unknown staging content.'
    Assert-True ([IO.File]::ReadAllText($unknown) -ceq 'preserve-unknown' -and $result.Warnings.Count -eq 1 -and $result.Warnings[0].Code -ceq 'StagingCleanupFailed') 'Unknown staging evidence/warning missing.'
    Assert-New $f
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).Warnings.Count -eq 1 -and (Test-DataSafeFile $unknown)) 'Repeated terminal cleanup deleted evidence.'
  }
  Test-Case 'strict v2 prior-pointer snapshot and substeps reject tampering without rewrite' {
    $f = New-Fixture
    Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -eq 'apply-journal') { throw 'crash' } } } crash
    $text = [IO.File]::ReadAllText($f.Path)
    foreach ($mutate in @(
      { param($j) $j.previousPointer.manifestPath = '../escape' },
      { param($j) $j.previousPointer.sha256 = 'A' * 64 },
      { param($j) $j.operations[0].archiveState = 'invented' },
      { param($j) $j.destinationFileSystem = 'unknown' },
      { param($j) $j.timestampToleranceTicks = 20000000 },
      { param($j) $j.pointerCaptured = $false },
      { param($j) $j.previousPointer | Add-Member unknown value }
    )) {
      $j = ConvertFrom-DataSafeTransactionJson $text; & $mutate $j
      Write-File $f.Path (ConvertTo-Json $j -Depth 32)
      Assert-Throws { Read-DataSafeTransaction $f.Path } 'path|hash|substep|unknown|pointer|timestamp|policy'
    }
    Write-File $f.Path $text
  }
  Test-Case 'legacy v1 detached journal requires owned strict upgrade before recovery apply' {
    $f=New-Fixture -Initial
    $legacy=Read-DataSafeTransaction $f.Path; $legacy.formatVersion=1
    foreach ($name in @('previousPointer','pointerCaptured','destinationFileSystem','timestampToleranceTicks')) { $legacy.PSObject.Properties.Remove($name) }
    foreach ($op in $legacy.operations) { foreach ($name in @('archiveState','promoteState','metadataState')) { $op.PSObject.Properties.Remove($name) } }
    Write-File $f.Path (ConvertTo-Json $legacy -Depth 32)
    $detached=Read-DataSafeTransaction $f.Path
    Assert-True ($detached.formatVersion -eq 1) 'Legacy strict read failed.'
    Assert-Throws { Invoke-DataSafeTransaction $detached } 'owner|live'
    Close-TestOwners
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Legacy recovery failed.'
    $upgraded=Read-DataSafeTransaction $f.Path
    Assert-True ($upgraded.formatVersion -eq 2 -and $upgraded.pointerCaptured -and $upgraded.destinationFileSystem -ceq 'NTFS' -and $upgraded.timestampToleranceTicks -eq 0) 'Owned upgrade lost strict destination/pointer authority.'
  }
  Test-Case 'rollback journal-write boundaries reconcile repeated failures idempotently' {
    $originalWriter = ${function:Write-DataSafeTransactionJournal}
    $script:rollbackWrites = 0; $script:rollbackFault = 0
    try {
      function Write-DataSafeTransactionJournal($Transaction, [string]$Path, [switch]$CreateOnly) {
        if ($Transaction.state -in @('rollingBack','rolledBack')) {
          $script:rollbackWrites++
          if ($script:rollbackFault -eq $script:rollbackWrites) { throw 'injected rollback write failure' }
        }
        & $originalWriter $Transaction $Path -CreateOnly:$CreateOnly
      }
      $f = New-Fixture
      Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -eq 'promote-filesystem') { throw 'crash' } } } crash
      [IO.File]::Delete(@($f.Tx.operations | Where-Object { $_.stagedPath -and (Test-DataSafeFile $_.stagedPath) })[-1].stagedPath)
      Close-TestOwners; $null = Recover-DataSafeTransaction $f.Repo $f.Path
      $total = $script:rollbackWrites
      Assert-True ($total -gt 3) 'Rollback did not expose journal boundaries.'
      for ($point=1; $point -le $total; $point++) {
        $script:rollbackFault = 0; $f = New-Fixture
        Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -eq 'promote-filesystem') { throw 'crash' } } } crash
        [IO.File]::Delete(@($f.Tx.operations | Where-Object { $_.stagedPath -and (Test-DataSafeFile $_.stagedPath) })[-1].stagedPath)
        Close-TestOwners
        $script:rollbackWrites=0; $script:rollbackFault=$point
        Assert-Throws { Recover-DataSafeTransaction $f.Repo $f.Path } 'injected rollback write failure'
        $script:rollbackFault=0
        Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'rolledBack') "Rollback boundary $point not recoverable."
        Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'rolledBack') 'Repeated rollback not idempotent.'
      }
      Write-Host "Rollback boundaries checked: $total"
    } finally { ${function:Write-DataSafeTransactionJournal} = $originalWriter }
  }
  foreach ($transition in @('directory-file','file-directory')) {
    Test-Case "partial new directory rollback restores dependency tree $transition" {
      $f = New-Fixture -Transition $transition
      Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -eq 'promote-filesystem') { throw 'crash' } } } crash
      $remaining = @($f.Tx.operations | Where-Object { $_.stagedPath -and (Test-DataSafeFile $_.stagedPath) })[-1]
      [IO.File]::Delete($remaining.stagedPath); Close-TestOwners
      Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'rolledBack') 'Dependency rollback failed.'
      foreach ($entry in $f.Old.entries) { Assert-True (Test-DataSafeTransactionObject (Join-Path $f.Repo.Root $entry.versionLocation) $entry -Metadata) 'Previous directory tree not restored.' }
    }
  }
} finally { Close-TestOwners; Remove-DataSafeDirectoryTree $tempRoot }
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
Write-Host "Result: $passes passed; $($failures.Count) failed."
if ($failures.Count) { exit 1 }

param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'), [string]$CasePattern = '.')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passes = New-Object 'System.Collections.Generic.List[string]'
$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '.') {
  try { & $Action | Out-Null } catch {
    if ($_.Exception -is [Management.Automation.CommandNotFoundException]) { throw }
    Assert-True ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)"
    return
  }
  throw 'Expected rejection, but operation succeeded.'
}
function Test-Case([string]$Name, [scriptblock]$Action) {
  if ($Name -notmatch $CasePattern) { return }
  try { & $Action; $passes.Add($Name) } catch { $failures.Add("${Name}: $($_.Exception.Message)") }
  finally {
    foreach ($owner in @($script:DataSafeTransactionOwners.Values)) {
      # Test-only process-loss cleanup: invalid schema/absent-baseline fixtures
      # must not manufacture a rolledBack journal just to close their handles.
      if ($null -ne $owner.Handle) {
        Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath)
        $owner.Handle=$null
      }
    }
    $script:live.Clear()
  }
}
. (Join-Path $WindowsRoot 'DataSafe.IncrementalPlan.ps1')
$library = Join-Path $WindowsRoot 'DataSafe.Transaction.ps1'
if (Test-Path -LiteralPath $library) { . $library }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-transaction-tests-' + [guid]::NewGuid().ToString('N'))
Ensure-DataSafeDirectory $tempRoot
$script:live = New-Object 'System.Collections.Generic.List[object]'
function Write-TestFile([string]$Path, [string]$Text) {
  Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Path))
  [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $Path), $Text, (New-Object Text.UTF8Encoding($false)))
}
function New-Fixture([switch]$Mixed, [switch]$Long) {
  $root = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
  if ($Long) { 1..7 | ForEach-Object { $root = Join-Path $root ('segment-' + ('x' * 30)) } }
  Ensure-DataSafeDirectory $root
  $repo = Initialize-DataSafeRepository $root 'Transaction PC' ([guid]::NewGuid().ToString('D'))
  $source = Join-Path $root 'source'
  Write-TestFile (Join-Path $source 'a.txt') 'abc'
  $job = [PSCustomObject]@{ id = 'docs'; path = $source; name = 'Documents' }
  $previous = $null
  if ($Mixed) {
    foreach ($name in @('b.txt','c.txt','d.txt','e.txt','f.txt')) { Write-TestFile (Join-Path $source $name) 'old' }
    $previous = New-DataSafeSourceManifest @($job)
    Write-TestFile (Join-Path $source 'a.txt') 'replacement'
    [IO.File]::SetLastWriteTimeUtc((ConvertTo-DataSafeExtendedPath (Join-Path $source 'b.txt')), [datetime]::UtcNow.AddDays(-1))
    [IO.File]::Delete((ConvertTo-DataSafeExtendedPath (Join-Path $source 'c.txt')))
    Write-TestFile (Join-Path $source 'new.txt') 'new'
    Ensure-DataSafeDirectory (Join-Path $source 'empty')
  }
  $manifest = New-DataSafeSourceManifest @($job) $previous
  $cap = Get-DataSafeFilesystemCapabilities 'NTFS'; $cap | Add-Member TotalBytes ([long]20GB)
  $plan = New-DataSafeIncrementalPlan $repo $previous $manifest $cap 100GB
  Assert-True ($plan.BlockingErrors.Count -eq 0 -and -not $plan.DeletionReviewRequired) 'Fixture plan failed.'
  [PSCustomObject]@{ Root = $root; Repo = $repo; Source = $source; Manifest = $manifest; Plan = $plan }
}
function Start-Transaction($Fixture) {
  $tx = New-DataSafeTransaction $Fixture.Repo $Fixture.Plan
  $script:live.Add($tx)
  return $tx
}
function Get-JournalPath($Fixture) { Join-Path $Fixture.Repo.TransactionRoot ($Fixture.Plan.TransactionId + '.json') }
function Read-JournalText($Fixture) { [IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath (Get-JournalPath $Fixture))) }
function Write-JournalObject($Fixture, $Value) { Write-TestFile (Get-JournalPath $Fixture) (ConvertTo-Json -InputObject $Value -Depth 32) }
try {
  Test-Case 'transaction UUID case normalizes before canonical pointer publication' {
    $f=New-Fixture; $f.Plan.TransactionId=$f.Plan.TransactionId.ToUpperInvariant()
    $tx=Start-Transaction $f; $null=Stage-DataSafeTransaction $tx
    Assert-True ((Invoke-DataSafeTransaction $tx).FinalState -ceq 'committed') 'Uppercase UUID plan could not commit.'
    Assert-True ($tx.transactionId -ceq $f.Plan.TransactionId.ToLowerInvariant() -and (Read-DataSafeCurrentPointer $f.Repo).transactionId -ceq $tx.transactionId) 'UUID/pointer canonical identity diverged.'
  }
  Test-Case 'portable source flags stage and strict journal binds bounded media policy' {
    $f=New-Fixture
    $path=Join-Path $f.Source a.txt
    [IO.File]::SetAttributes($path, [IO.FileAttributes]([long][IO.File]::GetAttributes($path) -bor 256))
    $job=[PSCustomObject]@{id='docs';path=$f.Source;name='Documents'}
    $f.Manifest=New-DataSafeSourceManifest @($job)
    $cap=Get-DataSafeFilesystemCapabilities NTFS; $cap | Add-Member TotalBytes ([long]20GB)
    $f.Plan=New-DataSafeIncrementalPlan $f.Repo $null $f.Manifest $cap 100GB
    $tx=Start-Transaction $f
    Assert-True ($tx.formatVersion -eq 3 -and $null -eq $tx.mutationIntent -and $tx.destinationFileSystem -ceq 'NTFS' -and $tx.timestampToleranceTicks -eq 0 -and -not $tx.pointerCaptured) 'Strict media policy/nullable mutation intent missing from v3 journal.'
    Assert-True (($tx.currentManifest.entries[0].attributes -band 256) -eq 0) 'Temporary source flag persisted.'
    $null=Stage-DataSafeTransaction $tx
    $j=Read-DataSafeTransaction (Get-JournalPath $f); $j.timestampToleranceTicks=1
    try { Write-JournalObject $f $j; Assert-Throws { Read-DataSafeTransaction (Get-JournalPath $f) } 'timestamp|granularity|policy' }
    finally { Write-JournalObject $f $tx }
  }
  Test-Case 'apply verifies and commits an extended Unicode-capable long path' {
    $f = New-Fixture -Long; $tx = Start-Transaction $f
    $null = Stage-DataSafeTransaction $tx
    $r = Invoke-DataSafeTransaction $tx
    Assert-True ($r.FinalState -ceq 'committed' -and (Get-DataSafeSha256 $tx.operations[0].currentPath) -ceq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'Long-path apply lost content.'
    Assert-True ((Read-DataSafeCurrentPointer $f.Repo).transactionId -ceq $tx.transactionId) 'Long-path pointer absent.'
  }
  foreach ($direction in @('directory-to-file','file-to-directory')) {
    Test-Case "review type replacement $direction keeps old and new descendant trees separate" {
      $f = New-Fixture
      foreach ($name in @('keep1.txt','keep2.txt','keep3.txt')) { Write-TestFile (Join-Path $f.Source $name) 'keep' }
      $foo = Join-Path $f.Source 'foo'
      if ($direction -ceq 'directory-to-file') { Write-TestFile (Join-Path $foo 'bar.txt') 'child' }
      else { Write-TestFile $foo 'old file' }
      $job = [PSCustomObject]@{ id = 'docs'; path = $f.Source; name = 'Documents' }
      $old = New-DataSafeSourceManifest @($job)
      if ($direction -ceq 'directory-to-file') { Remove-DataSafeDirectoryTree $foo; Write-TestFile $foo 'new file' }
      else { [IO.File]::Delete($foo); Write-TestFile (Join-Path $foo 'bar.txt') 'child' }
      $new = New-DataSafeSourceManifest @($job) $old
      $cap = Get-DataSafeFilesystemCapabilities 'NTFS'; $cap | Add-Member TotalBytes ([long]20GB)
      $f.Plan = New-DataSafeIncrementalPlan $f.Repo $old $new $cap 100GB
      Assert-True ($f.Plan.BlockingErrors.Count -eq 0 -and -not $f.Plan.DeletionReviewRequired) 'Valid type-replacement plan was blocked.'
      Assert-True (($f.Plan.Operations.relativePath -join ',') -ceq 'foo,foo/bar.txt' -and ($f.Plan.Operations.sequence -join ',') -ceq '1,2') 'Operation order/schema correspondence changed.'
      Assert-True (($f.Plan.Operations.kind -join ',') -ceq $(if ($direction -ceq 'directory-to-file') { 'replace,delete' } else { 'replace,add' })) 'Wrong type-change operations.'
      $tx = Start-Transaction $f; $null = Stage-DataSafeTransaction $tx
      $disk = Read-DataSafeTransaction (Get-JournalPath $f)
      Assert-True ($disk.state -ceq 'prepared' -and ($disk.operations.status -join ',') -ceq 'verified,verified') 'Valid replacement could not prepare.'
      Assert-True (@($disk.operations | Where-Object { $_.stagedPath }).Count -eq 1) 'Directory or deletion staged content.'
      Assert-True ([IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $f.Repo.LatestRoot)).Count -eq 0 -and [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $f.Repo.HistoryRoot)).Count -eq 0) 'Staging modified current/history roots.'
    }
  }
  Test-Case 'review duplicate UUID in independent repositories preserves both live owners and locks' {
    $one = New-Fixture; $two = New-Fixture
    $two.Plan.TransactionId = $one.Plan.TransactionId
    foreach ($op in $two.Plan.Operations) {
      if ($op.stagedPath) { $op.stagedPath = Join-Path (Join-Path $two.Repo.StagingRoot $two.Plan.TransactionId) $op.newEntry.versionLocation.Substring(14) }
    }
    $owners = New-Object 'System.Collections.Generic.List[object]'
    try {
      $first = Start-Transaction $one; $owners.Add((Get-DataSafeTransactionOwner $first))
      $second = Start-Transaction $two; $owners.Add((Get-DataSafeTransactionOwner $second))
      $null = Stage-DataSafeTransaction $first; $null = Stage-DataSafeTransaction $second
      Assert-True ($first.state -ceq 'prepared' -and $second.state -ceq 'prepared') 'Duplicate UUID stranded an independent live owner.'
      Set-DataSafeTransactionState $first rollingBack; Set-DataSafeTransactionState $first rolledBack
      Assert-Throws { New-DataSafeTransaction $two.Repo $two.Plan } 'already running'
      Set-DataSafeTransactionState $first rolledBack
      Assert-Throws { New-DataSafeTransaction $two.Repo $two.Plan } 'already running'
      Set-DataSafeTransactionState $second rollingBack; Set-DataSafeTransactionState $second rolledBack
      foreach ($f in @($one,$two)) {
        $lock = Join-Path $f.Repo.MetadataRoot 'operation.lock'
        $handle = Acquire-DataSafeOperationLock (ConvertTo-DataSafeExtendedPath $lock)
        Release-DataSafeOperationLock $handle (ConvertTo-DataSafeExtendedPath $lock)
      }
    } finally {
      # Retain these exact handles for RED cleanup even if the old UUID-only
      # registry loses the first context. Never release another owner's path.
      foreach ($owner in $owners) {
        if ($null -ne $owner.Handle -and $owner.Handle.CanWrite) {
          Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath)
          $owner.Handle = $null
        }
      }
      $script:live.Clear()
    }
  }
  Test-Case 'review ownership canonicalizes case slash extended aliases without granting forged authority' {
    $f = New-Fixture; $tx = Start-Transaction $f
    $key = Get-DataSafeTransactionOwnerKey $f.Repo.Root $f.Repo.ComputerId $tx.transactionId
    foreach ($alias in @($f.Repo.Root.ToUpperInvariant(), $f.Repo.Root.Replace('\','/'), (ConvertTo-DataSafeExtendedPath $f.Repo.Root))) {
      Assert-True ((Get-DataSafeTransactionOwnerKey $alias $f.Repo.ComputerId.ToUpperInvariant() $tx.transactionId.ToUpperInvariant()) -ceq $key) 'A physical root/UUID alias changed the ownership key.'
    }
    $aliasRepo = Read-DataSafeRepository $f.Repo.Root.ToUpperInvariant()
    Assert-Throws { New-DataSafeTransaction $aliasRepo $f.Plan } 'already running'
    $aliasRepo.Root = $f.Repo.Root.Replace('\','/')
    Assert-Throws { New-DataSafeTransaction $aliasRepo $f.Plan } 'already running|repository.*mismatch'
    $aliasRepo.Root = ConvertTo-DataSafeExtendedPath $f.Repo.Root
    Assert-Throws { New-DataSafeTransaction $aliasRepo $f.Plan } 'repository.*mismatch|prefix|path'
    $bad = Read-DataSafeRepository $f.Repo.Root; $bad.ComputerId = [guid]::NewGuid().ToString('D')
    Assert-Throws { New-DataSafeTransaction $bad $f.Plan } 'repository.*mismatch|identity'
    $forged = Read-DataSafeTransaction (Get-JournalPath $f); $forged.computerId = $bad.ComputerId
    Assert-Throws { Stage-DataSafeTransaction $forged } 'live|owner|identity'
    $null = Stage-DataSafeTransaction $tx
  }
  foreach ($state in @('staging','prepared','applying','committed','rollingBack','rolledBack')) {
    Test-Case "review empty-operation $state journal enforces transaction-level failure invariant" {
      $f = New-Fixture; $cap = Get-DataSafeFilesystemCapabilities 'NTFS'; $cap | Add-Member TotalBytes ([long]20GB)
      $f.Plan = New-DataSafeIncrementalPlan $f.Repo $f.Manifest $f.Manifest $cap 100GB
      $tx = Start-Transaction $f; $j = Read-DataSafeTransaction (Get-JournalPath $f)
      try {
        $j.state = $state; Write-JournalObject $f $j
        Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -ceq $state) 'Valid empty journal failed round-trip.'
        $j.failure = 'failed'; Write-JournalObject $f $j
        if ($state -cin @('prepared','applying','committed')) {
          Assert-Throws { Read-DataSafeTransaction (Get-JournalPath $f) } 'failure|state|prepared'
        } else {
          Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).failure -ceq 'failed') 'Failure-bearing non-success journal could not round-trip.'
        }
      } finally { Write-JournalObject $f $tx }
    }
  }
  foreach ($terminal in @('rolledBack','committed')) {
    Test-Case "review terminal $terminal idempotence rejects caller detached and durable state mutations" {
      $f = New-Fixture; $tx = Start-Transaction $f; $null = Stage-DataSafeTransaction $tx
      $other = if ($terminal -ceq 'rolledBack') { 'committed' } else { 'rolledBack' }
      $preparedJson = Read-JournalText $f
      try {
        $tx.state = $other
        Assert-Throws { Set-DataSafeTransactionState $tx $other } 'metadata|state|live|owner'
      } finally { $tx.state = 'prepared' }
      Assert-True ((Read-JournalText $f) -ceq $preparedJson) 'Mutated live caller changed durable state.'
      Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'already running'
      if ($terminal -ceq 'committed') { $null = Invoke-DataSafeTransaction $tx }
      else { Set-DataSafeTransactionState $tx rollingBack; Set-DataSafeTransactionState $tx rolledBack }
      $terminalJson = Read-JournalText $f
      try {
        $tx.state = $other
        Assert-Throws { Set-DataSafeTransactionState $tx $other } 'metadata|state|live|owner|terminal'
      } finally { $tx.state = $terminal }
      $detached = Read-DataSafeTransaction (Get-JournalPath $f)
      Assert-Throws { Set-DataSafeTransactionState $detached $terminal } 'live|owner|terminal'
      $detached.state = $other
      Assert-Throws { Set-DataSafeTransactionState $detached $other } 'live|owner|terminal'
      Assert-True ((Read-JournalText $f) -ceq $terminalJson) 'Detached or mutated terminal caller changed disk.'
      try {
        $disk = Read-DataSafeTransaction (Get-JournalPath $f); $disk.state = $other
        Write-JournalObject $f $disk
        Assert-Throws { Set-DataSafeTransactionState $tx $terminal } 'metadata|state|durable|terminal'
        Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -ceq $other) 'Terminal validation rewrote tampered disk.'
      } finally { Write-TestFile (Get-JournalPath $f) $terminalJson }
      Set-DataSafeTransactionState $tx $terminal
      Assert-True ((Read-JournalText $f) -ceq $terminalJson) 'Valid terminal idempotence rewrote the journal.'
    }
  }
  foreach ($manifestName in @('previousManifest','currentManifest')) {
    foreach ($depth in @('manifest','source','entry','sourceError')) {
      Test-Case "review strict $manifestName rejects unknown nested field at $depth depth" {
        $f = New-Fixture -Mixed; $tx = Start-Transaction $f; $j = Read-DataSafeTransaction (Get-JournalPath $f)
        try {
          $manifest = $j.$manifestName
          switch ($depth) {
            manifest { $target = $manifest }
            source { $target = $manifest.sources[0] }
            entry { $target = $manifest.entries[0] }
            sourceError {
              $manifest.entries = @()
              $manifest.sourceErrors = @([PSCustomObject]@{ sourceId = 'docs'; path = $f.Source; message = 'unavailable' })
              $target = $manifest.sourceErrors[0]
            }
          }
          $target | Add-Member -NotePropertyName unrecognized -NotePropertyValue 'must not survive a strict read'
          Write-JournalObject $f $j
          $before = Read-JournalText $f
          Assert-Throws { Read-DataSafeTransaction (Get-JournalPath $f) } 'unknown field: unrecognized'
          Assert-True ((Read-JournalText $f) -ceq $before) 'Reader rewrote rejected nested metadata.'
        } finally { Write-JournalObject $f $tx }
      }
    }
  }
  Test-Case 'review canonical manifest creation and round-trip preserve only documented nested fields' {
    $f = New-Fixture -Mixed
    foreach ($name in @('PreviousManifest','CurrentManifest')) {
      $f.Plan.$name | Add-Member extension 'discard top extension'
      $f.Plan.$name.sources[0] | Add-Member extension 'discard source extension'
      # Use an unchanged entry: changed entries also belong to the already
      # strict operation snapshots and are not an extensible input boundary.
      @($f.Plan.$name.entries | Where-Object { $_.relativePath -ceq 'd.txt' })[0] | Add-Member extension 'discard entry extension'
    }
    $tx = Start-Transaction $f; $disk = Read-DataSafeTransaction (Get-JournalPath $f)
    foreach ($name in @('previousManifest','currentManifest')) {
      Assert-True (($disk.$name.PSObject.Properties.Name -join ',') -ceq 'schema,formatVersion,createdUtc,sources,entries,sourceErrors') 'Manifest extension survived canonical persistence.'
      Assert-True (($disk.$name.sources[0].PSObject.Properties.Name -join ',') -ceq 'sourceId,path,relativeDestination') 'Source extension survived canonical persistence.'
      Assert-True (($disk.$name.entries[0].PSObject.Properties.Name -join ',') -ceq 'sourceId,relativePath,entryType,length,modifiedUtc,attributes,sha256,versionLocation') 'Entry extension survived canonical persistence.'
    }
    Assert-True ((Read-JournalText $f) -notmatch 'discard .* extension') 'Unknown metadata was serialized.'
  }
  Test-Case 'complete manifests round-trip unchanged entries and are isolated from caller mutation' {
    $f = New-Fixture -Mixed; $tx = Start-Transaction $f
    Assert-True ($null -ne $tx.PSObject.Properties['currentManifest'] -and $null -ne $tx.PSObject.Properties['previousManifest']) 'Durable full manifests are absent.'
    $f.Plan.CurrentManifest.entries[0].sha256 = 'F' * 64
    $disk = Read-DataSafeTransaction (Get-JournalPath $f)
    Assert-True ($disk.previousManifest.entries.Count -eq 6 -and $disk.currentManifest.entries.Count -eq 7 -and $disk.operations.Count -eq 5) 'Complete baseline or unchanged entries lost.'
    Assert-True ($disk.currentManifest.entries[0].sha256 -ceq '95713E9CBDD1DFCB2D4080C2537F418D43CA0DA25F0D7D6631F4F7C97B89DC47') 'Current manifest changed through caller alias.'
  }
  Test-Case 'only add and replace files stage ordinary verified bytes with complete durable operation records' {
    $f = New-Fixture -Mixed
    Write-TestFile (Join-Path $f.Repo.LatestRoot 'sentinel.txt') 'committed'
    Write-TestFile (Join-Path $f.Repo.HistoryRoot 'sentinel.txt') 'history'
    $tx = Start-Transaction $f
    $stagedReads = New-Object 'System.Collections.Generic.HashSet[string]'
    $result = Stage-DataSafeTransaction $tx { param($p)
      if ($p.StartsWith($f.Repo.StagingRoot, [StringComparison]::OrdinalIgnoreCase)) { $null = $stagedReads.Add($p) }
      Get-DataSafeSha256 $p
    }
    $loaded = Read-DataSafeTransaction (Get-JournalPath $f)
    Assert-True ($result.state -ceq 'prepared' -and $loaded.state -ceq 'prepared') 'Verified transaction not prepared.'
    Assert-True ($loaded.operations.Count -eq 5 -and $stagedReads.Count -eq 2) 'Wrong operation count or staged read-back count.'
    Assert-True (@([IO.Directory]::GetFiles((ConvertTo-DataSafeExtendedPath (Join-Path $f.Repo.StagingRoot $tx.transactionId)), '*', [IO.SearchOption]::AllDirectories)).Count -eq 2) 'Non-content operation copied bytes.'
    foreach ($op in $loaded.operations) {
      Assert-True ($op.status -ceq 'verified') 'Operation status not durable.'
      foreach ($name in @('sequence','kind','sourceId','relativePath','sourcePath','currentPath','oldCurrentPath','historyPath','stagedPath','expectedOldSha256','expectedNewSha256','oldEntry','newEntry','status')) {
        Assert-True ($null -ne $op.PSObject.Properties[$name]) "Missing journal field $name"
      }
      if ($op.stagedPath) { Assert-True ((Get-DataSafeSha256 $op.stagedPath) -ceq $op.expectedNewSha256) 'Staged bytes differ.' }
    }
    Assert-True ([IO.File]::ReadAllText((Join-Path $f.Repo.LatestRoot 'sentinel.txt')) -ceq 'committed') 'Latest changed.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $f.Repo.HistoryRoot 'sentinel.txt')) -ceq 'history') 'History changed.'
    Assert-Throws { Stage-DataSafeTransaction (Read-DataSafeTransaction (Get-JournalPath $f)) } 'live|lock|owner'
  }
  foreach ($change in @('content','length','mtime','attributes','type')) {
    Test-Case "source $change change after scan blocks preparation and durably records failure" {
      $f = New-Fixture; $tx = Start-Transaction $f; $path = Join-Path $f.Source 'a.txt'
      switch ($change) {
        content { $time = [IO.File]::GetLastWriteTimeUtc($path); Write-TestFile $path 'xyz'; [IO.File]::SetLastWriteTimeUtc($path, $time) }
        length { Write-TestFile $path 'longer' }
        mtime { [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddDays(-1)) }
        attributes { [IO.File]::SetAttributes($path, [IO.FileAttributes]::Hidden) }
        type { [IO.File]::Delete($path); Ensure-DataSafeDirectory $path }
      }
      Assert-Throws { Stage-DataSafeTransaction $tx } 'source|changed|hash|snapshot'
      $loaded = Read-DataSafeTransaction (Get-JournalPath $f)
      Assert-True ($loaded.state -cne 'prepared' -and $loaded.operations[0].status -ceq 'failed' -and $loaded.failure.Length -gt 0) 'Failure/status not durable.'
    }
  }
  Test-Case 'source mutation during hashing is rechecked after copying' {
    $f = New-Fixture; $tx = Start-Transaction $f; $script:mutated = $false
    Assert-Throws { Stage-DataSafeTransaction $tx { param($p)
      $hash = Get-DataSafeSha256 $p
      if (-not $script:mutated) { $script:mutated = $true; Write-TestFile $p 'xyz' }
      $hash
    } } 'source|changed|hash|snapshot'
    Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -cne 'prepared') 'Racing source prepared.'
  }
  Test-Case 'corrupt staged copy cannot be prepared even when source is unchanged' {
    $f = New-Fixture; $tx = Start-Transaction $f
    Assert-Throws { Stage-DataSafeTransaction $tx { param($p)
      if ($p.StartsWith($f.Repo.StagingRoot, [StringComparison]::OrdinalIgnoreCase)) { Write-TestFile $p 'corrupt' }
      Get-DataSafeSha256 $p
    } } 'staged|hash|length'
    Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).operations[0].status -ceq 'failed') 'Corruption not journaled.'
  }
  Test-Case 'forced provider exception leaves readable non-prepared journal and existing backup untouched' {
    $f = New-Fixture; Write-TestFile (Join-Path $f.Repo.LatestRoot 'old.txt') 'old'; $tx = Start-Transaction $f
    Assert-Throws { Stage-DataSafeTransaction $tx { throw 'forced staging exception' } } 'forced staging exception'
    $disk = Read-DataSafeTransaction (Get-JournalPath $f)
    Assert-True ($disk.state -ceq 'staging' -and $disk.failure -match 'forced staging exception' -and $disk.operations[0].status -ceq 'failed') 'Exception lost durable diagnostics.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $f.Repo.LatestRoot 'old.txt')) -ceq 'old') 'Old committed file changed.'
  }
  Test-Case 'late forced exception preserves earlier verified operation statuses durably' {
    $f = New-Fixture -Mixed; $tx = Start-Transaction $f
    Assert-Throws { Stage-DataSafeTransaction $tx { param($p)
      if ($p -ieq (Join-Path $f.Source 'new.txt')) { throw 'late forced exception' }
      Get-DataSafeSha256 $p
    } } 'late forced exception'
    $disk = Read-DataSafeTransaction (Get-JournalPath $f)
    Assert-True ($disk.state -ceq 'staging' -and ($disk.operations.status -join ',') -ceq 'verified,verified,verified,verified,failed') 'Complete durable operation progress was lost.'
    Assert-True ([IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $f.Repo.LatestRoot)).Count -eq 0 -and [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $f.Repo.HistoryRoot)).Count -eq 0) 'Failure changed ordinary-file roots.'
  }
  Test-Case 'exclusive lock persists through prepared and is released only by owning terminal transition' {
    $f = New-Fixture; $tx = Start-Transaction $f
    Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'already running'
    $null = Stage-DataSafeTransaction $tx
    Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'already running'
    $disk = Read-DataSafeTransaction (Get-JournalPath $f)
    Assert-Throws { Set-DataSafeTransactionState $disk rollingBack } 'live|lock|owner'
    Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'already running'
    Set-DataSafeTransactionState $tx rollingBack; Set-DataSafeTransactionState $tx rolledBack
    $next = New-Fixture
    $next.Plan.TransactionId = [guid]::NewGuid().ToString('D')
    $next.Plan = New-DataSafeIncrementalPlan $f.Repo $null $next.Manifest ((Get-DataSafeDestinationCapabilities $f.Repo.Root)) 100GB
    $second = New-DataSafeTransaction $f.Repo $next.Plan; $script:live.Add($second)
    Set-DataSafeTransactionState $tx rolledBack
    Assert-Throws { New-DataSafeTransaction $f.Repo $next.Plan } 'already running'
  }
  Test-Case 'state graph blocks unsafe preparation skipped backward and unknown transitions' {
    $f = New-Fixture; $tx = Start-Transaction $f
    foreach ($state in @('prepared','applying','committed','rolledBack','bogus')) { Assert-Throws { Set-DataSafeTransactionState $tx $state } 'state|transition|staging' }
    $null = Stage-DataSafeTransaction $tx
    Set-DataSafeTransactionState $tx prepared
    Assert-Throws { Set-DataSafeTransactionState $tx committed } 'transition'
    Set-DataSafeTransactionState $tx applying; Set-DataSafeTransactionState $tx applying
    Assert-Throws { Set-DataSafeTransactionState $tx prepared } 'transition'
    Assert-Throws { Set-DataSafeTransactionState $tx committed } 'pointer'
    $null = Invoke-DataSafeTransaction $tx; Set-DataSafeTransactionState $tx committed
    Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -ceq 'committed') 'Legal graph not durable.'
    Assert-Throws { Set-DataSafeTransactionState $tx rollingBack } 'transition|terminal|live|lock'
  }
  Test-Case 'locked source prevents preparation' {
    $f = New-Fixture; $tx = Start-Transaction $f
    $handle = [IO.File]::Open((Join-Path $f.Source 'a.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { Assert-Throws { Stage-DataSafeTransaction $tx } 'process|sharing|used|access' } finally { $handle.Dispose() }
    Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -cne 'prepared') 'Locked source prepared.'
  }
  Test-Case 'ancestor junction substituted after creation is not followed' {
    $f = New-Fixture; $tx = Start-Transaction $f; $moved = $f.Source + '-original'
    [IO.Directory]::Move($f.Source, $moved)
    New-Item -ItemType Junction -Path $f.Source -Target $moved | Out-Null
    try { Assert-Throws { Stage-DataSafeTransaction $tx } 'reparse' }
    finally { [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $f.Source)) }
    Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -cne 'prepared') 'Junction was followed.'
  }
  Test-Case 'file replaced by reparse point is rejected without traversing its target' {
    $f = New-Fixture; $tx = Start-Transaction $f; $path = Join-Path $f.Source 'a.txt'
    [IO.File]::Delete($path)
    New-Item -ItemType Junction -Path $path -Target $f.Repo.LatestRoot | Out-Null
    try { Assert-Throws { Stage-DataSafeTransaction $tx } 'reparse' }
    finally { [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $path)) }
  }
  Test-Case 'long source repository staging and journal paths are supported' {
    $f = New-Fixture -Long; $tx = Start-Transaction $f; $null = Stage-DataSafeTransaction $tx
    Assert-True ($tx.operations[0].stagedPath.Length -gt 260 -and (Read-DataSafeTransaction (Get-JournalPath $f)).state -ceq 'prepared') 'Long paths failed.'
  }
  Test-Case 'two sources with the same relative filename receive independent staged paths' {
    $f = New-Fixture; $other = Join-Path $f.Root 'other'; Write-TestFile (Join-Path $other 'a.txt') 'xyz'
    $m = New-DataSafeSourceManifest @([PSCustomObject]@{ id = 'one'; path = $f.Source; name = 'One' }, [PSCustomObject]@{ id = 'two'; path = $other; name = 'Two' })
    $cap = Get-DataSafeDestinationCapabilities $f.Repo.Root
    $f.Plan = New-DataSafeIncrementalPlan $f.Repo $null $m $cap 100GB
    $tx = Start-Transaction $f; $null = Stage-DataSafeTransaction $tx
    Assert-True ($tx.operations[0].stagedPath -ine $tx.operations[1].stagedPath -and (Get-DataSafeSha256 $tx.operations[0].stagedPath) -cne (Get-DataSafeSha256 $tx.operations[1].stagedPath)) 'Sources collided.'
  }
  Test-Case 'reused journal staging root and staged destination never overwrite existing bytes' {
    $f = New-Fixture; $tx = Start-Transaction $f
    Write-TestFile $tx.operations[0].stagedPath 'occupied'
    Assert-Throws { Stage-DataSafeTransaction $tx } 'exist|collision|occupied'
    Assert-True ([IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $tx.operations[0].stagedPath)) -ceq 'occupied') 'Staging collision overwritten.'
    Set-DataSafeTransactionState $tx rollingBack; Set-DataSafeTransactionState $tx rolledBack
    $before = Read-JournalText $f
    Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'exist|collision|occupied'
    Assert-True ((Read-JournalText $f) -ceq $before) 'Journal reused.'
    $f = New-Fixture
    Ensure-DataSafeDirectory (Join-Path $f.Repo.StagingRoot $f.Plan.TransactionId)
    Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'exist|collision|occupied'
  }
  foreach ($mutate in @(
    { param($p) $p.BlockingErrors = @('blocked') }, { param($p) $p.DeletionReviewRequired = $true },
    { param($p) $p.Operations += $p.Operations[0] }, { param($p) $p.Operations[0].currentPath = (Join-Path $tempRoot 'escape') },
    { param($p) $p.Operations[0].stagedPath = (Join-Path $tempRoot 'escape') }, { param($p) $p.Operations[0].sourcePath = 'relative' },
    { param($p) $p.Operations[0].kind = 'bogus' }, { param($p) $p.Operations[0].PSObject.Properties.Remove('oldEntry') },
    { param($p) $p.Operations[0].expectedNewSha256 = ('F' * 64) }, { param($p) $p.Operations[0].sequence = @(1) },
    { param($p) $p.MetadataOverheadBytes = [long]1 }, { param($p) $p.PeakRequiredBytes = [long]0 }
  )) {
    Test-Case "invalid or gated plan cannot create transaction: $mutate" {
      $f = New-Fixture; & $mutate $f.Plan
      Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'plan|schema|path|operation|metadata|space|review|blocked|duplicate|sequence|hash'
      Assert-True (-not (Test-DataSafeFile (Get-JournalPath $f))) 'Invalid plan published journal.'
    }
  }
  Test-Case 'repository identity and history-name availability are checked under lock' {
    $f = New-Fixture; $f.Repo.ComputerId = [guid]::NewGuid().ToString('D')
    Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'identity|repository'
    $f = New-Fixture -Mixed; Ensure-DataSafeDirectory (Join-Path $f.Repo.HistoryRoot $f.Plan.DisplayHistoryFolder)
    Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'history|occupied|exist'
    $f = New-Fixture -Mixed; $tx = Start-Transaction $f
    Ensure-DataSafeDirectory (Join-Path $f.Repo.HistoryRoot $f.Plan.DisplayHistoryFolder)
    Assert-Throws { Stage-DataSafeTransaction $tx } 'history|occupied|exist'
    Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -cne 'prepared') 'Occupied history prepared.'
  }
  Test-Case 'changed actual free space is rechecked before creation and staging' {
    $f = New-Fixture
    $original = ${function:Get-DataSafeFreeBytes}
    try {
      function Get-DataSafeFreeBytes([string]$Path) { return [long]0 }
      Assert-Throws { New-DataSafeTransaction $f.Repo $f.Plan } 'space'
    } finally { ${function:Get-DataSafeFreeBytes} = $original }
    $tx = Start-Transaction $f
    try {
      function Get-DataSafeFreeBytes([string]$Path) { return [long]0 }
      Assert-Throws { Stage-DataSafeTransaction $tx } 'space'
    } finally { ${function:Get-DataSafeFreeBytes} = $original }
    Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -cne 'prepared') 'Full drive prepared.'
  }
  Test-Case 'complete serialized metadata must fit the original plan allowance' {
    $f = New-Fixture; $id = 'x' * 300000
    $f.Plan.CurrentManifest.sources[0].sourceId = $id
    $f.Plan.CurrentManifest.entries[0].sourceId = $id
    $f.Plan.Operations[0].sourceId = $id; $f.Plan.Operations[0].newEntry.sourceId = $id
    Assert-Throws { $null = Start-Transaction $f } 'metadata|allowance'
    Assert-True (-not (Test-DataSafeFile (Get-JournalPath $f))) 'Oversized metadata was published.'
  }
  Test-Case 'unchanged source disappearing after creation cannot prepare an empty operation set' {
    $f = New-Fixture; $cap = Get-DataSafeFilesystemCapabilities 'NTFS'; $cap | Add-Member TotalBytes ([long]20GB)
    $f.Plan = New-DataSafeIncrementalPlan $f.Repo $f.Manifest $f.Manifest $cap 100GB
    $tx = Start-Transaction $f
    [IO.Directory]::Move($f.Source, ($f.Source + '-gone'))
    Assert-Throws { Stage-DataSafeTransaction $tx } 'source|unavailable|find'
    Assert-True ((Read-DataSafeTransaction (Get-JournalPath $f)).state -cne 'prepared') 'Missing unchanged source prepared.'
  }
  foreach ($mutate in @(
    { param($j) $j.state = 'bogus' }, { param($j) $j.state = @('staging') },
    { param($j) $j.operations = $j.operations[0] }, { param($j) $j.operations[0].status = 'bogus' },
    { param($j) $j.operations[0].kind = 'bogus' }, { param($j) $j.operations[0].PSObject.Properties.Remove('sourcePath') },
    { param($j) $j.operations[0].sourcePath = @($j.operations[0].sourcePath) },
    { param($j) $j.operations[0].currentPath = (Join-Path $tempRoot 'escape') },
    { param($j) $j.transactionId = [guid]::NewGuid().ToString('D') },
    { param($j) $j.operations += $j.operations[0] }, { param($j) $j.state = 'prepared' }
    { param($j) $j.currentManifest = $null }, { param($j) $j.currentManifest = @($j.currentManifest) },
    { param($j) $j.currentManifest.entries[0].sha256 = 'F' * 64 },
    { param($j) $j.currentManifest.entries += $j.currentManifest.entries[0] },
    { param($j) $j.currentManifest.sources[0].path = (Join-Path $tempRoot 'other-source') }
  )) {
    Test-Case "strict journal reader rejects malformed durable data: $mutate" {
      $f = New-Fixture; $tx = Start-Transaction $f
      $j = Read-DataSafeTransaction (Get-JournalPath $f); & $mutate $j
      Write-JournalObject $f $j
      Assert-Throws { Read-DataSafeTransaction (Get-JournalPath $f) } 'schema|state|status|kind|field|path|UUID|transaction|duplicate|operation|prepared'
      # Restore the original document for normal owning cleanup.
      Write-JournalObject $f $tx
    }
  }
  Test-Case 'strict reader rejects duplicate JSON keys and malformed UTF8' {
    $f = New-Fixture; $tx = Start-Transaction $f
    $json = Read-JournalText $f
    try {
      $duplicate = $json -replace '"state"\s*:\s*"staging"', '"state":"staging","State":"prepared"'
      Assert-True ($duplicate -cne $json) 'Duplicate-key fixture did not change the document.'
      Write-TestFile (Get-JournalPath $f) $duplicate
      Assert-Throws { Read-DataSafeTransaction (Get-JournalPath $f) } 'duplicate'
      [IO.File]::WriteAllBytes((ConvertTo-DataSafeExtendedPath (Get-JournalPath $f)), [byte[]]@(123,34,120,34,58,34,255,34,125))
      Assert-Throws { Read-DataSafeTransaction (Get-JournalPath $f) } 'UTF|invalid|JSON'
    } finally { Write-TestFile (Get-JournalPath $f) $json }
  }
} finally {
  # Only this unique disposable root is removed; reparse fixtures remove their links first.
  Remove-DataSafeDirectoryTree $tempRoot
}
foreach ($name in $passes) { Write-Host "PASS: $name" }
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
Write-Host "Result: $($passes.Count) passed; $($failures.Count) failed."
if ($failures.Count -gt 0) { exit 1 }
exit 0

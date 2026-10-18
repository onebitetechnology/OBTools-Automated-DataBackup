param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'), [string]$CasePattern = '.')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $WindowsRoot 'DataSafe.Transaction.ps1')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-final-regression-' + [guid]::NewGuid().ToString('N'))
Ensure-DataSafeDirectory $tempRoot
$passes = 0; $failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch {
    if ($_.Exception -is [Management.Automation.CommandNotFoundException]) { throw }
    Assert-True ($_.Exception.Message -match $Pattern) $_.Exception.Message; return
  }
  throw 'Expected rejection.'
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
function Write-File([string]$Path, [string]$Text) {
  Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Path))
  [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $Path), $Text)
}
function New-Plan($Repo, $Old, $New) {
  $cap = Get-DataSafeFilesystemCapabilities NTFS; $cap | Add-Member TotalBytes ([long]20GB)
  $plan = New-DataSafeIncrementalPlan $Repo $Old $New $cap 100GB
  Assert-True ($plan.BlockingErrors.Count -eq 0 -and -not $plan.DeletionReviewRequired) 'Fixture plan blocked.'
  return $plan
}
function New-MetadataFixture([int]$FileCount) {
  $root = Join-Path $tempRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $root
  $repo = Initialize-DataSafeRepository $root 'Final Regression PC' ([guid]::NewGuid().ToString('D'))
  $source = Join-Path $root source
  foreach ($n in 1..$FileCount) { Write-File (Join-Path $source "nested/file-$n.txt") "literal-payload-$n" }
  $job = [PSCustomObject]@{id='docs';path=$source;relativeDestination=@('Documents')}
  $old = New-DataSafeSourceManifest @($job)
  # Seed a fully validated committed baseline. Initial backup has its own worker
  # and fault coverage; these measurements isolate unchanged/small-change apply.
  foreach ($entry in $old.entries) {
    $target=Join-Path $repo.Root $entry.versionLocation
    if ($entry.entryType -ceq 'directory') { Ensure-DataSafeDirectory $target }
    else { Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($target)); [IO.File]::Copy((Join-Path $source $entry.relativePath),$target) }
  }
  foreach ($entry in @($old.entries | Sort-Object @{Expression={$_.relativePath.Length};Descending=$true})) { Set-DataSafeTransactionMetadata (Join-Path $repo.Root $entry.versionLocation) $entry }
  $baseId=[guid]::NewGuid().ToString('D'); $basePath=Write-DataSafeManifest $repo $old $baseId
  Write-DataSafeAtomicJson (Join-Path $repo.MetadataRoot 'current-manifest.json') ([PSCustomObject]@{schema='datasafe.current-manifest';formatVersion=1;transactionId=$baseId;manifestPath=('manifests/'+$baseId+'.json');sha256=(Get-DataSafeSha256 $basePath)})
  Assert-DataSafeTransactionTree $repo $old -Metadata
  return [PSCustomObject]@{Root=$root;Repo=$repo;Source=$source;Job=$job;Old=$old}
}
function Measure-Apply($Transaction) {
  # Observe real I/O, not replacement behavior. Scope is apply only, after stage.
  $writer=${function:Write-DataSafeTransactionJournal}; $setter=${function:Set-DataSafeTransactionMetadataSteps}; $hasher=${function:Get-DataSafeSha256}
  $script:counts=[ordered]@{Entries=$Transaction.currentManifest.entries.Count;Operations=$Transaction.operations.Count;MetadataMutations=0;MetadataIntents=0;MetadataCompletions=0;JournalWrites=0;JournalBytes=[long]0;HashBytes=[long]0;ApplyMilliseconds=[long]0}
  $watch=[Diagnostics.Stopwatch]::StartNew()
  try {
    function Write-DataSafeTransactionJournal($Transaction,[string]$Path,[switch]$CreateOnly) {
      & $writer $Transaction $Path -CreateOnly:$CreateOnly
      $script:counts.JournalWrites++
      $script:counts.JournalBytes+=(New-Object IO.FileInfo((ConvertTo-DataSafeExtendedPath $Path))).Length
    }
    function Set-DataSafeTransactionMetadataSteps([string]$Path,$Entry,$Owner,$Operation,[scriptblock]$AfterOperation) {
      $script:counts.MetadataMutations++
      & $setter $Path $Entry $Owner $Operation $AfterOperation
    }
    function Get-DataSafeSha256([string]$Path) {
      $script:counts.HashBytes+=(New-Object IO.FileInfo((ConvertTo-DataSafeExtendedPath $Path))).Length
      & $hasher $Path
    }
    $result=Invoke-DataSafeTransaction $Transaction {
      param($c)
      if ($c.Phase -ceq 'metadata-intent') { $script:counts.MetadataIntents++ }
      if ($c.Phase -ceq 'metadata') { $script:counts.MetadataCompletions++ }
    }
    Assert-True ($result.FinalState -ceq 'committed') 'Measured transaction did not commit.'
  } finally {
    $watch.Stop(); $script:counts.ApplyMilliseconds=$watch.ElapsedMilliseconds
    ${function:Write-DataSafeTransactionJournal}=$writer; ${function:Set-DataSafeTransactionMetadataSteps}=$setter; ${function:Get-DataSafeSha256}=$hasher
    Write-Host ('COUNTERS: '+(ConvertTo-Json $script:counts -Compress))
  }
  return [PSCustomObject]$script:counts
}
try {
  foreach ($position in @('root','ancestor')) {
    Test-Case "cleanup rejects $position junction before touching external sentinel" {
      $root=Join-Path $tempRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $root
      $external=Join-Path $tempRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $external
      $target=if ($position -ceq 'root') { $external } else { Join-Path $external child }
      $sentinel=Join-Path $target sentinel.txt; Write-File $sentinel 'external-must-survive'
      $link=Join-Path $root junction; New-Item -ItemType Junction -Path $link -Target $external | Out-Null
      $remove=if ($position -ceq 'root') { $link } else { Join-Path $link child }
      try {
        $rejected=$false
        try { Remove-DataSafeDirectoryTree $remove } catch { $rejected=$_.Exception.Message -match 'reparse' }
        Assert-True ((Test-DataSafeFile $sentinel) -and [IO.File]::ReadAllText($sentinel) -ceq 'external-must-survive') 'Cleanup deleted external sentinel through junction.'
        Assert-True $rejected 'Cleanup did not reject the reparse root/ancestor.'
      } finally { if (Test-DataSafeDirectory $link) { [IO.Directory]::Delete($link,$false) } }
    }
  }
  Test-Case 'legacy incomplete cleanup preserves stage junction target and reports refusal' {
    $root=Join-Path $tempRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $root
    $external=Join-Path $tempRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $external
    $sentinel=Join-Path $external sentinel.txt; Write-File $sentinel 'legacy-external-must-survive'
    $link=Join-Path $root .stage; New-Item -ItemType Junction -Path $link -Target $external | Out-Null
    try {
      $warnings=@(Remove-DataSafeIncompleteSnapshots $root 3>&1)
      Assert-True ((Test-DataSafeFile $sentinel) -and [IO.File]::ReadAllText($sentinel) -ceq 'legacy-external-must-survive') 'Legacy incomplete cleanup deleted external sentinel.'
      Assert-True ($warnings.Count -gt 0 -and "$warnings" -match 'reparse') 'Legacy cleanup did not report retained junction.'
    } finally { if (Test-DataSafeDirectory $link) { [IO.Directory]::Delete($link,$false) } }
  }
  Test-Case 'cleanup removes child junction without traversing its target' {
    $root=Join-Path $tempRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $root
    $external=Join-Path $tempRoot ([guid]::NewGuid().ToString('N')); Ensure-DataSafeDirectory $external
    $sentinel=Join-Path $external sentinel.txt; Write-File $sentinel 'child-external-must-survive'
    New-Item -ItemType Junction -Path (Join-Path $root child) -Target $external | Out-Null
    Remove-DataSafeDirectoryTree $root
    Assert-True (-not (Test-DataSafeDirectory $root)) 'Ordinary cleanup root remains.'
    Assert-True ([IO.File]::ReadAllText($sentinel) -ceq 'child-external-must-survive') 'Child junction target was traversed.'
  }
  foreach ($count in @(8,32)) {
    Test-Case "unchanged $count files have zero per-entry metadata mutation and journal work" {
      $f=New-MetadataFixture $count; $current=New-DataSafeSourceManifest @($f.Job) $f.Old
      $tx=New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.Old $current); $null=Stage-DataSafeTransaction $tx
      Assert-True ($tx.operations.Count -eq 0) 'Unchanged fixture has operations.'
      $c=Measure-Apply $tx
      Assert-True ($c.MetadataMutations -eq 0 -and $c.MetadataIntents -eq 0 -and $c.MetadataCompletions -eq 0) "Unchanged tree performed per-entry metadata work: $($c.MetadataMutations) mutations."
      Assert-True ($c.JournalWrites -le 4) "Unchanged journal writes scale with entries: $($c.JournalWrites)."
      Assert-DataSafeTransactionTree $f.Repo $current -Metadata
    }
  }
  Test-Case 'one changed file bounds metadata work to file and child-dirtied parent' {
    $f=New-MetadataFixture 32
    Write-File (Join-Path $f.Source 'nested/file-1.txt') 'changed-literal-payload'
    $current=New-DataSafeSourceManifest @($f.Job) $f.Old
    $tx=New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.Old $current); $null=Stage-DataSafeTransaction $tx
    Assert-True ($tx.operations.Count -eq 1) 'One-file fixture changed unrelated entries.'
    $c=Measure-Apply $tx
    Assert-True ($c.MetadataMutations -gt 0 -and $c.MetadataMutations -le 2) "One file caused $($c.MetadataMutations) metadata mutations."
    Assert-True ($c.MetadataIntents -eq $c.MetadataMutations -and $c.MetadataCompletions -eq $c.MetadataMutations -and $c.JournalWrites -le 12) 'Real metadata mutations lack bounded durable boundaries.'
    Assert-DataSafeTransactionTree $f.Repo $current -Metadata
    Assert-True ([IO.File]::ReadAllText((Join-Path $f.Repo.LatestRoot 'Documents/nested/file-1.txt')) -ceq 'changed-literal-payload') 'Changed ordinary bytes missing.'
    $history=@(Get-DataSafeFileEntries $f.Repo.HistoryRoot)
    Assert-True ($history.Count -eq 1 -and [IO.File]::ReadAllText($history[0].FullName) -ceq 'literal-payload-1') 'Prior ordinary file was not preserved.'
  }
  Test-Case 'already-correct active metadata intent is durably finalized after recovery' {
    $f=New-MetadataFixture 2
    [IO.File]::SetLastWriteTimeUtc((Join-Path $f.Source 'nested/file-1.txt'),[datetime]'2017-01-01Z')
    $current=New-DataSafeSourceManifest @($f.Job) $f.Old
    $tx=New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.Old $current); $null=Stage-DataSafeTransaction $tx
    Assert-True ($tx.operations.Count -eq 1 -and $tx.operations[0].kind -ceq 'metadata') 'Active-intent fixture requires one metadata operation.'
    Assert-Throws { Invoke-DataSafeTransaction $tx { param($c) if ($c.Sequence -eq 1 -and $c.Phase -ceq 'metadata-filesystem') { throw 'final fixture metadata crash' } } } 'final fixture metadata crash'
    $path=Join-Path $f.Repo.TransactionRoot ($tx.transactionId+'.json')
    Assert-True ($null -ne (Read-DataSafeTransaction $path).mutationIntent) 'Crash fixture lacks durable intent.'
    Assert-DataSafeTransactionTree $f.Repo $current -Metadata
    Close-TestOwners
    Assert-True ((Recover-DataSafeTransaction $f.Repo $path).FinalState -ceq 'committed') 'Correct metadata intent could not recover.'
    $durable=Read-DataSafeTransaction $path
    Assert-True ($null -eq $durable.mutationIntent -and $durable.operations[0].metadataState -ceq 'done') 'Existing intent silently skipped instead of durably finalized.'
    Assert-True ((Recover-DataSafeTransaction $f.Repo $path).FinalState -ceq 'committed') 'Repeated metadata recovery failed.'
  }
} finally { Close-TestOwners; Remove-DataSafeDirectoryTree $tempRoot }
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
Write-Host "$passes passed; $($failures.Count) failed."
if ($failures.Count) { exit 1 }

param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passes = New-Object 'System.Collections.Generic.List[string]'
$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Action) {
  try { & $Action; $passes.Add($Name) } catch { $failures.Add("${Name}: $($_.Exception.Message)") }
}
. (Join-Path $WindowsRoot 'DataSafe.Manifest.ps1')
$library = Join-Path $WindowsRoot 'DataSafe.IncrementalPlan.ps1'
if (Test-Path -LiteralPath $library) { . $library }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-plan-tests-' + [guid]::NewGuid().ToString('N'))
Ensure-DataSafeDirectory $tempRoot
function New-Fixture([int]$Count = 1, [string]$Id = 'documents') {
  $source = Join-Path $tempRoot $Id
  Ensure-DataSafeDirectory $source
  [PSCustomObject]@{
    schema = 'datasafe.manifest'; formatVersion = 2; createdUtc = '2026-10-16T12:00:00.0000000Z'
    sources = @([PSCustomObject]@{ sourceId = $Id; path = $source; relativeDestination = $Id })
    entries = @(for ($i = 0; $i -lt $Count; $i++) { [PSCustomObject]@{
      sourceId = $Id; relativePath = ('file-{0:d4}.txt' -f $i); entryType = 'file'; length = [long]3
      modifiedUtc = '2026-10-15T12:00:00.0000000Z'; attributes = [long]32; sha256 = ('A' * 64)
      versionLocation = ('Latest Backup/' + $Id + '/file-{0:d4}.txt' -f $i)
    } }); sourceErrors = @()
  }
}
function New-Capability([string]$FileSystem = 'NTFS', [long]$Total = 20GB) {
  $result = Get-DataSafeFilesystemCapabilities $FileSystem
  $result | Add-Member TotalBytes $Total
  return $result
}
function New-Plan($Previous, $Current, $Capability = (New-Capability), [long]$Free = 100GB, $Repo = $repository) {
  New-DataSafeIncrementalPlan -Repository $Repo -PreviousManifest $Previous -CurrentManifest $Current -Capabilities $Capability -FreeBytes $Free
}
function Assert-Blocked($Plan, [string]$Pattern) {
  Assert-True ($Plan.BlockingErrors.Count -gt 0 -and ($Plan.BlockingErrors -join '|') -match $Pattern) 'Missing blocking diagnostic.'
  Assert-True ($Plan.Operations.Count -eq 0) 'Blocked plan retained executable operations.'
  $null = ConvertTo-Json -InputObject $Plan -Depth 30
}
try {
  $repository = Initialize-DataSafeRepository $tempRoot 'Plan PC' '00112233-4455-4677-8899-aabbccddeeff'
  Test-Case 'executable plan carries complete validated manifests including unchanged entries for durable commit' {
    $previous = New-Fixture 3; $current = New-Fixture 3; $current.entries[0].sha256 = 'B' * 64
    $plan = New-Plan $previous $current
    Assert-True ($null -ne $plan.PSObject.Properties['PreviousManifest'] -and $null -ne $plan.PSObject.Properties['CurrentManifest']) 'Full manifests are absent from transaction input.'
    Assert-True ($plan.PreviousManifest.entries.Count -eq 3 -and $plan.CurrentManifest.entries.Count -eq 3 -and $plan.Operations.Count -eq 1) 'Unchanged entries were lost from transaction input.'
    Assert-True ($plan.PreviousManifest.entries[0].sha256 -ceq ('A' * 64) -and $plan.CurrentManifest.entries[0].sha256 -ceq ('B' * 64)) 'Manifest snapshots do not preserve previous/current state.'
    $current.entries[0].sha256 = 'C' * 64
    Assert-True ($plan.CurrentManifest.entries[0].sha256 -ceq ('B' * 64)) 'Plan retained a mutable input manifest alias.'
    $initial = New-Plan $null (New-Fixture)
    Assert-True ($null -eq $initial.PreviousManifest -and $initial.CurrentManifest.entries.Count -eq 1) 'Initial manifest contract is invalid.'
  }
  Test-Case 'initial plan stages files and is serializable without history timestamp' {
    $plan = New-Plan $null (New-Fixture)
    Assert-True ($plan.BlockingErrors.Count -eq 0 -and $plan.StageBytes -eq 3 -and $plan.Operations.Count -eq 1) 'Initial plan failed.'
    Assert-True ($null -eq $plan.PreviousBackupTimestamp -and $null -eq $plan.DisplayHistoryFolder) 'Initial plan invented a prior timestamp.'
    Assert-True ($plan.Operations[0].kind -ceq 'add' -and $null -eq $plan.Operations[0].oldEntry -and $plan.Operations[0].newEntry.length -eq 3) 'Typed operation data missing.'
    $null = ConvertTo-Json -InputObject $plan -Depth 30
  }
  Test-Case 'unavailable source blocks and emits no executable delete' {
    $current = New-Fixture 0
    $current.sourceErrors = @([PSCustomObject]@{ sourceId = 'documents'; path = $current.sources[0].path; message = 'Unavailable' })
    Assert-Blocked (New-Plan (New-Fixture 100) $current) 'source|Unavailable'
  }
  foreach ($row in @(@{ Length = [long]4294967295; Block = $false }, @{ Length = [long]4294967296; Block = $true })) {
    Test-Case "FAT32 pending length $($row.Length)" {
      $current = New-Fixture; $current.entries[0].length = $row.Length
      $plan = New-Plan $null $current (New-Capability 'FAT32')
      Assert-True (($plan.BlockingErrors.Count -gt 0) -eq $row.Block) 'FAT32 boundary incorrect.'
    }
  }
  Test-Case 'FAT32 unchanged oversized historical file is not pending content' {
    $old = New-Fixture; $old.entries[0].length = [long]4294967296
    $plan = New-Plan $old $old (New-Capability 'FAT32')
    Assert-True ($plan.BlockingErrors.Count -eq 0 -and $plan.StageBytes -eq 0) 'Unchanged bytes were checked as pending.'
  }
  foreach ($row in @(
    @{ Prior = 200; Deleted = 19; Review = $false }, @{ Prior = 200; Deleted = 20; Review = $true },
    @{ Prior = 201; Deleted = 20; Review = $false }, @{ Prior = 40; Deleted = 19; Review = $false },
    @{ Prior = 40; Deleted = 20; Review = $true }, @{ Prior = 2; Deleted = 1; Review = $true },
    @{ Prior = 3; Deleted = 1; Review = $false }, @{ Prior = 0; Deleted = 0; Review = $false }
  )) {
    Test-Case "deletion boundary $($row.Deleted) of $($row.Prior)" {
      $previous = New-Fixture $row.Prior; $current = New-Fixture ($row.Prior - $row.Deleted)
      $plan = New-Plan $previous $current
      Assert-True ($plan.BlockingErrors.Count -eq 0 -and $plan.DeletionReviewRequired -eq $row.Review) 'Deletion review boundary incorrect.'
      Assert-True ($plan.DeletionCountsBySource[0].DeletedFileCount -eq $row.Deleted -and $plan.DeletionCountsBySource[0].PreviousFileCount -eq $row.Prior) 'File counts incorrect.'
      $deletes = @($plan.Operations | Where-Object { $_.kind -eq 'delete' })
      Assert-True ($deletes.Count -eq $(if ($row.Review) { 0 } else { $row.Deleted })) 'Executable delete review gate incorrect.'
    }
  }
  Test-Case 'review is per source and excludes directories' {
    $previous = New-Fixture 100; $other = New-Fixture 2 'pictures'
    $previous.sources += $other.sources; $previous.entries += $other.entries
    $current = New-Fixture 100; $other = New-Fixture 1 'pictures'
    $current.sources += $other.sources; $current.entries += $other.entries
    $plan = New-Plan $previous $current
    Assert-True ($plan.DeletionReviewRequired -and $plan.DeletionCountsBySource[1].ReviewRequired -and -not $plan.DeletionCountsBySource[0].ReviewRequired) 'Source-level threshold was pooled.'
    $previous = New-Fixture 1; $current = New-Fixture 1
    $directory = (New-Fixture).entries[0]; $directory.relativePath = 'folder'; $directory.entryType = 'directory'
    $directory.length = [long]0; $directory.sha256 = $null; $directory.attributes = [long]16; $directory.versionLocation = 'Latest Backup/documents/folder'
    $previous.entries += $directory
    $plan = New-Plan $previous $current
    Assert-True (-not $plan.DeletionReviewRequired -and $plan.DeletionCountsBySource[0].DeletedFileCount -eq 0) 'Directory counted as deleted file.'
  }
  Test-Case 'stage bytes exclude metadata directories deletions and same-volume history' {
    $previous = New-Fixture 10; $current = New-Fixture 10
    $current.entries[0].sha256 = 'B' * 64; $current.entries[0].length = [long]7
    $current.entries[1].attributes = [long]2
    $current.entries = @($current.entries | Where-Object { $_.relativePath -ne 'file-0009.txt' })
    $added = (New-Fixture 11).entries[10]; $added.length = [long]11; $current.entries += $added
    $directory = (New-Fixture).entries[0]; $directory.relativePath = 'empty'; $directory.entryType = 'directory'; $directory.length = [long]0
    $directory.attributes = [long]16; $directory.sha256 = $null; $directory.versionLocation = 'Latest Backup/documents/empty'; $current.entries += $directory
    $plan = New-Plan $previous $current
    Assert-True ($plan.BlockingErrors.Count -eq 0 -and $plan.StageBytes -eq 18) 'Wrong staging byte count.'
    $replace = @($plan.Operations | Where-Object { $_.kind -eq 'replace' })[0]
    Assert-True ($replace.historyPath -like '*Previous Versions*' -and $replace.expectedOldSha256 -ceq ('A' * 64) -and $replace.expectedNewSha256 -ceq ('B' * 64)) 'Replacement history/hash missing.'
    $delete = @($plan.Operations | Where-Object { $_.kind -eq 'delete' })[0]
    Assert-True ($delete.historyPath -like '*Deleted Files*' -and $null -eq $delete.stagedPath) 'Deletion staging/history incorrect.'
    Assert-True (@($plan.Operations | Where-Object { $_.stagedPath }).Count -eq 2) 'Non-content operation staged.'
  }
  Test-Case 'peak equal and surplus allowed insufficient blocks with fixed conservative reserve' {
    $current = New-Fixture; $first = New-Plan $null $current
    Assert-True ($first.ReserveBytes -eq 5368709120 -and $first.MetadataOverheadBytes -ge 1048576) 'Small-drive reserve/overhead missing.'
    Assert-True ($first.PeakRequiredBytes -eq (3 + $first.MetadataOverheadBytes + 5368709120)) 'Peak double-counted history or omitted overhead.'
    Assert-Blocked (New-Plan $null $current (New-Capability) ($first.PeakRequiredBytes - 1)) 'space'
    Assert-True ((New-Plan $null $current (New-Capability) $first.PeakRequiredBytes).BlockingErrors.Count -eq 0) 'Exact peak blocked.'
    Assert-True ((New-Plan $null $current (New-Capability) ($first.PeakRequiredBytes + 1)).BlockingErrors.Count -eq 0) 'Surplus blocked.'
    Assert-True ((New-Plan $null $current (New-Capability 'NTFS' 100GB)).ReserveBytes -eq 10737418240) 'Ten-percent reserve missing.'
  }
  Test-Case 'Int64 overflow fails closed for stage totals and peak addition' {
    $current = New-Fixture 2; $current.entries[0].length = [long]::MaxValue
    Assert-Blocked (New-Plan $null $current (New-Capability) ([long]::MaxValue)) 'overflow|large|Int64'
    $current = New-Fixture; $current.entries[0].length = [long]::MaxValue - 1
    Assert-Blocked (New-Plan $null $current (New-Capability) ([long]::MaxValue)) 'overflow|large|Int64'
  }
  foreach ($mutate in @(
    { param($m) $m.entries += $m.entries[0] },
    { param($m) $m.entries[0].relativePath = '../escape' },
    { param($m) $m.entries[0].length = @(3) },
    { param($m) $m.formatVersion = 1 }
  )) {
    Test-Case "unsafe handcrafted manifest blocks: $mutate" {
      $current = New-Fixture; & $mutate $current
      Assert-Blocked (New-Plan $null $current) 'manifest|collision|schema|path|version'
    }
  }
  Test-Case 'normalized case collision becomes a blocking diagnostic' {
    $current = New-Fixture; $duplicate = (New-Fixture).entries[0]; $duplicate.relativePath = 'FILE-0000.txt'; $current.entries += $duplicate
    Assert-Blocked (New-Plan $null $current) 'collision'
  }
  Test-Case 'operations are ordinal deterministic by source then slash-normalized path' {
    $current = New-Fixture 2 'z'; $other = New-Fixture 2 'a'
    $current.sources += $other.sources; $current.entries = @($current.entries[1], $other.entries[1], $other.entries[0], $current.entries[0])
    $plan = New-Plan $null $current
    Assert-True (($plan.Operations | ForEach-Object { $_.sourceId + '/' + $_.relativePath }) -join '|' -ceq 'a/file-0000.txt|a/file-0001.txt|z/file-0000.txt|z/file-0001.txt') 'Operation ordering unstable.'
    Assert-True (($plan.Operations.sequence -join ',') -ceq '1,2,3,4') 'Sequence missing.'
  }
  Test-Case 'history suffixes inspect existing ordinary folders without creating a new one' {
    $previous = New-Fixture; $current = New-Fixture; $current.entries[0].sha256 = 'B' * 64
    $plan = New-Plan $previous $current
    Assert-True ($plan.PreviousBackupTimestamp -ceq '2026-10-16T12:00:00.0000000Z' -and $plan.DisplayHistoryFolder -ceq 'Backup from 2026-10-16 12-00-00') 'Previous timestamp not authoritative.'
    Ensure-DataSafeDirectory (Join-Path $repository.HistoryRoot $plan.DisplayHistoryFolder)
    $next = New-Plan $previous $current
    Assert-True ($next.DisplayHistoryFolder -ceq 'Backup from 2026-10-16 12-00-00 (2)') 'First suffix missing.'
    Ensure-DataSafeDirectory (Join-Path $repository.HistoryRoot $next.DisplayHistoryFolder)
    $third = New-Plan $previous $current
    Assert-True ($third.DisplayHistoryFolder -ceq 'Backup from 2026-10-16 12-00-00 (3)' -and -not (Test-DataSafeDirectory (Join-Path $repository.HistoryRoot $third.DisplayHistoryFolder))) 'History planning wrote or collided.'
  }
  foreach ($mutate in @(
    { param($c) $c.Supported = $false }, { param($c) $c.FileSystem = 'unknown' },
    { param($c) $c.PSObject.Properties.Remove('TotalBytes') }, { param($c) $c.TotalBytes = 0 },
    { param($c) $c.TotalBytes = @(20GB) }, { param($c) $c.TotalBytes = '20000' },
    { param($c) $c.MaxFileBytes = 0 }, { param($c) $c.Supported = 'true' }
  )) {
    Test-Case "malformed capability blocks: $mutate" {
      $cap = New-Capability; & $mutate $cap
      Assert-Blocked (New-Plan $null (New-Fixture) $cap) 'capabilit|filesystem|capacity'
    }
  }
  Test-Case 'malformed repository and unreadable required metadata block without mutation' {
    Assert-Blocked (New-Plan $null (New-Fixture) (New-Capability) 100GB $null) 'repository'
    $bad = Read-DataSafeRepository $repository.Root; $bad.StagingRoot = $tempRoot
    Assert-Blocked (New-Plan $null (New-Fixture) (New-Capability) 100GB $bad) 'repository'
    $metadataPath = Join-Path $repository.MetadataRoot 'repository.json'
    $held = [IO.File]::Open($metadataPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { Assert-Blocked (New-Plan $null (New-Fixture)) 'repository|JSON|metadata' } finally { $held.Dispose() }
  }
  Test-Case 'source disappearing after scan blocks even an unchanged plan' {
    $current = New-Fixture 1 'vanished'
    [IO.Directory]::Delete($current.sources[0].path)
    Assert-Blocked (New-Plan $current $current) 'source|unavailable'
  }
  Test-Case 'selected files resolve to the selected path and reject a fabricated child' {
    $current = New-Fixture 1 'selected'
    $file = Join-Path $current.sources[0].path 'file-0000.txt'
    [IO.File]::WriteAllText($file, 'abc'); $current.sources[0].path = $file
    $plan = New-Plan $null $current
    Assert-True ($plan.BlockingErrors.Count -eq 0 -and $plan.Operations[0].sourcePath -ceq $file) 'Selected-file path duplicated its basename.'
    $current.entries[0].relativePath = 'fabricated.txt'; $current.entries[0].versionLocation = 'Latest Backup/selected/fabricated.txt'
    Assert-Blocked (New-Plan $null $current) 'source|selected|file'
  }
  Test-Case 'long repository and source paths remain ordinary absolute operation paths' {
    $deep = Join-Path $tempRoot 'deep'
    1..7 | ForEach-Object { $deep = Join-Path $deep ('segment-' + ('x' * 30)) }
    Ensure-DataSafeDirectory $deep
    $repo = Initialize-DataSafeRepository $deep 'Deep PC' '10112233-4455-4677-8899-aabbccddeeff'
    $current = New-Fixture; $current.sources[0].path = $deep
    $plan = New-Plan $null $current (New-Capability) 100GB $repo
    Assert-True ($plan.BlockingErrors.Count -eq 0 -and $plan.Operations[0].currentPath.Length -gt 260 -and -not $plan.Operations[0].currentPath.StartsWith('\\?\')) 'Long paths were rejected or serialized as device paths.'
  }
  Test-Case 'reparse source and current destination ancestry fail closed' {
    $outside = Join-Path $tempRoot 'outside'; Ensure-DataSafeDirectory $outside
    $link = Join-Path $tempRoot 'source-junction'
    New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
    try {
      $current = New-Fixture; $current.sources[0].path = $link
      Assert-Blocked (New-Plan $current $current) 'reparse|source'
    } finally { [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $link)) }
    $link = Join-Path $repository.LatestRoot 'documents'
    New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
    try { Assert-Blocked (New-Plan $null (New-Fixture)) 'reparse' }
    finally { [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $link)) }
  }
  Test-Case 'planning preserves all repository paths content and timestamps' {
    # Isolate from earlier junction creation/removal: NTFS may publish that
    # prior directory timestamp change on a subsequent attribute query.
    $repo = Initialize-DataSafeRepository $tempRoot 'Mutation PC' '20112233-4455-4677-8899-aabbccddeeff'
    foreach ($directory in @(Get-ChildItem -LiteralPath $repo.Root -Recurse -Force -Directory)) {
      [IO.Directory]::SetLastWriteTimeUtc($directory.FullName, [datetime]'2020-01-01T00:00:00Z')
    }
    $before = @(Get-ChildItem -LiteralPath $repo.Root -Recurse -Force | ForEach-Object { $_.FullName + '|' + $_.LastWriteTimeUtc.Ticks + '|' + $(if (-not $_.PSIsContainer) { Get-DataSafeSha256 $_.FullName }) }) -join "`n"
    $null = New-Plan (New-Fixture 10) (New-Fixture 9) (New-Capability) 100GB $repo
    $after = @(Get-ChildItem -LiteralPath $repo.Root -Recurse -Force | ForEach-Object { $_.FullName + '|' + $_.LastWriteTimeUtc.Ticks + '|' + $(if (-not $_.PSIsContainer) { Get-DataSafeSha256 $_.FullName }) }) -join "`n"
    Assert-True ($before -ceq $after) ("Planning mutated the repository: " + ((Compare-Object ($before -split "`n") ($after -split "`n") | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject }) -join '; '))
  }
} finally { Remove-DataSafeDirectoryTree $tempRoot }
foreach ($name in $passes) { Write-Host "PASS: $name" }
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
Write-Host "Result: $($passes.Count) passed; $($failures.Count) failed."
if ($failures.Count -gt 0) { exit 1 }
exit 0

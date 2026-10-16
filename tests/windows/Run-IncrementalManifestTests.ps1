param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passes = New-Object 'System.Collections.Generic.List[string]'
$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch {
    if ($_.Exception -is [Management.Automation.CommandNotFoundException]) { throw }
    Assert-True ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)"
    return
  }
  throw 'Expected rejection, but operation succeeded.'
}
function Test-Case([string]$Name, [scriptblock]$Action) {
  try { & $Action; $passes.Add($Name) } catch { $failures.Add("${Name}: $($_.Exception.Message)") }
}
. (Join-Path $WindowsRoot 'DataSafe.Repository.ps1')
$library = Join-Path $WindowsRoot 'DataSafe.Manifest.ps1'
if (Test-Path -LiteralPath $library) { . $library }

function New-FixtureManifest {
  return [PSCustomObject][ordered]@{
    schema = 'datasafe.manifest'; formatVersion = 2; createdUtc = '2026-10-16T12:00:00.0000000Z'
    sources = @([PSCustomObject]@{ sourceId = 'documents'; path = 'C:\Source'; relativeDestination = 'Documents' })
    entries = @([PSCustomObject][ordered]@{
      sourceId = 'documents'; relativePath = 'report.txt'; entryType = 'file'; length = [long]3
      modifiedUtc = '2026-10-15T12:00:00.0000000Z'; attributes = [long]32; sha256 = ('A' * 64)
      versionLocation = 'Latest Backup/Documents/report.txt'
    })
    sourceErrors = @()
  }
}

Test-Case 'initial comparison exposes file counts and byte totals' {
  $result = Compare-DataSafeManifests -Previous $null -Current (New-FixtureManifest)
  Assert-True ($result.Added.Count -eq 1 -and $result.Deleted.Count -eq 0) 'Initial comparison was not an addition.'
  Assert-True ($result.AddedBytes -eq 3 -and $result.TotalBytes -eq 3 -and $result.TotalFileCount -eq 1) 'Incorrect aggregate totals.'
}
Test-Case 'case-insensitive normalized entry collisions reject both comparisons and prior scan input' {
  $manifest = New-FixtureManifest
  $duplicate = New-FixtureManifest
  $duplicate.entries[0].relativePath = 'REPORT.txt'
  $manifest.entries += $duplicate.entries
  Assert-Throws { Compare-DataSafeManifests $null $manifest } 'collision|duplicate'
  Assert-Throws { New-DataSafeSourceManifest -Jobs @() -PreviousManifest $manifest } 'collision|duplicate'
}
Test-Case 'slash-normalized collisions reject ambiguous manifests' {
  $manifest = New-FixtureManifest
  $manifest.entries[0].relativePath = 'sub/report.txt'
  $manifest.entries[0].versionLocation = 'Latest Backup/Documents/sub/report.txt'
  $duplicate = New-FixtureManifest
  $duplicate.entries[0].relativePath = 'sub\report.txt'
  $duplicate.entries[0].versionLocation = 'Latest Backup/Documents/sub/report.txt'
  $manifest.entries += $duplicate.entries
  Assert-Throws { Compare-DataSafeManifests $manifest (New-FixtureManifest) } 'collision|duplicate'
}
foreach ($unsafe in @('../escape', '/rooted', 'C:\escape', 'a/../escape', 'a//b', 'a/./b', 'a:stream', 'trailing.', 'space ', 'NUL.txt', 'CONIN$', 'a\..\b')) {
  Test-Case "unsafe source-relative path rejected: $unsafe" {
    $manifest = New-FixtureManifest
    $manifest.entries[0].relativePath = $unsafe
    Assert-Throws { Compare-DataSafeManifests $null $manifest } 'path|segment|unsafe'
  }
}
foreach ($mutation in @(
  { param($m) $m.formatVersion = '2' },
  { param($m) $m.schema = 'other' },
  { param($m) $m.entries[0].length = -1 },
  { param($m) $m.entries[0].length = 1.5 },
  { param($m) $m.entries[0].sha256 = 'no hash' },
  { param($m) $m.entries[0].modifiedUtc = 'yesterday' },
  { param($m) $m.entries[0].entryType = 'symlink' },
  { param($m) $m.entries[0].sourceId = 'unknown' },
  { param($m) $m.entries[0].attributes = 1024 },
  { param($m) $m.sources[0].path = 'C:\Source:stream' },
  { param($m) $m.sources[0].path = 'C:\Source\trailing.' },
  { param($m) $m.entries[0].versionLocation = '../escape' },
  { param($m) $m.entries[0].versionLocation = '.datasafe/content' },
  { param($m) $m.entries[0].versionLocation = 'Latest Backup/Other/report.txt' },
  { param($m) $m.sources += $m.sources[0] },
  { param($m) $m.entries = $null },
  { param($m) $m.entries = $m.entries[0] }
)) {
  Test-Case "malformed manifest rejected: $mutation" {
    $manifest = New-FixtureManifest
    & $mutation $manifest
    Assert-Throws { Compare-DataSafeManifests $null $manifest } 'manifest|schema|path|source|hash|time|attribute|duplicate'
  }
}
Test-Case 'ordinal case-insensitive keys do not depend on Turkish culture' {
  $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
  try {
    [Threading.Thread]::CurrentThread.CurrentCulture = New-Object Globalization.CultureInfo('tr-TR')
    $previous = New-FixtureManifest
    $previous.entries[0].relativePath = 'FILE.txt'
    $previous.entries[0].versionLocation = 'Latest Backup/Documents/FILE.txt'
    $current = New-FixtureManifest
    $current.entries[0].relativePath = 'file.txt'
    $current.entries[0].versionLocation = $previous.entries[0].versionLocation
    $diff = Compare-DataSafeManifests $previous $current
    Assert-True ($diff.Added.Count -eq 0 -and $diff.Deleted.Count -eq 0 -and $diff.Unchanged.Count -eq 1) 'Keys were culture dependent.'
  } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }
}
Test-Case 'deliberately omitted sources remain visible as proposed deletions' {
  $current = New-FixtureManifest
  $current.sources = @(); $current.entries = @()
  $diff = Compare-DataSafeManifests (New-FixtureManifest) $current
  Assert-True ($diff.Deleted.Count -eq 1 -and $diff.DeletedBytes -eq 3) 'Source-set removal was hidden.'
}
Test-Case 'directory schema requires every entry field including an explicit null hash' {
  $manifest = New-FixtureManifest
  $manifest.entries[0].entryType = 'directory'; $manifest.entries[0].length = [long]0
  $manifest.entries[0].attributes = [long]16; $manifest.entries[0].sha256 = $null
  $manifest.entries[0].PSObject.Properties.Remove('sha256')
  Assert-Throws { Compare-DataSafeManifests $null $manifest } 'schema|field|hash'
}

if ([IO.Path]::DirectorySeparatorChar -eq '\') {
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-manifest-tests-' + [guid]::NewGuid().ToString('N'))
  Ensure-DataSafeDirectory $tempRoot
  function New-TestSource {
    $path = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
    Ensure-DataSafeDirectory $path
    return $path
  }
  function Write-TestFile([string]$Path, [string]$Content) {
    Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $Path), $Content, (New-Object Text.UTF8Encoding($false)))
  }
  function New-TestJob([string]$Path) { return [PSCustomObject]@{ id = 'documents'; path = $Path; name = 'Documents' } }
  function Read-TestJson([string]$Json) {
    $path = Join-Path $tempRoot ([guid]::NewGuid().ToString('N') + '.json')
    Write-TestFile $path $Json
    return Read-DataSafeManifest $path
  }
  try {
    Test-Case 'initial scan is deterministic includes directories Unicode and independently verified SHA256' {
      $source = New-TestSource
      $unicodeName = ([string][char]0x00e9) + '.txt'
      Write-TestFile (Join-Path $source 'z.txt') 'z'
      Write-TestFile (Join-Path $source 'A.txt') 'abc'
      Write-TestFile (Join-Path $source $unicodeName) 'unicode'
      Ensure-DataSafeDirectory (Join-Path $source 'Empty')
      $manifest = New-DataSafeSourceManifest -Jobs @((New-TestJob $source))
      Assert-True ($manifest.schema -ceq 'datasafe.manifest' -and $manifest.formatVersion -eq 2 -and $manifest.sourceErrors.Count -eq 0) 'Missing schema/errors.'
      Assert-True (($manifest.entries.relativePath -join '|') -ceq ('A.txt|Empty|z.txt|' + $unicodeName)) 'Enumeration order is not ordinal case-insensitive.'
      $entry = $manifest.entries[0]
      Assert-True ($entry.length -eq 3 -and $entry.sha256 -eq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'Incorrect file metadata/hash.'
      Assert-True ($entry.sourceId -ceq 'documents' -and $entry.versionLocation -ceq 'Latest Backup/Documents/A.txt') 'Identity or browseable location was lost.'
      Assert-True ($manifest.entries[1].entryType -eq 'directory' -and $null -eq $manifest.entries[1].sha256) 'Empty directory was not represented.'
      $diff = Compare-DataSafeManifests $null $manifest
      Assert-True ($diff.Added.Count -eq 4 -and $diff.TotalFileCount -eq 3 -and $diff.TotalBytes -eq 11 -and $diff.AddedBytes -eq 11) 'Directory/file totals are incorrect.'
    }
    Test-Case 'unchanged second scan performs zero hash calls and preserves content hashes' {
      $source = New-TestSource
      Write-TestFile (Join-Path $source 'file.txt') 'abc'
      $first = New-DataSafeSourceManifest @((New-TestJob $source))
      $script:hashCalls = 0
      $second = New-DataSafeSourceManifest @((New-TestJob $source)) $first { param($path) $script:hashCalls++; Get-DataSafeSha256 $path }
      $diff = Compare-DataSafeManifests $first $second
      Assert-True ($script:hashCalls -eq 0 -and $second.entries[0].sha256 -ceq $first.entries[0].sha256) 'Unchanged scan hashed content.'
      Assert-True ($diff.Unchanged.Count -eq 1 -and $diff.UnchangedBytes -eq 3 -and $diff.ContentChanged.Count -eq 0) 'Unchanged scan was misclassified.'
    }
    Test-Case 'hash candidates are enumerated deterministically regardless of creation order' {
      $source = New-TestSource
      Write-TestFile (Join-Path $source 'z.txt') 'z'; Write-TestFile (Join-Path $source 'A.txt') 'a'
      $observed = New-Object 'System.Collections.Generic.List[string]'
      $manifest = New-DataSafeSourceManifest @((New-TestJob $source)) $null { param($p) $observed.Add([IO.Path]::GetFileName($p)); Get-DataSafeSha256 $p }
      Assert-True (($observed -join '|') -ceq 'A.txt|z.txt') 'Hash traversal depended on native directory enumeration order.'
      Assert-True ($manifest.entries.Count -eq 2) 'Deterministic hashing lost entries.'
    }
    Test-Case 'changed content hashes and produces content-change bytes' {
      $source = New-TestSource; $path = Join-Path $source 'file.txt'
      Write-TestFile $path 'abc'
      $first = New-DataSafeSourceManifest @((New-TestJob $source))
      Write-TestFile $path 'longer'
      $script:hashCalls = 0
      $second = New-DataSafeSourceManifest @((New-TestJob $source)) $first { param($p) $script:hashCalls++; Get-DataSafeSha256 $p }
      $diff = Compare-DataSafeManifests $first $second
      Assert-True ($script:hashCalls -eq 1 -and $diff.ContentChanged.Count -eq 1 -and $diff.ContentChangedBytes -eq 6) 'Content change not detected.'
    }
    Test-Case 'time-only and attribute-only updates are metadata changes without duplicate content' {
      $source = New-TestSource; $path = Join-Path $source 'file.txt'
      Write-TestFile $path 'abc'
      $first = New-DataSafeSourceManifest @((New-TestJob $source))
      [IO.File]::SetLastWriteTimeUtc((ConvertTo-DataSafeExtendedPath $path), [datetime]::UtcNow.AddHours(-1))
      $script:hashCalls = 0
      $second = New-DataSafeSourceManifest @((New-TestJob $source)) $first { param($p) $script:hashCalls++; Get-DataSafeSha256 $p }
      $diff = Compare-DataSafeManifests $first $second
      Assert-True ($script:hashCalls -eq 1 -and $diff.MetadataChanged.Count -eq 1 -and $diff.ContentChanged.Count -eq 0) 'Same content with new time was recopied.'
      [IO.File]::SetAttributes((ConvertTo-DataSafeExtendedPath $path), [IO.FileAttributes]::Hidden)
      $script:hashCalls = 0
      $third = New-DataSafeSourceManifest @((New-TestJob $source)) $second { param($p) $script:hashCalls++; Get-DataSafeSha256 $p }
      Assert-True ($script:hashCalls -eq 0 -and (Compare-DataSafeManifests $second $third).MetadataChanged.Count -eq 1) 'Attribute-only update was lost.'
    }
    Test-Case 'add delete and rename are separate deterministic change sets' {
      $source = New-TestSource
      Write-TestFile (Join-Path $source 'remove.txt') 'old'
      Write-TestFile (Join-Path $source 'before.txt') 'rename'
      $first = New-DataSafeSourceManifest @((New-TestJob $source))
      [IO.File]::Delete((ConvertTo-DataSafeExtendedPath (Join-Path $source 'remove.txt')))
      Move-DataSafeSameVolume (Join-Path $source 'before.txt') (Join-Path $source 'after.txt')
      Write-TestFile (Join-Path $source 'new.txt') 'new'
      $diff = Compare-DataSafeManifests $first (New-DataSafeSourceManifest @((New-TestJob $source)) $first)
      Assert-True (($diff.Added.relativePath -join '|') -ceq 'after.txt|new.txt') 'Added or renamed file missing.'
      Assert-True (($diff.Deleted.relativePath -join '|') -ceq 'before.txt|remove.txt') 'Deleted or renamed file missing.'
      Assert-True ($diff.AddedBytes -eq 9 -and $diff.DeletedBytes -eq 9 -and $diff.ContentChanged.Count -eq 0) 'Rename was not delete plus add.'
    }
    Test-Case 'unavailable source reports errors and never fabricates deletions' {
      $source = New-TestSource
      Write-TestFile (Join-Path $source 'file.txt') 'abc'
      $first = New-DataSafeSourceManifest @((New-TestJob $source))
      Move-DataSafeSameVolume $source ($source + '-disconnected')
      $second = New-DataSafeSourceManifest @((New-TestJob $source)) $first
      $diff = Compare-DataSafeManifests $first $second
      Assert-True ($second.sourceErrors.Count -eq 1 -and $second.sourceErrors[0].sourceId -ceq 'documents') 'Unavailable source was not explicit.'
      Assert-True ($diff.Deleted.Count -eq 0 -and $diff.SourceErrors.Count -eq 1) 'Unavailable source became deletions.'
    }
    Test-Case 'read failure discards partial source scan and preserves errors through diff and persistence' {
      $source = New-TestSource
      Write-TestFile (Join-Path $source 'a.txt') 'abc'; Write-TestFile (Join-Path $source 'z.txt') 'last'
      $first = New-DataSafeSourceManifest @((New-TestJob $source))
      $held = [IO.File]::Open((ConvertTo-DataSafeExtendedPath (Join-Path $source 'z.txt')), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
      try { $second = New-DataSafeSourceManifest @((New-TestJob $source)) $null } finally { $held.Dispose() }
      Assert-True ($second.entries.Count -eq 0 -and $second.sourceErrors.Count -eq 1) 'Partial source was accepted after unreadable file.'
      $diff = Compare-DataSafeManifests $first $second
      Assert-True ($diff.Deleted.Count -eq 0 -and $diff.SourceErrors.Count -eq 1) 'Read failure fabricated deletions.'
      $roundTrip = Read-TestJson (ConvertTo-Json -InputObject $second -Depth 12)
      Assert-True ($roundTrip.sourceErrors.Count -eq 1) 'Source error lost on persistence.'
    }
    Test-Case 'duplicate source identities and unsafe absolute source paths reject scan' {
      $source = New-TestSource
      Assert-Throws { New-DataSafeSourceManifest @((New-TestJob $source), (New-TestJob $source)) } 'duplicate|collision'
      foreach ($path in @('relative\path', ($source + '\..\escape'))) {
        Assert-Throws { New-DataSafeSourceManifest @((New-TestJob $path)) } 'absolute|path|traversal'
      }
    }
    Test-Case 'destination roots follow established browseable priority and reject unsafe collisions' {
      $source = New-TestSource; Write-TestFile (Join-Path $source 'file.txt') 'x'
      $job = New-TestJob $source
      $job | Add-Member relativeDestination @('User Files', 'Documents')
      $job | Add-Member backupDestinationKey 'Fallback'
      $manifest = New-DataSafeSourceManifest @($job)
      Assert-True ($manifest.entries[0].versionLocation -ceq 'Latest Backup/User Files/Documents/file.txt') 'relativeDestination priority was lost.'
      $job.PSObject.Properties.Remove('relativeDestination')
      Assert-True ((New-DataSafeSourceManifest @($job)).entries[0].versionLocation -ceq 'Latest Backup/Fallback/file.txt') 'backupDestinationKey priority was lost.'
      $other = New-TestJob (New-TestSource); $other.id = 'other'
      $job.PSObject.Properties.Remove('backupDestinationKey')
      Assert-Throws { New-DataSafeSourceManifest @($job, $other) } 'destination|collision'
    }
    Test-Case 'destination sanitization matches existing engine segments rather than computer-name rules' {
      $source = New-TestSource; Write-TestFile (Join-Path $source 'file.txt') 'x'
      $job = New-TestJob $source
      $job.name = 'Customer.Notes.txt'
      Assert-True ((New-DataSafeSourceManifest @($job)).entries[0].versionLocation -ceq 'Latest Backup/Customer-Notes/file.txt') 'Name sanitization differs from the engine.'
      $job | Add-Member relativeDestination @('Team/Files', 'Reports.txt')
      Assert-True ((New-DataSafeSourceManifest @($job)).entries[0].versionLocation -ceq 'Latest Backup/Team-Files/Reports/file.txt') 'Explicit destination sanitization differs from the engine.'
    }
    Test-Case 'unsafe extended-path filename aborts scan instead of becoming a source error' {
      $source = New-TestSource
      # Join-Path/GetFullPath normalize away trailing dots. Preserve the actual
      # NTFS name by appending it only after converting the parent to extended.
      [IO.File]::WriteAllText(((ConvertTo-DataSafeExtendedPath $source) + '\trailing.'), 'unsafe')
      Assert-Throws { New-DataSafeSourceManifest @((New-TestJob $source)) } 'unsafe|path|segment'
    }
    Test-Case 'moving a source root cannot reuse old size/time hashes' {
      $source = New-TestSource; $other = New-TestSource
      $firstPath = Join-Path $source 'file.txt'; $secondPath = Join-Path $other 'file.txt'
      Write-TestFile $firstPath 'abc'; Write-TestFile $secondPath 'xyz'
      [IO.File]::SetLastWriteTimeUtc((ConvertTo-DataSafeExtendedPath $secondPath), [IO.File]::GetLastWriteTimeUtc((ConvertTo-DataSafeExtendedPath $firstPath)))
      $first = New-DataSafeSourceManifest @((New-TestJob $source))
      $second = New-DataSafeSourceManifest @((New-TestJob $other)) $first
      Assert-True ((Compare-DataSafeManifests $first $second).ContentChanged.Count -eq 1) 'New root reused an unrelated content hash.'
    }
    Test-Case 'reparse children are neither traversed hashed nor emitted and root junction is an error' {
      $source = New-TestSource; $outside = New-TestSource
      Write-TestFile (Join-Path $outside 'outside.txt') 'outside'
      Write-TestFile (Join-Path $source 'inside.txt') 'inside'
      $link = Join-Path $source 'junction'
      New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
      try {
        $manifest = New-DataSafeSourceManifest @((New-TestJob $source))
        Assert-True ($manifest.entries.Count -eq 1 -and $manifest.entries[0].relativePath -ceq 'inside.txt') 'Junction was traversed/emitted.'
        $rootLink = New-DataSafeSourceManifest @((New-TestJob $link))
        Assert-True ($rootLink.entries.Count -eq 0 -and $rootLink.sourceErrors.Count -eq 1) 'Root junction was traversed.'
      } finally { [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $link)) }
    }
    Test-Case 'long-path scan hash and manifest persistence round-trip without publishing pointer' {
      $deep = New-TestSource
      1..7 | ForEach-Object { $deep = Join-Path $deep ('segment-' + ('x' * 30)) }
      Ensure-DataSafeDirectory $deep
      Write-TestFile (Join-Path $deep 'file.txt') 'abc'
      $manifest = New-DataSafeSourceManifest @((New-TestJob $deep))
      $repository = Initialize-DataSafeRepository $deep 'PC' '00112233-4455-4677-8899-aabbccddeeff'
      $transaction = [guid]::NewGuid().ToString('D')
      $path = Write-DataSafeManifest $repository $manifest $transaction
      Assert-True ($path.Length -gt 260 -and $path.StartsWith($repository.ManifestRoot + '\') -and (Test-DataSafeFile $path)) 'Manifest was not written under long manifest root.'
      $bytes = [IO.File]::ReadAllBytes((ConvertTo-DataSafeExtendedPath $path))
      Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Manifest is not BOM-free UTF-8.'
      $loaded = Read-DataSafeManifest $path
      Assert-True ($loaded.entries[0].sha256 -ceq $manifest.entries[0].sha256 -and (Compare-DataSafeManifests $manifest $loaded).Unchanged.Count -eq 1) 'Manifest round-trip changed content.'
      Assert-Throws { Write-DataSafeManifest $repository $manifest $transaction } 'exist|collision|overwrite'
      Assert-True ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((ConvertTo-DataSafeExtendedPath $path))) -ceq [Text.Encoding]::UTF8.GetString($bytes)) 'Retry overwrote manifest.'
      $secondPath = Write-DataSafeManifest $repository $manifest ([guid]::NewGuid().ToString('D'))
      Assert-True ($path -cne $secondPath) 'Transaction filenames collided.'
      $metadata = Read-DataSafeRepositoryJson (Join-Path $repository.MetadataRoot 'repository.json')
      Assert-True ($null -eq $metadata.PSObject.Properties['currentManifest']) 'Manifest writer published a current pointer.'
      Assert-Throws { Write-DataSafeManifest $repository $manifest '../escape' } 'UUID|transaction|identity'
    }
    foreach ($badJson in @(
      '{broken',
      '{"schema":"datasafe.manifest",}',
      '{/*comment*/"schema":"datasafe.manifest"}',
      '[{}]',
      ((ConvertTo-Json -InputObject (New-FixtureManifest) -Depth 12 -Compress).Replace('"length":3', '"length":3,"Length":3')),
      ((ConvertTo-Json -InputObject (New-FixtureManifest) -Depth 12 -Compress).Replace('"length":3', '"length":3,"lengt\u0068":3')),
      ((ConvertTo-Json -InputObject (New-FixtureManifest) -Depth 12 -Compress).Replace('"sources":[{', '"sources":[{"path":"C:\\shadow",'))
    )) {
      Test-Case "corrupt or duplicate JSON rejected: $badJson" { Assert-Throws { Read-TestJson $badJson } 'JSON|duplicate|schema|manifest' }
    }
    Test-Case 'strict UTF-8 rejects malformed bytes and UTF-16 BOM without touching files' {
      $path = Join-Path $tempRoot 'invalid-encoding.json'
      [IO.File]::WriteAllBytes($path, [byte[]]@(123,34,120,34,58,34,255,34,125))
      Assert-Throws { Read-DataSafeManifest $path } 'UTF|JSON|invalid'
      [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject (New-FixtureManifest) -Depth 12), [Text.Encoding]::Unicode)
      Assert-Throws { Read-DataSafeManifest $path } 'UTF|JSON|invalid'
    }
    Test-Case 'manifest reader refuses a reparse ancestor' {
      $outside = New-TestSource; $link = Join-Path $tempRoot 'manifest-junction'
      Write-TestFile (Join-Path $outside 'manifest.json') (ConvertTo-Json -InputObject (New-FixtureManifest) -Depth 12)
      New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
      try { Assert-Throws { Read-DataSafeManifest (Join-Path $link 'manifest.json') } 'reparse' }
      finally { [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $link)) }
    }
  } finally { Remove-DataSafeDirectoryTree $tempRoot }
} else { Write-Host 'SKIP: Windows filesystem integration cases.' }

foreach ($name in $passes) { Write-Host "PASS: $name" }
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
Write-Host "Result: $($passes.Count) passed; $($failures.Count) failed."
if ($failures.Count -gt 0) { exit 1 }
exit 0

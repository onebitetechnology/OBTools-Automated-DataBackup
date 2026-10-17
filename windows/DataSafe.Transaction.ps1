Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DataSafe.IncrementalPlan.ps1')

# Journal v3 adds one strict durable mutation intent to v2's media policy,
# prior-pointer capture and per-operation substeps. Legacy v1/v2 are strictly read and upgraded only
# under a newly validated owned lock. Live handles are NEVER restored by
# reading a journal. Keep ownership across repeated dot-sourcing of the library.
if ($null -eq (Get-Variable DataSafeTransactionOwners -Scope Script -ErrorAction SilentlyContinue)) {
  $script:DataSafeTransactionOwners = @{}
}

function Get-DataSafeTransactionOwnerKey([string]$RepositoryRoot, [string]$ComputerId, [string]$TransactionId) {
  Assert-DataSafeComputerId $ComputerId
  Assert-DataSafeComputerId $TransactionId
  $ordinary = (ConvertFrom-DataSafeExtendedPath $RepositoryRoot).Replace('/', '\')
  Assert-DataSafeManifestSourcePath $ordinary
  $canonical = [IO.Path]::GetFullPath($ordinary).TrimEnd('\').ToUpperInvariant()
  return $canonical + [char]0 + ([guid]$ComputerId).ToString('D') + [char]0 + ([guid]$TransactionId).ToString('D')
}

function Assert-DataSafeTransactionFields($Value, [string[]]$Names) {
  if ($Value -isnot [PSCustomObject]) { throw 'DataSafe transaction schema requires an object.' }
  foreach ($name in $Names) {
    if ($null -eq $Value.PSObject.Properties[$name]) { throw "DataSafe transaction schema is missing field: $name" }
  }
  foreach ($property in $Value.PSObject.Properties) {
    if ($property.Name -cnotin $Names) { throw "DataSafe transaction schema has an unknown field: $($property.Name)" }
  }
}

function Assert-DataSafeTransactionManifestFields($Manifest) {
  Assert-DataSafeTransactionFields $Manifest @('schema','formatVersion','createdUtc','sources','entries','sourceErrors')
  foreach ($source in $Manifest.sources) {
    Assert-DataSafeTransactionFields $source @('sourceId','path','relativeDestination')
  }
  foreach ($entry in $Manifest.entries) {
    Assert-DataSafeTransactionFields $entry @('sourceId','relativePath','entryType','length','modifiedUtc','attributes','sha256','versionLocation')
  }
  foreach ($sourceError in $Manifest.sourceErrors) {
    Assert-DataSafeTransactionFields $sourceError @('sourceId','path','message')
  }
}

function ConvertFrom-DataSafeTransactionJson([string]$Json) {
  Assert-DataSafeIdentityJsonShape $Json
  $options = @{ InputObject = $Json; ErrorAction = 'Stop' }
  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
  return ConvertFrom-Json @options
}

function Assert-DataSafeTransactionPath($Path, $Expected, [switch]$AllowNull) {
  if ($null -eq $Path -and $AllowNull -and $null -eq $Expected) { return }
  if ($Path -isnot [string] -or $Expected -isnot [string]) { throw 'DataSafe transaction path schema is invalid.' }
  Assert-DataSafeManifestSourcePath $Path
  if (-not $Path.Replace('/', '\').Equals($Expected.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'DataSafe transaction path does not match its repository/entry identity.'
  }
  Assert-DataSafeNoReparsePath $Path
}

function Assert-DataSafeTransactionEntry($Entry, [string]$SourceId, [string]$RelativePath, [string]$RepositoryRoot) {
  Assert-DataSafeTransactionFields $Entry @('sourceId','relativePath','entryType','length','modifiedUtc','attributes','sha256','versionLocation')
  $id = Get-DataSafeManifestScalar $Entry 'sourceId'
  $relative = ConvertTo-DataSafeManifestRelativePath (Get-DataSafeManifestScalar $Entry 'relativePath')
  $location = ConvertTo-DataSafeManifestRelativePath (Get-DataSafeManifestScalar $Entry 'versionLocation')
  if ($id -ine $SourceId -or $relative -ine $RelativePath -or -not $location.StartsWith('Latest Backup/', [StringComparison]::Ordinal) -or
      -not $location.EndsWith('/' + $relative, [StringComparison]::OrdinalIgnoreCase)) { throw 'DataSafe transaction entry identity/path is invalid.' }
  $destinationLength = $location.Length - 14 - 1 - $relative.Length
  if ($destinationLength -le 0) { throw 'DataSafe transaction entry destination path is invalid.' }
  # Reuse the authoritative manifest type/metadata/hash/path validator. The
  # synthetic source is only a schema boundary, not a new selected source.
  $manifest = [PSCustomObject]@{
    schema = 'datasafe.manifest'; formatVersion = 2; createdUtc = '2026-01-01T00:00:00.0000000Z'
    sources = @([PSCustomObject]@{ sourceId = $SourceId; path = $RepositoryRoot; relativeDestination = $location.Substring(14, $destinationLength) })
    entries = @($Entry); sourceErrors = @()
  }
  $null = ConvertTo-DataSafeValidatedManifest $manifest
}

function Assert-DataSafeTransactionSchema($Transaction, [string]$Path) {
  $version = Get-DataSafeManifestScalar $Transaction 'formatVersion' 'integer'
  $fields = @('schema','formatVersion','operationSchemaVersion','transactionId','computerId','repositoryRoot','state','createdUtc','previousBackupTimestamp','displayHistoryFolder','previousManifest','currentManifest','stageBytes','peakRequiredBytes','metadataOverheadBytes','reserveBytes','operations','failure')
  if ($version -ge 2) { $fields += @('previousPointer','pointerCaptured','destinationFileSystem','timestampToleranceTicks') }
  if ($version -eq 3) { $fields += 'mutationIntent' }
  Assert-DataSafeTransactionFields $Transaction $fields
  if ((Get-DataSafeManifestScalar $Transaction 'schema') -cne 'datasafe.transaction' -or
      $version -notin @(1,2,3) -or
      (Get-DataSafeManifestScalar $Transaction 'operationSchemaVersion' 'integer') -ne 1) { throw 'DataSafe transaction schema version is invalid.' }
  $id = Get-DataSafeManifestScalar $Transaction 'transactionId'; Assert-DataSafeComputerId $id
  $computerId = Get-DataSafeManifestScalar $Transaction 'computerId'; Assert-DataSafeComputerId $computerId
  $root = Get-DataSafeManifestScalar $Transaction 'repositoryRoot'; Assert-DataSafeManifestSourcePath $root
  $repo = Read-DataSafeRepository $root
  if ($repo.ComputerId -ine $computerId) { throw 'DataSafe transaction repository identity is invalid.' }
  Assert-DataSafeTransactionPath $Path (Join-Path $repo.TransactionRoot ($id + '.json'))
  $state = Get-DataSafeManifestScalar $Transaction 'state'
  if ($state -cnotin @('staging','prepared','applying','committed','rollingBack','rolledBack')) { throw 'DataSafe transaction state is invalid.' }
  Assert-DataSafeManifestUtc (Get-DataSafeManifestScalar $Transaction 'createdUtc')
  $prior = Get-DataSafeManifestScalar $Transaction 'previousBackupTimestamp' -AllowNull
  $history = Get-DataSafeManifestScalar $Transaction 'displayHistoryFolder' -AllowNull
  if ($null -eq $prior) {
    if ($null -ne $history) { throw 'DataSafe transaction history timestamp is invalid.' }
  } else {
    Assert-DataSafeManifestUtc $prior
    $timestamp = [datetime]::ParseExact($prior, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $base = 'Backup from ' + $timestamp.ToString('yyyy-MM-dd HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
    if ($null -eq $history -or $history -cnotmatch ('^' + [regex]::Escape($base) + '(?: \([2-9][0-9]*\)| \(1[0-9]+\))?$')) { throw 'DataSafe transaction history display path is invalid.' }
  }
  $failure = Get-DataSafeManifestScalar $Transaction 'failure' -AllowNull
  if ($null -ne $failure -and $failure.Length -gt 4096) { throw 'DataSafe transaction failure diagnostic is too large.' }
  if ($state -cin @('prepared','applying','committed') -and $null -ne $failure) { throw 'DataSafe transaction prepared/applying/committed state cannot contain a failure.' }
  foreach ($name in @('stageBytes','peakRequiredBytes','metadataOverheadBytes','reserveBytes')) {
    if ((Get-DataSafeManifestScalar $Transaction $name 'integer') -lt 0) { throw 'DataSafe transaction byte allowance is invalid.' }
  }
  if ($Transaction.metadataOverheadBytes -lt 1048576 -or $Transaction.reserveBytes -lt 5368709120 -or
      [decimal]$Transaction.peakRequiredBytes -ne ([decimal]$Transaction.stageBytes + $Transaction.metadataOverheadBytes + $Transaction.reserveBytes)) { throw 'DataSafe transaction metadata/space allowance is invalid.' }
  if ($Transaction.operations -isnot [array]) { throw 'DataSafe transaction operations schema requires an array.' }
  Assert-DataSafeTransactionManifestFields $Transaction.currentManifest
  $current = ConvertTo-DataSafeValidatedManifest $Transaction.currentManifest
  $previous = $null
  if ($null -ne $Transaction.previousManifest) {
    Assert-DataSafeTransactionManifestFields $Transaction.previousManifest
    $previous = ConvertTo-DataSafeValidatedManifest $Transaction.previousManifest
  }
  if ($version -eq 1) {
    # Legacy snapshots predate portable-attribute normalization. Validate all
    # scalars above, but compare operations to their exact original snapshots.
    foreach ($pair in @(@{Raw=$Transaction.previousManifest; Valid=$previous},@{Raw=$Transaction.currentManifest; Valid=$current})) {
      if ($null -eq $pair.Raw) { continue }
      foreach ($e in $pair.Valid.entries) {
        $raw=@($pair.Raw.entries | Where-Object { $_.sourceId -ieq $e.sourceId -and $_.relativePath -ieq $e.relativePath })[0]
        $e.attributes=$raw.attributes
      }
    }
  }
  if ($current.sourceErrors.Count -ne 0 -or ($null -ne $previous -and $previous.sourceErrors.Count -ne 0)) { throw 'DataSafe transaction manifest contains source errors.' }
  if ($prior -cne $(if ($null -ne $previous) { $previous.createdUtc } else { $null })) { throw 'DataSafe transaction previous manifest timestamp does not match.' }
  if ($version -ge 2) {
    $fs = Get-DataSafeManifestScalar $Transaction 'destinationFileSystem'
    $policy = Get-DataSafeFilesystemCapabilities $fs
    if (-not $policy.Supported -or $fs -cne $fs.ToUpperInvariant() -or
        (Get-DataSafeManifestScalar $Transaction 'timestampToleranceTicks' 'integer') -ne $policy.TimestampToleranceTicks) { throw 'DataSafe transaction destination timestamp policy is invalid.' }
    if ($Transaction.pointerCaptured -isnot [bool]) { throw 'DataSafe transaction pointer capture schema is invalid.' }
    if (-not $Transaction.pointerCaptured -and $null -ne $Transaction.previousPointer) { throw 'DataSafe transaction uncaptured pointer must be null.' }
    if ($Transaction.pointerCaptured -and (($null -eq $Transaction.previousPointer) -ne ($null -eq $previous))) { throw 'DataSafe transaction previous pointer/manifest identity is invalid.' }
    if ($Transaction.pointerCaptured -and $null -ne $Transaction.previousPointer) {
      $null = Assert-DataSafeCurrentPointer $repo $Transaction.previousPointer $previous
    }
  }
  $oldEntries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  $newEntries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  $sources = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($source in $current.sources) { $sources.Add($source.sourceId, $source) }
  foreach ($pair in @(@{ Manifest = $previous; Entries = $oldEntries }, @{ Manifest = $current; Entries = $newEntries })) {
    if ($null -eq $pair.Manifest) { continue }
    foreach ($entry in $pair.Manifest.entries) {
      if (-not $entry.versionLocation.StartsWith('Latest Backup/', [StringComparison]::Ordinal)) { throw 'DataSafe transaction manifest is not a latest baseline.' }
      $pair.Entries.Add(($entry.sourceId + [char]0 + $entry.relativePath), $entry)
    }
  }
  $diff = Compare-DataSafeManifests $previous $current
  $expectedOperations = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($row in @(@{ Group = 'Added'; Kind = 'add' }, @{ Group = 'ContentChanged'; Kind = 'replace' }, @{ Group = 'MetadataChanged'; Kind = 'metadata' }, @{ Group = 'Deleted'; Kind = 'delete' })) {
    foreach ($entry in $diff.($row.Group)) { $expectedOperations.Add(($entry.sourceId + [char]0 + $entry.relativePath), $row.Kind) }
  }
  if ($version -eq 1) {
    $expectedOperations.Clear()
    foreach ($key in $newEntries.Keys) {
      $new=$newEntries[$key]
      if (-not $oldEntries.ContainsKey($key)) { $expectedOperations[$key]='add'; continue }
      $old=$oldEntries[$key]
      if ($old.entryType -cne $new.entryType -or $old.sha256 -cne $new.sha256) { $expectedOperations[$key]='replace' }
      elseif ($old.length -ne $new.length -or $old.modifiedUtc -cne $new.modifiedUtc -or $old.attributes -ne $new.attributes -or $old.versionLocation -cne $new.versionLocation) { $expectedOperations[$key]='metadata' }
    }
    foreach ($key in $oldEntries.Keys) { if (-not $newEntries.ContainsKey($key)) { $expectedOperations[$key]='delete' } }
  }
  if ($Transaction.operations.Count -ne $expectedOperations.Count) { throw 'DataSafe transaction operation set does not match its complete manifests.' }
  if ($null -ne $previous) {
    foreach ($source in $previous.sources) {
      $priorFiles = @($previous.entries | Where-Object { $_.sourceId -ieq $source.sourceId -and $_.entryType -ceq 'file' }).Count
      $deletedFiles = @($diff.Deleted | Where-Object { $_.sourceId -ieq $source.sourceId -and $_.entryType -ceq 'file' }).Count
      if ($priorFiles -gt 0 -and (($deletedFiles -ge 20 -and [decimal]$deletedFiles * 10 -ge $priorFiles) -or [decimal]$deletedFiles * 2 -ge $priorFiles)) { throw 'DataSafe transaction manifests require deletion review.' }
    }
  }
  $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $currentPaths = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  $oldPaths = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  $stagePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $sourcePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $total = [decimal]0; $sequence = 0
  foreach ($op in $Transaction.operations) {
    $opFields = @('sequence','kind','sourceId','relativePath','sourcePath','currentPath','oldCurrentPath','historyPath','stagedPath','expectedOldSha256','expectedNewSha256','oldEntry','newEntry','status','error')
    if ($version -ge 2) {
      $opFields += @('archiveState','promoteState','metadataState')
      foreach ($substep in @('archiveState','promoteState','metadataState')) {
        if ((Get-DataSafeManifestScalar $op $substep) -cnotin @('pending','done')) { throw 'DataSafe transaction substep state is invalid.' }
      }
    }
    Assert-DataSafeTransactionFields $op $opFields
    $sequence++
    if ((Get-DataSafeManifestScalar $op 'sequence' 'integer') -ne $sequence) { throw 'DataSafe transaction operation sequence is invalid or duplicate.' }
    $kind = Get-DataSafeManifestScalar $op 'kind'
    $status = Get-DataSafeManifestScalar $op 'status'
    if ($kind -cnotin @('add','replace','metadata','delete') -or $status -cnotin @('pending','copying','verified','failed')) { throw 'DataSafe transaction operation kind/status is invalid.' }
    $errorText = Get-DataSafeManifestScalar $op 'error' -AllowNull
    if ($null -ne $errorText -and $errorText.Length -gt 4096) { throw 'DataSafe transaction operation diagnostic is too large.' }
    if ($state -cin @('prepared','applying','committed') -and ($status -cne 'verified' -or $null -ne $errorText)) { throw 'DataSafe transaction prepared state requires verified operations without failures.' }
    $sourceId = Get-DataSafeManifestScalar $op 'sourceId'
    $relative = ConvertTo-DataSafeManifestRelativePath (Get-DataSafeManifestScalar $op 'relativePath')
    $key = $sourceId + [char]0 + $relative
    if ([string]::IsNullOrWhiteSpace($sourceId) -or -not $keys.Add($key)) { throw 'DataSafe transaction duplicate operation identity.' }
    if (-not $expectedOperations.ContainsKey($key) -or $kind -cne $expectedOperations[$key]) { throw 'DataSafe transaction operation kind/identity does not match its manifests.' }
    $old = $op.oldEntry; $new = $op.newEntry
    if (($kind -ceq 'add' -and ($null -ne $old -or $null -eq $new)) -or
        ($kind -ceq 'delete' -and ($null -eq $old -or $null -ne $new)) -or
        ($kind -cin @('replace','metadata') -and ($null -eq $old -or $null -eq $new))) { throw 'DataSafe transaction operation entry schema is invalid.' }
    foreach ($entry in @($old,$new)) { if ($null -ne $entry) { Assert-DataSafeTransactionEntry $entry $sourceId $relative $root } }
    $expectedOldEntry = if ($oldEntries.ContainsKey($key)) { $oldEntries[$key] } else { $null }
    $expectedNewEntry = if ($newEntries.ContainsKey($key)) { $newEntries[$key] } else { $null }
    if ((ConvertTo-Json -InputObject $old -Depth 12 -Compress) -cne (ConvertTo-Json -InputObject $expectedOldEntry -Depth 12 -Compress) -or
        (ConvertTo-Json -InputObject $new -Depth 12 -Compress) -cne (ConvertTo-Json -InputObject $expectedNewEntry -Depth 12 -Compress)) { throw 'DataSafe transaction operation entry does not match its complete manifest.' }
    if ($kind -ceq 'metadata' -and ($old.entryType -cne $new.entryType -or $old.sha256 -cne $new.sha256 -or $old.length -ne $new.length -or ($version -ge 2 -and $old.versionLocation -cne $new.versionLocation))) { throw 'DataSafe transaction metadata operation changes content/location.' }
    if ($kind -ceq 'replace' -and $old.entryType -ceq $new.entryType -and $old.sha256 -ceq $new.sha256 -and $old.versionLocation -ceq $new.versionLocation) { throw 'DataSafe transaction replace operation has no content/location change.' }
    $oldHash = Get-DataSafeManifestScalar $op 'expectedOldSha256' -AllowNull
    $newHash = Get-DataSafeManifestScalar $op 'expectedNewSha256' -AllowNull
    if ($oldHash -cne $(if ($null -ne $old) { $old.sha256 } else { $null }) -or
        $newHash -cne $(if ($null -ne $new) { $new.sha256 } else { $null })) { throw 'DataSafe transaction expected hash does not match its entry.' }
    $entry = if ($null -ne $new) { $new } else { $old }
    Assert-DataSafeTransactionPath $op.currentPath (Join-Path $root $entry.versionLocation)
    if ($null -ne $new) {
      if ($currentPaths.ContainsKey($op.currentPath)) { throw 'DataSafe transaction duplicate current path.' }
      $currentPaths.Add($op.currentPath, $new)
    }
    $expectedOld = if ($null -ne $old) { Join-Path $root $old.versionLocation } else { $null }
    Assert-DataSafeTransactionPath $op.oldCurrentPath $expectedOld -AllowNull
    if ($null -ne $old) {
      if ($oldPaths.ContainsKey($op.oldCurrentPath)) { throw 'DataSafe transaction duplicate old current path.' }
      $oldPaths.Add($op.oldCurrentPath, $old)
    }
    $expectedHistory = $null
    if ($kind -cin @('replace','delete')) {
      if ($null -eq $history) { throw 'DataSafe transaction history path requires a previous timestamp.' }
      $category = if ($kind -ceq 'delete') { 'Deleted Files' } else { 'Previous Versions' }
      $expectedHistory = Join-Path (Join-Path (Join-Path $repo.HistoryRoot $history) $category) $old.versionLocation.Substring(14)
    }
    Assert-DataSafeTransactionPath $op.historyPath $expectedHistory -AllowNull
    $expectedStage = $null
    if ($null -ne $new -and $new.entryType -ceq 'file' -and $kind -cin @('add','replace')) {
      $expectedStage = Join-Path (Join-Path $repo.StagingRoot $id) $new.versionLocation.Substring(14)
      $total += [decimal]$new.length
      if (-not $stagePaths.Add($expectedStage)) { throw 'DataSafe transaction duplicate staged path.' }
    }
    Assert-DataSafeTransactionPath $op.stagedPath $expectedStage -AllowNull
    if ($kind -ceq 'delete') {
      if ($null -ne $op.sourcePath) { throw 'DataSafe transaction deleted operation source path is invalid.' }
    } else {
      $source = Get-DataSafeManifestScalar $op 'sourcePath'; Assert-DataSafeManifestSourcePath $source
      $suffix = '\' + $relative.Replace('/', '\')
      if (-not $source.Replace('/', '\').EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) -or -not $sourcePaths.Add($source)) { throw 'DataSafe transaction source path does not match its operation identity or is duplicate.' }
      $selected = $sources[$sourceId].path
      $child = Join-Path $selected $relative
      $selectedFile = $new.entryType -ceq 'file' -and $relative -ieq [IO.Path]::GetFileName($selected) -and $source.Equals($selected, [StringComparison]::OrdinalIgnoreCase)
      if (-not $selectedFile -and -not $source.Replace('/', '\').Equals($child.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'DataSafe transaction source path escapes its manifest selection.' }
    }
  }
  # New and old trees are checked separately: file-to-directory changes are
  # legitimate, but neither individual tree may traverse a file destination.
  foreach ($paths in @($currentPaths,$oldPaths)) {
    foreach ($pathKey in $paths.Keys) {
      $parent = [IO.Path]::GetDirectoryName($pathKey)
      while ($parent.Length -gt $repo.LatestRoot.Length) {
        if ($paths.ContainsKey($parent) -and $paths[$parent].entryType -ceq 'file') { throw 'DataSafe transaction operation path traverses a file.' }
        $parent = [IO.Path]::GetDirectoryName($parent)
      }
    }
  }
  if ($total -ne [decimal]$Transaction.stageBytes) { throw 'DataSafe transaction stage byte count is invalid.' }
  if ($version -eq 3) { Assert-DataSafeMutationIntentSchema $Transaction $repo }
  return $repo
}

function Read-DataSafeTransactionDocument([string]$Path, [string]$ExpectedPath) {
  Assert-DataSafeNoReparsePath $Path
  $encoding = New-Object Text.UTF8Encoding($false, $true)
  $json = $encoding.GetString([IO.File]::ReadAllBytes((ConvertTo-DataSafeExtendedPath $Path)))
  $result = ConvertFrom-DataSafeTransactionJson $json
  $null = Assert-DataSafeTransactionSchema $result $ExpectedPath
  return $result
}

function Read-DataSafeTransaction([string]$Path) {
  try { return Read-DataSafeTransactionDocument $Path $Path }
  catch { throw "DataSafe transaction JSON is invalid: $($_.Exception.Message)" }
}

function Write-DataSafeTransactionJournal($Transaction, [string]$Path, [switch]$CreateOnly) {
  $null = Assert-DataSafeTransactionSchema $Transaction $Path
  $json = ConvertTo-Json -InputObject $Transaction -Depth 32
  if ([decimal]2 * [Text.Encoding]::UTF8.GetByteCount($json) -gt $Transaction.metadataOverheadBytes) { throw 'DataSafe transaction durable metadata exceeds plan allowance.' }
  $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.transaction-' + [guid]::NewGuid().ToString('N') + '.tmp')
  try {
    # Existing primitive flushes data to disk and verifies bytes. Validate the
    # complete strict transaction schema on disk BEFORE atomic publication.
    Write-DataSafeAtomicJson $temporary $Transaction -CreateOnly
    $null = Read-DataSafeTransactionDocument $temporary $Path
    Assert-DataSafeNoReparsePath $Path
    if (-not $CreateOnly -and (Test-DataSafeFile $Path)) {
      [IO.File]::Replace((ConvertTo-DataSafeExtendedPath $temporary), (ConvertTo-DataSafeExtendedPath $Path), [Management.Automation.Language.NullString]::Value)
    } else { Move-DataSafeSameVolume $temporary $Path }
  } finally {
    if (Test-DataSafeFile $temporary) { [IO.File]::Delete((ConvertTo-DataSafeExtendedPath $temporary)) }
  }
}

function Assert-DataSafeTransactionSpaceAndHistory($Transaction, $Repository, [long]$RemainingStageBytes) {
  $null = Assert-DataSafeTransactionSchema $Transaction (Join-Path $Repository.TransactionRoot ($Transaction.transactionId + '.json'))
  if ($null -ne $Transaction.displayHistoryFolder) {
    $path = Join-Path $Repository.HistoryRoot $Transaction.displayHistoryFolder
    Assert-DataSafeNoReparsePath $path
    if ((Test-DataSafeFile $path) -or (Test-DataSafeDirectory $path)) { throw 'DataSafe transaction history display name is already occupied.' }
  }
  $required = [decimal]$RemainingStageBytes + $Transaction.metadataOverheadBytes + $Transaction.reserveBytes
  if ([decimal](Get-DataSafeFreeBytes $Repository.Root) -lt $required) { throw 'DataSafe transaction has insufficient actual free space.' }
}

function Assert-DataSafeTransactionSelections($Transaction) {
  foreach ($source in $Transaction.currentManifest.sources) {
    try {
      Assert-DataSafeNoReparsePath $source.path
      $extended = ConvertTo-DataSafeExtendedPath $source.path
      $attributes = [IO.File]::GetAttributes($extended)
      if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        # Check enumeration access even when this source has no operations.
        # This returns names only, without traversing any child/reparse entry.
        $null = [IO.Directory]::GetFileSystemEntries($extended)
      } else {
        $entries = @($Transaction.currentManifest.entries | Where-Object { $_.sourceId -ieq $source.sourceId })
        if ($entries.Count -ne 1 -or $entries[0].entryType -cne 'file' -or $entries[0].relativePath -ine [IO.Path]::GetFileName($source.path)) { throw 'Selected-file source entry schema changed.' }
        $stream = [IO.File]::Open($extended, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $stream.Dispose()
      }
    } catch { throw "DataSafe source selection is unavailable: $($source.path): $($_.Exception.Message)" }
  }
}

function New-DataSafeTransaction($Repository, $Plan) {
  $root = Get-DataSafeManifestScalar $Repository 'Root'
  $repo = Read-DataSafeRepository $root
  foreach ($name in @('FormatVersion','ComputerId','ComputerName','Root','LatestRoot','HistoryRoot','MetadataRoot','ManifestRoot','TransactionRoot','StagingRoot')) {
    $kind = if ($name -eq 'FormatVersion') { 'integer' } else { 'string' }
    $value = Get-DataSafeManifestScalar $Repository $name $kind
    if ($value -ine $repo.$name) { throw "DataSafe transaction repository identity/path mismatch: $name" }
  }
  if ($Plan -isnot [PSCustomObject] -or $Plan.BlockingErrors -isnot [array] -or $Plan.BlockingErrors.Count -ne 0 -or
      $Plan.DeletionReviewRequired -isnot [bool] -or $Plan.DeletionReviewRequired) { throw 'DataSafe transaction plan is blocked or requires deletion review.' }
  if ((Get-DataSafeManifestScalar $Plan 'OperationSchemaVersion' 'integer') -ne 1 -or $Plan.Operations -isnot [array]) { throw 'DataSafe transaction plan operation schema is invalid.' }
  $id = Get-DataSafeManifestScalar $Plan 'TransactionId'; Assert-DataSafeComputerId $id
  $id = ([guid]$id).ToString('D')
  $path = Join-Path $repo.TransactionRoot ($id + '.json')
  $staging = Join-Path $repo.StagingRoot $id
  $transaction = [PSCustomObject][ordered]@{
    schema = 'datasafe.transaction'; formatVersion = 3; operationSchemaVersion = 1
    transactionId = $id; computerId = $repo.ComputerId; repositoryRoot = $repo.Root; state = 'staging'
    createdUtc = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    previousBackupTimestamp = Get-DataSafeManifestScalar $Plan 'PreviousBackupTimestamp' -AllowNull
    displayHistoryFolder = Get-DataSafeManifestScalar $Plan 'DisplayHistoryFolder' -AllowNull
    previousManifest = $(if ($null -ne $Plan.PreviousManifest) { ConvertTo-DataSafeValidatedManifest $Plan.PreviousManifest } else { $null })
    currentManifest = ConvertTo-DataSafeValidatedManifest $Plan.CurrentManifest
    stageBytes = Get-DataSafeManifestScalar $Plan 'StageBytes' 'integer'
    peakRequiredBytes = Get-DataSafeManifestScalar $Plan 'PeakRequiredBytes' 'integer'
    metadataOverheadBytes = Get-DataSafeManifestScalar $Plan 'MetadataOverheadBytes' 'integer'
    reserveBytes = Get-DataSafeManifestScalar $Plan 'ReserveBytes' 'integer'
    operations = @(); failure = $null
    destinationFileSystem = Get-DataSafeManifestScalar $Plan 'DestinationFileSystem'
    timestampToleranceTicks = Get-DataSafeManifestScalar $Plan 'TimestampToleranceTicks' 'integer'
    previousPointer = $null; pointerCaptured = $false; mutationIntent = $null
  }
  # Detach all manifest/operation metadata from the caller before retaining it.
  $transaction = ConvertFrom-DataSafeTransactionJson (ConvertTo-Json -InputObject $transaction -Depth 32)
  $transaction.operations = @(foreach ($op in $Plan.Operations) {
    Assert-DataSafeTransactionFields $op @('sequence','kind','sourceId','relativePath','sourcePath','currentPath','oldCurrentPath','historyPath','stagedPath','expectedOldSha256','expectedNewSha256','oldEntry','newEntry','status')
    if ((Get-DataSafeManifestScalar $op 'status') -cne 'pending') { throw 'DataSafe transaction plan operation must be pending.' }
    $copy = ConvertFrom-DataSafeTransactionJson (ConvertTo-Json -InputObject $op -Depth 32)
    $copy | Add-Member -NotePropertyName error -NotePropertyValue $null
    foreach ($name in @('archiveState','promoteState','metadataState')) { $copy | Add-Member $name pending }
    $copy
  })
  $null = Assert-DataSafeTransactionSchema $transaction $path
  $ownerKey = Get-DataSafeTransactionOwnerKey $repo.Root $repo.ComputerId $id
  if ($script:DataSafeTransactionOwners.ContainsKey($ownerKey)) {
    $existing = $script:DataSafeTransactionOwners[$ownerKey]
    if ($null -ne $existing.Handle -and $existing.Handle.CanWrite) { throw 'A DataSafe backup or restore is already running. Wait for it to finish before starting another operation.' }
    throw 'DataSafe transaction UUID/path is already occupied; existing ownership will not be overwritten.'
  }
  $lockPath = Join-Path $repo.MetadataRoot 'operation.lock'
  Assert-DataSafeNoReparsePath $lockPath
  $handle = Acquire-DataSafeOperationLock (ConvertTo-DataSafeExtendedPath $lockPath)
  try {
    Assert-DataSafeTransactionSelections $transaction
    Assert-DataSafeTransactionSpaceAndHistory $transaction $repo $transaction.stageBytes
    foreach ($occupied in @($path,$staging)) {
      Assert-DataSafeNoReparsePath $occupied
      if ((Test-DataSafeFile $occupied) -or (Test-DataSafeDirectory $occupied)) { throw 'DataSafe transaction UUID/path is already occupied; existing content will not be overwritten.' }
    }
    Write-DataSafeTransactionJournal $transaction $path -CreateOnly
    Ensure-DataSafeDirectory $staging
    $script:DataSafeTransactionOwners[$ownerKey] = [PSCustomObject]@{
      Transaction = $transaction; Repository = $repo; Path = $path; LockPath = $lockPath; Handle = $handle
      Json = ConvertTo-Json -InputObject $transaction -Depth 32 -Compress
    }
    return $transaction
  } catch {
    Release-DataSafeOperationLock $handle (ConvertTo-DataSafeExtendedPath $lockPath)
    throw
  }
}

function Get-DataSafeTransactionOwner($Transaction) {
  $id = Get-DataSafeManifestScalar $Transaction 'transactionId'
  $ownerKey = Get-DataSafeTransactionOwnerKey (Get-DataSafeManifestScalar $Transaction 'repositoryRoot') (Get-DataSafeManifestScalar $Transaction 'computerId') $id
  if (-not $script:DataSafeTransactionOwners.ContainsKey($ownerKey)) { throw 'DataSafe transaction requires its live lock owner; disk reads do not restore authority.' }
  $owner = $script:DataSafeTransactionOwners[$ownerKey]
  if (-not [object]::ReferenceEquals($owner.Transaction, $Transaction) -or $null -eq $owner.Handle -or -not $owner.Handle.CanWrite) { throw 'DataSafe transaction requires its live lock owner.' }
  if ((ConvertTo-Json -InputObject $Transaction -Depth 32 -Compress) -cne $owner.Json) { throw 'DataSafe transaction in-memory metadata was changed outside its journal writer.' }
  $disk = Read-DataSafeTransaction $owner.Path
  if ((ConvertTo-Json -InputObject $disk -Depth 32 -Compress) -cne $owner.Json) { throw 'DataSafe transaction durable metadata was changed outside its live owner.' }
  return $owner
}

function Save-DataSafeOwnedTransaction($Owner) {
  Write-DataSafeTransactionJournal $Owner.Transaction $Owner.Path
  $Owner.Json = ConvertTo-Json -InputObject $Owner.Transaction -Depth 32 -Compress
}

function Get-DataSafeTransactionHash([string]$Path, [scriptblock]$HashProvider) {
  Assert-DataSafeNoReparsePath $Path
  $hash = if ($null -eq $HashProvider) { Get-DataSafeSha256 $Path } else { & $HashProvider $Path }
  if ($hash -isnot [string] -or $hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'DataSafe transaction hash provider returned an invalid SHA-256.' }
  return $hash.ToUpperInvariant()
}

function Assert-DataSafeTransactionSource($Operation, [scriptblock]$HashProvider) {
  $path = $Operation.sourcePath; $entry = $Operation.newEntry
  Assert-DataSafeNoReparsePath $path
  $extended = ConvertTo-DataSafeExtendedPath $path
  $attributes = [long][IO.File]::GetAttributes($extended)
  $isDirectory = ($attributes -band 16) -ne 0
  $modified = [IO.File]::GetLastWriteTimeUtc($extended).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
  if ($isDirectory -ne ($entry.entryType -ceq 'directory') -or (ConvertTo-DataSafePortableAttributes $attributes $isDirectory) -ne $entry.attributes -or $modified -cne $entry.modifiedUtc) { throw "DataSafe source snapshot changed after scan: $path" }
  if (-not $isDirectory) {
    $info = New-Object IO.FileInfo($extended)
    if ($info.Length -ne $entry.length -or (Get-DataSafeTransactionHash $path $HashProvider) -cne $Operation.expectedNewSha256) { throw "DataSafe source length/hash changed after scan: $path" }
  }
}

function Copy-DataSafeTransactionFile($Operation) {
  Assert-DataSafeNoReparsePath $Operation.sourcePath
  Assert-DataSafeNoReparsePath $Operation.stagedPath
  Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Operation.stagedPath))
  $source = [IO.File]::Open((ConvertTo-DataSafeExtendedPath $Operation.sourcePath), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    # CreateNew is essential: a collision is never a retry/overwrite.
    $target = New-Object IO.FileStream((ConvertTo-DataSafeExtendedPath $Operation.stagedPath), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536, [IO.FileOptions]::WriteThrough)
    try {
      $source.CopyTo($target, 65536)
      $target.Flush($true)
      if ($source.Position -ne $Operation.newEntry.length -or $target.Length -ne $Operation.newEntry.length) { throw 'DataSafe source short read or staged length mismatch.' }
    } finally { $target.Dispose() }
  } finally { $source.Dispose() }
}

function Assert-DataSafeTransactionStaged($Operation, [scriptblock]$HashProvider) {
  Assert-DataSafeNoReparsePath $Operation.stagedPath
  $info = Get-DataSafeFileEntry $Operation.stagedPath
  if ($null -eq $info -or $info.Length -ne $Operation.newEntry.length -or
      (Get-DataSafeTransactionHash $Operation.stagedPath $HashProvider) -cne $Operation.expectedNewSha256) { throw 'DataSafe staged file length/hash verification failed.' }
}

function Stage-DataSafeTransaction($Transaction, [scriptblock]$HashProvider = $null) {
  $owner = Get-DataSafeTransactionOwner $Transaction
  if ($Transaction.state -cne 'staging' -or $null -ne $Transaction.failure) { throw 'DataSafe transaction staging requires a fresh staging state.' }
  $active = $null
  try {
    Assert-DataSafeTransactionSelections $Transaction
    Assert-DataSafeTransactionSpaceAndHistory $Transaction $owner.Repository $Transaction.stageBytes
    foreach ($op in $Transaction.operations) {
      $active = $op
      if ($op.kind -cne 'delete') { Assert-DataSafeTransactionSource $op $HashProvider }
      if ($null -ne $op.stagedPath) {
        $op.status = 'copying'; Save-DataSafeOwnedTransaction $owner
        Copy-DataSafeTransactionFile $op
        Assert-DataSafeTransactionSource $op $HashProvider
        Assert-DataSafeTransactionStaged $op $HashProvider
      }
      $op.status = 'verified'; Save-DataSafeOwnedTransaction $owner
    }
    # Recheck earlier copies after all later I/O: corruption/source changes
    # introduced while processing another operation cannot escape preparation.
    foreach ($op in $Transaction.operations) {
      $active = $op
      if ($op.kind -cne 'delete') { Assert-DataSafeTransactionSource $op $HashProvider }
      if ($null -ne $op.stagedPath) { Assert-DataSafeTransactionStaged $op $HashProvider }
    }
    Assert-DataSafeTransactionSelections $Transaction
    Assert-DataSafeTransactionSpaceAndHistory $Transaction $owner.Repository 0
    $Transaction.state = 'prepared'
    Save-DataSafeOwnedTransaction $owner
    return $Transaction
  } catch {
    $original = $_
    $Transaction.state = 'staging'
    $message = $original.Exception.Message
    if ($message.Length -gt 4096) { $message = $message.Substring(0,4096) }
    $Transaction.failure = $message
    if ($null -ne $active) { $active.status = 'failed'; $active.error = $message }
    try { Save-DataSafeOwnedTransaction $owner } catch {
      # A disconnected/full/unwritable destination may prevent diagnostics.
      # Never pretend the prior readable journal became prepared successfully.
      throw "DataSafe staging failed: $message; failure journal could not be persisted: $($_.Exception.Message)"
    }
    throw $original
  }
}

function Set-DataSafeTransactionState($Transaction, [string]$State) {
  if ($State -cnotin @('prepared','applying','committed','rollingBack','rolledBack')) { throw 'DataSafe transaction state is invalid.' }
  $id = Get-DataSafeManifestScalar $Transaction 'transactionId'
  $ownerKey = Get-DataSafeTransactionOwnerKey (Get-DataSafeManifestScalar $Transaction 'repositoryRoot') (Get-DataSafeManifestScalar $Transaction 'computerId') $id
  # Idempotence is allowed on the original terminal object, but must not
  # dispose/delete a newer transaction's repository lock.
  if ($script:DataSafeTransactionOwners.ContainsKey($ownerKey)) {
    $existing = $script:DataSafeTransactionOwners[$ownerKey]
    if ([object]::ReferenceEquals($existing.Transaction, $Transaction) -and $null -eq $existing.Handle -and $Transaction.state -ceq $State -and $State -cin @('committed','rolledBack')) {
      if ((ConvertTo-Json -InputObject $Transaction -Depth 32 -Compress) -cne $existing.Json) { throw 'DataSafe terminal transaction caller metadata no longer matches its durable state.' }
      $disk = Read-DataSafeTransaction $existing.Path
      if ($disk.state -cne $State -or (ConvertTo-Json -InputObject $disk -Depth 32 -Compress) -cne $existing.Json) { throw 'DataSafe terminal transaction durable metadata no longer matches its owner.' }
      return
    }
  }
  $owner = Get-DataSafeTransactionOwner $Transaction
  if ($Transaction.state -ceq $State) { return }
  $graph = @{ staging = @('rollingBack'); prepared = @('applying','rollingBack'); applying = @('committed','rollingBack'); rollingBack = @('rolledBack'); committed = @(); rolledBack = @() }
  if ($State -cnotin $graph[$Transaction.state]) { throw "DataSafe transaction illegal state transition: $($Transaction.state) -> $State" }
  if ($State -ceq 'committed') { Assert-DataSafeTransactionCommit $owner }
  if ($State -ceq 'rolledBack') { Initialize-DataSafeApplyJournal $owner; Assert-DataSafeTransactionRollback $owner }
  if ($State -ceq 'rollingBack') {
    $pointer = Read-DataSafeCurrentPointer $owner.Repository
    if ($null -ne $pointer -and $pointer.transactionId -ieq $Transaction.transactionId) { throw 'DataSafe committed pointer cannot be rolled back.' }
  }
  $old = $Transaction.state; $Transaction.state = $State
  try { Save-DataSafeOwnedTransaction $owner } catch { $Transaction.state = $old; throw }
  if ($State -cin @('committed','rolledBack')) {
    Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath)
    $owner.Handle = $null
  }
}

# Pointer v1 is the only commit point. Its path is canonical, relative to
# .datasafe, and derived solely from its UUID; arbitrary paths are never read.
function Assert-DataSafeCurrentPointer($Repository, $Pointer, $ExpectedManifest = $null) {
  Assert-DataSafeTransactionFields $Pointer @('schema','formatVersion','transactionId','manifestPath','sha256')
  if ((Get-DataSafeManifestScalar $Pointer 'schema') -cne 'datasafe.current-manifest' -or
      (Get-DataSafeManifestScalar $Pointer 'formatVersion' 'integer') -ne 1) { throw 'DataSafe current pointer schema is invalid.' }
  $id = Get-DataSafeManifestScalar $Pointer 'transactionId'; Assert-DataSafeComputerId $id
  $canonical = ([guid]$id).ToString('D')
  if ($id -cne $canonical -or (Get-DataSafeManifestScalar $Pointer 'manifestPath') -cne ('manifests/' + $canonical + '.json')) { throw 'DataSafe current pointer path/UUID is not canonical.' }
  $hash = Get-DataSafeManifestScalar $Pointer 'sha256'
  if ($hash -cnotmatch '^[A-F0-9]{64}$') { throw 'DataSafe current pointer hash schema is invalid.' }
  $path = Join-Path $Repository.MetadataRoot $Pointer.manifestPath
  Assert-DataSafeNoReparsePath $path
  if (-not (Test-DataSafeFile $path) -or (Get-DataSafeSha256 $path) -cne $hash) { throw 'DataSafe current pointer manifest hash verification failed.' }
  $manifest = Read-DataSafeManifest $path
  if ($null -ne $ExpectedManifest -and (ConvertTo-Json $manifest -Depth 32 -Compress) -cne (ConvertTo-Json (ConvertTo-DataSafeValidatedManifest $ExpectedManifest) -Depth 32 -Compress)) { throw 'DataSafe current pointer does not match the transaction manifest.' }
  return $path
}

function Read-DataSafeCurrentPointer($Repository) {
  $path = Join-Path $Repository.MetadataRoot 'current-manifest.json'
  Assert-DataSafeNoReparsePath $path
  if (Test-DataSafeDirectory $path) { throw 'DataSafe current pointer path is occupied by a directory.' }
  if (-not (Test-DataSafeFile $path)) { return $null }
  try {
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $pointer = ConvertFrom-DataSafeTransactionJson ($encoding.GetString([IO.File]::ReadAllBytes((ConvertTo-DataSafeExtendedPath $path))))
    $null = Assert-DataSafeCurrentPointer $Repository $pointer
    return $pointer
  } catch { throw "DataSafe current pointer is invalid: $($_.Exception.Message)" }
}

function Test-DataSafeTransactionObject([string]$Path, $Entry, [switch]$Metadata, [long]$TimestampToleranceTicks = 0) {
  Assert-DataSafeNoReparsePath $Path
  if ($null -eq $Entry) { return (-not (Test-DataSafeFile $Path) -and -not (Test-DataSafeDirectory $Path)) }
  $extended = ConvertTo-DataSafeExtendedPath $Path
  if ($Entry.entryType -ceq 'directory') { if (-not (Test-DataSafeDirectory $Path)) { return $false } }
  else {
    if (-not (Test-DataSafeFile $Path)) { return $false }
    $info = New-Object IO.FileInfo($extended)
    if ($info.Length -ne $Entry.length -or (Get-DataSafeSha256 $Path) -cne $Entry.sha256) { return $false }
  }
  if ($Metadata) {
    if ($TimestampToleranceTicks -notin @([long]0,[long]100000,[long]20000000)) { throw 'DataSafe destination timestamp tolerance is invalid.' }
    $expected = [datetime]::ParseExact($Entry.modifiedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $actual = [IO.File]::GetLastWriteTimeUtc($extended)
    if ((ConvertTo-DataSafePortableAttributes ([long][IO.File]::GetAttributes($extended)) ($Entry.entryType -ceq 'directory')) -ne $Entry.attributes -or
        [Math]::Abs($actual.Ticks - $expected.Ticks) -gt $TimestampToleranceTicks) { return $false }
  }
  return $true
}

function Get-DataSafeTransactionTreePaths($Repository, $Manifest) {
  $paths = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  if ($null -ne $Manifest) {
    foreach ($entry in $Manifest.entries) {
      $path = Join-Path $Repository.Root $entry.versionLocation
      $paths[$path] = $entry
      $parent = [IO.Path]::GetDirectoryName($path)
      while ($parent.Length -gt $Repository.LatestRoot.Length) {
        if (-not $paths.ContainsKey($parent)) { $paths[$parent] = [PSCustomObject]@{entryType='directory'; structural=$true} }
        $parent = [IO.Path]::GetDirectoryName($parent)
      }
    }
  }
  return ,$paths
}

function Assert-DataSafeTransactionTree($Repository, $Manifest, [switch]$Metadata, [long]$TimestampToleranceTicks = 0) {
  $paths = Get-DataSafeTransactionTreePaths $Repository $Manifest
  foreach ($path in $paths.Keys) {
    $entry = $paths[$path]
    if ($null -ne $entry.PSObject.Properties['structural']) {
      Assert-DataSafeNoReparsePath $path
      if (-not (Test-DataSafeDirectory $path)) { throw 'DataSafe manifest parent directory is missing.' }
    } elseif (-not (Test-DataSafeTransactionObject $path $entry -Metadata:$Metadata -TimestampToleranceTicks $TimestampToleranceTicks)) { throw "DataSafe current tree hash/type/metadata verification failed: $path" }
  }
  $pending = New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($Repository.LatestRoot)
  while ($pending.Count) {
    $directory = $pending.Pop(); Assert-DataSafeNoReparsePath $directory
    foreach ($path in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $directory))) {
      $ordinary = ConvertFrom-DataSafeExtendedPath $path
      Assert-DataSafeNoReparsePath $ordinary
      if (-not $paths.ContainsKey($ordinary)) { throw "DataSafe current tree has unknown content: $ordinary" }
      if (Test-DataSafeDirectory $ordinary) { $pending.Push($ordinary) }
    }
  }
}

function Set-DataSafeTransactionMetadata([string]$Path, $Entry) {
  Set-DataSafeTransactionMetadataSteps $Path $Entry $null $null $null
}

function Set-DataSafeTransactionMetadataSteps([string]$Path,$Entry,$Owner,$Operation,[scriptblock]$AfterOperation) {
  Assert-DataSafeNoReparsePath $Path
  $extended = ConvertTo-DataSafeExtendedPath $Path
  # Clear read-only for time updates, then restore the supported ordinary flags.
  [IO.File]::SetAttributes($extended, [IO.FileAttributes]::Normal)
  if ($null -ne $Owner) { Send-DataSafeTransactionBoundary $Owner $Operation 'metadata-attributes-cleared' $AfterOperation }
  $time = [datetime]::ParseExact($Entry.modifiedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
  if ($Entry.entryType -ceq 'directory') { [IO.Directory]::SetLastWriteTimeUtc($extended, $time) }
  else { [IO.File]::SetLastWriteTimeUtc($extended, $time) }
  if ($null -ne $Owner) { Send-DataSafeTransactionBoundary $Owner $Operation 'metadata-time-filesystem' $AfterOperation }
  $portable = ConvertTo-DataSafePortableAttributes $Entry.attributes ($Entry.entryType -ceq 'directory')
  [IO.File]::SetAttributes($extended, [IO.FileAttributes]$(if ($portable -eq 0) { 128 } else { $portable }))
  if ($null -ne $Owner) { Send-DataSafeTransactionBoundary $Owner $Operation 'metadata-filesystem' $AfterOperation }
}

function Send-DataSafeTransactionBoundary($Owner, $Operation, [string]$Phase, [scriptblock]$AfterOperation) {
  if ($null -ne $AfterOperation) {
    & $AfterOperation ([PSCustomObject]@{ TransactionId=$Owner.Transaction.transactionId; Sequence=$(if ($null -eq $Operation) { 0 } else { $Operation.sequence }); Phase=$Phase; State=$Owner.Transaction.state }) | Out-Null
  }
}

function Save-DataSafeTransactionBoundary($Owner, $Operation, [string]$Phase, [scriptblock]$AfterOperation) {
  Save-DataSafeOwnedTransaction $Owner
  Send-DataSafeTransactionBoundary $Owner $Operation $Phase $AfterOperation
}

function Initialize-DataSafeApplyJournal($Owner) {
  $tx = $Owner.Transaction
  $pointer = Read-DataSafeCurrentPointer $Owner.Repository
  $saveUpgrade=$false
  $legacyCopies=New-Object 'System.Collections.Generic.List[object]'
  if ($tx.formatVersion -eq 1) {
    $capabilities = Get-DataSafeDestinationCapabilities $Owner.Repository.Root
    if (-not $capabilities.Supported) { throw 'DataSafe legacy journal cannot upgrade on an unsupported filesystem.' }
    $tx.previousManifest=$(if ($null -ne $tx.previousManifest) { ConvertTo-DataSafeValidatedManifest $tx.previousManifest } else { $null })
    $tx.currentManifest=ConvertTo-DataSafeValidatedManifest $tx.currentManifest
    foreach ($op in $tx.operations) {
      foreach ($field in @('oldEntry','newEntry')) {
        if ($null -ne $op.$field) { $op.$field.attributes=ConvertTo-DataSafePortableAttributes $op.$field.attributes ($op.$field.entryType -ceq 'directory') }
      }
    }
    # Drop raw-flag-only legacy operations which normalize to unchanged.
    $diff=Compare-DataSafeManifests $tx.previousManifest $tx.currentManifest
    $changed=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($group in @('Added','ContentChanged','MetadataChanged','Deleted')) { foreach ($e in $diff.$group) { $null=$changed.Add($e.sourceId+[char]0+$e.relativePath) } }
    $tx.operations=@($tx.operations | Where-Object { $changed.Contains($_.sourceId+[char]0+$_.relativePath) })
    foreach ($op in $tx.operations) {
      if ($op.kind -ceq 'metadata' -and $op.oldEntry.versionLocation -cne $op.newEntry.versionLocation) {
        $op.kind='replace'
        $op.historyPath=Join-Path (Join-Path (Join-Path $Owner.Repository.HistoryRoot $tx.displayHistoryFolder) 'Previous Versions') $op.oldEntry.versionLocation.Substring(14)
        if ($op.newEntry.entryType -ceq 'file') {
          $op.stagedPath=Join-Path (Join-Path $Owner.Repository.StagingRoot $tx.transactionId) $op.newEntry.versionLocation.Substring(14)
          $legacyCopies.Add($op)
        }
      }
    }
    $bytes=[decimal]0; foreach ($op in $tx.operations) { if ($null -ne $op.stagedPath) { $bytes+=$op.newEntry.length } }
    $tx.stageBytes=[long]$bytes; $tx.peakRequiredBytes=[long]($bytes+$tx.metadataOverheadBytes+$tx.reserveBytes)
    $sequence=0; foreach ($op in $tx.operations) { $sequence++; $op.sequence=$sequence }
    $tx | Add-Member destinationFileSystem $capabilities.FileSystem.ToUpperInvariant()
    $tx | Add-Member timestampToleranceTicks $capabilities.TimestampToleranceTicks
    $tx | Add-Member previousPointer $null
    $tx | Add-Member pointerCaptured $false
    $tx.transactionId = ([guid]$tx.transactionId).ToString('D')
    foreach ($op in $tx.operations) { foreach ($name in @('archiveState','promoteState','metadataState')) { $op | Add-Member $name pending } }
    $tx.formatVersion = 2
  }
  if ($tx.formatVersion -eq 2) { $tx | Add-Member mutationIntent $null; $tx.formatVersion=3; $saveUpgrade=$true }
  if (-not $tx.pointerCaptured) {
    if (($null -eq $pointer) -ne ($null -eq $tx.previousManifest)) { throw 'DataSafe previous pointer/manifest baseline mismatch.' }
    if ($null -ne $pointer) { $null = Assert-DataSafeCurrentPointer $Owner.Repository $pointer $tx.previousManifest }
    $tx.previousPointer = $pointer; $tx.pointerCaptured = $true
    Save-DataSafeOwnedTransaction $Owner; $saveUpgrade=$false
  } elseif ((ConvertTo-Json $pointer -Depth 8 -Compress) -cne (ConvertTo-Json $tx.previousPointer -Depth 8 -Compress)) {
    if ($null -eq $pointer -or $pointer.transactionId -ine $tx.transactionId) { throw 'DataSafe current pointer changed outside the transaction.' }
    $null = Assert-DataSafeCurrentPointer $Owner.Repository $pointer $tx.currentManifest
  }
  if ($saveUpgrade) { Save-DataSafeOwnedTransaction $Owner }
  # The strict captured v2 journal above is durable BEFORE upgrade-only I/O.
  # A crash before a complete copy leaves recovery free to restore the old tree.
  if ($legacyCopies.Count) {
    $needed=[decimal]$tx.metadataOverheadBytes+$tx.reserveBytes
    foreach ($op in $legacyCopies) { $needed+=$op.newEntry.length }
    if ([decimal](Get-DataSafeFreeBytes $Owner.Repository.Root) -lt $needed) { throw 'DataSafe legacy upgrade has insufficient actual free space.' }
    foreach ($op in $legacyCopies) {
      if (-not (Test-DataSafeTransactionObject $op.oldCurrentPath $op.oldEntry)) { throw 'DataSafe legacy relocation old content verification failed.' }
      $copy=[PSCustomObject]@{sourcePath=$op.oldCurrentPath;stagedPath=$op.stagedPath;newEntry=$op.newEntry}
      Copy-DataSafeTransactionFile $copy
      Assert-DataSafeTransactionStaged $op $null
      Set-DataSafeTransactionMetadata $op.stagedPath $op.newEntry
      if (-not (Test-DataSafeTransactionObject $op.stagedPath $op.newEntry -Metadata -TimestampToleranceTicks $tx.timestampToleranceTicks)) { throw 'DataSafe legacy relocation staged verification failed.' }
      Save-DataSafeOwnedTransaction $Owner
    }
  }
}

function Assert-DataSafeTransactionCommit($Owner) {
  $tx = $Owner.Transaction
  $pointer = Read-DataSafeCurrentPointer $Owner.Repository
  if ($null -eq $pointer -or $pointer.transactionId -cne $tx.transactionId) { throw 'DataSafe transaction cannot commit without its durable pointer.' }
  $null = Assert-DataSafeCurrentPointer $Owner.Repository $pointer $tx.currentManifest
  Assert-DataSafeTransactionTree $Owner.Repository $tx.currentManifest -Metadata -TimestampToleranceTicks $tx.timestampToleranceTicks
}

function Assert-DataSafeTransactionRollback($Owner) {
  $tx=$Owner.Transaction
  if ($tx.formatVersion -lt 2 -or -not $tx.pointerCaptured) { throw 'DataSafe rollback requires captured previous authority.' }
  Assert-DataSafeTransactionTree $Owner.Repository $tx.previousManifest -Metadata -TimestampToleranceTicks $tx.timestampToleranceTicks
  $actual=Read-DataSafeCurrentPointer $Owner.Repository
  if ((ConvertTo-Json $actual -Depth 8 -Compress) -cne (ConvertTo-Json $tx.previousPointer -Depth 8 -Compress)) { throw 'DataSafe rollback previous pointer mismatch.' }
}

function Complete-DataSafeTransactionResult($Owner) {
  $warnings = @(); $tx = $Owner.Transaction
  if ($tx.formatVersion -eq 2) { Initialize-DataSafeApplyJournal $Owner }
  $staging = Join-Path $Owner.Repository.StagingRoot $tx.transactionId
  # Cleanup only a schema-derived transaction staging root, never history.
  try {
    Assert-DataSafeNoReparsePath $staging
    if (Test-DataSafeFile $staging) { throw 'DataSafe staging cleanup preserved an unknown root type.' }
    if (Test-DataSafeDirectory $staging) {
      $known = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
      $known.Add($staging, 'directory')
      foreach ($op in $tx.operations) {
        if ($null -eq $op.stagedPath) { continue }
        $known[$op.stagedPath] = 'file'
        $parent = [IO.Path]::GetDirectoryName($op.stagedPath)
        while ($parent.Length -gt $staging.Length) {
          $known[$parent] = 'directory'; $parent = [IO.Path]::GetDirectoryName($parent)
        }
      }
      # Validate the ENTIRE cleanup tree before deleting any evidence. Only
      # paths reserved by this exact journal and their parents are ours to clean.
      $pending = New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($staging)
      while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $directory))) {
          $path = ConvertFrom-DataSafeExtendedPath $extended; Assert-DataSafeNoReparsePath $path
          if (-not $known.ContainsKey($path)) { throw 'DataSafe staging cleanup preserved unknown content.' }
          $isDirectory = Test-DataSafeDirectory $path
          if ($isDirectory -ne ($known[$path] -ceq 'directory')) { throw 'DataSafe staging cleanup preserved an unknown entry type.' }
          if (-not $isDirectory) {
            $matches=@($tx.operations | Where-Object { $null -ne $_.stagedPath -and $_.stagedPath.Equals($path,[StringComparison]::OrdinalIgnoreCase) })
            if ($matches.Count -ne 1 -or $tx.state -cne 'rolledBack' -or $matches[0].status -cne 'verified' -or
                -not (Test-DataSafeTransactionObject $path $matches[0].newEntry)) { throw 'DataSafe staging cleanup preserved unproven reserved-path content.' }
          }
          if ($isDirectory) { $pending.Push($path) }
        }
      }
      Remove-DataSafeDirectoryTree $staging
    }
  }
  catch { $warnings += [PSCustomObject]@{ Code='StagingCleanupFailed'; Message=$_.Exception.Message } }
  $pointer = Read-DataSafeCurrentPointer $Owner.Repository
  $manifestPath = if ($null -ne $pointer) { Join-Path $Owner.Repository.MetadataRoot $pointer.manifestPath } else { $null }
  return [PSCustomObject]@{ FinalState=$tx.state; RecoveredOperationCount=$tx.operations.Count; ManifestPath=$manifestPath; Warnings=@($warnings) }
}

function Test-DataSafeTransactionDirectoryOwned($Owner,[string]$Path,$OldPaths=$null) {
  Assert-DataSafeNoReparsePath $Path
  if (-not (Test-DataSafeDirectory $Path)) { return $false }
  if ($null -eq $OldPaths) { $OldPaths=Get-DataSafeTransactionTreePaths $Owner.Repository $Owner.Transaction.previousManifest }
  if ($OldPaths.ContainsKey($Path) -and $OldPaths[$Path].entryType -ceq 'directory') { return $true }
  $tx=$Owner.Transaction
  if ($tx.formatVersion -eq 3 -and $null -ne $tx.mutationIntent -and $tx.mutationIntent.kind -ceq 'promote' -and $Path -in $tx.mutationIntent.directories) {
    Assert-DataSafeMutationIntentState $Owner
    return $true
  }
  foreach ($op in $tx.operations) {
    if ($op.kind -cnotin @('add','replace') -or $op.status -cne 'verified') { continue }
    $self=$op.currentPath.Equals($Path,[StringComparison]::OrdinalIgnoreCase)
    $descendant=$op.currentPath.StartsWith($Path+'\',[StringComparison]::OrdinalIgnoreCase)
    if (-not $self -and -not $descendant) { continue }
    if ($op.newEntry.entryType -ceq 'directory') {
      if ($tx.formatVersion -ge 2 -and $op.promoteState -ceq 'done' -and (Test-DataSafeTransactionObject $op.currentPath $op.newEntry)) { return $true }
      if ($descendant -and $tx.state -ceq 'rollingBack' -and $tx.formatVersion -ge 2 -and $op.promoteState -ceq 'done' -and
          -not (Test-DataSafeFile $op.currentPath) -and -not (Test-DataSafeDirectory $op.currentPath)) {
        # A durable directory promotion can be retracted before its journal.
        # Retain only its necessary, empty ancestor chain: unlike returned
        # file bytes, this proof must inspect every remaining descendant.
        $chain=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $ancestor=[IO.Path]::GetDirectoryName($op.currentPath)
        while ($ancestor.Equals($Path,[StringComparison]::OrdinalIgnoreCase) -or $ancestor.StartsWith($Path+'\',[StringComparison]::OrdinalIgnoreCase)) {
          $null=$chain.Add($ancestor); $ancestor=[IO.Path]::GetDirectoryName($ancestor)
        }
        $pending=New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($Path); $bounded=$true
        while ($pending.Count -and $bounded) {
          foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $pending.Pop()))) {
            $child=ConvertFrom-DataSafeExtendedPath $extended
            Assert-DataSafeNoReparsePath $child
            if (-not $chain.Contains($child) -or -not (Test-DataSafeDirectory $child)) { $bounded=$false; break }
            $pending.Push($child)
          }
        }
        if ($bounded) { return $true }
      }
    } elseif ($descendant -and (Test-DataSafeTransactionObject $op.currentPath $op.newEntry) -and
        -not (Test-DataSafeFile $op.stagedPath) -and -not (Test-DataSafeDirectory $op.stagedPath)) {
      # A verified current leaf plus its absent verified stage proves the
      # rename gap and owns its necessary ancestors, unlike a bare directory.
      return $true
    } elseif ($descendant -and $tx.state -ceq 'rollingBack' -and $tx.formatVersion -ge 2 -and $op.promoteState -ceq 'done' -and
        -not (Test-DataSafeFile $op.currentPath) -and -not (Test-DataSafeDirectory $op.currentPath) -and
        (Test-DataSafeTransactionObject $op.stagedPath $op.newEntry)) {
      # Retraction can empty an owned implicit ancestor before its cleanup
      # journal. Durable promotion plus verified returned bytes retains proof.
      return $true
    }
  }
  return $false
}

function Test-DataSafeTransactionProgress($Owner) {
  if ($Owner.Transaction.state -cin @('staging','prepared')) { return $false }
  $oldPaths=Get-DataSafeTransactionTreePaths $Owner.Repository $Owner.Transaction.previousManifest
  # A matching current file with its stage still present is not a completed
  # rename. A preexisting implicit directory is likewise not a new promotion.
  foreach ($op in $Owner.Transaction.operations) {
    if ($null -ne $op.historyPath -and (Test-DataSafeTransactionObject $op.historyPath $op.oldEntry) -and
        (-not (Test-DataSafeTransactionObject $op.oldCurrentPath $op.oldEntry) -or ($Owner.Transaction.formatVersion -ge 2 -and $op.archiveState -ceq 'done'))) { return $true }
    if ($op.kind -cin @('add','replace') -and (Test-DataSafeTransactionObject $op.currentPath $op.newEntry)) {
      if ($op.newEntry.entryType -ceq 'directory') {
        if ((-not $oldPaths.ContainsKey($op.currentPath) -or $oldPaths[$op.currentPath].entryType -cne 'directory' -or
            ($Owner.Transaction.formatVersion -ge 2 -and $op.promoteState -ceq 'done')) -and
            (Test-DataSafeTransactionDirectoryOwned $Owner $op.currentPath $oldPaths)) { return $true }
      } elseif (-not (Test-DataSafeFile $op.stagedPath) -and -not (Test-DataSafeDirectory $op.stagedPath) -and
          ($op.kind -ceq 'add' -or -not (Test-DataSafeTransactionObject $op.currentPath $op.oldEntry))) { return $true }
    }
    if ($op.kind -ceq 'metadata' -and $Owner.Transaction.formatVersion -ge 2 -and
        (Test-DataSafeTransactionObject $op.currentPath $op.newEntry -Metadata -TimestampToleranceTicks $Owner.Transaction.timestampToleranceTicks) -and
        -not (Test-DataSafeTransactionObject $op.currentPath $op.oldEntry -Metadata -TimestampToleranceTicks $Owner.Transaction.timestampToleranceTicks)) { return $true }
    if ($Owner.Transaction.formatVersion -ge 2 -and $op.metadataState -ceq 'done') { return $true }
  }
  return $false
}

function Assert-DataSafeTransactionOwnedHistory($Owner) {
  $tx=$Owner.Transaction; $repo=$Owner.Repository
  if ($null -eq $tx.displayHistoryFolder) { return }
  $root=Join-Path $repo.HistoryRoot $tx.displayHistoryFolder
  if (-not (Test-DataSafeDirectory $root)) {
    if (Test-DataSafeFile $root) { throw 'DataSafe history collision.' }; return
  }
  $known=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($op in $tx.operations) {
    if ($null -eq $op.historyPath) { continue }
    $known[$op.historyPath]=$op.oldEntry
    $parent=[IO.Path]::GetDirectoryName($op.historyPath)
    while ($parent.Length -gt $root.Length) { if (-not $known.ContainsKey($parent)) { $known[$parent]=$null }; $parent=[IO.Path]::GetDirectoryName($parent) }
  }
  $pending=New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($root)
  while ($pending.Count) {
    $dir=$pending.Pop(); Assert-DataSafeNoReparsePath $dir
    foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $dir))) {
      $path=ConvertFrom-DataSafeExtendedPath $extended; Assert-DataSafeNoReparsePath $path
      if (-not $known.ContainsKey($path)) { throw 'DataSafe history collision: unknown content.' }
      if ($null -eq $known[$path]) { if (-not (Test-DataSafeDirectory $path)) { throw 'DataSafe history structural collision.' } }
      elseif (-not (Test-DataSafeTransactionObject $path $known[$path])) { throw 'DataSafe history content verification failed.' }
      if (Test-DataSafeDirectory $path) { $pending.Push($path) }
    }
  }
}

function Get-DataSafeIntentTarget($Transaction, $Intent) {
  if ($Intent.kind -cin @('archive','promote')) {
    $op=$Transaction.operations[$Intent.sequence-1]
    return [PSCustomObject]@{Operation=$op; Entry=$(if ($Intent.kind -ceq 'archive') { $op.oldEntry } else { $op.newEntry })}
  }
  $manifest=$(if ($Intent.kind -ceq 'rollbackMetadata') { $Transaction.previousManifest } else { $Transaction.currentManifest })
  $entry=@($manifest.entries | Where-Object { $_.sourceId -ceq $Intent.sourceId -and $_.relativePath -ceq $Intent.relativePath })[0]
  $op=$(if ($Intent.sequence -gt 0) { $Transaction.operations[$Intent.sequence-1] } else { $null })
  return [PSCustomObject]@{Operation=$op;Entry=$entry}
}

function Assert-DataSafeMutationIntentSchema($Transaction,$Repository) {
  $i=$Transaction.mutationIntent; if ($null -eq $i) { return }
  Assert-DataSafeTransactionFields $i @('transactionId','sequence','sourceId','relativePath','targetPath','kind','directories','before')
  if ((Get-DataSafeManifestScalar $i 'transactionId') -cne $Transaction.transactionId -or
      $Transaction.state -cnotin @('applying','rollingBack') -or -not $Transaction.pointerCaptured) { throw 'DataSafe mutation intent authority/state is invalid.' }
  $sequence=Get-DataSafeManifestScalar $i 'sequence' 'integer'
  $kind=Get-DataSafeManifestScalar $i 'kind'
  if ($kind -cnotin @('archive','promote','metadata','rollbackMetadata') -or $sequence -lt 0 -or $sequence -gt $Transaction.operations.Count -or
      ($kind -cin @('archive','promote') -and $sequence -eq 0) -or $i.directories -isnot [array]) { throw 'DataSafe mutation intent kind/sequence is invalid.' }
  $source=Get-DataSafeManifestScalar $i 'sourceId'; $relative=Get-DataSafeManifestScalar $i 'relativePath'
  if ($sequence -gt 0) {
    $op=$Transaction.operations[$sequence-1]
    if ($op.sourceId -ine $source -or $op.relativePath -ine $relative -or
        ($kind -ceq 'archive' -and $op.kind -cnotin @('replace','delete')) -or
        ($kind -ceq 'promote' -and $op.kind -cnotin @('add','replace'))) { throw 'DataSafe mutation intent operation identity is invalid.' }
  }
  $manifest=$(if ($kind -cin @('archive','rollbackMetadata')) { $Transaction.previousManifest } else { $Transaction.currentManifest })
  $entries=@($manifest.entries | Where-Object { $_.sourceId -ceq $source -and $_.relativePath -ceq $relative })
  if ($entries.Count -ne 1) { throw 'DataSafe mutation intent manifest identity is invalid.' }
  $entry=$entries[0]
  if ($kind -cin @('metadata','rollbackMetadata')) {
    $entryField=$(if ($kind -ceq 'rollbackMetadata') { 'oldEntry' } else { 'newEntry' })
    $matching=@($Transaction.operations | Where-Object { $null -ne $_.$entryField -and $_.$entryField.versionLocation -ieq $entry.versionLocation })
    $expectedSequence=$(if ($matching.Count) { $matching[0].sequence } else { 0 })
    if ($sequence -ne $expectedSequence) { throw 'DataSafe metadata intent operation binding is invalid.' }
  }
  $target=$(if ($kind -ceq 'archive') { $op.historyPath } elseif ($kind -ceq 'promote') { $op.currentPath } else { Join-Path $Repository.Root $entry.versionLocation })
  Assert-DataSafeTransactionPath $i.targetPath $target
  if ($kind -cin @('metadata','rollbackMetadata')) {
    if ($i.directories.Count -ne 0) { throw 'DataSafe metadata intent cannot create directories.' }
    Assert-DataSafeTransactionFields $i.before @('entryType','attributes','modifiedUtc')
    if ((Get-DataSafeManifestScalar $i.before 'entryType') -cne $entry.entryType) { throw 'DataSafe metadata intent type is invalid.' }
    $attrs=Get-DataSafeManifestScalar $i.before 'attributes' 'integer'
    if ($attrs -ne (ConvertTo-DataSafePortableAttributes $attrs ($entry.entryType -ceq 'directory'))) { throw 'DataSafe metadata intent attributes are invalid.' }
    Assert-DataSafeManifestUtc (Get-DataSafeManifestScalar $i.before 'modifiedUtc')
  } else {
    if ($null -ne $i.before) { throw 'DataSafe structural intent cannot carry metadata.' }
    $parent=$(if ($entry.entryType -ceq 'directory') { $target } else { [IO.Path]::GetDirectoryName($target) })
    $allowed=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stop=$(if ($kind -ceq 'archive') { $Repository.HistoryRoot } else { $Repository.LatestRoot })
    while ($parent.Length -gt $stop.Length) { $null=$allowed.Add($parent); $parent=[IO.Path]::GetDirectoryName($parent) }
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $lastLength=0
    foreach ($dir in $i.directories) {
      if ($dir -isnot [string] -or -not $allowed.Contains($dir) -or -not $seen.Add($dir) -or $dir.Length -le $lastLength) { throw 'DataSafe structural intent reserved path is invalid.' }
      $lastLength=$dir.Length
    }
    if ($i.directories.Count) {
      $leaf=$(if ($entry.entryType -ceq 'directory') { $target } else { [IO.Path]::GetDirectoryName($target) })
      if (-not $leaf.Equals($i.directories[-1],[StringComparison]::OrdinalIgnoreCase)) { throw 'DataSafe structural intent omits its reserved leaf parent.' }
      for ($n=1;$n -lt $i.directories.Count;$n++) {
        if (-not ([IO.Path]::GetDirectoryName($i.directories[$n])).Equals($i.directories[$n-1],[StringComparison]::OrdinalIgnoreCase)) { throw 'DataSafe structural intent directory chain is incomplete.' }
      }
    }
  }
}

function Start-DataSafeMutationIntent($Owner,$Operation,$Entry,[string]$Path,[string]$Kind,[scriptblock]$AfterOperation) {
  if ($null -ne $Owner.Transaction.mutationIntent) { throw 'DataSafe an earlier mutation intent is unresolved.' }
  $directories=@(); $before=$null
  if ($Kind -cin @('metadata','rollbackMetadata')) {
    if (-not (Test-DataSafeTransactionObject $Path $Entry)) { throw 'DataSafe metadata intent content/type verification failed.' }
    $ext=ConvertTo-DataSafeExtendedPath $Path
    $before=[PSCustomObject]@{entryType=$Entry.entryType;attributes=(ConvertTo-DataSafePortableAttributes ([long][IO.File]::GetAttributes($ext)) ($Entry.entryType -ceq 'directory'));modifiedUtc=[IO.File]::GetLastWriteTimeUtc($ext).ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
  } else {
    $dir=$(if ($Entry.entryType -ceq 'directory') { $Path } else { [IO.Path]::GetDirectoryName($Path) })
    $stop=$(if ($Kind -ceq 'archive') { $Owner.Repository.HistoryRoot } else { $Owner.Repository.LatestRoot })
    while ($dir.Length -gt $stop.Length) {
      Assert-DataSafeNoReparsePath $dir
      if (Test-DataSafeFile $dir) { throw 'DataSafe structural intent parent is occupied by a file.' }
      if (Test-DataSafeDirectory $dir) {
        if ($Kind -ceq 'promote' -and $dir.Length -gt $stop.Length -and -not (Test-DataSafeTransactionDirectoryOwned $Owner $dir)) { throw 'DataSafe promotion parent is an unowned directory.' }
        break
      }
      $directories=@($dir)+$directories; $dir=[IO.Path]::GetDirectoryName($dir)
    }
  }
  $Owner.Transaction.mutationIntent=[PSCustomObject][ordered]@{transactionId=$Owner.Transaction.transactionId;sequence=$(if ($null -eq $Operation) { 0 } else { $Operation.sequence });sourceId=$Entry.sourceId;relativePath=$Entry.relativePath;targetPath=$Path;kind=$Kind;directories=@($directories);before=$before}
  Save-DataSafeTransactionBoundary $Owner $Operation ($Kind+'-intent') $AfterOperation
}

function Assert-DataSafeMutationIntentState($Owner) {
  $i=$Owner.Transaction.mutationIntent; if ($null -eq $i) { return }
  $target=Get-DataSafeIntentTarget $Owner.Transaction $i
  foreach ($dir in $i.directories) {
    Assert-DataSafeNoReparsePath $dir
    if (Test-DataSafeFile $dir) { throw 'DataSafe intended structural directory has an unknown type.' }
    if (Test-DataSafeDirectory $dir) {
      foreach ($ext in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $dir))) {
        $path=ConvertFrom-DataSafeExtendedPath $ext; Assert-DataSafeNoReparsePath $path
        if ($path -in $i.directories -and (Test-DataSafeDirectory $path)) { continue }
        $moved=$false
        if ($path.Equals($i.targetPath,[StringComparison]::OrdinalIgnoreCase) -and $target.Entry.entryType -ceq 'file' -and (Test-DataSafeTransactionObject $path $target.Entry)) {
          $from=$(if ($i.kind -ceq 'archive') { $target.Operation.oldCurrentPath } else { $target.Operation.stagedPath })
          $moved=(-not (Test-DataSafeFile $from) -and -not (Test-DataSafeDirectory $from))
        }
        if (-not $moved) { throw 'DataSafe intended scaffolding has unknown/nonempty content.' }
      }
    }
  }
  if ($i.kind -cin @('metadata','rollbackMetadata')) {
    if (-not (Test-DataSafeTransactionObject $i.targetPath $target.Entry)) { throw 'DataSafe intended metadata content/type changed.' }
    $ext=ConvertTo-DataSafeExtendedPath $i.targetPath; $attrs=ConvertTo-DataSafePortableAttributes ([long][IO.File]::GetAttributes($ext)) ($target.Entry.entryType -ceq 'directory')
    $time=[IO.File]::GetLastWriteTimeUtc($ext); $tol=$Owner.Transaction.timestampToleranceTicks
    $prior=[datetime]::ParseExact($i.before.modifiedUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $new=[datetime]::ParseExact($target.Entry.modifiedUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $clear=ConvertTo-DataSafePortableAttributes 128 ($target.Entry.entryType -ceq 'directory')
    if (-not ((($attrs -eq $i.before.attributes -or $attrs -eq $clear) -and [Math]::Abs($time.Ticks-$prior.Ticks) -le $tol) -or
        (($attrs -eq $clear -or $attrs -eq $target.Entry.attributes) -and [Math]::Abs($time.Ticks-$new.Ticks) -le $tol))) { throw 'DataSafe metadata intent has an unexpected intermediate state.' }
  }
}

function Assert-DataSafeIntentBaseline($Owner) {
  $tx=$Owner.Transaction; $repo=$Owner.Repository; $i=$tx.mutationIntent
  Assert-DataSafeMutationIntentState $Owner
  $old=Get-DataSafeTransactionTreePaths $repo $tx.previousManifest
  foreach ($path in $old.Keys) {
    $e=$old[$path]
    if ($null -ne $e.PSObject.Properties['structural']) { if (-not (Test-DataSafeDirectory $path)) { throw 'DataSafe prior structural baseline is missing.' }; continue }
    $skipTime=$false
    foreach ($dir in $i.directories) { if ([IO.Path]::GetDirectoryName($dir).Equals($path,[StringComparison]::OrdinalIgnoreCase)) { $skipTime=$true } }
    if ($i.kind -ceq 'metadata' -and $path.Equals($i.targetPath,[StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($i.kind -ceq 'archive' -and $e.entryType -ceq 'directory') {
      $op=$tx.operations[$i.sequence-1]
      if ($path.Equals($op.oldCurrentPath,[StringComparison]::OrdinalIgnoreCase)) {
        $cleared=ConvertFrom-DataSafeTransactionJson (ConvertTo-Json $e -Compress)
        $cleared.attributes=ConvertTo-DataSafePortableAttributes 128 $true
        if (Test-DataSafeTransactionObject $path $cleared -Metadata -TimestampToleranceTicks $tx.timestampToleranceTicks) { continue }
      }
    }
    if ($skipTime) {
      if (-not (Test-DataSafeTransactionObject $path $e) -or (ConvertTo-DataSafePortableAttributes ([long][IO.File]::GetAttributes((ConvertTo-DataSafeExtendedPath $path))) ($e.entryType -ceq 'directory')) -ne $e.attributes) { throw 'DataSafe prior parent metadata/type changed.' }
    } elseif (-not (Test-DataSafeTransactionObject $path $e -Metadata -TimestampToleranceTicks $tx.timestampToleranceTicks)) { throw 'DataSafe prior metadata baseline verification failed.' }
  }
  $pending=New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($repo.LatestRoot)
  while ($pending.Count) {
    $dir=$pending.Pop(); Assert-DataSafeNoReparsePath $dir
    foreach ($ext in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $dir))) {
      $path=ConvertFrom-DataSafeExtendedPath $ext; Assert-DataSafeNoReparsePath $path
      if (-not $old.ContainsKey($path) -and $path -notin $i.directories) { throw 'DataSafe intent baseline has unknown current content.' }
      if (Test-DataSafeDirectory $path) { $pending.Push($path) }
    }
  }
  if ($null -ne $tx.displayHistoryFolder) {
    $root=Join-Path $repo.HistoryRoot $tx.displayHistoryFolder
    if (Test-DataSafeFile $root) { throw 'DataSafe history collision.' }
    if (Test-DataSafeDirectory $root) {
      if ($i.kind -cne 'archive' -or $root -notin $i.directories) { throw 'DataSafe history collision without owned structural intent.' }
      $pending.Push($root)
      while ($pending.Count) {
        $dir=$pending.Pop(); Assert-DataSafeNoReparsePath $dir
        foreach ($ext in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $dir))) {
          $path=ConvertFrom-DataSafeExtendedPath $ext; Assert-DataSafeNoReparsePath $path
          if ($path -notin $i.directories -or -not (Test-DataSafeDirectory $path)) { throw 'DataSafe intended history scaffolding has unknown/nonempty content.' }
          $pending.Push($path)
        }
      }
    }
  }
}

function Ensure-DataSafeIntentDirectories($Owner,$Operation,[scriptblock]$AfterOperation) {
  foreach ($dir in $Owner.Transaction.mutationIntent.directories) {
    Assert-DataSafeNoReparsePath $dir
    if (-not (Test-DataSafeDirectory $dir)) {
      [IO.Directory]::CreateDirectory((ConvertTo-DataSafeExtendedPath $dir)) | Out-Null
      Send-DataSafeTransactionBoundary $Owner $Operation ($Owner.Transaction.mutationIntent.kind+'-parent-filesystem') $AfterOperation
    }
  }
}

function Invoke-DataSafeOwnedMetadata($Owner,$Operation,$Entry,[string]$Path,[string]$Kind,[scriptblock]$AfterOperation) {
  if ($null -eq $Owner.Transaction.mutationIntent) { Start-DataSafeMutationIntent $Owner $Operation $Entry $Path $Kind $AfterOperation }
  Assert-DataSafeMutationIntentState $Owner
  Set-DataSafeTransactionMetadataSteps $Path $Entry $Owner $Operation $AfterOperation
  if (-not (Test-DataSafeTransactionObject $Path $Entry -Metadata -TimestampToleranceTicks $Owner.Transaction.timestampToleranceTicks)) { throw 'DataSafe destination metadata verification failed.' }
  if ($Kind -ceq 'metadata' -and $null -ne $Operation) { $Operation.metadataState='done' }
  $Owner.Transaction.mutationIntent=$null
  Save-DataSafeTransactionBoundary $Owner $Operation 'metadata' $AfterOperation
}

function Invoke-DataSafeOwnedArchive($Owner,$Operation,[scriptblock]$AfterOperation) {
  $op=$Operation; $tx=$Owner.Transaction
  if ($null -eq $tx.mutationIntent) { Start-DataSafeMutationIntent $Owner $op $op.oldEntry $op.historyPath archive $AfterOperation }
  Ensure-DataSafeIntentDirectories $Owner $op $AfterOperation
  if ($op.oldEntry.entryType -ceq 'file') {
    if (Test-DataSafeTransactionObject $op.historyPath $op.oldEntry) {
      if (Test-DataSafeTransactionObject $op.oldCurrentPath $op.oldEntry) { throw 'DataSafe blocked recovery: duplicate old file locations.' }
    } else {
      if ((Test-DataSafeFile $op.historyPath) -or (Test-DataSafeDirectory $op.historyPath)) { throw 'DataSafe history collision or unknown content.' }
      if (-not (Test-DataSafeTransactionObject $op.oldCurrentPath $op.oldEntry)) { throw 'DataSafe old file hash verification failed.' }
      Move-DataSafeSameVolume $op.oldCurrentPath $op.historyPath
      Send-DataSafeTransactionBoundary $Owner $op 'archive-filesystem' $AfterOperation
      if (-not (Test-DataSafeTransactionObject $op.historyPath $op.oldEntry)) { throw 'DataSafe archive verification failed.' }
    }
  } else {
    Assert-DataSafeNoReparsePath $op.historyPath
    if (-not (Test-DataSafeDirectory $op.historyPath)) { throw 'DataSafe intended archive directory is missing.' }
    if (Test-DataSafeDirectory $op.oldCurrentPath) {
      [IO.File]::SetAttributes((ConvertTo-DataSafeExtendedPath $op.oldCurrentPath),[IO.FileAttributes]::Normal)
      Send-DataSafeTransactionBoundary $Owner $op 'archive-old-attributes-cleared' $AfterOperation
      [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $op.oldCurrentPath),$false)
      Send-DataSafeTransactionBoundary $Owner $op 'archive-old-directory-removed' $AfterOperation
    } elseif (Test-DataSafeFile $op.oldCurrentPath) { throw 'DataSafe unknown old directory content.' }
    Set-DataSafeTransactionMetadataSteps $op.historyPath $op.oldEntry $Owner $op $AfterOperation
    if (-not (Test-DataSafeTransactionObject $op.historyPath $op.oldEntry -Metadata -TimestampToleranceTicks $tx.timestampToleranceTicks)) { throw 'DataSafe archived directory metadata verification failed.' }
    Send-DataSafeTransactionBoundary $Owner $op 'archive-filesystem' $AfterOperation
  }
  $op.archiveState='done'; $tx.mutationIntent=$null
  Save-DataSafeTransactionBoundary $Owner $op archived $AfterOperation
}

function Invoke-DataSafeOwnedPromotion($Owner,$Operation,[scriptblock]$AfterOperation) {
  $op=$Operation; $tx=$Owner.Transaction
  if ($op.kind -ceq 'metadata') {
    if (-not (Test-DataSafeTransactionObject $op.currentPath $op.newEntry)) { throw 'DataSafe metadata target verification failed.' }
  } else {
    if ($null -eq $tx.mutationIntent) { Start-DataSafeMutationIntent $Owner $op $op.newEntry $op.currentPath promote $AfterOperation }
    Ensure-DataSafeIntentDirectories $Owner $op $AfterOperation
    if ($op.newEntry.entryType -ceq 'directory') {
      if (-not (Test-DataSafeDirectory $op.currentPath)) { throw 'DataSafe intended promotion directory is missing.' }
      Send-DataSafeTransactionBoundary $Owner $op 'promote-filesystem' $AfterOperation
    } elseif (Test-DataSafeTransactionObject $op.currentPath $op.newEntry) {
      if (Test-DataSafeFile $op.stagedPath) { throw 'DataSafe blocked recovery: duplicate promoted content.' }
    } else {
      Assert-DataSafeTransactionStaged $op $null
      Move-DataSafeSameVolume $op.stagedPath $op.currentPath
      Send-DataSafeTransactionBoundary $Owner $op 'promote-filesystem' $AfterOperation
      if (-not (Test-DataSafeTransactionObject $op.currentPath $op.newEntry)) { throw 'DataSafe promotion verification failed.' }
    }
  }
  $op.promoteState='done'; $tx.mutationIntent=$null
  Save-DataSafeTransactionBoundary $Owner $op promoted $AfterOperation
}

function Resume-DataSafeMutationIntent($Owner,[scriptblock]$AfterOperation) {
  $i=$Owner.Transaction.mutationIntent; if ($null -eq $i) { return }
  Assert-DataSafeMutationIntentState $Owner
  $target=Get-DataSafeIntentTarget $Owner.Transaction $i
  switch -CaseSensitive ($i.kind) {
    archive { Invoke-DataSafeOwnedArchive $Owner $target.Operation $AfterOperation }
    promote { Invoke-DataSafeOwnedPromotion $Owner $target.Operation $AfterOperation }
    default { Invoke-DataSafeOwnedMetadata $Owner $target.Operation $target.Entry $i.targetPath $i.kind $AfterOperation }
  }
}

function Invoke-DataSafeTransaction($Transaction, [scriptblock]$AfterOperation = $null) {
  $owner = Get-DataSafeTransactionOwner $Transaction
  if ($Transaction.state -cnotin @('prepared','applying')) { throw 'DataSafe apply requires prepared/applying state.' }
  $repo = $owner.Repository
  $tolerance = if ($Transaction.formatVersion -ge 2) { $Transaction.timestampToleranceTicks } else { (Get-DataSafeDestinationCapabilities $repo.Root).TimestampToleranceTicks }
  $progress=Test-DataSafeTransactionProgress $owner
  $intent=$(if ($Transaction.formatVersion -eq 3) { $Transaction.mutationIntent } else { $null })
  if ($null -ne $intent) { Assert-DataSafeMutationIntentState $owner }
  if (-not $progress) {
    # Whole-baseline and whole-stage checks precede every mutation of user data.
    if ($null -ne $intent) { Assert-DataSafeIntentBaseline $owner }
    else { Assert-DataSafeTransactionTree $repo $Transaction.previousManifest -Metadata -TimestampToleranceTicks $tolerance }
    foreach ($op in $Transaction.operations) { if ($null -ne $op.stagedPath) { Assert-DataSafeTransactionStaged $op $null } }
    if ($null -eq $intent) { Assert-DataSafeTransactionSpaceAndHistory $Transaction $repo 0 }
    elseif ([decimal](Get-DataSafeFreeBytes $repo.Root) -lt ([decimal]$Transaction.metadataOverheadBytes+$Transaction.reserveBytes)) { throw 'DataSafe transaction has insufficient actual free space.' }
  } else {
    # Resuming the original owner must be as strict as explicit disk recovery.
    Assert-DataSafeTransactionRecoverable $owner -Forward
    Assert-DataSafeTransactionOwnedHistory $owner
    $required=[decimal]$Transaction.metadataOverheadBytes+$Transaction.reserveBytes
    if ([decimal](Get-DataSafeFreeBytes $repo.Root) -lt $required) { throw 'DataSafe transaction has insufficient actual free space.' }
  }
  Initialize-DataSafeApplyJournal $owner
  Send-DataSafeTransactionBoundary $owner $null 'apply-journal' $AfterOperation
  if ($Transaction.state -ceq 'prepared') { Set-DataSafeTransactionState $Transaction applying; Send-DataSafeTransactionBoundary $owner $null 'applying' $AfterOperation }
  Resume-DataSafeMutationIntent $owner $AfterOperation
  # Old entries are handled individually, deepest first. Directories are never
  # recursively moved: children can belong to different history categories.
  foreach ($op in @($Transaction.operations | Sort-Object @{Expression={ $_.relativePath.Split('/').Count }; Descending=$true}, sequence)) {
    if ($op.kind -notin @('replace','delete') -or $op.archiveState -ceq 'done') { continue }
    Invoke-DataSafeOwnedArchive $owner $op $AfterOperation
  }
  $newOperations = @($Transaction.operations | Where-Object { $null -ne $_.newEntry } | Sort-Object @{Expression={ if ($_.newEntry.entryType -ceq 'directory') { 0 } else { 1 } }}, @{Expression={ $_.relativePath.Split('/').Count }}, sequence)
  $oldPaths = Get-DataSafeTransactionTreePaths $repo $Transaction.previousManifest
  $newPaths = Get-DataSafeTransactionTreePaths $repo $Transaction.currentManifest
  foreach ($path in @($oldPaths.Keys | Sort-Object Length -Descending)) {
    if ($oldPaths[$path].entryType -ceq 'directory' -and
        (-not $newPaths.ContainsKey($path) -or $newPaths[$path].entryType -ceq 'file') -and (Test-DataSafeDirectory $path)) {
      Assert-DataSafeNoReparsePath $path
      [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $path), $false)
      Send-DataSafeTransactionBoundary $owner $null 'remove-parents-filesystem' $AfterOperation
    }
  }
  foreach ($op in $newOperations) {
    if ($op.promoteState -ceq 'done') { continue }
    Invoke-DataSafeOwnedPromotion $owner $op $AfterOperation
  }
  $oldPaths = Get-DataSafeTransactionTreePaths $repo $Transaction.previousManifest
  $newPaths = Get-DataSafeTransactionTreePaths $repo $Transaction.currentManifest
  foreach ($path in @($oldPaths.Keys | Sort-Object Length -Descending)) {
    if (-not $newPaths.ContainsKey($path) -and (Test-DataSafeDirectory $path)) {
      # Only known, now-empty structural ancestors may disappear. Unknown
      # descendants make the nonrecursive delete fail without losing content.
      [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $path), $false)
      Send-DataSafeTransactionBoundary $owner $null 'remove-parents-filesystem' $AfterOperation
    }
  }
  # Child mutations change parent times, so metadata is restored files first,
  # then deepest directories last, including otherwise unchanged directories.
  foreach ($entry in @($Transaction.currentManifest.entries | Sort-Object @{Expression={ if ($_.entryType -ceq 'file') { 0 } else { 1 } }}, @{Expression={ $_.relativePath.Split('/').Count }; Descending=$true})) {
    $path=Join-Path $repo.Root $entry.versionLocation
    $operation=@($newOperations | Where-Object { $_.sourceId -ieq $entry.sourceId -and $_.relativePath -ieq $entry.relativePath })
    $metadataOperation=$(if ($operation.Count) { $operation[0] } else { $null })
    Invoke-DataSafeOwnedMetadata $owner $metadataOperation $entry $path metadata $AfterOperation
  }
  Assert-DataSafeTransactionTree $repo $Transaction.currentManifest -Metadata -TimestampToleranceTicks $tolerance
  $manifestPath = Join-Path $repo.ManifestRoot ($Transaction.transactionId + '.json')
  if (Test-DataSafeFile $manifestPath) {
    if ((ConvertTo-Json (Read-DataSafeManifest $manifestPath) -Depth 32 -Compress) -cne (ConvertTo-Json $Transaction.currentManifest -Depth 32 -Compress)) { throw 'DataSafe manifest UUID collision.' }
  } else { $manifestPath = Write-DataSafeManifest $repo $Transaction.currentManifest $Transaction.transactionId }
  Send-DataSafeTransactionBoundary $owner $null 'manifest' $AfterOperation
  $pointer = [PSCustomObject][ordered]@{ schema='datasafe.current-manifest'; formatVersion=1; transactionId=$Transaction.transactionId; manifestPath=('manifests/'+$Transaction.transactionId+'.json'); sha256=(Get-DataSafeSha256 $manifestPath) }
  $null = Assert-DataSafeCurrentPointer $repo $pointer $Transaction.currentManifest
  # Recheck authority immediately before the atomic publish.
  $actual = Read-DataSafeCurrentPointer $repo
  if ((ConvertTo-Json $actual -Depth 8 -Compress) -cne (ConvertTo-Json $Transaction.previousPointer -Depth 8 -Compress) -and
      (ConvertTo-Json $actual -Depth 8 -Compress) -cne (ConvertTo-Json $pointer -Depth 8 -Compress)) { throw 'DataSafe pointer changed outside the transaction.' }
  Write-DataSafeAtomicJson (Join-Path $repo.MetadataRoot 'current-manifest.json') $pointer
  Send-DataSafeTransactionBoundary $owner $null 'pointer' $AfterOperation
  Assert-DataSafeTransactionCommit $owner
  Set-DataSafeTransactionState $Transaction committed
  Send-DataSafeTransactionBoundary $owner $null 'committed' $AfterOperation
  return Complete-DataSafeTransactionResult $owner
}

function Assert-DataSafeTransactionRecoverable($Owner, [switch]$Forward) {
  $tx = $Owner.Transaction; $repo = $Owner.Repository
  $oldPaths = Get-DataSafeTransactionTreePaths $repo $tx.previousManifest
  $newPaths = Get-DataSafeTransactionTreePaths $repo $tx.currentManifest
  # Prove every existing latest object is known before recovery changes anything.
  $pending = New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($repo.LatestRoot)
  while ($pending.Count) {
    $dir = $pending.Pop(); Assert-DataSafeNoReparsePath $dir
    foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $dir))) {
      $path = ConvertFrom-DataSafeExtendedPath $extended; Assert-DataSafeNoReparsePath $path
      $known = $false
      foreach ($map in @($oldPaths,$newPaths)) {
        if ($map.ContainsKey($path)) {
          if ($null -ne $map[$path].PSObject.Properties['structural']) { if (Test-DataSafeDirectory $path) { $known = $true } }
          elseif (Test-DataSafeTransactionObject $path $map[$path]) { $known = $true }
        }
      }
      if (-not $known) { throw "DataSafe blocked recovery: unknown current content: $path" }
      if (Test-DataSafeDirectory $path) {
        if (-not (Test-DataSafeTransactionDirectoryOwned $Owner $path $oldPaths)) { throw "DataSafe blocked recovery: unowned current directory without promotion proof: $path" }
        $pending.Push($path)
      }
    }
  }
  if ($null -ne $tx.previousManifest) {
    foreach ($entry in $tx.previousManifest.entries) {
      if ($entry.entryType -cne 'file') { continue }
      $path = Join-Path $repo.Root $entry.versionLocation
      if (Test-DataSafeTransactionObject $path $entry) { continue }
      $ops = @($tx.operations | Where-Object { $null -ne $_.oldEntry -and $_.oldEntry.versionLocation -ieq $entry.versionLocation -and $_.kind -in @('replace','delete') })
      if ($ops.Count -ne 1 -or -not (Test-DataSafeTransactionObject $ops[0].historyPath $entry)) { throw 'DataSafe blocked recovery: required old file is missing or corrupt.' }
    }
  }
  foreach ($op in $tx.operations) {
    if ($null -ne $op.historyPath -and ((Test-DataSafeFile $op.historyPath) -or (Test-DataSafeDirectory $op.historyPath)) -and
        -not (Test-DataSafeTransactionObject $op.historyPath $op.oldEntry)) { throw 'DataSafe blocked recovery: unknown history content.' }
  }
  if ($Forward) {
    foreach ($entry in $tx.currentManifest.entries) {
      if ($entry.entryType -cne 'file') { continue }
      $path = Join-Path $repo.Root $entry.versionLocation
      if (Test-DataSafeTransactionObject $path $entry) { continue }
      $ops = @($tx.operations | Where-Object { $null -ne $_.stagedPath -and $_.newEntry.versionLocation -ieq $entry.versionLocation })
      if ($ops.Count -ne 1 -or -not (Test-DataSafeTransactionObject $ops[0].stagedPath $entry)) { throw 'DataSafe remaining new content is missing or corrupt.' }
    }
  }
}

function Undo-DataSafeTransaction($Transaction) {
  $owner = Get-DataSafeTransactionOwner $Transaction; $repo = $owner.Repository
  if ($Transaction.state -cnotin @('staging','prepared','applying','rollingBack')) { throw 'DataSafe undo cannot undo a committed/terminal transaction.' }
  Initialize-DataSafeApplyJournal $owner
  $pointer = Read-DataSafeCurrentPointer $repo
  if ($null -ne $pointer -and $pointer.transactionId -ieq $Transaction.transactionId) { throw 'DataSafe committed pointer cannot be undone.' }
  Assert-DataSafeTransactionRecoverable $owner
  if ($null -ne $Transaction.mutationIntent -and $Transaction.mutationIntent.kind -cin @('metadata','rollbackMetadata')) { Resume-DataSafeMutationIntent $owner $null }
  if ($Transaction.state -cne 'rollingBack') { Set-DataSafeTransactionState $Transaction rollingBack }
  $oldPaths = Get-DataSafeTransactionTreePaths $repo $Transaction.previousManifest
  foreach ($op in @($Transaction.operations | Sort-Object @{Expression={ $_.relativePath.Split('/').Count }; Descending=$true}, sequence)) {
    if ($op.kind -cnotin @('add','replace')) { continue }
    # A pre-existing old object is not a promotion. Never remove it on undo.
    if ($null -ne $op.oldEntry -and $op.currentPath.Equals($op.oldCurrentPath, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-DataSafeTransactionObject $op.currentPath $op.oldEntry)) { continue }
    # The complete previous tree, not this operation's relocated oldEntry,
    # owns implicit ancestors needed by already restored old descendants.
    if ($op.newEntry.entryType -ceq 'directory' -and $oldPaths.ContainsKey($op.currentPath) -and
        $oldPaths[$op.currentPath].entryType -ceq 'directory') { continue }
    if (Test-DataSafeTransactionObject $op.currentPath $op.newEntry) {
      $extended = ConvertTo-DataSafeExtendedPath $op.currentPath
      [IO.File]::SetAttributes($extended, [IO.FileAttributes]::Normal)
      if ($op.newEntry.entryType -ceq 'file') {
        # Retract by verified no-overwrite rename, preserving new bytes as evidence
        # until the old tree is fully restored and terminal journal is durable.
        if (Test-DataSafeFile $op.stagedPath) {
          if (-not (Test-DataSafeTransactionObject $op.stagedPath $op.newEntry)) { throw 'DataSafe blocked rollback: occupied staging destination.' }
          [IO.File]::Delete($extended)
        } else {
          Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($op.stagedPath))
          Move-DataSafeSameVolume $op.currentPath $op.stagedPath
        }
      } else {
        [IO.Directory]::Delete($extended, $false)
        Send-DataSafeTransactionBoundary $owner $op 'rollback-directory-removed' $null
      }
    }
    Save-DataSafeOwnedTransaction $owner
  }
  # Remove only empty new implicit ancestors absent from the previous tree.
  $oldPaths = Get-DataSafeTransactionTreePaths $repo $Transaction.previousManifest
  $newPaths = Get-DataSafeTransactionTreePaths $repo $Transaction.currentManifest
  foreach ($path in @($newPaths.Keys | Sort-Object Length -Descending)) {
    if ($newPaths[$path].entryType -ceq 'directory' -and
        (-not $oldPaths.ContainsKey($path) -or $oldPaths[$path].entryType -ceq 'file') -and (Test-DataSafeDirectory $path)) {
      Assert-DataSafeNoReparsePath $path
      [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $path), $false)
      Send-DataSafeTransactionBoundary $owner $null 'rollback-parent-directory-removed' $null
    }
  }
  if ($null -ne $Transaction.previousManifest) {
    foreach ($entry in @($Transaction.previousManifest.entries | Sort-Object @{Expression={ if ($_.entryType -ceq 'directory') { 0 } else { 1 } }}, @{Expression={ $_.relativePath.Split('/').Count }})) {
      $path = Join-Path $repo.Root $entry.versionLocation
      if ($entry.entryType -ceq 'directory') { Ensure-DataSafeDirectory $path }
      elseif (-not (Test-DataSafeTransactionObject $path $entry)) {
        $op = @($Transaction.operations | Where-Object { $null -ne $_.oldEntry -and $_.oldEntry.versionLocation -ieq $entry.versionLocation })[0]
        if (-not (Test-DataSafeTransactionObject $op.historyPath $entry)) { throw 'DataSafe blocked rollback: old archive verification failed.' }
        Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($path))
        Move-DataSafeSameVolume $op.historyPath $path
      }
      Save-DataSafeOwnedTransaction $owner
    }
    Assert-DataSafeTransactionTree $repo $Transaction.previousManifest
    if ($null -ne $Transaction.mutationIntent) { $Transaction.mutationIntent=$null; Save-DataSafeOwnedTransaction $owner }
    foreach ($entry in @($Transaction.previousManifest.entries | Sort-Object @{Expression={ if ($_.entryType -ceq 'file') { 0 } else { 1 } }}, @{Expression={ $_.relativePath.Split('/').Count }; Descending=$true})) {
      $ops=@($Transaction.operations | Where-Object { $null -ne $_.oldEntry -and $_.oldEntry.versionLocation -ieq $entry.versionLocation })
      $op=$(if ($ops.Count) { $ops[0] } else { $null })
      Invoke-DataSafeOwnedMetadata $owner $op $entry (Join-Path $repo.Root $entry.versionLocation) rollbackMetadata $null
    }
  }
  if ($null -ne $Transaction.mutationIntent) { $Transaction.mutationIntent=$null; Save-DataSafeOwnedTransaction $owner }
  Assert-DataSafeTransactionTree $repo $Transaction.previousManifest -Metadata -TimestampToleranceTicks $Transaction.timestampToleranceTicks
  $actual = Read-DataSafeCurrentPointer $repo
  if ((ConvertTo-Json $actual -Depth 8 -Compress) -cne (ConvertTo-Json $Transaction.previousPointer -Depth 8 -Compress)) { throw 'DataSafe rollback previous pointer mismatch.' }
  Set-DataSafeTransactionState $Transaction rolledBack
  return Complete-DataSafeTransactionResult $owner
}

function Recover-DataSafeTransaction($Repository, [string]$TransactionPath) {
  $repo = Read-DataSafeRepository (Get-DataSafeManifestScalar $Repository 'Root')
  foreach ($name in @('FormatVersion','ComputerId','ComputerName','Root','LatestRoot','HistoryRoot','MetadataRoot','ManifestRoot','TransactionRoot','StagingRoot')) {
    if ($null -eq $Repository.PSObject.Properties[$name] -or $Repository.$name -ine $repo.$name) { throw 'DataSafe recovery repository identity/path mismatch.' }
  }
  # Lock before reading the journal, then bind every path/identity under it.
  $lockPath = Join-Path $repo.MetadataRoot 'operation.lock'; Assert-DataSafeNoReparsePath $lockPath
  $handle = Acquire-DataSafeOperationLock (ConvertTo-DataSafeExtendedPath $lockPath)
  $owner = $null
  try {
    $tx = Read-DataSafeTransaction $TransactionPath
    if ($tx.repositoryRoot -ine $repo.Root -or $tx.computerId -ine $repo.ComputerId) { throw 'DataSafe recovery transaction repository identity mismatch.' }
    Assert-DataSafeTransactionPath $TransactionPath (Join-Path $repo.TransactionRoot ($tx.transactionId+'.json'))
    $key = Get-DataSafeTransactionOwnerKey $repo.Root $repo.ComputerId $tx.transactionId
    $owner = [PSCustomObject]@{ Transaction=$tx; Repository=$repo; Path=$TransactionPath; LockPath=$lockPath; Handle=$handle; Json=(ConvertTo-Json $tx -Depth 32 -Compress) }
    $script:DataSafeTransactionOwners[$key] = $owner
    $pointer = Read-DataSafeCurrentPointer $repo
    if ($null -ne $pointer -and $pointer.transactionId -ieq $tx.transactionId) {
      # Publishing the pointer forbids rollback, including a crash before the
      # committed journal revision. Never substitute the previous tree here.
      Assert-DataSafeTransactionCommit $owner
      if ($tx.state -cne 'committed') {
        if ($tx.state -cne 'applying') { throw 'DataSafe blocked recovery: committed pointer has incompatible journal state.' }
        Set-DataSafeTransactionState $tx committed
      }
      return Complete-DataSafeTransactionResult $owner
    }
    if ($tx.state -ceq 'committed') { throw 'DataSafe blocked recovery: committed journal has no matching pointer.' }
    if ($tx.state -ceq 'rolledBack') {
      Initialize-DataSafeApplyJournal $owner
      Assert-DataSafeTransactionTree $repo $tx.previousManifest -Metadata -TimestampToleranceTicks $tx.timestampToleranceTicks
      return Complete-DataSafeTransactionResult $owner
    }
    Initialize-DataSafeApplyJournal $owner
    if ($tx.state -ceq 'staging' -or $tx.state -ceq 'rollingBack') { return Undo-DataSafeTransaction $tx }
    Assert-DataSafeTransactionRecoverable $owner
    $forward = $true
    try { Assert-DataSafeTransactionRecoverable $owner -Forward } catch { $forward = $false }
    if (-not $forward) { return Undo-DataSafeTransaction $tx }
    return Invoke-DataSafeTransaction $tx
  } finally {
    if ($null -ne $owner -and $null -ne $owner.Handle) {
      Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $lockPath); $owner.Handle = $null
    } elseif ($null -eq $owner) { Release-DataSafeOperationLock $handle (ConvertTo-DataSafeExtendedPath $lockPath) }
  }
}

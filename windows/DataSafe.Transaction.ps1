Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DataSafe.IncrementalPlan.ps1')

# Journal v1 is UTF-8 JSON metadata only. Task 5 owns apply/recovery and will
# extend operation statuses. Live handles are NEVER serialized or restored by
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
  if ($id -cne $SourceId -or $relative -cne $RelativePath -or -not $location.StartsWith('Latest Backup/', [StringComparison]::Ordinal) -or
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
  Assert-DataSafeTransactionFields $Transaction @('schema','formatVersion','operationSchemaVersion','transactionId','computerId','repositoryRoot','state','createdUtc','previousBackupTimestamp','displayHistoryFolder','previousManifest','currentManifest','stageBytes','peakRequiredBytes','metadataOverheadBytes','reserveBytes','operations','failure')
  if ((Get-DataSafeManifestScalar $Transaction 'schema') -cne 'datasafe.transaction' -or
      (Get-DataSafeManifestScalar $Transaction 'formatVersion' 'integer') -ne 1 -or
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
  if ($current.sourceErrors.Count -ne 0 -or ($null -ne $previous -and $previous.sourceErrors.Count -ne 0)) { throw 'DataSafe transaction manifest contains source errors.' }
  if ($prior -cne $(if ($null -ne $previous) { $previous.createdUtc } else { $null })) { throw 'DataSafe transaction previous manifest timestamp does not match.' }
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
    Assert-DataSafeTransactionFields $op @('sequence','kind','sourceId','relativePath','sourcePath','currentPath','oldCurrentPath','historyPath','stagedPath','expectedOldSha256','expectedNewSha256','oldEntry','newEntry','status','error')
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
    if ($kind -ceq 'metadata' -and ($old.entryType -cne $new.entryType -or $old.sha256 -cne $new.sha256 -or $old.length -ne $new.length)) { throw 'DataSafe transaction metadata operation changes content.' }
    if ($kind -ceq 'replace' -and $old.entryType -ceq $new.entryType -and $old.sha256 -ceq $new.sha256) { throw 'DataSafe transaction replace operation has no content change.' }
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
  $path = Join-Path $repo.TransactionRoot ($id + '.json')
  $staging = Join-Path $repo.StagingRoot $id
  $transaction = [PSCustomObject][ordered]@{
    schema = 'datasafe.transaction'; formatVersion = 1; operationSchemaVersion = 1
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
  }
  # Detach all manifest/operation metadata from the caller before retaining it.
  $transaction = ConvertFrom-DataSafeTransactionJson (ConvertTo-Json -InputObject $transaction -Depth 32)
  $transaction.operations = @(foreach ($op in $Plan.Operations) {
    Assert-DataSafeTransactionFields $op @('sequence','kind','sourceId','relativePath','sourcePath','currentPath','oldCurrentPath','historyPath','stagedPath','expectedOldSha256','expectedNewSha256','oldEntry','newEntry','status')
    if ((Get-DataSafeManifestScalar $op 'status') -cne 'pending') { throw 'DataSafe transaction plan operation must be pending.' }
    $copy = ConvertFrom-DataSafeTransactionJson (ConvertTo-Json -InputObject $op -Depth 32)
    $copy | Add-Member -NotePropertyName error -NotePropertyValue $null
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
  if ($isDirectory -ne ($entry.entryType -ceq 'directory') -or $attributes -ne $entry.attributes -or $modified -cne $entry.modifiedUtc) { throw "DataSafe source snapshot changed after scan: $path" }
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
  $old = $Transaction.state; $Transaction.state = $State
  try { Save-DataSafeOwnedTransaction $owner } catch { $Transaction.state = $old; throw }
  if ($State -cin @('committed','rolledBack')) {
    Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath)
    $owner.Handle = $null
  }
}

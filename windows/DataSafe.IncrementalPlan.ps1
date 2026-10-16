Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DataSafe.Manifest.ps1')

# Planning is read-only. Operations are transaction input, not an apply order:
# Task 4 must reject BlockingErrors and DeletionReviewRequired, acquire the
# repository lock, and revalidate the paths/space/history name before staging.
# Operation schema v1: sequence, kind (add/replace/metadata/delete), sourceId,
# relativePath, sourcePath, currentPath (new destination), oldCurrentPath,
# historyPath, stagedPath, expectedOldSha256, expectedNewSha256, oldEntry,
# newEntry, status. Paths are absolute; entry snapshots retain manifest types.
# Directory operations never stage bytes. A deleted/replaced directory must
# NOT be recursively moved with descendants: each entry is journaled separately.
function ConvertTo-DataSafePlanInt64([decimal]$Value) {
  if ($Value -lt 0 -or $Value -gt [long]::MaxValue -or [decimal]::Truncate($Value) -ne $Value) {
    throw 'DataSafe plan Int64 arithmetic overflow or invalid byte count.'
  }
  return [long]$Value
}

function New-DataSafeIncrementalPlan($Repository, $PreviousManifest, $CurrentManifest, $Capabilities, [long]$FreeBytes) {
  $plan = [PSCustomObject][ordered]@{
    TransactionId = [guid]::NewGuid().ToString('D')
    PreviousBackupTimestamp = $null; DisplayHistoryFolder = $null
    Operations = @(); StageBytes = [long]0; PeakRequiredBytes = [long]0
    DeletionReviewRequired = $false; DeletionCountsBySource = @(); BlockingErrors = @()
    OperationSchemaVersion = 1; MetadataOverheadBytes = [long]0; ReserveBytes = [long]0
  }
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $actual = $null; $current = $null; $previous = $null; $capabilityValid = $false
  try {
    if ($Repository -isnot [PSCustomObject]) { throw 'DataSafe plan repository must be an object.' }
    $root = Get-DataSafeManifestScalar $Repository 'Root'
    Assert-DataSafeManifestSourcePath $root
    $actual = Read-DataSafeRepository $root
    foreach ($name in @('FormatVersion','ComputerId','ComputerName','Root','LatestRoot','HistoryRoot','MetadataRoot','ManifestRoot','TransactionRoot','StagingRoot')) {
      $kind = if ($name -eq 'FormatVersion') { 'integer' } else { 'string' }
      $value = Get-DataSafeManifestScalar $Repository $name $kind
      if ($kind -eq 'integer') { $equal = $value -eq $actual.$name }
      else { $equal = $value.Equals($actual.$name, [StringComparison]::OrdinalIgnoreCase) }
      if (-not $equal) { throw "DataSafe plan repository field does not match required metadata: $name" }
    }
  } catch { $errors.Add("Repository: $($_.Exception.Message)"); $actual = $null }
  try {
    if ($Capabilities -isnot [PSCustomObject]) { throw 'DataSafe filesystem capabilities must be an object.' }
    $fs = Get-DataSafeManifestScalar $Capabilities 'FileSystem'
    $expected = Get-DataSafeFilesystemCapabilities $fs
    if (-not $expected.Supported) { throw 'DataSafe destination filesystem is unsupported.' }
    foreach ($name in @('Supported','Recommended','CompatibilityMode')) {
      if ($null -eq $Capabilities.PSObject.Properties[$name] -or $Capabilities.$name -isnot [bool] -or $Capabilities.$name -ne $expected.$name) {
        throw "DataSafe filesystem capabilities are invalid: $name"
      }
    }
    $maximum = Get-DataSafeManifestScalar $Capabilities 'MaxFileBytes' 'integer'
    $total = Get-DataSafeManifestScalar $Capabilities 'TotalBytes' 'integer'
    if ($maximum -ne $expected.MaxFileBytes -or $total -le 0) { throw 'DataSafe filesystem capabilities or total capacity are invalid.' }
    $plan.ReserveBytes = ConvertTo-DataSafePlanInt64 ([Math]::Max([decimal]5368709120, [decimal]::Ceiling([decimal]$total / 10)))
    $capabilityValid = $true
  } catch { $errors.Add("Capabilities: $($_.Exception.Message)") }
  try {
    $current = ConvertTo-DataSafeValidatedManifest $CurrentManifest
    if ($null -ne $PreviousManifest) {
      $previous = ConvertTo-DataSafeValidatedManifest $PreviousManifest
      $plan.PreviousBackupTimestamp = $previous.createdUtc
      if ($previous.sourceErrors.Count -gt 0) { throw 'Previous committed manifest contains source errors.' }
    }
    foreach ($sourceError in $current.sourceErrors) { $errors.Add("Source $($sourceError.sourceId): $($sourceError.message)") }
    # Recheck roots even for unchanged/empty sources: a root can disappear or
    # become a junction after the scan, without producing a pending operation.
    foreach ($source in $current.sources) {
      Assert-DataSafeNoReparsePath $source.path
      if (Test-DataSafeFile $source.path) {
        foreach ($entry in $current.entries) {
          if ($entry.sourceId.Equals($source.sourceId, [StringComparison]::OrdinalIgnoreCase) -and
              ($entry.entryType -cne 'file' -or -not $entry.relativePath.Equals([IO.Path]::GetFileName($source.path), [StringComparison]::OrdinalIgnoreCase))) {
            throw 'DataSafe selected-file source contains a fabricated child entry.'
          }
        }
      } elseif (-not (Test-DataSafeDirectory $source.path)) { throw "DataSafe source is unavailable: $($source.path)" }
    }
    # Current/previous committed entries must describe Latest Backup. Older
    # restore-point manifests with history locations are not current baselines.
    foreach ($manifest in @($previous, $current)) {
      if ($null -eq $manifest) { continue }
      foreach ($entry in $manifest.entries) {
        if (-not $entry.versionLocation.StartsWith('Latest Backup/', [StringComparison]::Ordinal)) {
          throw 'DataSafe plan requires a latest committed manifest, not a historical version location.'
        }
      }
    }
  } catch { $errors.Add("Manifest: $($_.Exception.Message)"); $current = $null }
  if ($FreeBytes -lt 0) { $errors.Add('DataSafe free space must not be negative.') }
  if ($null -ne $previous -and $null -ne $actual) {
    try {
      $timestamp = [datetime]::ParseExact($previous.createdUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
      $base = 'Backup from ' + $timestamp.ToString('yyyy-MM-dd HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
      $occupied = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($path in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $actual.HistoryRoot))) {
        $null = $occupied.Add([IO.Path]::GetFileName($path))
      }
      $candidate = $base; $suffix = 2
      while ($occupied.Contains($candidate)) { $candidate = $base + ' (' + $suffix + ')'; $suffix++ }
      $plan.DisplayHistoryFolder = $candidate
    } catch { $errors.Add("History metadata: $($_.Exception.Message)") }
  }
  if ($null -ne $current) {
    try {
      $diff = Compare-DataSafeManifests $previous $current
      $oldEntries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
      $sources = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
      $counts = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($manifest in @($previous, $current)) {
        if ($null -eq $manifest) { continue }
        foreach ($source in $manifest.sources) {
          $sources[$source.sourceId] = $source
          if (-not $counts.ContainsKey($source.sourceId)) {
            $counts.Add($source.sourceId, [PSCustomObject]@{ SourceId = $source.sourceId; PreviousFileCount = [long]0; DeletedFileCount = [long]0; ReviewRequired = $false })
          }
        }
      }
      if ($null -ne $previous) {
        foreach ($entry in $previous.entries) {
          $oldEntries.Add(($entry.sourceId + [char]0 + $entry.relativePath), $entry)
          if ($entry.entryType -ceq 'file') { $counts[$entry.sourceId].PreviousFileCount++ }
        }
      }
      foreach ($entry in $diff.Deleted) { if ($entry.entryType -ceq 'file') { $counts[$entry.sourceId].DeletedFileCount++ } }
      foreach ($count in $counts.Values) {
        $n = [decimal]$count.DeletedFileCount; $prior = [decimal]$count.PreviousFileCount
        $count.ReviewRequired = $prior -gt 0 -and (($n -ge 20 -and $n * 10 -ge $prior) -or $n * 2 -ge $prior)
        if ($count.ReviewRequired) { $plan.DeletionReviewRequired = $true }
      }
      $plan.DeletionCountsBySource = @(foreach ($key in @(Get-DataSafeManifestOrderedKeys $counts)) { $counts[$key] })
      $pending = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($row in @(
        @{ Group = 'Added'; Kind = 'add' }, @{ Group = 'ContentChanged'; Kind = 'replace' },
        @{ Group = 'MetadataChanged'; Kind = 'metadata' }, @{ Group = 'Deleted'; Kind = 'delete' }
      )) {
        foreach ($entry in $diff.($row.Group)) {
          $key = $entry.sourceId + [char]0 + $entry.relativePath
          $pending.Add($key, [PSCustomObject]@{ Kind = $row.Kind; Entry = $entry })
          if ($row.Kind -in @('add','replace') -and $entry.entryType -ceq 'file') {
            $plan.StageBytes = ConvertTo-DataSafePlanInt64 ([decimal]$plan.StageBytes + [decimal]$entry.length)
            if ($capabilityValid -and $entry.length -gt $maximum) { $errors.Add("Filesystem file limit exceeded: $($entry.sourceId)/$($entry.relativePath)") }
          }
        }
      }
      if ($null -ne $actual) {
        $operations = New-Object 'System.Collections.Generic.List[object]'
        foreach ($key in @(Get-DataSafeManifestOrderedKeys $pending)) {
          $item = $pending[$key]; $entry = $item.Entry; $kind = $item.Kind
          if ($kind -eq 'delete' -and $plan.DeletionReviewRequired) { continue }
          $old = $null; $new = $null; $sourcePath = $null; $history = $null; $staged = $null
          if ($oldEntries.ContainsKey($key)) { $old = $oldEntries[$key] }
          if ($kind -ne 'delete') {
            $new = $entry; $source = $sources[$entry.sourceId]
            # Selected single files keep their own absolute path, not path/name.
            $sourcePath = if (Test-DataSafeFile $source.path) { $source.path } else { Join-Path $source.path $entry.relativePath }
            Assert-DataSafeNoReparsePath $sourcePath
          }
          if ($kind -in @('replace','delete')) {
            $category = if ($kind -eq 'delete') { 'Deleted Files' } else { 'Previous Versions' }
            $history = Join-Path (Join-Path (Join-Path $actual.HistoryRoot $plan.DisplayHistoryFolder) $category) $old.versionLocation.Substring(14)
          }
          if ($null -ne $new -and $new.entryType -ceq 'file' -and $kind -in @('add','replace')) {
            $staged = Join-Path (Join-Path $actual.StagingRoot $plan.TransactionId) $new.versionLocation.Substring(14)
          }
          $currentPath = Join-Path $actual.Root $entry.versionLocation
          $oldPath = if ($null -ne $old) { Join-Path $actual.Root $old.versionLocation } else { $null }
          foreach ($path in @($currentPath, $oldPath, $history, $staged)) { if ($null -ne $path) { Assert-DataSafeNoReparsePath $path } }
          $operations.Add([PSCustomObject][ordered]@{
            sequence = $operations.Count + 1; kind = $kind; sourceId = $entry.sourceId; relativePath = $entry.relativePath
            sourcePath = $sourcePath; currentPath = $currentPath; oldCurrentPath = $oldPath; historyPath = $history; stagedPath = $staged
            expectedOldSha256 = $(if ($null -ne $old) { $old.sha256 } else { $null })
            expectedNewSha256 = $(if ($null -ne $new) { $new.sha256 } else { $null })
            oldEntry = $old; newEntry = $new; status = 'pending'
          })
        }
        $plan.Operations = $operations.ToArray()
        # Budget for two atomic copies of manifests/journal plus path/record
        # expansion: 1 MiB + 8x UTF-8 payload + 8 KiB per operation. Task 4
        # must keep its durable serialized metadata inside this allowance or
        # recheck peak space before writing. No history content bytes are added.
        $payload = [PSCustomObject]@{ previous = $previous; current = $current; operations = $plan.Operations }
        $json = ConvertTo-Json -InputObject $payload -Depth 30 -Compress
        $size = [Text.Encoding]::UTF8.GetByteCount($json)
        $plan.MetadataOverheadBytes = ConvertTo-DataSafePlanInt64 (1048576 + [decimal]8 * $size + [decimal]8192 * $plan.Operations.Count)
      }
    } catch { $errors.Add("Preflight: $($_.Exception.Message)") }
  }
  if ($capabilityValid -and $plan.MetadataOverheadBytes -gt 0) {
    try {
      $plan.PeakRequiredBytes = ConvertTo-DataSafePlanInt64 ([decimal]$plan.StageBytes + $plan.MetadataOverheadBytes + $plan.ReserveBytes)
      if ($FreeBytes -lt $plan.PeakRequiredBytes) { $errors.Add('DataSafe destination has insufficient peak free space.') }
    } catch { $errors.Add($_.Exception.Message) }
  }
  $plan.BlockingErrors = $errors.ToArray()
  if ($errors.Count -gt 0) { $plan.Operations = @() }
  return $plan
}

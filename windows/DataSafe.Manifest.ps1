Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'DataSafe.Repository.ps1')

# UTF-8 schema datasafe.manifest / formatVersion 2:
# { schema, formatVersion, createdUtc, sources: [{sourceId,path,relativeDestination}],
#   entries: [{sourceId,relativePath,entryType,length,modifiedUtc,attributes,sha256,versionLocation}],
#   sourceErrors: [{sourceId,path,message}] }
# Paths in metadata use '/', times use UTC round-trip strings, attributes use
# FileAttributes integers. Directories have length 0 / sha256 null. Entries do
# not include a directory source root itself. A selected file uses its basename
# as relativePath, matching Copy-BackupItem's destination folder plus basename.
# Jobs are already-selected/resolved engine jobs (id/path/name and optional
# destination fields), not consumer config. source.path is always the actual
# selection, not a selected file's parent.

function ConvertTo-DataSafeManifestRelativePath($Path) {
  if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { throw [ArgumentException]'DataSafe manifest requires a safe relative path.' }
  $normalized = $Path.Replace('\', '/')
  foreach ($segment in $normalized.Split('/')) {
    if ([string]::IsNullOrEmpty($segment) -or $segment -in @('.', '..') -or $segment -match '[<>:"|?*\x00-\x1f]' -or $segment -match '[. ]$' -or
        $segment -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)') {
      throw [ArgumentException]"DataSafe manifest contains an unsafe path segment: $Path"
    }
  }
  return $normalized
}

function Assert-DataSafeManifestSourcePath($Path) {
  if ($Path -isnot [string] -or $Path -notmatch '^(?:[a-zA-Z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))' -or
      $Path -match '(?:^|[\\/])\.{1,2}(?:[\\/]|$)' -or $Path -match '[\x00-\x1f]' -or $Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) {
    throw 'DataSafe manifest source path must be absolute without traversal or device prefixes.'
  }
  $ordinary = $Path.Replace('/', '\').TrimEnd('\')
  $suffix = if ($ordinary.StartsWith('\\')) { $ordinary.Substring(2) } else { $ordinary.Substring(2).TrimStart('\') }
  if ($suffix.Length -gt 0) { $null = ConvertTo-DataSafeManifestRelativePath $suffix }
}

function Assert-DataSafeManifestUtc($Value) {
  $parsed = [datetime]::MinValue
  if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$' -or
      -not [datetime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
    throw 'DataSafe manifest timestamp must be a UTC round-trip string.'
  }
}

function Get-DataSafeManifestOrderedKeys($Dictionary) {
  [string[]]$keys = @($Dictionary.Keys)
  [Array]::Sort($keys, [StringComparer]::OrdinalIgnoreCase)
  return $keys
}

function Get-DataSafeManifestScalar($Object, [string]$Name, [string]$Kind = 'string', [switch]$AllowNull) {
  if ($Object -isnot [PSCustomObject] -or $null -eq $Object.PSObject.Properties[$Name]) { throw "DataSafe manifest schema requires an object with field: $Name" }
  # Inspect the raw property before returning anything onto the pipeline. The
  # general property getter can collapse [value] into value and [] into null.
  $value = $Object.PSObject.Properties[$Name].Value
  if ($null -eq $value -and $AllowNull) { return $null }
  if (($Kind -eq 'string' -and $value -isnot [string]) -or
      ($Kind -eq 'integer' -and $value -isnot [int] -and $value -isnot [long])) {
    throw "DataSafe manifest schema requires a scalar $Kind field: $Name"
  }
  return $value
}

function ConvertTo-DataSafePortableAttributes([long]$Attributes, [bool]$IsDirectory) {
  # Portable DOS flags only: read-only, hidden, system and archive. Directory
  # is derived from entry type; storage-specific NTFS flags are not versioned.
  $result = $Attributes -band 39
  if ($IsDirectory) { $result = $result -bor 16 }
  return [long]$result
}

function ConvertTo-DataSafeValidatedManifest($Manifest) {
  if ($null -eq $Manifest -or $Manifest -isnot [PSCustomObject] -or (Get-DataSafeManifestScalar $Manifest 'schema') -cne 'datasafe.manifest') { throw 'DataSafe manifest schema is invalid.' }
  $version = Get-DataSafeManifestScalar $Manifest 'formatVersion' 'integer'
  if ($version -ne 2) { throw 'DataSafe manifest format version is unsupported.' }
  $created = Get-DataSafeManifestScalar $Manifest 'createdUtc'
  Assert-DataSafeManifestUtc $created
  foreach ($name in @('sources', 'entries', 'sourceErrors')) {
    # The general property helper emits onto the pipeline and unwraps singleton
    # arrays. Inspect the property itself to preserve JSON array cardinality.
    if ($null -eq $Manifest.PSObject.Properties[$name] -or $Manifest.$name -isnot [array]) { throw "DataSafe manifest $name must be an array." }
  }
  $sources = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  $destinations = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $physicalSources = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($source in $Manifest.sources) {
    $id = Get-DataSafeManifestScalar $source 'sourceId'
    if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id) -or $id.Contains([string][char]0)) { throw 'DataSafe manifest source identity is invalid.' }
    if ($sources.ContainsKey($id)) { throw 'DataSafe manifest contains duplicate source identities.' }
    $path = Get-DataSafeManifestScalar $source 'path'
    Assert-DataSafeManifestSourcePath $path
    # Physical paths are a collision guard only; sourceId remains identity.
    # Normalize Windows spelling without touching the selected filesystem.
    $physicalPath = [IO.Path]::GetFullPath($path.Replace('/', '\')).TrimEnd('\')
    if (-not $physicalSources.Add($physicalPath)) { throw 'DataSafe manifest contains duplicate physical source mappings.' }
    $destination = ConvertTo-DataSafeManifestRelativePath (Get-DataSafeManifestScalar $source 'relativeDestination')
    if (-not $destinations.Add($destination)) { throw 'DataSafe manifest contains a destination collision.' }
    $sources.Add($id, [PSCustomObject][ordered]@{ sourceId = $id; path = $path; relativeDestination = $destination })
  }
  # Overlapping destination roots would allow one source to occupy another's
  # namespace, even if that source happens to be empty during this scan.
  foreach ($destination in $destinations) {
    $parent = $destination
    while ($parent.Contains('/')) {
      $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
      if ($destinations.Contains($parent)) { throw 'DataSafe manifest contains overlapping destination paths.' }
    }
  }
  $entries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  $locations = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $Manifest.entries) {
    $id = Get-DataSafeManifestScalar $entry 'sourceId'
    if ($id -isnot [string] -or -not $sources.ContainsKey($id)) { throw 'DataSafe manifest entry has an unknown source identity.' }
    $relative = ConvertTo-DataSafeManifestRelativePath (Get-DataSafeManifestScalar $entry 'relativePath')
    $key = $id + [char]0 + $relative
    if ($entries.ContainsKey($key)) { throw "DataSafe manifest contains a case-insensitive path collision: $relative" }
    $type = Get-DataSafeManifestScalar $entry 'entryType'
    $length = Get-DataSafeManifestScalar $entry 'length' 'integer'
    $attributes = Get-DataSafeManifestScalar $entry 'attributes' 'integer'
    $hash = Get-DataSafeManifestScalar $entry 'sha256' -AllowNull
    $modified = Get-DataSafeManifestScalar $entry 'modifiedUtc'
    Assert-DataSafeManifestUtc $modified
    if ($type -cnotin @('file','directory') -or ($length -isnot [int] -and $length -isnot [long]) -or $length -lt 0 -or
        ($attributes -isnot [int] -and $attributes -isnot [long]) -or $attributes -lt 0 -or $attributes -gt [int]::MaxValue -or ($attributes -band 1024) -ne 0) {
      throw 'DataSafe manifest entry type, length, or attributes are invalid.'
    }
    if ($type -ceq 'file') {
      if ($hash -isnot [string] -or $hash -notmatch '^[a-fA-F0-9]{64}$' -or ($attributes -band 16) -ne 0) { throw 'DataSafe manifest file hash or attributes are invalid.' }
      $hash = $hash.ToUpperInvariant()
    } elseif ($length -ne 0 -or $null -ne $hash -or ($attributes -band 16) -eq 0) { throw 'DataSafe manifest directory schema is invalid.' }
    $location = ConvertTo-DataSafeManifestRelativePath (Get-DataSafeManifestScalar $entry 'versionLocation')
    if (-not $location.StartsWith('Latest Backup/', [StringComparison]::Ordinal) -and -not $location.StartsWith('Earlier Versions/', [StringComparison]::Ordinal)) { throw 'DataSafe manifest version location is outside the ordinary-file roots.' }
    $expectedLatest = 'Latest Backup/' + $sources[$id].relativeDestination + '/' + $relative
    if ($location.StartsWith('Latest Backup/', [StringComparison]::Ordinal) -and -not $location.Equals($expectedLatest, [StringComparison]::OrdinalIgnoreCase)) { throw 'DataSafe manifest latest version path does not match its source-relative destination.' }
    if (-not $locations.Add($location)) { throw 'DataSafe manifest contains a version-location path collision.' }
    $entries.Add($key, [PSCustomObject][ordered]@{
      sourceId = $id; relativePath = $relative; entryType = $type; length = [long]$length
      modifiedUtc = $modified; attributes = (ConvertTo-DataSafePortableAttributes $attributes ($type -ceq 'directory')); sha256 = $hash; versionLocation = $location
    })
  }
  foreach ($entry in $entries.Values) {
    $parent = $entry.relativePath
    while ($parent.Contains('/')) {
      $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
      $key = $entry.sourceId + [char]0 + $parent
      if ($entries.ContainsKey($key) -and $entries[$key].entryType -ceq 'file') { throw 'DataSafe manifest path traverses a file entry.' }
    }
  }
  $errors = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($sourceError in $Manifest.sourceErrors) {
    $id = Get-DataSafeManifestScalar $sourceError 'sourceId'
    $path = Get-DataSafeManifestScalar $sourceError 'path'
    $message = Get-DataSafeManifestScalar $sourceError 'message'
    if ($id -isnot [string] -or -not $sources.ContainsKey($id) -or $errors.ContainsKey($id) -or $path -cne $sources[$id].path -or
        $message -isnot [string] -or [string]::IsNullOrWhiteSpace($message)) { throw 'DataSafe manifest source-error schema is invalid.' }
    $errors.Add($id, [PSCustomObject][ordered]@{ sourceId = $id; path = $path; message = $message })
  }
  foreach ($entry in $entries.Values) {
    if ($errors.ContainsKey($entry.sourceId)) { throw 'DataSafe manifest contains partial entries for an errored source.' }
  }
  return [PSCustomObject][ordered]@{
    schema = 'datasafe.manifest'; formatVersion = 2; createdUtc = $created
    sources = @(foreach ($key in @(Get-DataSafeManifestOrderedKeys $sources)) { $sources[$key] })
    entries = @(foreach ($key in @(Get-DataSafeManifestOrderedKeys $entries)) { $entries[$key] })
    sourceErrors = @(foreach ($key in @(Get-DataSafeManifestOrderedKeys $errors)) { $errors[$key] })
  }
}

function ConvertTo-DataSafeManifestDestinationSegment([string]$Value, [string]$Fallback = 'Item') {
  $segment = if ([string]::IsNullOrWhiteSpace($Value)) { $Fallback } else { $Value }
  $segment = ($segment -replace '\.[^./\\]+$', '')
  $segment = ($segment -replace '[^a-zA-Z0-9 _-]', '-').Trim()
  if ([string]::IsNullOrWhiteSpace($segment)) { return $Fallback }
  return $segment
}

function Get-DataSafeManifestDestination($Job) {
  # Pure equivalent of backup-engine.ps1's Get-BackupDestinationSegments.
  # Task 6 should reconcile/reuse this boundary when routing resolved jobs.
  $segments = @((Get-DataSafeProperty $Job 'relativeDestination' @()) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { ConvertTo-DataSafeManifestDestinationSegment "$_" })
  if ($segments.Count -eq 0) {
    $key = Get-DataSafeProperty $Job 'backupDestinationKey'
    if (-not [string]::IsNullOrWhiteSpace("$key")) { $segments = @(ConvertTo-DataSafeManifestDestinationSegment "$key") }
    else {
      $name = Get-DataSafeProperty $Job 'name'
      $id = Get-DataSafeProperty $Job 'id'
      $segments = @(ConvertTo-DataSafeManifestDestinationSegment "$name" (ConvertTo-DataSafeManifestDestinationSegment "$id"))
    }
  }
  return ConvertTo-DataSafeManifestRelativePath ($segments -join '/')
}

function New-DataSafeSourceManifest([object[]]$Jobs, $PreviousManifest = $null, [scriptblock]$HashProvider = $null, [switch]$ApplyWorkerExclusions) {
  $previousEntries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  $previousSources = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  if ($null -ne $PreviousManifest) {
    $previous = ConvertTo-DataSafeValidatedManifest $PreviousManifest
    foreach ($source in $previous.sources) { $previousSources.Add($source.sourceId, $source) }
    foreach ($entry in $previous.entries) { $previousEntries.Add(($entry.sourceId + [char]0 + $entry.relativePath), $entry) }
  }
  $manifest = [PSCustomObject][ordered]@{
    schema = 'datasafe.manifest'; formatVersion = 2; createdUtc = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    sources = @(foreach ($job in $Jobs) {
      $path = Get-DataSafeManifestScalar $job 'path'
      Assert-DataSafeManifestSourcePath $path
      [PSCustomObject][ordered]@{ sourceId = Get-DataSafeManifestScalar $job 'id'; path = [IO.Path]::GetFullPath($path); relativeDestination = Get-DataSafeManifestDestination $job }
    })
    entries = @(); sourceErrors = @()
  }
  $manifest = ConvertTo-DataSafeValidatedManifest $manifest
  $allEntries = New-Object 'System.Collections.Generic.List[object]'
  $errors = New-Object 'System.Collections.Generic.List[object]'
  foreach ($source in $manifest.sources) {
    $sourceEntries = New-Object 'System.Collections.Generic.List[object]'
    try {
      Assert-DataSafeNoReparsePath $source.path
      $sourceAttributes = [IO.File]::GetAttributes((ConvertTo-DataSafeExtendedPath $source.path))
      $selectedFile = ($sourceAttributes -band [IO.FileAttributes]::Directory) -eq 0
      $browserExcluded = @(if ($ApplyWorkerExclusions -and -not $selectedFile) { Get-DataSafeBrowserExcludedDirectories $source.path })
      $pending = New-Object 'System.Collections.Generic.Stack[string]'
      $pending.Push($source.path)
      $relativeRoot = if ($selectedFile) { [IO.Path]::GetDirectoryName($source.path) } else { $source.path }
      $sourcePrefix = $relativeRoot.TrimEnd('\', '/') + '\'
      while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Assert-DataSafeNoReparsePath $directory
        [string[]]$children = @(if ($selectedFile) { ConvertTo-DataSafeExtendedPath $directory }
          else { [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $directory)) })
        [Array]::Sort($children, [StringComparer]::OrdinalIgnoreCase)
        foreach ($extended in $children) {
          $attributes = [IO.File]::GetAttributes($extended)
          if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
          $path = ConvertFrom-DataSafeExtendedPath $extended
          if ($ApplyWorkerExclusions -and ($attributes -band [IO.FileAttributes]::Directory) -ne 0 -and
              (Test-DataSafeScanExcludedDirectory $path $browserExcluded)) { continue }
          if (-not $path.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw [ArgumentException]'DataSafe manifest entry path escapes its source.' }
          # GetFullPath normalizes extended-only names (e.g. trailing dots).
          # Validate the actual enumerated name before any helper can do that.
          $relative = ConvertTo-DataSafeManifestRelativePath $path.Substring($sourcePrefix.Length)
          Assert-DataSafeNoReparsePath $path
          $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
          if ($selectedFile -and $isDirectory) { throw 'Selected source file changed into a directory during scanning.' }
          $length = [long]0; $hash = $null
          $modified = [IO.File]::GetLastWriteTimeUtc($extended).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
          if ($isDirectory) { $pending.Push($path) }
          else {
            $info = New-Object IO.FileInfo($extended)
            $length = $info.Length
            $key = $source.sourceId + [char]0 + $relative
            $old = $null
            if ($previousEntries.ContainsKey($key) -and $previousSources[$source.sourceId].path.Equals($source.path, [StringComparison]::OrdinalIgnoreCase)) { $old = $previousEntries[$key] }
            if ($null -ne $old -and $old.entryType -ceq 'file' -and $old.length -eq $length -and $old.modifiedUtc -ceq $modified) { $hash = $old.sha256 }
            elseif ($null -eq $HashProvider) { $hash = Get-DataSafeSha256 $path }
            else { $hash = & $HashProvider $path }
            if ($hash -isnot [string] -or $hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Hash provider returned an invalid SHA-256.' }
          }
          $sourceEntries.Add([PSCustomObject][ordered]@{
            sourceId = $source.sourceId; relativePath = $relative; entryType = $(if ($isDirectory) { 'directory' } else { 'file' })
            length = $length; modifiedUtc = $modified; attributes = [long]$attributes; sha256 = $hash
            versionLocation = 'Latest Backup/' + $source.relativeDestination + '/' + $relative
          })
        }
      }
    } catch [ArgumentException] {
      # Unsafe on-disk names are schema/safety failures, not unavailable data.
      throw
    } catch {
      $errors.Add([PSCustomObject][ordered]@{ sourceId = $source.sourceId; path = $source.path; message = $_.Exception.Message })
      continue
    }
    # Validation is deliberately outside the I/O catch: path collisions and
    # unsafe metadata must abort, not be downgraded to a source-read error.
    $allEntries.AddRange([object[]]$sourceEntries.ToArray())
  }
  $manifest.entries = $allEntries.ToArray()
  $manifest.sourceErrors = $errors.ToArray()
  return ConvertTo-DataSafeValidatedManifest $manifest
}

function Compare-DataSafeManifests($Previous, $Current) {
  $currentManifest = ConvertTo-DataSafeValidatedManifest $Current
  $oldEntries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
  if ($null -ne $Previous) {
    $oldManifest = ConvertTo-DataSafeValidatedManifest $Previous
    foreach ($entry in $oldManifest.entries) { $oldEntries.Add(($entry.sourceId + [char]0 + $entry.relativePath), $entry) }
  }
  $errored = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($sourceError in $currentManifest.sourceErrors) { $null = $errored.Add($sourceError.sourceId) }
  $result = [ordered]@{}
  foreach ($name in @('Added','ContentChanged','MetadataChanged','Deleted','Unchanged')) { $result[$name] = New-Object 'System.Collections.Generic.List[object]' }
  $currentKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $currentManifest.entries) {
    $key = $entry.sourceId + [char]0 + $entry.relativePath
    $null = $currentKeys.Add($key)
    if (-not $oldEntries.ContainsKey($key)) { $result.Added.Add($entry); continue }
    $old = $oldEntries[$key]
    if ($old.entryType -cne $entry.entryType -or $old.sha256 -cne $entry.sha256 -or $old.versionLocation -cne $entry.versionLocation) { $result.ContentChanged.Add($entry) }
    elseif ($old.length -ne $entry.length -or $old.modifiedUtc -cne $entry.modifiedUtc -or $old.attributes -ne $entry.attributes) { $result.MetadataChanged.Add($entry) }
    else { $result.Unchanged.Add($entry) }
  }
  foreach ($key in @(Get-DataSafeManifestOrderedKeys $oldEntries)) {
    $entry = $oldEntries[$key]
    if (-not $currentKeys.Contains($key) -and -not $errored.Contains($entry.sourceId)) { $result.Deleted.Add($entry) }
  }
  $result.SourceErrors = $currentManifest.sourceErrors
  foreach ($name in @('Added','ContentChanged','MetadataChanged','Deleted','Unchanged')) {
    $result[$name] = $result[$name].ToArray()
    $result[$name + 'Count'] = $result[$name].Count
    $bytes = [long]0; $files = 0
    foreach ($entry in $result[$name]) { if ($entry.entryType -ceq 'file') { $bytes += $entry.length; $files++ } }
    $result[$name + 'Bytes'] = $bytes
    $result[$name + 'FileCount'] = $files
  }
  $result.TotalCount = $currentManifest.entries.Count
  $result.TotalFileCount = $result.AddedFileCount + $result.ContentChangedFileCount + $result.MetadataChangedFileCount + $result.UnchangedFileCount
  $result.TotalBytes = [long]($result.AddedBytes + $result.ContentChangedBytes + $result.MetadataChangedBytes + $result.UnchangedBytes)
  return [PSCustomObject]$result
}

function Read-DataSafeManifest([string]$Path) {
  Assert-DataSafeNoReparsePath $Path
  try {
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $json = $encoding.GetString([IO.File]::ReadAllBytes((ConvertTo-DataSafeExtendedPath $Path))).TrimStart([char]0xfeff)
    Assert-DataSafeIdentityJsonShape $json
    # PowerShell 7.5's default date coercion would break the portable JSON
    # string schema. 5.1 already preserves strings and has no DateKind switch.
    $options = @{ InputObject = $json; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
    $manifest = ConvertFrom-Json @options
    return ConvertTo-DataSafeValidatedManifest $manifest
  } catch { throw "DataSafe manifest JSON is invalid: $($_.Exception.Message)" }
}

function Write-DataSafeManifest($Repository, $Manifest, [string]$TransactionId) {
  Assert-DataSafeComputerId $TransactionId
  $validated = ConvertTo-DataSafeValidatedManifest $Manifest
  $actual = Read-DataSafeRepository $Repository.Root
  if ($actual.ComputerId -ine $Repository.ComputerId -or -not $actual.ManifestRoot.Equals($Repository.ManifestRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'DataSafe manifest repository identity or path does not match.' }
  $path = Join-Path $actual.ManifestRoot (([guid]$TransactionId).ToString('D') + '.json')
  Write-DataSafeAtomicJson $path $validated -CreateOnly
  return $path
}

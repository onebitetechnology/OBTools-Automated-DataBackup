Set-StrictMode -Version Latest

$script:DataSafeDestinationMarkerFile = ".datasafe-backup.json"
$script:DataSafeManifestFile = ".datasafe-manifest.json"
$script:DataSafeCompleteFile = ".datasafe-complete.json"
$script:DataSafeIntegrityFile = ".datasafe-integrity.jsonl"
$script:DataSafeVerificationFile = ".datasafe-verification.json"

function Read-DataSafeJson([string]$Path) {
  Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Write-DataSafeJson([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 12
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Get-DataSafeProperty($Value, [string]$Name, $DefaultValue = $null) {
  if ($null -eq $Value -or $null -eq $Value.PSObject.Properties[$Name]) {
    return $DefaultValue
  }

  return $Value.$Name
}

function Expand-DataSafePath([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  return [Environment]::ExpandEnvironmentVariables($Value)
}

function Get-DataSafeComparablePath([string]$Value) {
  $expanded = Expand-DataSafePath $Value
  if ([string]::IsNullOrWhiteSpace($expanded)) {
    return ""
  }

  try {
    return [System.IO.Path]::GetFullPath($expanded).TrimEnd('\', '/')
  } catch {
    return $expanded.TrimEnd('\', '/')
  }
}

function Test-DataSafeSnapshotJobMatchesActiveJob($SnapshotJob, $ActiveJob) {
  if ($null -eq $SnapshotJob -or $null -eq $ActiveJob) {
    return $false
  }

  $snapshotId = "$(Get-DataSafeProperty $SnapshotJob 'id' '')"
  $activeId = "$(Get-DataSafeProperty $ActiveJob 'id' '')"
  $snapshotType = "$(Get-DataSafeProperty $SnapshotJob 'type' '')"
  $activeType = "$(Get-DataSafeProperty $ActiveJob 'type' '')"
  $snapshotPath = Get-DataSafeComparablePath "$(Get-DataSafeProperty $SnapshotJob 'sourcePath' '')"
  $activePath = Get-DataSafeComparablePath "$(Get-DataSafeProperty $ActiveJob 'path' '')"

  return (
    -not [string]::IsNullOrWhiteSpace($snapshotId) -and
    $snapshotId -eq $activeId -and
    -not [string]::IsNullOrWhiteSpace($snapshotType) -and
    $snapshotType -eq $activeType -and
    -not [string]::IsNullOrWhiteSpace($snapshotPath) -and
    -not [string]::IsNullOrWhiteSpace($activePath) -and
    $snapshotPath.Equals($activePath, [System.StringComparison]::OrdinalIgnoreCase)
  )
}

function Test-DataSafePathInside([string]$CandidatePath, [string]$RootPath) {
  $candidate = Get-DataSafeComparablePath $CandidatePath
  $root = Get-DataSafeComparablePath $RootPath
  if ([string]::IsNullOrWhiteSpace($candidate) -or [string]::IsNullOrWhiteSpace($root)) {
    return $false
  }

  $separator = [System.IO.Path]::DirectorySeparatorChar
  return (
    $candidate.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
    $candidate.StartsWith("$root$separator", [System.StringComparison]::OrdinalIgnoreCase)
  )
}

function Assert-DataSafeAlternateRestoreTarget(
  [string]$ChosenTarget,
  [string]$BaseRoot,
  [string]$SnapshotRoot,
  [string]$OriginalSourcePath
) {
  if ([string]::IsNullOrWhiteSpace($ChosenTarget)) {
    throw "Choose a restore folder before restoring to another location."
  }

  $protectedRoots = @(
    [PSCustomObject]@{ Label = "DataSafe backup repository"; Path = $BaseRoot },
    [PSCustomObject]@{ Label = "selected snapshot"; Path = $SnapshotRoot },
    [PSCustomObject]@{ Label = "original source"; Path = $OriginalSourcePath }
  )
  foreach ($protectedRoot in $protectedRoots) {
    if (Test-DataSafePathInside -CandidatePath $ChosenTarget -RootPath $protectedRoot.Path) {
      throw "DataSafe will not use a restore folder inside the $($protectedRoot.Label). Choose a separate location."
    }
  }
}

function Acquire-DataSafeOperationLock([string]$LockPath) {
  if (Test-Path -LiteralPath $LockPath) {
    $existing = Get-Item -LiteralPath $LockPath -ErrorAction SilentlyContinue
    $ageHours = if ($existing) { ((Get-Date) - $existing.LastWriteTime).TotalHours } else { 0 }
    if ($ageHours -lt 12) {
      throw "A DataSafe backup or restore is already running. Wait for it to finish before starting another operation."
    }

    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
  }

  try {
    $handle = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID`nstartedAt=$((Get-Date).ToString('o'))`n")
    $handle.Write($bytes, 0, $bytes.Length)
    $handle.Flush()
    $handle.Position = 0
    return $handle
  } catch {
    throw "A DataSafe backup or restore is already running. Wait for it to finish before starting another operation."
  }
}

function Release-DataSafeOperationLock($Handle, [string]$LockPath) {
  if ($Handle) {
    $Handle.Dispose()
  }

  Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}

function Resolve-DataSafeDestination($Destination) {
  if (
    (Get-DataSafeProperty $Destination "mode" "") -eq "label" -and
    -not [string]::IsNullOrWhiteSpace("$(Get-DataSafeProperty $Destination 'label' '')")
  ) {
    $label = "$(Get-DataSafeProperty $Destination 'label' '')"
    $volume = Get-Volume | Where-Object { $_.FileSystemLabel -eq $label } | Select-Object -First 1
    if ($volume -and $volume.DriveLetter) {
      return "$($volume.DriveLetter):\"
    }
  }

  $driveLetter = "$(Get-DataSafeProperty $Destination 'driveLetter' '')"
  if (-not [string]::IsNullOrWhiteSpace($driveLetter)) {
    return "$($driveLetter.TrimEnd(':')):\"
  }

  throw "No destination drive could be resolved."
}

function Get-DataSafeBaseRoot($Config) {
  $driveRoot = Resolve-DataSafeDestination $Config.destination
  if (-not (Test-Path -LiteralPath $driveRoot)) {
    throw "Destination drive is not available: $driveRoot"
  }

  $baseFolder = "$(Get-DataSafeProperty $Config.destination 'baseFolder' '')"
  if ([string]::IsNullOrWhiteSpace($baseFolder)) {
    return $driveRoot
  }

  return Join-Path $driveRoot $baseFolder
}

function Get-DataSafeInstallId($Config) {
  return "$(Get-DataSafeProperty $Config 'installId' '')"
}

function Get-DataSafeDestinationId($Config) {
  return "$(Get-DataSafeProperty $Config.destination 'id' '')"
}

function Test-DataSafeStatusHasHistory($Status) {
  if ($null -eq $Status) {
    return $false
  }

  if (-not [string]::IsNullOrWhiteSpace("$(Get-DataSafeProperty $Status 'lastBackupAt' '')")) {
    return $true
  }

  $snapshots = @(Get-DataSafeProperty $Status "recentSnapshots" @())
  return $snapshots.Count -gt 0
}

function Get-DataSafeBaseRootContent([string]$BaseRoot) {
  if (-not (Test-Path -LiteralPath $BaseRoot)) {
    return @()
  }

  return @(Get-ChildItem -LiteralPath $BaseRoot -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -ne $script:DataSafeDestinationMarkerFile
  })
}

function Assert-DataSafeDestinationIdentity(
  [string]$BaseRoot,
  $Config,
  $Status,
  [switch]$AllowNewDestination
) {
  $installId = Get-DataSafeInstallId $Config
  $destinationId = Get-DataSafeDestinationId $Config
  if ([string]::IsNullOrWhiteSpace($installId) -or [string]::IsNullOrWhiteSpace($destinationId)) {
    throw "DataSafe could not verify this backup location because the installation or destination identity is missing. Open DataSafe, choose the backup location again, and save Settings."
  }

  $markerPath = Join-Path $BaseRoot $script:DataSafeDestinationMarkerFile
  if (Test-Path -LiteralPath $markerPath) {
    try {
      $marker = Read-DataSafeJson $markerPath
    } catch {
      throw "The backup destination identity marker cannot be read. DataSafe will not write to this drive until the destination is reviewed."
    }

    $markerInstallId = "$(Get-DataSafeProperty $marker 'installId' '')"
    $markerDestinationId = "$(Get-DataSafeProperty $marker 'destinationId' '')"
    if ([string]::IsNullOrWhiteSpace($markerInstallId) -or $markerInstallId -ne $installId) {
      throw "This backup destination does not match this DataSafe installation. DataSafe stopped before writing any backup files."
    }

    if (-not [string]::IsNullOrWhiteSpace($markerDestinationId) -and $markerDestinationId -ne $destinationId) {
      throw "This backup destination identity marker belongs to a different configured backup location. DataSafe stopped before writing any backup files."
    }

    return $marker
  }

  $existingContent = @(Get-DataSafeBaseRootContent $BaseRoot)
  if ($existingContent.Count -gt 0) {
    throw "The selected location contains backup data but its DataSafe identity marker is missing. DataSafe stopped before writing so existing data cannot be mixed with a new backup set."
  }

  if (-not $AllowNewDestination) {
    throw "The expected DataSafe identity marker was not found. Scheduled backups cannot initialize a new drive. Open DataSafe, confirm the backup location, and run the first backup manually."
  }

  return $null
}

function Ensure-DataSafeDestinationMarker([string]$BaseRoot, $Config, $ExistingMarker = $null) {
  New-Item -ItemType Directory -Force -Path $BaseRoot | Out-Null
  $markerPath = Join-Path $BaseRoot $script:DataSafeDestinationMarkerFile
  $createdAt = "$(Get-DataSafeProperty $ExistingMarker 'createdAt' '')"
  if ([string]::IsNullOrWhiteSpace($createdAt)) {
    $createdAt = (Get-Date).ToString("o")
  }

  $marker = [ordered]@{
    formatVersion = 1
    installId = Get-DataSafeInstallId $Config
    destinationId = Get-DataSafeDestinationId $Config
    businessName = "$(Get-DataSafeProperty $Config 'businessName' '')"
    createdAt = $createdAt
    lastVerifiedAt = (Get-Date).ToString("o")
    machineName = $env:COMPUTERNAME
  }
  Write-DataSafeJson $markerPath $marker
  return [PSCustomObject]$marker
}

function Test-DataSafeMediaReadWrite([string]$BaseRoot) {
  New-Item -ItemType Directory -Force -Path $BaseRoot | Out-Null
  $probePath = Join-Path $BaseRoot ".datasafe-write-test-$([guid]::NewGuid().ToString('N')).tmp"
  $expected = New-Object byte[] 65536
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($expected)

  try {
    $stream = New-Object System.IO.FileStream(
      $probePath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None,
      65536,
      [System.IO.FileOptions]::WriteThrough
    )
    try {
      $stream.Write($expected, 0, $expected.Length)
      $stream.Flush($true)
      $stream.Position = 0
      $actual = New-Object byte[] $expected.Length
      $offset = 0
      while ($offset -lt $actual.Length) {
        $read = $stream.Read($actual, $offset, $actual.Length - $offset)
        if ($read -le 0) {
          break
        }
        $offset += $read
      }
    } finally {
      $stream.Dispose()
    }

    if ($offset -ne $expected.Length) {
      throw "The test file could not be read back completely."
    }

    for ($index = 0; $index -lt $expected.Length; $index++) {
      if ($expected[$index] -ne $actual[$index]) {
        throw "The test file changed when it was read back."
      }
    }
  } catch {
    throw "The backup location failed a write and read test. DataSafe stopped before copying customer data. Check that the drive is writable and healthy, then try again. $($_.Exception.Message)"
  } finally {
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
  }
}

function Get-DataSafeFreeBytes([string]$Path) {
  $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
  $drive = New-Object System.IO.DriveInfo($root)
  return [int64]$drive.AvailableFreeSpace
}

function Get-DataSafePathSize([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return [int64]0
  }

  $item = Get-Item -LiteralPath $Path
  if (-not $item.PSIsContainer) {
    return [int64]$item.Length
  }

  $total = [int64]0
  Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $total += [int64]$_.Length
  }
  return $total
}

function Assert-DataSafeCapacity([string]$BaseRoot, [int64]$EstimatedBytes) {
  $reserve = [Math]::Max([int64]($EstimatedBytes * 0.10), [int64](256MB))
  $required = $EstimatedBytes + $reserve
  $free = Get-DataSafeFreeBytes $BaseRoot
  if ($free -lt $required) {
    $requiredGb = [Math]::Ceiling($required / 1GB * 10) / 10
    $freeGb = [Math]::Floor($free / 1GB * 10) / 10
    throw "The backup drive does not have enough free space for a safe snapshot. DataSafe needs about $requiredGb GB including working space, but only $freeGb GB is available."
  }

  return [PSCustomObject]@{
    estimatedBytes = $EstimatedBytes
    reserveBytes = $reserve
    requiredBytes = $required
    freeBytes = $free
  }
}

function Get-DataSafeRelativePath([string]$RootPath, [string]$ChildPath) {
  $separator = [System.IO.Path]::DirectorySeparatorChar
  $normalizedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/') + $separator
  $normalizedChild = [System.IO.Path]::GetFullPath($ChildPath)
  if (-not $normalizedChild.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "A file was found outside the expected DataSafe folder."
  }

  return $normalizedChild.Substring($normalizedRoot.Length)
}

function New-DataSafeIntegrityIndex([string]$SnapshotPath) {
  $indexPath = Join-Path $SnapshotPath $script:DataSafeIntegrityFile
  $metadataPaths = @(
    [System.IO.Path]::GetFullPath((Join-Path $SnapshotPath $script:DataSafeManifestFile)),
    [System.IO.Path]::GetFullPath((Join-Path $SnapshotPath $script:DataSafeCompleteFile)),
    [System.IO.Path]::GetFullPath((Join-Path $SnapshotPath $script:DataSafeIntegrityFile)),
    [System.IO.Path]::GetFullPath((Join-Path $SnapshotPath $script:DataSafeVerificationFile))
  )
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $writer = New-Object System.IO.StreamWriter($indexPath, $false, $utf8NoBom)
  $fileCount = 0
  $totalBytes = [int64]0

  try {
    $files = @(Get-ChildItem -LiteralPath $SnapshotPath -File -Recurse -Force -ErrorAction Stop | Where-Object {
      [System.IO.Path]::GetFullPath($_.FullName) -notin $metadataPaths
    } | Sort-Object FullName)

    foreach ($file in $files) {
      $relativePath = Get-DataSafeRelativePath $SnapshotPath $file.FullName
      $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
      $record = [ordered]@{
        path = $relativePath
        length = [int64]$file.Length
        lastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
        sha256 = $hash.Hash.ToUpperInvariant()
      }
      $writer.WriteLine(($record | ConvertTo-Json -Compress))
      $fileCount += 1
      $totalBytes += [int64]$file.Length
    }
  } finally {
    $writer.Dispose()
  }

  $indexHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToUpperInvariant()
  return [PSCustomObject]@{
    path = $indexPath
    sha256 = $indexHash
    fileCount = $fileCount
    totalBytes = $totalBytes
  }
}

function Write-DataSafeSnapshotMetadata(
  [string]$SnapshotPath,
  [string]$SnapshotName,
  $Config,
  $Jobs,
  $Integrity
) {
  $completedAt = (Get-Date).ToString("o")
  $jobRecords = @($Jobs | ForEach-Object {
    [ordered]@{
      id = "$(Get-DataSafeProperty $_ 'id' '')"
      name = "$(Get-DataSafeProperty $_ 'name' '')"
      type = "$(Get-DataSafeProperty $_ 'type' '')"
      sourcePath = Expand-DataSafePath "$(Get-DataSafeProperty $_ 'path' '')"
      sourceKind = "$(Get-DataSafeProperty $_ 'sourceKind' '')"
      emailApp = "$(Get-DataSafeProperty $_ 'emailApp' '')"
      processNames = @(
        Get-DataSafeProperty $_ "processNames" @()
      )
      relativeDestination = @(
        Get-DataSafeProperty $_ "relativeDestination" @()
      )
    }
  })
  $manifest = [ordered]@{
    formatVersion = 1
    snapshotName = $SnapshotName
    createdAt = $completedAt
    completedAt = $completedAt
    installId = Get-DataSafeInstallId $Config
    destinationId = Get-DataSafeDestinationId $Config
    machineName = $env:COMPUTERNAME
    jobs = $jobRecords
    integrity = [ordered]@{
      algorithm = "SHA256"
      indexFile = $script:DataSafeIntegrityFile
      indexSha256 = $Integrity.sha256
      fileCount = [int]$Integrity.fileCount
      totalBytes = [int64]$Integrity.totalBytes
    }
  }
  $manifestPath = Join-Path $SnapshotPath $script:DataSafeManifestFile
  Write-DataSafeJson $manifestPath $manifest
  $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
  $complete = [ordered]@{
    formatVersion = 1
    snapshotName = $SnapshotName
    completedAt = $completedAt
    manifestFile = $script:DataSafeManifestFile
    manifestSha256 = $manifestHash
    integrityIndexFile = $script:DataSafeIntegrityFile
    integrityIndexSha256 = $Integrity.sha256
  }
  Write-DataSafeJson (Join-Path $SnapshotPath $script:DataSafeCompleteFile) $complete

  return [PSCustomObject]@{
    manifest = [PSCustomObject]$manifest
    complete = [PSCustomObject]$complete
  }
}

function Get-DataSafeCompletedSnapshot([string]$SnapshotPath) {
  if (-not (Test-Path -LiteralPath $SnapshotPath)) {
    return $null
  }

  $snapshotName = Split-Path -Leaf $SnapshotPath
  if ($snapshotName -notmatch '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$') {
    return $null
  }

  $manifestPath = Join-Path $SnapshotPath $script:DataSafeManifestFile
  $completePath = Join-Path $SnapshotPath $script:DataSafeCompleteFile
  $integrityPath = Join-Path $SnapshotPath $script:DataSafeIntegrityFile
  if (
    -not (Test-Path -LiteralPath $manifestPath) -or
    -not (Test-Path -LiteralPath $completePath) -or
    -not (Test-Path -LiteralPath $integrityPath)
  ) {
    return $null
  }

  try {
    $manifest = Read-DataSafeJson $manifestPath
    $complete = Read-DataSafeJson $completePath
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $integrityHash = (Get-FileHash -LiteralPath $integrityPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if (
      [int](Get-DataSafeProperty $manifest "formatVersion" 0) -ne 1 -or
      [int](Get-DataSafeProperty $complete "formatVersion" 0) -ne 1 -or
      "$(Get-DataSafeProperty $manifest 'snapshotName' '')" -ne $snapshotName -or
      "$(Get-DataSafeProperty $complete 'snapshotName' '')" -ne $snapshotName -or
      "$(Get-DataSafeProperty $complete 'manifestFile' '')" -ne $script:DataSafeManifestFile -or
      "$(Get-DataSafeProperty $complete 'integrityIndexFile' '')" -ne $script:DataSafeIntegrityFile -or
      "$(Get-DataSafeProperty $manifest.integrity 'indexFile' '')" -ne $script:DataSafeIntegrityFile -or
      $manifestHash -ne ("$(Get-DataSafeProperty $complete 'manifestSha256' '')").ToUpperInvariant() -or
      ("$(Get-DataSafeProperty $manifest.integrity 'indexSha256' '')").ToUpperInvariant() -ne
        ("$(Get-DataSafeProperty $complete 'integrityIndexSha256' '')").ToUpperInvariant() -or
      $integrityHash -ne ("$(Get-DataSafeProperty $complete 'integrityIndexSha256' '')").ToUpperInvariant()
    ) {
      return $null
    }

    $completedAt = [datetime]::Parse("$(Get-DataSafeProperty $complete 'completedAt' '')")
    return [PSCustomObject]@{
      Name = $snapshotName
      FullName = $SnapshotPath
      Timestamp = $completedAt
      Manifest = $manifest
      Complete = $complete
    }
  } catch {
    return $null
  }
}

function Get-DataSafeCompletedSnapshots([string]$SnapshotsRoot) {
  if (-not (Test-Path -LiteralPath $SnapshotsRoot)) {
    return @()
  }

  $snapshots = @(Get-ChildItem -LiteralPath $SnapshotsRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $completed = Get-DataSafeCompletedSnapshot $_.FullName
    if ($null -ne $completed) {
      $completed
    }
  })
  return @($snapshots | Sort-Object Timestamp -Descending)
}

function Get-DataSafeSnapshotJob($Snapshot, [string]$JobId) {
  $jobs = @(Get-DataSafeProperty $Snapshot.Manifest "jobs" @())
  $matches = @($jobs | Where-Object { "$(Get-DataSafeProperty $_ 'id' '')" -eq $JobId } | Select-Object -First 1)
  if ($matches.Count -eq 0) {
    throw "The selected backup item is not recorded in this snapshot. Choose a different snapshot or backup item."
  }

  return $matches[0]
}

function Remove-DataSafeIncompleteSnapshots([string]$SnapshotsRoot) {
  if (-not (Test-Path -LiteralPath $SnapshotsRoot)) {
    return
  }

  Get-ChildItem -LiteralPath $SnapshotsRoot -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '\.incomplete$' -or $_.Name -match '^\.incomplete-' } |
    ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-DataSafeIntegrityIndex([string]$SnapshotPath, [string]$RelativePrefix = "") {
  $snapshot = Get-DataSafeCompletedSnapshot $SnapshotPath
  if ($null -eq $snapshot) {
    throw "The selected snapshot is incomplete or its completion record is invalid."
  }

  $indexPath = Join-Path $SnapshotPath $script:DataSafeIntegrityFile
  $expectedIndexHash = ("$(Get-DataSafeProperty $snapshot.Complete 'integrityIndexSha256' '')").ToUpperInvariant()
  $actualIndexHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToUpperInvariant()
  if ($actualIndexHash -ne $expectedIndexHash) {
    throw "The snapshot integrity index has changed since the backup completed."
  }

  $normalizedPrefix = $RelativePrefix.Trim().TrimStart('\', '/').TrimEnd('\', '/')
  if (
    [System.IO.Path]::IsPathRooted($normalizedPrefix) -or
    $normalizedPrefix -match '(^|[\\/])\.\.?(?=([\\/]|$))'
  ) {
    throw "The requested backup item path is not safe."
  }

  $normalizedPrefix = $normalizedPrefix.Replace('/', '\')
  $expectedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $metadataPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($metadataName in @(
    $script:DataSafeManifestFile,
    $script:DataSafeCompleteFile,
    $script:DataSafeIntegrityFile,
    $script:DataSafeVerificationFile
  )) {
    [void]$metadataPaths.Add([System.IO.Path]::GetFullPath((Join-Path $SnapshotPath $metadataName)))
  }

  $checked = 0
  $checkedBytes = [int64]0
  foreach ($line in [System.IO.File]::ReadLines($indexPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $entry = $line | ConvertFrom-Json
    $relativePath = "$(Get-DataSafeProperty $entry 'path' '')"
    if (
      [string]::IsNullOrWhiteSpace($relativePath) -or
      [System.IO.Path]::IsPathRooted($relativePath) -or
      $relativePath -match '(^|[\\/])\.\.?(?=([\\/]|$))'
    ) {
      throw "The snapshot integrity index contains an unsafe file path."
    }

    $comparisonPath = $relativePath.Replace('/', '\')
    if (-not $expectedPaths.Add($comparisonPath)) {
      throw "The snapshot integrity index contains a duplicate file path: $relativePath"
    }

    if (
      -not [string]::IsNullOrWhiteSpace($normalizedPrefix) -and
      $comparisonPath -ne $normalizedPrefix -and
      -not $comparisonPath.StartsWith("$normalizedPrefix\", [System.StringComparison]::OrdinalIgnoreCase)
    ) {
      continue
    }

    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $SnapshotPath $relativePath))
    $safeRoot = [System.IO.Path]::GetFullPath($SnapshotPath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($safeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "The snapshot integrity index contains an unsafe file path."
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      throw "A backed up file is missing: $relativePath"
    }

    $file = Get-Item -LiteralPath $fullPath
    if ([int64]$file.Length -ne [int64](Get-DataSafeProperty $entry "length" -1)) {
      throw "A backed up file has changed size: $relativePath"
    }

    $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne ("$(Get-DataSafeProperty $entry 'sha256' '')").ToUpperInvariant()) {
      throw "A backed up file failed its checksum: $relativePath"
    }

    $checked += 1
    $checkedBytes += [int64]$file.Length
  }

  if (-not [string]::IsNullOrWhiteSpace($normalizedPrefix) -and $checked -eq 0) {
    throw "No integrity records were found for the selected backup item."
  }

  foreach ($file in @(Get-ChildItem -LiteralPath $SnapshotPath -File -Recurse -Force -ErrorAction Stop)) {
    $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
    if ($metadataPaths.Contains($fullPath)) {
      continue
    }

    $relativePath = Get-DataSafeRelativePath $SnapshotPath $fullPath
    $comparisonPath = $relativePath.Replace('/', '\')
    if (
      -not [string]::IsNullOrWhiteSpace($normalizedPrefix) -and
      $comparisonPath -ne $normalizedPrefix -and
      -not $comparisonPath.StartsWith("$normalizedPrefix\", [System.StringComparison]::OrdinalIgnoreCase)
    ) {
      continue
    }

    if (-not $expectedPaths.Contains($comparisonPath)) {
      throw "A file is present in the snapshot but is not listed in its integrity index: $relativePath"
    }
  }

  return [PSCustomObject]@{
    snapshotName = $snapshot.Name
    filesChecked = $checked
    bytesChecked = $checkedBytes
    checkedAt = (Get-Date).ToString("o")
  }
}

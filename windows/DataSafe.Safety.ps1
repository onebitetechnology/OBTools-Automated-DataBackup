Set-StrictMode -Version Latest

$script:DataSafeDestinationMarkerFile = ".datasafe-backup.json"
$script:DataSafeManifestFile = ".datasafe-manifest.json"
$script:DataSafeCompleteFile = ".datasafe-complete.json"
$script:DataSafeIntegrityFile = ".datasafe-integrity.jsonl"
$script:DataSafeVerificationFile = ".datasafe-verification.json"

function ConvertTo-DataSafeExtendedPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  if ($Path.StartsWith("\\?\", [System.StringComparison]::Ordinal)) {
    return $Path
  }

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ($fullPath.StartsWith("\\", [System.StringComparison]::Ordinal)) {
    return "\\?\UNC\$($fullPath.Substring(2))"
  }
  return "\\?\$fullPath"
}

function ConvertFrom-DataSafeExtendedPath([string]$Path) {
  if ($Path.StartsWith("\\?\UNC\", [System.StringComparison]::OrdinalIgnoreCase)) {
    return "\\$($Path.Substring(8))"
  }
  if ($Path.StartsWith("\\?\", [System.StringComparison]::Ordinal)) {
    return $Path.Substring(4)
  }
  return $Path
}

function Test-DataSafeFile([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  return [System.IO.File]::Exists((ConvertTo-DataSafeExtendedPath $Path))
}

function Test-DataSafeDirectory([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  return [System.IO.Directory]::Exists((ConvertTo-DataSafeExtendedPath $Path))
}

function Ensure-DataSafeDirectory([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }
  [System.IO.Directory]::CreateDirectory((ConvertTo-DataSafeExtendedPath $Path)) | Out-Null
}

function Get-DataSafeFileEntry([string]$Path) {
  $extendedPath = ConvertTo-DataSafeExtendedPath $Path
  if (-not [System.IO.File]::Exists($extendedPath)) {
    return $null
  }

  $file = New-Object System.IO.FileInfo($extendedPath)
  return [PSCustomObject]@{
    FullName = ConvertFrom-DataSafeExtendedPath $file.FullName
    Length = [int64]$file.Length
    LastWriteTimeUtc = $file.LastWriteTimeUtc
  }
}

function Get-DataSafeFileEntries([string]$RootPath, [bool]$IgnoreInaccessible = $false) {
  $extendedRoot = ConvertTo-DataSafeExtendedPath $RootPath
  if (-not [System.IO.Directory]::Exists($extendedRoot)) {
    return @()
  }

  $pending = New-Object "System.Collections.Generic.Stack[string]"
  $pending.Push($extendedRoot)
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    try {
      $files = @([System.IO.Directory]::GetFiles($directory))
      $directories = @([System.IO.Directory]::GetDirectories($directory))
    } catch {
      if ($IgnoreInaccessible) {
        continue
      }
      throw
    }

    foreach ($filePath in $files) {
      $file = New-Object System.IO.FileInfo($filePath)
      [PSCustomObject]@{
        FullName = ConvertFrom-DataSafeExtendedPath $file.FullName
        Length = [int64]$file.Length
        LastWriteTimeUtc = $file.LastWriteTimeUtc
      }
    }

    foreach ($childDirectory in $directories) {
      $attributes = [System.IO.File]::GetAttributes($childDirectory)
      if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        $pending.Push($childDirectory)
      }
    }
  }
}

function Copy-DataSafeFile([string]$SourcePath, [string]$DestinationPath) {
  $extendedSource = ConvertTo-DataSafeExtendedPath $SourcePath
  if (-not [System.IO.File]::Exists($extendedSource)) {
    throw "DataSafe could not find the file to copy: $SourcePath"
  }

  $destinationFullPath = [System.IO.Path]::GetFullPath($DestinationPath)
  $destinationParent = [System.IO.Path]::GetDirectoryName($destinationFullPath)
  Ensure-DataSafeDirectory $destinationParent
  [System.IO.File]::Copy($extendedSource, (ConvertTo-DataSafeExtendedPath $destinationFullPath), $true)
}

function Remove-DataSafeDirectoryTree([string]$Path) {
  $extendedRoot = ConvertTo-DataSafeExtendedPath $Path
  if (-not [System.IO.Directory]::Exists($extendedRoot)) {
    return
  }

  $pending = New-Object "System.Collections.Generic.Stack[string]"
  $directories = New-Object "System.Collections.Generic.List[string]"
  $pending.Push($extendedRoot)
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    $directories.Add($directory)

    foreach ($filePath in @([System.IO.Directory]::GetFiles($directory))) {
      [System.IO.File]::SetAttributes($filePath, [System.IO.FileAttributes]::Normal)
      [System.IO.File]::Delete($filePath)
    }

    foreach ($childDirectory in @([System.IO.Directory]::GetDirectories($directory))) {
      $attributes = [System.IO.File]::GetAttributes($childDirectory)
      if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        [System.IO.File]::SetAttributes($childDirectory, [System.IO.FileAttributes]::Normal)
        [System.IO.Directory]::Delete($childDirectory, $false)
      } else {
        $pending.Push($childDirectory)
      }
    }
  }

  foreach ($directory in @($directories | Sort-Object Length -Descending)) {
    [System.IO.File]::SetAttributes($directory, [System.IO.FileAttributes]::Normal)
    [System.IO.Directory]::Delete($directory, $false)
  }
}

function Remove-DataSafePath([string]$Path) {
  $extendedPath = ConvertTo-DataSafeExtendedPath $Path
  if ([System.IO.File]::Exists($extendedPath)) {
    [System.IO.File]::SetAttributes($extendedPath, [System.IO.FileAttributes]::Normal)
    [System.IO.File]::Delete($extendedPath)
    return
  }

  if ([System.IO.Directory]::Exists($extendedPath)) {
    Remove-DataSafeDirectoryTree $Path
  }
}

function Get-DataSafeBrowserExcludedDirectories([string]$Source) {
  $normalized = [System.IO.Path]::GetFullPath($Source).TrimEnd('\', '/').ToLowerInvariant()
  $isChromiumUserData =
    $normalized -like "*\google\chrome\user data" -or
    $normalized -like "*\microsoft\edge\user data" -or
    $normalized -like "*\bravesoftware\brave-browser\user data"
  if (-not $isChromiumUserData -or -not (Test-DataSafeDirectory $Source)) {
    return @()
  }

  $excluded = New-Object System.Collections.Generic.List[string]
  foreach ($name in @(
    "Crashpad",
    "GrShaderCache",
    "GraphiteDawnCache",
    "ShaderCache",
    "BrowserMetrics",
    "Component CRX Cache",
    "component_crx_cache",
    "OptGuideOnDeviceModel",
    "optimization_guide_model_store"
  )) {
    $candidatePath = Join-Path $Source $name
    if (Test-DataSafeDirectory $candidatePath) {
      $excluded.Add($candidatePath)
    }
  }

  foreach ($profilePath in @([System.IO.Directory]::GetDirectories((ConvertTo-DataSafeExtendedPath $Source)))) {
    $profileName = [System.IO.Path]::GetFileName($profilePath)
    if (
      $profileName -ne "Default" -and
      $profileName -notlike "Profile *" -and
      $profileName -ne "Guest Profile" -and
      $profileName -ne "System Profile"
    ) {
      continue
    }

    $normalProfilePath = ConvertFrom-DataSafeExtendedPath $profilePath
    foreach ($relativePath in @(
      "Cache",
      "Code Cache",
      "GPUCache",
      "DawnCache",
      "Media Cache",
      "Blob Storage",
      "Service Worker\CacheStorage",
      "Service Worker\ScriptCache"
    )) {
      $candidatePath = Join-Path $normalProfilePath $relativePath
      if (Test-DataSafeDirectory $candidatePath) {
        $excluded.Add($candidatePath)
      }
    }
  }

  return @($excluded)
}

function Read-DataSafeJson([string]$Path) {
  Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Write-DataSafeJson([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 12
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

# Check every existing ancestor, not just the leaf: a junction in a parent can
# redirect otherwise well-formed repository paths onto another volume or PC.
function Assert-DataSafeNoReparsePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'DataSafe requires a filesystem path.' }
  $current = [System.IO.Path]::GetFullPath((ConvertFrom-DataSafeExtendedPath $Path))
  $ancestors = New-Object 'System.Collections.Generic.Stack[string]'
  while (-not [string]::IsNullOrEmpty($current)) {
    $ancestors.Push($current)
    $current = [System.IO.Path]::GetDirectoryName($current)
  }
  # Build the chain without I/O, then reject a link before querying descendants.
  while ($ancestors.Count -gt 0) {
    $current = $ancestors.Pop()
    try {
      $attributes = [System.IO.File]::GetAttributes((ConvertTo-DataSafeExtendedPath $current))
      if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "DataSafe refuses a reparse point in the filesystem path: $current"
      }
    } catch [System.IO.FileNotFoundException] {
      # Missing descendants are allowed, but their existing ancestors are checked.
    } catch [System.IO.DirectoryNotFoundException] {
    }
  }
}

function Move-DataSafeSameVolume([string]$SourcePath, [string]$DestinationPath) {
  Assert-DataSafeNoReparsePath $SourcePath
  Assert-DataSafeNoReparsePath $DestinationPath
  $source = [System.IO.Path]::GetFullPath((ConvertFrom-DataSafeExtendedPath $SourcePath))
  $destination = [System.IO.Path]::GetFullPath((ConvertFrom-DataSafeExtendedPath $DestinationPath))
  if (-not [System.IO.Path]::GetPathRoot($source).Equals([System.IO.Path]::GetPathRoot($destination), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'DataSafe requires a same-volume move; copying across volumes is not allowed.'
  }
  if ((Test-DataSafeFile $destination) -or (Test-DataSafeDirectory $destination)) {
    throw "DataSafe will not overwrite an existing move destination: $destination"
  }
  if (Test-DataSafeFile $source) {
    [System.IO.File]::Move((ConvertTo-DataSafeExtendedPath $source), (ConvertTo-DataSafeExtendedPath $destination))
  } elseif (Test-DataSafeDirectory $source) {
    [System.IO.Directory]::Move((ConvertTo-DataSafeExtendedPath $source), (ConvertTo-DataSafeExtendedPath $destination))
  } else { throw "DataSafe move source is missing: $source" }
}

function Write-DataSafeAtomicJson([string]$Path, $Value, [switch]$CreateOnly) {
  Assert-DataSafeNoReparsePath $Path
  $fullPath = [System.IO.Path]::GetFullPath((ConvertFrom-DataSafeExtendedPath $Path))
  $parent = [System.IO.Path]::GetDirectoryName($fullPath)
  Ensure-DataSafeDirectory $parent
  $temporaryPath = Join-Path $parent ('.datasafe-' + [guid]::NewGuid().ToString('N') + '.tmp')
  $json = ConvertTo-Json -InputObject $Value -Depth 32
  $encoding = New-Object System.Text.UTF8Encoding($false, $true)
  $bytes = $encoding.GetBytes($json)
  try {
    $stream = New-Object System.IO.FileStream((ConvertTo-DataSafeExtendedPath $temporaryPath), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    # Read back before publishing; never delete the old document as a fallback.
    $verifiedJson = [System.IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $temporaryPath), $encoding)
    if ($verifiedJson -cne $json) { throw 'DataSafe atomic JSON verification failed.' }
    $null = ConvertFrom-Json -InputObject $verifiedJson -ErrorAction Stop
    Assert-DataSafeNoReparsePath $fullPath
    if (-not $CreateOnly -and (Test-DataSafeFile $fullPath)) {
      [System.IO.File]::Replace((ConvertTo-DataSafeExtendedPath $temporaryPath), (ConvertTo-DataSafeExtendedPath $fullPath), [System.Management.Automation.Language.NullString]::Value)
    } else {
      Move-DataSafeSameVolume $temporaryPath $fullPath
    }
  } finally {
    if (Test-DataSafeFile $temporaryPath) { [System.IO.File]::Delete((ConvertTo-DataSafeExtendedPath $temporaryPath)) }
  }
}

function Get-DataSafeSha256([string]$Path) {
  $extendedPath = ConvertTo-DataSafeExtendedPath $Path
  if ([string]::IsNullOrWhiteSpace($extendedPath) -or -not [System.IO.File]::Exists($extendedPath)) {
    throw "DataSafe could not read a file needed for integrity verification: $Path"
  }

  $stream = [System.IO.File]::Open($extendedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  $algorithm = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace("-", "")
  } finally {
    $algorithm.Dispose()
    $stream.Dispose()
  }
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
    $staleHandle = $null
    try {
      $staleHandle = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {
      throw "A DataSafe backup or restore is already running. Wait for it to finish before starting another operation."
    } finally {
      if ($staleHandle) {
        $staleHandle.Dispose()
      }
    }

    try {
      Remove-Item -LiteralPath $LockPath -Force -ErrorAction Stop
    } catch {
      throw "A DataSafe backup or restore is already running. Wait for it to finish before starting another operation."
    }
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
  if (-not (Test-DataSafeFile $Path) -and -not (Test-DataSafeDirectory $Path)) {
    return [int64]0
  }

  $file = Get-DataSafeFileEntry $Path
  if ($null -ne $file) {
    return [int64]$file.Length
  }

  $total = [int64]0
  Get-DataSafeFileEntries -RootPath $Path -IgnoreInaccessible $true | ForEach-Object {
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
    $files = @(Get-DataSafeFileEntries $SnapshotPath | Where-Object {
      [System.IO.Path]::GetFullPath($_.FullName) -notin $metadataPaths
    } | Sort-Object FullName)

    foreach ($file in $files) {
      $relativePath = Get-DataSafeRelativePath $SnapshotPath $file.FullName
      $hash = Get-DataSafeSha256 -Path $file.FullName
      $record = [ordered]@{
        path = $relativePath
        length = [int64]$file.Length
        lastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
        sha256 = $hash
      }
      $writer.WriteLine(($record | ConvertTo-Json -Compress))
      $fileCount += 1
      $totalBytes += [int64]$file.Length
    }
  } finally {
    $writer.Dispose()
  }

  $indexHash = Get-DataSafeSha256 -Path $indexPath
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
  $manifestHash = Get-DataSafeSha256 -Path $manifestPath
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
    $manifestHash = Get-DataSafeSha256 -Path $manifestPath
    $integrityHash = Get-DataSafeSha256 -Path $integrityPath
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

function Get-DataSafeStagingSnapshotPath([string]$SnapshotsRoot) {
  if ([string]::IsNullOrWhiteSpace($SnapshotsRoot)) {
    throw "DataSafe could not create a staging location because the snapshots folder is missing."
  }

  # The operation lock allows one in-progress snapshot, so keep this path short for deep source folders.
  for ($index = 0; $index -lt 1000; $index++) {
    $folderName = if ($index -eq 0) { ".stage" } else { ".stage-$index" }
    $candidate = Join-Path $SnapshotsRoot $folderName
    if (-not (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  throw "DataSafe could not create a temporary backup workspace because earlier incomplete workspaces are still present."
}

function Remove-DataSafeIncompleteSnapshots([string]$SnapshotsRoot) {
  if (-not (Test-Path -LiteralPath $SnapshotsRoot)) {
    return
  }

  Get-ChildItem -LiteralPath $SnapshotsRoot -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\.stage(?:-\d+)?$' -or $_.Name -match '\.incomplete$' -or $_.Name -match '^\.incomplete-' } |
    ForEach-Object {
      $incompleteSnapshot = $_
      try {
        Remove-DataSafeDirectoryTree $incompleteSnapshot.FullName
      } catch {
        Write-Warning "DataSafe could not remove incomplete backup folder '$($incompleteSnapshot.FullName)': $($_.Exception.Message)"
      }
    }
}

function Test-DataSafeIntegrityIndex([string]$SnapshotPath, [string]$RelativePrefix = "") {
  $snapshot = Get-DataSafeCompletedSnapshot $SnapshotPath
  if ($null -eq $snapshot) {
    throw "The selected snapshot is incomplete or its completion record is invalid."
  }

  $indexPath = Join-Path $SnapshotPath $script:DataSafeIntegrityFile
  $expectedIndexHash = ("$(Get-DataSafeProperty $snapshot.Complete 'integrityIndexSha256' '')").ToUpperInvariant()
  $actualIndexHash = Get-DataSafeSha256 -Path $indexPath
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
  foreach ($line in [System.IO.File]::ReadLines((ConvertTo-DataSafeExtendedPath $indexPath))) {
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

    $file = Get-DataSafeFileEntry $fullPath
    if ($null -eq $file) {
      throw "A backed up file is missing: $relativePath"
    }

    if ([int64]$file.Length -ne [int64](Get-DataSafeProperty $entry "length" -1)) {
      throw "A backed up file has changed size: $relativePath"
    }

    $actualHash = Get-DataSafeSha256 -Path $fullPath
    if ($actualHash -ne ("$(Get-DataSafeProperty $entry 'sha256' '')").ToUpperInvariant()) {
      throw "A backed up file failed its checksum: $relativePath"
    }

    $checked += 1
    $checkedBytes += [int64]$file.Length
  }

  if (-not [string]::IsNullOrWhiteSpace($normalizedPrefix) -and $checked -eq 0) {
    throw "No integrity records were found for the selected backup item."
  }

  foreach ($file in @(Get-DataSafeFileEntries $SnapshotPath)) {
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

param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,
  [Parameter(Mandatory = $true)]
  [string]$StatusPath,
  [Parameter(Mandatory = $true)]
  [string]$SnapshotName,
  [Parameter(Mandatory = $true)]
  [string]$JobId,
  [Parameter(Mandatory = $true)]
  [ValidateSet("original", "alternate")]
  [string]$RestoreMode,
  [ValidateSet("plan", "restore")]
  [string]$Action = "restore",
  [string]$TargetPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$safetyModulePath = Join-Path $PSScriptRoot "DataSafe.Safety.ps1"
. $safetyModulePath

function Expand-WindowsPath([string]$Value) {
  [Environment]::ExpandEnvironmentVariables($Value)
}

function Write-RestoreResult($Value) {
  Write-Output "__OB_RESULT__:$(($Value | ConvertTo-Json -Depth 8 -Compress))"
}

function Assert-SafeSnapshotName([string]$Value) {
  if ($Value -notmatch '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$') {
    throw "The selected snapshot name is not valid."
  }
}

function Assert-SafeRestoreTarget([string]$DestinationPath, $Job) {
  if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    throw "DataSafe could not resolve a restore location for this backup item."
  }

  $fullPath = [System.IO.Path]::GetFullPath($DestinationPath)
  $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
  $normalizedFullPath = $fullPath -replace '\\+$', ''
  $normalizedRootPath = $rootPath -replace '\\+$', ''
  if ((Get-DataSafeProperty $Job "type" "folder") -eq "folder" -and $normalizedFullPath -eq $normalizedRootPath) {
    throw "DataSafe will not restore a folder directly onto the root of a drive. Choose another restore folder."
  }
}

function Get-SafeBackupSegment([string]$Value, [string]$Fallback = "Item") {
  $segment = if ([string]::IsNullOrWhiteSpace($Value)) { $Fallback } else { $Value }
  $segment = ($segment -replace '\.[^./\\]+$', '')
  $segment = ($segment -replace '[^a-zA-Z0-9 _-]', '-').Trim()
  if ([string]::IsNullOrWhiteSpace($segment)) {
    return $Fallback
  }

  return $segment
}

function Get-BackupDestinationSegments($Job) {
  $relativeDestination = @(Get-DataSafeProperty $Job "relativeDestination" @())
  if ($relativeDestination.Count -gt 0) {
    $segments = @($relativeDestination | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object {
      Get-SafeBackupSegment "$_"
    })
    if ($segments.Count -gt 0) {
      return @($segments)
    }
  }

  $destinationKey = "$(Get-DataSafeProperty $Job 'backupDestinationKey' '')"
  if (-not [string]::IsNullOrWhiteSpace($destinationKey)) {
    return @(Get-SafeBackupSegment $destinationKey)
  }

  $name = "$(Get-DataSafeProperty $Job 'name' '')"
  $id = "$(Get-DataSafeProperty $Job 'id' '')"
  return @(Get-SafeBackupSegment $name (Get-SafeBackupSegment $id "Item"))
}

function Get-BackupItemRoot($Job, [string]$SnapshotRoot) {
  $destination = $SnapshotRoot
  foreach ($segment in @(Get-BackupDestinationSegments $Job)) {
    $destination = Join-Path $destination $segment
  }

  return $destination
}

function Get-RunningProcessNames($Job) {
  $requested = @(Get-DataSafeProperty $Job "processNames" @() | Where-Object {
    -not [string]::IsNullOrWhiteSpace("$_")
  })
  if ($requested.Count -eq 0) {
    return @()
  }

  $running = @()
  foreach ($processName in $requested) {
    if (@(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0) {
      $running += $processName
    }
  }

  return @($running | Select-Object -Unique)
}

function Get-SourceFile($BackupItemRoot) {
  if ((Test-Path -LiteralPath $BackupItemRoot) -and -not (Get-Item -LiteralPath $BackupItemRoot).PSIsContainer) {
    return Get-Item -LiteralPath $BackupItemRoot
  }

  return Get-ChildItem -LiteralPath $BackupItemRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
    Select-Object -First 1
}

function Get-UniqueAlternateTarget($Job, [string]$ChosenTarget, [string]$Snapshot) {
  if ([string]::IsNullOrWhiteSpace($ChosenTarget)) {
    throw "Choose a restore folder before restoring to another location."
  }

  $sourceLeaf = Split-Path -Leaf (Expand-WindowsPath "$(Get-DataSafeProperty $Job 'path' '')")
  if ([string]::IsNullOrWhiteSpace($sourceLeaf)) {
    $sourceLeaf = Get-SafeBackupSegment "$(Get-DataSafeProperty $Job 'name' 'Restored Item')" "Restored Item"
  }

  $candidate = Join-Path $ChosenTarget "$sourceLeaf - Restored $Snapshot"
  $counter = 2
  while (Test-Path -LiteralPath $candidate) {
    $candidate = Join-Path $ChosenTarget "$sourceLeaf - Restored $Snapshot ($counter)"
    $counter += 1
  }

  return $candidate
}

function Get-RestoreTarget($Job, [string]$Mode, [string]$ChosenTarget, [string]$Snapshot) {
  if ($Mode -eq "alternate") {
    return Get-UniqueAlternateTarget $Job $ChosenTarget $Snapshot
  }

  return Expand-WindowsPath "$(Get-DataSafeProperty $Job 'path' '')"
}

function Invoke-CheckedRobocopy($Arguments, [string]$FailureMessage) {
  $output = @(robocopy @Arguments 2>&1)
  if ($LASTEXITCODE -lt 8) {
    return
  }

  $detail = $output |
    ForEach-Object { "$_".Trim() } |
    Where-Object {
      $_ -and (
        $_ -match 'ERROR' -or
        $_ -match 'Access is denied' -or
        $_ -match 'cannot access the file' -or
        $_ -match 'used by another process' -or
        $_ -match 'not enough space'
      )
    } |
    Select-Object -First 1

  if ($detail) {
    throw "$FailureMessage $detail"
  }

  throw $FailureMessage
}

function Copy-RestoreFolder([string]$SourcePath, [string]$DestinationPath, [switch]$Mirror) {
  New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
  $copyMode = if ($Mirror) { "/MIR" } else { "/E" }
  Invoke-CheckedRobocopy -Arguments @($SourcePath, $DestinationPath, $copyMode, "/FFT", "/R:1", "/W:1", "/XJ") -FailureMessage "Some files could not be copied. Close related apps and try again."
}

function Copy-RestoreFile([string]$SourceFile, [string]$DestinationPath) {
  $parent = Split-Path -Parent $DestinationPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  Copy-Item -LiteralPath $SourceFile -Destination $DestinationPath -Force
}

function Get-FileMap([string]$RootPath, [bool]$IsFolder) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $RootPath)) {
    return $map
  }

  if (-not $IsFolder) {
    $item = Get-Item -LiteralPath $RootPath
    if (-not $item.PSIsContainer) {
      $map[""] = $item
    }
    return $map
  }

  foreach ($file in @(Get-ChildItem -LiteralPath $RootPath -File -Recurse -Force -ErrorAction SilentlyContinue)) {
    $map[(Get-DataSafeRelativePath $RootPath $file.FullName)] = $file
  }
  return $map
}

function Get-RestorePlan(
  [string]$SourcePath,
  [string]$RestoreTarget,
  [bool]$IsFolder,
  [string]$Mode,
  [string]$BaseRoot,
  [string]$SafetyPath
) {
  $sourceMap = Get-FileMap $SourcePath $IsFolder
  $newFiles = 0
  $identicalFiles = 0
  $conflictingFiles = 0
  $newerCurrentFiles = 0
  $sourceBytes = [int64]0

  foreach ($relativePath in $sourceMap.Keys) {
    $sourceFile = $sourceMap[$relativePath]
    $sourceBytes += [int64]$sourceFile.Length
    $targetFilePath = if ($IsFolder) { Join-Path $RestoreTarget $relativePath } else { $RestoreTarget }
    if (-not (Test-Path -LiteralPath $targetFilePath -PathType Leaf)) {
      $newFiles += 1
      continue
    }

    $targetFile = Get-Item -LiteralPath $targetFilePath
    $sameLength = [int64]$sourceFile.Length -eq [int64]$targetFile.Length
    $sameHash = $false
    if ($sameLength) {
      $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
      $targetHash = (Get-FileHash -LiteralPath $targetFile.FullName -Algorithm SHA256).Hash
      $sameHash = $sourceHash -eq $targetHash
    }

    if ($sameHash) {
      $identicalFiles += 1
      continue
    }

    $conflictingFiles += 1
    if ($targetFile.LastWriteTimeUtc -gt $sourceFile.LastWriteTimeUtc) {
      $newerCurrentFiles += 1
    }
  }

  $safetyCopyRequired = $Mode -eq "original" -and (Test-Path -LiteralPath $RestoreTarget)
  $safetyCopyBytes = if ($safetyCopyRequired) { Get-DataSafePathSize $RestoreTarget } else { [int64]0 }
  $freeBytes = Get-DataSafeFreeBytes $BaseRoot
  $safetyReserve = if ($safetyCopyRequired) {
    [Math]::Max([int64]($safetyCopyBytes * 0.10), [int64](256MB))
  } else {
    [int64]0
  }

  return [PSCustomObject]@{
    snapshotName = $SnapshotName
    jobId = $JobId
    jobName = "$(Get-DataSafeProperty $activeJob 'name' 'Backup item')"
    mode = $Mode
    targetPath = $RestoreTarget
    sourceFiles = $sourceMap.Count
    sourceBytes = $sourceBytes
    newFiles = $newFiles
    identicalFiles = $identicalFiles
    conflictingFiles = $conflictingFiles
    newerCurrentFiles = $newerCurrentFiles
    safetyCopyRequired = $safetyCopyRequired
    safetyCopyBytes = $safetyCopyBytes
    safetyCopyPath = if ($safetyCopyRequired) { $SafetyPath } else { $null }
    freeBytes = $freeBytes
    enoughSpaceForSafetyCopy = -not $safetyCopyRequired -or $freeBytes -ge ($safetyCopyBytes + $safetyReserve)
  }
}

function Assert-SafetyCopyCapacity($Plan) {
  if ($Plan.safetyCopyRequired -and -not $Plan.enoughSpaceForSafetyCopy) {
    $neededGb = [Math]::Ceiling(($Plan.safetyCopyBytes + [Math]::Max([int64]($Plan.safetyCopyBytes * 0.10), [int64](256MB))) / 1GB * 10) / 10
    $freeGb = [Math]::Floor($Plan.freeBytes / 1GB * 10) / 10
    throw "DataSafe needs about $neededGb GB of free backup-drive space to protect the current files before restoring, but only $freeGb GB is available."
  }
}

function Assert-CopyMatches([string]$SourcePath, [string]$DestinationPath, [bool]$IsFolder) {
  $sourceMap = Get-FileMap $SourcePath $IsFolder
  foreach ($relativePath in $sourceMap.Keys) {
    $sourceFile = $sourceMap[$relativePath]
    $destinationFilePath = if ($IsFolder) { Join-Path $DestinationPath $relativePath } else { $DestinationPath }
    if (-not (Test-Path -LiteralPath $destinationFilePath -PathType Leaf)) {
      throw "The safety copy is missing $relativePath."
    }

    $destinationFile = Get-Item -LiteralPath $destinationFilePath
    if ([int64]$sourceFile.Length -ne [int64]$destinationFile.Length) {
      throw "The safety copy has a size mismatch for $relativePath."
    }

    $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destinationFile.FullName -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
      throw "The safety copy failed checksum verification for $relativePath."
    }
  }
}

function Update-RestoreJournal([string]$JournalPath, $Journal, [string]$State, [string]$Message) {
  $Journal.state = $State
  $Journal.message = $Message
  $Journal.updatedAt = (Get-Date).ToString("o")
  Write-DataSafeJson $JournalPath $Journal
}

$config = Read-DataSafeJson $ConfigPath
$status = Read-DataSafeJson $StatusPath
Assert-SafeSnapshotName $SnapshotName
$job = @($config.jobs | Where-Object { $_.id -eq $JobId } | Select-Object -First 1)
if ($job.Count -eq 0) {
  throw "The selected backup item could not be found in this app configuration."
}

$activeJob = $job[0]
$runningProcesses = @(Get-RunningProcessNames $activeJob)
if ($runningProcesses.Count -gt 0) {
  $sourceKind = "$(Get-DataSafeProperty $activeJob 'sourceKind' '')"
  $appLabel = if ($sourceKind -eq "browser") { "browser" } elseif ($sourceKind -eq "email") { "email app" } else { "app" }
  throw "Close the related $appLabel before restoring this data: $($runningProcesses -join ', ')."
}

$baseRoot = Get-DataSafeBaseRoot $config
$null = Assert-DataSafeDestinationIdentity -BaseRoot $baseRoot -Config $config -Status $status
$snapshotRoot = Join-Path (Join-Path $baseRoot "snapshots") $SnapshotName
$completedSnapshot = Get-DataSafeCompletedSnapshot $snapshotRoot
if ($null -eq $completedSnapshot) {
  throw "The selected snapshot is incomplete or its completion record is invalid. DataSafe will not restore from it."
}

$backupItemRoot = Get-BackupItemRoot $activeJob $snapshotRoot
if (-not (Test-Path -LiteralPath $backupItemRoot)) {
  throw "That backup item is not available in the selected snapshot. It may have been added after that snapshot was created."
}

$isFolder = "$(Get-DataSafeProperty $activeJob 'type' 'folder')" -eq "folder"
$sourcePath = $backupItemRoot
if (-not $isFolder) {
  $sourceFile = Get-SourceFile $backupItemRoot
  if ($null -eq $sourceFile) {
    throw "The selected snapshot does not contain a restorable file for this backup item."
  }
  $sourcePath = $sourceFile.FullName
}

$sourceFileCount = (Get-FileMap $sourcePath $isFolder).Count
if ($sourceFileCount -gt 0) {
  $integrityPrefix = @(Get-BackupDestinationSegments $activeJob) -join '\'
  $null = Test-DataSafeIntegrityIndex -SnapshotPath $snapshotRoot -RelativePrefix $integrityPrefix
}

$restoreTarget = Get-RestoreTarget $activeJob $RestoreMode $TargetPath $SnapshotName
Assert-SafeRestoreTarget $restoreTarget $activeJob
$restoreJobSegment = Get-SafeBackupSegment "$(Get-DataSafeProperty $activeJob 'name' 'Item')"
$restoreId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 8))-$restoreJobSegment"
$safetyRoot = Join-Path (Join-Path $baseRoot "restore-safety") $restoreId
$safetyOriginal = Join-Path $safetyRoot "original"
$plan = Get-RestorePlan -SourcePath $sourcePath -RestoreTarget $restoreTarget -IsFolder $isFolder -Mode $RestoreMode -BaseRoot $baseRoot -SafetyPath $safetyOriginal

if ($Action -eq "plan") {
  Write-RestoreResult $plan
  Write-Output "Restore plan prepared."
  exit 0
}

Assert-SafetyCopyCapacity $plan
if ($plan.safetyCopyRequired) {
  Test-DataSafeMediaReadWrite $baseRoot
}
$journalPath = Join-Path $safetyRoot "restore-journal.json"
$journal = [PSCustomObject]@{
  formatVersion = 1
  restoreId = $restoreId
  snapshotName = $SnapshotName
  jobId = $JobId
  jobName = "$(Get-DataSafeProperty $activeJob 'name' 'Backup item')"
  mode = $RestoreMode
  targetPath = $restoreTarget
  safetyCopyPath = if ($plan.safetyCopyRequired) { $safetyOriginal } else { $null }
  startedAt = (Get-Date).ToString("o")
  updatedAt = (Get-Date).ToString("o")
  state = "preparing"
  message = "Preparing restore."
  conflictReport = [PSCustomObject]@{
    newFiles = $plan.newFiles
    identicalFiles = $plan.identicalFiles
    conflictingFiles = $plan.conflictingFiles
    newerCurrentFiles = $plan.newerCurrentFiles
  }
}

if ($plan.safetyCopyRequired) {
  New-Item -ItemType Directory -Force -Path $safetyRoot | Out-Null
  Write-DataSafeJson $journalPath $journal
  Update-RestoreJournal $journalPath $journal "copying-safety" "Copying current files to the backup drive before restore."
  if ($isFolder) {
    Copy-RestoreFolder $restoreTarget $safetyOriginal
  } else {
    Copy-RestoreFile $restoreTarget $safetyOriginal
  }
  Assert-CopyMatches $restoreTarget $safetyOriginal $isFolder
  Update-RestoreJournal $journalPath $journal "safety-verified" "The current files were copied and checksum verified."
}

try {
  if ($plan.safetyCopyRequired) {
    Update-RestoreJournal $journalPath $journal "restoring" "Restoring the selected snapshot to the original location."
  }

  if ($isFolder) {
    Copy-RestoreFolder $sourcePath $restoreTarget
  } else {
    Copy-RestoreFile $sourcePath $restoreTarget
  }

  if ($plan.safetyCopyRequired) {
    Update-RestoreJournal $journalPath $journal "completed" "Restore completed. The verified safety copy was retained."
  }
} catch {
  $restoreError = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" }
  if ($RestoreMode -eq "alternate") {
    Remove-Item -LiteralPath $restoreTarget -Recurse -Force -ErrorAction SilentlyContinue
    throw "The restore could not be completed, so DataSafe removed the incomplete alternate restore folder. $restoreError"
  }

  try {
    if ($plan.safetyCopyRequired) {
      Update-RestoreJournal $journalPath $journal "rolling-back" "The restore failed. DataSafe is putting the safety copy back."
      if ($isFolder) {
        Copy-RestoreFolder $safetyOriginal $restoreTarget -Mirror
      } else {
        Copy-RestoreFile $safetyOriginal $restoreTarget
      }
      Update-RestoreJournal $journalPath $journal "rolled-back" "The restore failed, and the original files were restored from the safety copy."
    } else {
      Remove-Item -LiteralPath $restoreTarget -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {
    $rollbackError = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" }
    if (Test-Path -LiteralPath $journalPath) {
      Update-RestoreJournal $journalPath $journal "rollback-failed" "Restore and automatic rollback both need attention."
    }
    throw "The restore failed and DataSafe could not fully put the original files back. Do not make more changes at $restoreTarget. Safety copy: $safetyOriginal. Restore error: $restoreError Rollback error: $rollbackError"
  }

  throw "The restore failed, but DataSafe put the original files back. $restoreError"
}

$result = [PSCustomObject]@{
  snapshotName = $SnapshotName
  jobId = $JobId
  mode = $RestoreMode
  targetPath = $restoreTarget
  safetyCopyPath = if ($plan.safetyCopyRequired) { $safetyOriginal } else { $null }
  journalPath = if ($plan.safetyCopyRequired) { $journalPath } else { $null }
  conflictingFiles = $plan.conflictingFiles
  newerCurrentFiles = $plan.newerCurrentFiles
}
Write-RestoreResult $result
Write-Output "Restore completed to $restoreTarget"

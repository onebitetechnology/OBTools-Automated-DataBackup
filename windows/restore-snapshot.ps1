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
  [string]$TargetPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-Json([string]$Path) {
  Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Expand-WindowsPath([string]$Value) {
  [Environment]::ExpandEnvironmentVariables($Value)
}

function Resolve-Destination($Destination) {
  if ($Destination.mode -eq "label" -and $Destination.label) {
    $volume = Get-Volume | Where-Object { $_.FileSystemLabel -eq $Destination.label } | Select-Object -First 1
    if ($volume -and $volume.DriveLetter) {
      return "$($volume.DriveLetter):\"
    }
  }

  if ($Destination.driveLetter) {
    return "$($Destination.driveLetter.TrimEnd(':')):\"
  }

  throw "No destination drive could be resolved."
}

function Get-BackupItemRoot($Job, [string]$SnapshotRoot) {
  $destination = $null
  if ($null -ne $Job.PSObject.Properties["relativeDestination"] -and $Job.relativeDestination) {
    $segments = @($Job.relativeDestination | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object {
      (("$_") -replace '[^a-zA-Z0-9 _-]', '-').Trim()
    })

    if ($segments.Count -gt 0) {
      $destination = $SnapshotRoot
      foreach ($segment in $segments) {
        $destination = Join-Path $destination $segment
      }
    }
  }

  if (-not $destination) {
    $safeName = ($Job.name -replace '[^a-zA-Z0-9_-]', '-').Trim('-')
    $destination = Join-Path $SnapshotRoot $safeName
  }

  return $destination
}

function Get-RunningProcessNames($Job) {
  if ($null -eq $Job.PSObject.Properties["processNames"] -or -not $Job.processNames) {
    return @()
  }

  $requested = @($Job.processNames | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
  if ($requested.Count -eq 0) {
    return @()
  }

  $running = @()
  foreach ($processName in $requested) {
    $matches = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    if ($matches.Count -gt 0) {
      $running += $processName
    }
  }

  return @($running | Select-Object -Unique)
}

function Get-RestoreTarget($Job, [string]$Mode, [string]$ChosenTarget) {
  if ($Mode -eq "alternate") {
    if ([string]::IsNullOrWhiteSpace($ChosenTarget)) {
      throw "Choose a restore folder before restoring to another location."
    }

    $leafName = Split-Path -Leaf (Expand-WindowsPath $Job.path)
    if ($Job.type -eq "folder") {
      return Join-Path $ChosenTarget $leafName
    }

    return Join-Path $ChosenTarget $leafName
  }

  return Expand-WindowsPath $Job.path
}

function Copy-RestoreFolder([string]$SourcePath, [string]$DestinationPath) {
  New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
  $robocopyOutput = @(robocopy $SourcePath $DestinationPath /E /FFT /R:1 /W:1 /XJ 2>&1)
  if ($LASTEXITCODE -ge 8) {
    $detail = $robocopyOutput |
      ForEach-Object { "$_".Trim() } |
      Where-Object { $_ -and ($_ -match 'ERROR' -or $_ -match 'Access is denied' -or $_ -match 'cannot access the file' -or $_ -match 'used by another process') } |
      Select-Object -First 1

    if ($detail) {
      throw "Some files could not be restored. $detail"
    }

    throw "Some files could not be restored. Close any related apps and try again."
  }
}

function Copy-RestoreFile([string]$SourceRoot, [string]$DestinationPath) {
  $sourceFile = $null

  if ((Test-Path -LiteralPath $SourceRoot) -and -not (Get-Item -LiteralPath $SourceRoot).PSIsContainer) {
    $sourceFile = Get-Item -LiteralPath $SourceRoot
  } else {
    $sourceFile = Get-ChildItem -Path $SourceRoot -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  }

  if ($null -eq $sourceFile) {
    throw "The selected snapshot does not contain a restorable file for this backup item."
  }

  $parent = Split-Path -Parent $DestinationPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  Copy-Item -LiteralPath $sourceFile.FullName -Destination $DestinationPath -Force
}

$config = Read-Json $ConfigPath
$job = @($config.jobs | Where-Object { $_.id -eq $JobId } | Select-Object -First 1)
if ($job.Count -eq 0) {
  throw "The selected backup item could not be found in this app configuration."
}

$activeJob = $job[0]
$runningProcesses = @(Get-RunningProcessNames $activeJob)
if ($runningProcesses.Count -gt 0) {
  $appLabel = if ($activeJob.sourceKind -eq "browser") { "browser" } elseif ($activeJob.sourceKind -eq "email") { "email app" } else { "app" }
  throw "Close the related $appLabel before restoring this data: $($runningProcesses -join ', ')."
}

$driveRoot = Resolve-Destination $config.destination
$baseRoot = if ([string]::IsNullOrWhiteSpace($config.destination.baseFolder)) { $driveRoot } else { Join-Path $driveRoot $config.destination.baseFolder }
$snapshotRoot = Join-Path (Join-Path $baseRoot "snapshots") $SnapshotName

if (-not (Test-Path -LiteralPath $snapshotRoot)) {
  throw "The selected snapshot could not be found on the backup drive."
}

$backupItemRoot = Get-BackupItemRoot $activeJob $snapshotRoot
if (-not (Test-Path -LiteralPath $backupItemRoot)) {
  throw "That backup item is not available in the selected snapshot. It may have been added after that snapshot was created."
}

$restoreTarget = Get-RestoreTarget $activeJob $RestoreMode $TargetPath

if ($activeJob.type -eq "folder") {
  Copy-RestoreFolder $backupItemRoot $restoreTarget
} else {
  Copy-RestoreFile $backupItemRoot $restoreTarget
}

Write-Output "Restore completed to $restoreTarget"

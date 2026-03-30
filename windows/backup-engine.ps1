param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,
  [Parameter(Mandatory = $true)]
  [string]$StatusPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-Json([string]$Path) {
  Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Write-Json([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 8
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Get-RetentionPolicy($Config) {
  $legacyCount = 0
  if ($null -ne $Config.PSObject.Properties["retentionCount"]) {
    $legacyCount = [int]$Config.retentionCount
  }

  $retention = $null
  if ($null -ne $Config.PSObject.Properties["retention"]) {
    $retention = $Config.retention
  }
  $days = if ($retention -and $null -ne $retention.PSObject.Properties["days"]) { [int]$retention.days } elseif ($legacyCount -gt 0) { $legacyCount } else { 3 }
  $months = if ($retention -and $null -ne $retention.PSObject.Properties["months"]) { [int]$retention.months } else { 0 }
  $years = if ($retention -and $null -ne $retention.PSObject.Properties["years"]) { [int]$retention.years } else { 0 }

  $policy = [ordered]@{
    days = [Math]::Max($days, 0)
    months = [Math]::Max($months, 0)
    years = [Math]::Max($years, 0)
  }

  if (($policy.days + $policy.months + $policy.years) -le 0) {
    $policy.days = 1
  }

  return [PSCustomObject]$policy
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

function Expand-WindowsPath([string]$Value) {
  [Environment]::ExpandEnvironmentVariables($Value)
}

function Write-ProgressMarker(
  [string]$Phase,
  [string]$JobName,
  [int]$Step,
  [int]$TotalSteps,
  [string]$Detail
) {
  $percent = if ($TotalSteps -le 0) { 0 } else { [Math]::Min([Math]::Round(($Step / $TotalSteps) * 100), 100) }
  if ($Phase -ne "complete" -and $percent -ge 100) {
    $percent = 96
  }
  $payload = @{
    phase = $Phase
    jobName = $JobName
    step = $Step
    totalSteps = $TotalSteps
    percent = [int]$percent
    detail = $Detail
  } | ConvertTo-Json -Compress

  Write-Output "__OB_PROGRESS__:$payload"
}

function Get-RobocopyExcludedDirectories([string]$Source) {
  $normalized = $Source.ToLowerInvariant()
  $isChromiumUserData =
    $normalized -like "*\google\chrome\user data" -or
    $normalized -like "*\microsoft\edge\user data" -or
    $normalized -like "*\bravesoftware\brave-browser\user data"

  if (-not $isChromiumUserData) {
    return @("System Volume Information", '$RECYCLE.BIN')
  }

  $excluded = New-Object System.Collections.Generic.List[string]
  $excluded.Add("System Volume Information")
  $excluded.Add('$RECYCLE.BIN')

  $topLevelCandidates = @(
    "Crashpad",
    "GrShaderCache",
    "GraphiteDawnCache",
    "ShaderCache",
    "BrowserMetrics",
    "Component CRX Cache"
  )

  foreach ($name in $topLevelCandidates) {
    $candidatePath = Join-Path $Source $name
    if (Test-Path -LiteralPath $candidatePath) {
      $excluded.Add($candidatePath)
    }
  }

  $profileDirs = @(Get-ChildItem -Path $Source -Directory -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq "Default" -or
    $_.Name -like "Profile *" -or
    $_.Name -eq "Guest Profile" -or
    $_.Name -eq "System Profile"
  })

  $profileCacheCandidates = @(
    "Cache",
    "Code Cache",
    "GPUCache",
    "DawnCache",
    "Media Cache",
    "Blob Storage",
    "Service Worker\\CacheStorage",
    "Service Worker\\ScriptCache"
  )

  foreach ($profileDir in $profileDirs) {
    foreach ($relativePath in $profileCacheCandidates) {
      $candidatePath = Join-Path $profileDir.FullName $relativePath
      if (Test-Path -LiteralPath $candidatePath) {
        $excluded.Add($candidatePath)
      }
    }
  }

  return @($excluded)
}

function Parse-SnapshotTimestamp([string]$SnapshotName) {
  try {
    return [datetime]::ParseExact($SnapshotName, "yyyy-MM-dd_HH-mm-ss", [System.Globalization.CultureInfo]::InvariantCulture)
  } catch {
    return $null
  }
}

function Get-SnapshotEntries([string]$SnapshotsRoot) {
  if (-not (Test-Path -LiteralPath $SnapshotsRoot)) {
    return @()
  }

  $entries = @(Get-ChildItem -Path $SnapshotsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $timestamp = Parse-SnapshotTimestamp $_.Name
    if ($null -eq $timestamp) {
      return
    }

    [PSCustomObject]@{
      Name = $_.Name
      FullName = $_.FullName
      Timestamp = $timestamp
    }
  })

  return @($entries | Sort-Object Timestamp -Descending)
}

function Select-RetainedSnapshots($Snapshots, $RetentionPolicy) {
  $selected = New-Object "System.Collections.Generic.HashSet[string]"

  if ($RetentionPolicy.days -gt 0) {
    $dailyGroups = @($Snapshots | Group-Object { $_.Timestamp.ToString("yyyy-MM-dd") } | Sort-Object Name -Descending)
    foreach ($group in @($dailyGroups | Select-Object -First $RetentionPolicy.days)) {
      $candidate = @($group.Group | Sort-Object Timestamp -Descending | Select-Object -First 1)
      if ($candidate.Count -gt 0) {
        [void]$selected.Add($candidate[0].Name)
      }
    }
  }

  if ($RetentionPolicy.months -gt 0) {
    $monthlyGroups = @($Snapshots | Group-Object { $_.Timestamp.ToString("yyyy-MM") } | Sort-Object Name -Descending)
    foreach ($group in @($monthlyGroups | Select-Object -First $RetentionPolicy.months)) {
      $candidate = @($group.Group | Sort-Object Timestamp -Descending | Select-Object -First 1)
      if ($candidate.Count -gt 0) {
        [void]$selected.Add($candidate[0].Name)
      }
    }
  }

  if ($RetentionPolicy.years -gt 0) {
    $yearlyGroups = @($Snapshots | Group-Object { $_.Timestamp.ToString("yyyy") } | Sort-Object Name -Descending)
    foreach ($group in @($yearlyGroups | Select-Object -First $RetentionPolicy.years)) {
      $candidate = @($group.Group | Sort-Object Timestamp | Select-Object -First 1)
      if ($candidate.Count -gt 0) {
        [void]$selected.Add($candidate[0].Name)
      }
    }
  }

  return @($Snapshots | Where-Object { $selected.Contains($_.Name) })
}

function Prune-Snapshots([string]$SnapshotsRoot, $RetentionPolicy) {
  $allSnapshots = @(Get-SnapshotEntries $SnapshotsRoot)
  $retainedSnapshots = @(Select-RetainedSnapshots $allSnapshots $RetentionPolicy)
  $retainedNames = New-Object "System.Collections.Generic.HashSet[string]"

  foreach ($snapshot in $retainedSnapshots) {
    [void]$retainedNames.Add($snapshot.Name)
  }

  $snapshotsToRemove = @($allSnapshots | Where-Object { -not $retainedNames.Contains($_.Name) })
  foreach ($snapshot in $snapshotsToRemove) {
    Remove-Item -LiteralPath $snapshot.FullName -Recurse -Force
  }

  return @($retainedSnapshots | Sort-Object Timestamp -Descending)
}

function Copy-BackupItem($Job, [string]$RootPath) {
  $source = Expand-WindowsPath $Job.path
  if (-not (Test-Path -LiteralPath $source)) {
    throw "Backup source missing: $source"
  }

  $destination = $null
  if ($null -ne $Job.PSObject.Properties["relativeDestination"] -and $Job.relativeDestination) {
    $segments = @($Job.relativeDestination | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object {
      (("$_") -replace '[^a-zA-Z0-9 _-]', '-').Trim()
    })

    if ($segments.Count -gt 0) {
      $destination = $RootPath
      foreach ($segment in $segments) {
        $destination = Join-Path $destination $segment
      }
    }
  }

  if (-not $destination) {
    $safeName = ($Job.name -replace '[^a-zA-Z0-9_-]', '-').Trim('-')
    $destination = Join-Path $RootPath $safeName
  }

  if ($Job.type -eq "folder") {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $robocopyArgs = @($source, $destination, "/MIR", "/FFT", "/R:1", "/W:1", "/XJ")
    $excludedDirectories = Get-RobocopyExcludedDirectories $source
    if ($excludedDirectories.Count -gt 0) {
      $robocopyArgs += "/XD"
      $robocopyArgs += $excludedDirectories
    }
    $robocopyOutput = @(robocopy @robocopyArgs 2>&1)
    if ($LASTEXITCODE -ge 8) {
      if ($robocopyOutput -match 'ERROR 112' -or $robocopyOutput -match 'not enough space on the disk') {
        throw "The backup drive ran out of space while copying files from $source. Free up space or use a larger drive, then try again."
      }

      $detail = $robocopyOutput |
        ForEach-Object { "$_".Trim() } |
        Where-Object {
          $_ -and (
            $_ -match 'ERROR' -or
            $_ -match 'Access is denied' -or
            $_ -match 'cannot access the file' -or
            $_ -match 'used by another process' -or
            $_ -match 'mismatch'
          )
        } |
        Select-Object -First 1

      if ($detail) {
        throw "Some files in $source could not be copied. $detail"
      }

      throw "Some files in $source could not be copied. Close open files or cloud-sync apps, then try the backup again."
    }
    return
  }

  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  Copy-Item -LiteralPath $source -Destination $destination -Force
}

$config = Read-Json $ConfigPath
$status = Read-Json $StatusPath

$driveRoot = Resolve-Destination $config.destination
if (-not (Test-Path -LiteralPath $driveRoot)) {
  throw "Destination drive is not available: $driveRoot"
}

$baseRoot = if ([string]::IsNullOrWhiteSpace($config.destination.baseFolder)) {
  $driveRoot
} else {
  Join-Path $driveRoot $config.destination.baseFolder
}
$currentRoot = Join-Path $baseRoot "current"
$snapshotsRoot = Join-Path $baseRoot "snapshots"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$snapshotPath = Join-Path $snapshotsRoot $timestamp
$retentionPolicy = Get-RetentionPolicy $config
$enabledJobs = @($config.jobs | Where-Object { $_.enabled })
$totalSteps = [Math]::Max(($enabledJobs.Count * 2) + 1, 1)

New-Item -ItemType Directory -Force -Path $currentRoot | Out-Null
New-Item -ItemType Directory -Force -Path $snapshotsRoot | Out-Null

Write-ProgressMarker -Phase "preparing" -JobName "" -Step 1 -TotalSteps $totalSteps -Detail "Preparing the backup destination."
[void](Prune-Snapshots $snapshotsRoot $retentionPolicy)

for ($index = 0; $index -lt $enabledJobs.Count; $index++) {
  $job = $enabledJobs[$index]
  $currentStep = 2 + ($index * 2)

  Write-ProgressMarker -Phase "copying-current" -JobName $job.name -Step $currentStep -TotalSteps $totalSteps -Detail "Copying to the current backup set."
  Copy-BackupItem $job $currentRoot

  Write-ProgressMarker -Phase "copying-snapshot" -JobName $job.name -Step ($currentStep + 1) -TotalSteps $totalSteps -Detail "Creating the dated snapshot copy."
  Copy-BackupItem $job $snapshotPath
}

$remainingSnapshots = @(Prune-Snapshots $snapshotsRoot $retentionPolicy)
$remaining = @($remainingSnapshots | Select-Object -ExpandProperty Name)
$status.lastBackupAt = (Get-Date).ToString("o")
$status.lastBackupResult = "success"
$status.lastBackupMessage = "Backup completed to $baseRoot"
$status.destinationStatus = "Connected"
$status.recentSnapshots = @($remaining)

Write-Json $StatusPath $status
Write-ProgressMarker -Phase "complete" -JobName "" -Step $totalSteps -TotalSteps $totalSteps -Detail "Backup completed successfully."
Write-Output "Backup completed successfully."

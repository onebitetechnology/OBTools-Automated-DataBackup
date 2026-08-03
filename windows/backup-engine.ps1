param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,
  [Parameter(Mandatory = $true)]
  [string]$StatusPath,
  [switch]$AllowNewDestination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$safetyModulePath = Join-Path $PSScriptRoot "DataSafe.Safety.ps1"
. $safetyModulePath

function Read-Json([string]$Path) {
  Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Write-Json([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 8
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function New-DefaultStatus {
  [PSCustomObject]@{
    lastBackupAt = $null
    lastBackupResult = $null
    lastBackupMessage = "No backups have been run yet."
    destinationStatus = "Unknown"
    recentSnapshots = @()
    integrity = [PSCustomObject]@{
      checkedAt = $null
      level = "info"
      summary = "Backup integrity has not been verified yet."
      snapshotName = $null
      filesChecked = 0
    }
    cloud = [PSCustomObject]@{
      checkedAt = $null
      summary = "Cloud check has not been run yet."
      level = "info"
      recommendations = @()
    }
    automation = [PSCustomObject]@{
      installedAt = $null
      message = "Windows automation has not been installed yet."
    }
    licensing = [PSCustomObject]@{
      enabled = $false
      state = "disabled"
      message = "Licensing is disabled while backup testing continues."
      renewalDate = $null
      lastCheckedAt = $null
    }
  }
}

function Get-SupportContact($Config) {
  $support = $null
  if ($Config -and $null -ne $Config.PSObject.Properties["support"]) {
    $support = $Config.support
  }
  $businessName = if ($Config -and $null -ne $Config.PSObject.Properties["businessName"]) { [string]$Config.businessName } else { "One Bite Technology" }
  return [PSCustomObject]@{
    name = if ($support -and $support.name) { [string]$support.name } elseif ($businessName) { $businessName } else { "One Bite Technology" }
    phone = if ($support -and $support.phone) { [string]$support.phone } else { "" }
    email = if ($support -and $support.email) { [string]$support.email } else { "jeff@onebitetechnology.ca" }
    contactUrl = if ($support -and $support.contactUrl) { [string]$support.contactUrl } else { "" }
  }
}

function Get-ContactTarget($Support) {
  if ($Support.contactUrl) {
    return $Support.contactUrl
  }
  if ($Support.email) {
    return "mailto:$($Support.email)"
  }
  return $null
}

function Get-ContactLine($Support) {
  $parts = New-Object System.Collections.Generic.List[string]
  if ($Support.name) {
    $parts.Add($Support.name)
  }
  if ($Support.phone) {
    $parts.Add($Support.phone)
  }
  if ($Support.email) {
    $parts.Add($Support.email)
  }

  if ($parts.Count -eq 0) {
    return ""
  }

  return "Contact: $($parts -join ' | ')"
}

function Show-BackupNotification(
  [string]$Title,
  [string]$Message,
  [ValidateSet("Info", "Warning", "Error")]
  [string]$Level,
  [string]$ClickTarget
) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Visible = $true
    $notify.Icon = switch ($Level) {
      "Error" { [System.Drawing.SystemIcons]::Error }
      "Warning" { [System.Drawing.SystemIcons]::Warning }
      default { [System.Drawing.SystemIcons]::Information }
    }
    $notify.BalloonTipTitle = $Title
    $notify.BalloonTipText = $Message

    $subscription = $null
    if ($ClickTarget) {
      $subscription = Register-ObjectEvent -InputObject $notify -EventName BalloonTipClicked -Action {
        Start-Process $using:ClickTarget | Out-Null
      }
    }

    $notify.ShowBalloonTip(15000)
    Start-Sleep -Seconds 16

    if ($subscription) {
      Unregister-Event -SourceIdentifier $subscription.Name -ErrorAction SilentlyContinue
      Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
    }

    $notify.Dispose()
    return
  } catch {
    # Fall back to a traditional popup if the tray balloon cannot be shown.
  }

  $shell = New-Object -ComObject WScript.Shell
  $iconCode = if ($Level -eq "Error") { 16 } elseif ($Level -eq "Warning") { 48 } else { 64 }
  $shell.Popup($Message, 20, $Title, $iconCode) | Out-Null
}

function Write-FailedBackupStatus([string]$Path, [string]$Message) {
  try {
    $status = Read-Json $Path
  } catch {
    $status = New-DefaultStatus
  }

  if ($null -eq $status.PSObject.Properties["lastBackupAttemptAt"]) {
    $status | Add-Member -NotePropertyName "lastBackupAttemptAt" -NotePropertyValue $null
  }
  $status.lastBackupAttemptAt = (Get-Date).ToString("o")
  $status.lastBackupResult = "error"
  $status.lastBackupMessage = $Message
  if ($Message -match "Destination drive is not available" -or $Message -match "No destination drive could be resolved") {
    $status.destinationStatus = "Drive Not Connected"
  } elseif ($Message -match "identity marker" -or $Message -match "does not match this DataSafe installation") {
    $status.destinationStatus = "Destination Not Recognized"
  } else {
    $status.destinationStatus = "Issue Detected"
  }

  try {
    Write-Json $Path $status
  } catch {
    # Preserve the original backup error; the app will still show it from stderr/stdout.
  }
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

function Test-TruthyJobProperty($Job, [string]$PropertyName) {
  if ($null -eq $Job.PSObject.Properties[$PropertyName]) {
    return $false
  }

  $value = $Job.$PropertyName
  if ($value -is [bool]) {
    return $value
  }

  return "$value".ToLowerInvariant() -eq "true"
}

function Resolve-KnownFolderPath($Job, [string]$FallbackPath) {
  if ($null -eq $Job.PSObject.Properties["windowsKnownFolder"] -or [string]::IsNullOrWhiteSpace("$($Job.windowsKnownFolder)")) {
    return $FallbackPath
  }

  $knownFolder = "$($Job.windowsKnownFolder)"
  try {
    $resolvedPath = switch ($knownFolder) {
      "Desktop" { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::DesktopDirectory) }
      "MyDocuments" { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments) }
      "MyPictures" { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyPictures) }
      default { "" }
    }

    # Windows can report an absent Public Desktop as the known desktop folder.
    if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path -LiteralPath $resolvedPath)) {
      return $resolvedPath
    }

    return $FallbackPath
  } catch {
    return $FallbackPath
  }
}

function Resolve-JobSourcePath($Job) {
  $fallbackPath = Expand-WindowsPath $Job.path
  $resolvedPath = Resolve-KnownFolderPath $Job $fallbackPath
  if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
    return $fallbackPath
  }

  return $resolvedPath
}

function Resolve-PublicFolderPath([string]$FolderName) {
  $publicRoot = [Environment]::GetEnvironmentVariable("PUBLIC")
  if ([string]::IsNullOrWhiteSpace($publicRoot)) {
    $systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { "C:" } else { $env:SystemDrive }
    $driveRoot = if ($systemDrive.EndsWith("\")) { $systemDrive } else { "$systemDrive\" }
    $publicRoot = Join-Path $driveRoot "Users\Public"
  }

  return Join-Path $publicRoot $FolderName
}

function Get-AdditionalBackupSources($Job, [string]$PrimarySource) {
  $sources = New-Object System.Collections.Generic.List[string]
  $publicFolderName = ""
  if ($null -ne $Job.PSObject.Properties["includePublicFolder"] -and -not [string]::IsNullOrWhiteSpace("$($Job.includePublicFolder)")) {
    $publicFolderName = "$($Job.includePublicFolder)"
  } elseif (Test-TruthyJobProperty $Job "includePublicDesktop") {
    $publicFolderName = "Desktop"
  }

  if (-not [string]::IsNullOrWhiteSpace($publicFolderName)) {
    $publicPath = Resolve-PublicFolderPath $publicFolderName
    $primaryKey = ($PrimarySource -replace '\\+$', '').ToLowerInvariant()
    $publicKey = ($publicPath -replace '\\+$', '').ToLowerInvariant()
    if ($publicKey -ne $primaryKey -and (Test-Path -LiteralPath $publicPath)) {
      $sources.Add($publicPath)
    }
  }

  return @($sources)
}

function Invoke-CheckedRobocopy($RobocopyArgs, [string]$Source) {
  $robocopyOutput = @(robocopy @RobocopyArgs 2>&1)
  if ($LASTEXITCODE -lt 8) {
    return
  }

  if ($robocopyOutput -match 'ERROR 112' -or $robocopyOutput -match 'not enough space on the disk') {
    throw "The backup drive ran out of space while copying files from $Source. Free up space or use a larger drive, then try again."
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
    throw "Some files in $Source could not be copied. $detail"
  }

  throw "Some files in $Source could not be copied. Close open files or cloud-sync apps, then try the backup again."
}

function Copy-FolderToPath([string]$Source, [string]$Destination, [bool]$Mirror) {
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  $copyMode = if ($Mirror) { "/MIR" } else { "/E" }
  $robocopyArgs = @($Source, $Destination, $copyMode, "/FFT", "/R:1", "/W:1", "/XJ")
  $excludedDirectories = Get-RobocopyExcludedDirectories $Source
  if ($excludedDirectories.Count -gt 0) {
    $robocopyArgs += "/XD"
    $robocopyArgs += $excludedDirectories
  }

  Invoke-CheckedRobocopy $robocopyArgs $Source
}

function Copy-MergedFolderSources($Sources, [string]$Destination) {
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($source in @($Sources)) {
    Copy-FolderToPath $source $Destination $false
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
  if ($null -ne $Job.PSObject.Properties["relativeDestination"] -and $Job.relativeDestination) {
    $segments = @($Job.relativeDestination | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object {
      Get-SafeBackupSegment "$_"
    })

    if ($segments.Count -gt 0) {
      return @($segments)
    }
  }

  if ($null -ne $Job.PSObject.Properties["backupDestinationKey"] -and -not [string]::IsNullOrWhiteSpace($Job.backupDestinationKey)) {
    return @(Get-SafeBackupSegment "$($Job.backupDestinationKey)")
  }

  $name = if ($null -ne $Job.PSObject.Properties["name"]) { "$($Job.name)" } else { "" }
  $id = if ($null -ne $Job.PSObject.Properties["id"]) { "$($Job.id)" } else { "" }
  return @(Get-SafeBackupSegment $name (Get-SafeBackupSegment $id "Item"))
}

function Get-BackupItemTargetPath($Job, [string]$RootPath) {
  $destination = $RootPath
  foreach ($segment in @(Get-BackupDestinationSegments $Job)) {
    $destination = Join-Path $destination $segment
  }

  return $destination
}

function Test-BackupJobPlan($Jobs) {
  $sourceOwners = @{}
  $destinationOwners = @{}
  if (@($Jobs).Count -eq 0) {
    throw "Turn on at least one backup item before running a backup."
  }

  foreach ($job in @($Jobs)) {
    $name = if ($job.name) { "$($job.name)" } else { "Unnamed backup item" }
    $rawPath = if ($null -ne $job.PSObject.Properties["path"]) { "$($job.path)" } else { "" }
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
      throw "$name needs a Windows path before it can be backed up."
    }

    $source = Resolve-JobSourcePath $job
    $sourceKey = ($source -replace '\\+$', '').ToLowerInvariant()
    if ($sourceOwners.ContainsKey($sourceKey)) {
      throw "$name points to the same source as $($sourceOwners[$sourceKey]). Remove the duplicate or choose a different path."
    }
    $sourceOwners[$sourceKey] = $name

    $destinationKey = (@(Get-BackupDestinationSegments $job) -join '\').ToLowerInvariant()
    if ($destinationOwners.ContainsKey($destinationKey)) {
      throw "$name would write to the same backup folder as $($destinationOwners[$destinationKey]). Rename one item or remove the duplicate before running backup."
    }
    $destinationOwners[$destinationKey] = $name
  }
}

function Parse-SnapshotTimestamp([string]$SnapshotName) {
  try {
    return [datetime]::ParseExact($SnapshotName, "yyyy-MM-dd_HH-mm-ss", [System.Globalization.CultureInfo]::InvariantCulture)
  } catch {
    return $null
  }
}

function Get-SnapshotEntries([string]$SnapshotsRoot) {
  return @(Get-DataSafeCompletedSnapshots $SnapshotsRoot)
}

function Select-RetainedSnapshots($Snapshots, $RetentionPolicy) {
  $selected = New-Object "System.Collections.Generic.HashSet[string]"
  $newestSnapshot = @($Snapshots | Sort-Object Timestamp -Descending | Select-Object -First 1)
  if ($newestSnapshot.Count -gt 0) {
    [void]$selected.Add($newestSnapshot[0].Name)
  }

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
  $source = Resolve-JobSourcePath $Job
  if (-not (Test-Path -LiteralPath $source)) {
    throw "Backup source missing: $source"
  }

  $destination = Get-BackupItemTargetPath $Job $RootPath

  if ($Job.type -eq "folder") {
    $additionalSources = @(Get-AdditionalBackupSources $Job $source)
    if ($additionalSources.Count -gt 0) {
      Copy-MergedFolderSources -Sources @($additionalSources + $source) -Destination $destination
    } else {
      Copy-FolderToPath $source $destination $true
    }
    return
  }

  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Get-BackupPlanSize($Jobs) {
  $total = [int64]0
  foreach ($job in @($Jobs)) {
    $source = Resolve-JobSourcePath $job
    if (-not (Test-Path -LiteralPath $source)) {
      throw "Backup source missing: $source"
    }

    $total += Get-DataSafePathSize $source
    foreach ($additionalSource in @(Get-AdditionalBackupSources $job $source)) {
      $total += Get-DataSafePathSize $additionalSource
    }
  }

  return $total
}

$lockPath = "$StatusPath.lock"
$lockHandle = $null
$configForNotification = $null
$stagingSnapshotPath = $null

try {
  $lockHandle = Acquire-DataSafeOperationLock $lockPath
  $config = Read-Json $ConfigPath
  $configForNotification = $config
  $status = Read-Json $StatusPath

  $baseRoot = Get-DataSafeBaseRoot $config
  $snapshotsRoot = Join-Path $baseRoot "snapshots"
  $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
  $snapshotPath = Join-Path $snapshotsRoot $timestamp
  $stagingSnapshotPath = Get-DataSafeStagingSnapshotPath $snapshotsRoot
  $retentionPolicy = Get-RetentionPolicy $config
  $enabledJobs = @($config.jobs | Where-Object { $_.enabled })
  $totalSteps = [Math]::Max($enabledJobs.Count + 4, 4)
  Test-BackupJobPlan $enabledJobs

  $existingMarker = Assert-DataSafeDestinationIdentity -BaseRoot $baseRoot -Config $config -Status $status -AllowNewDestination:$AllowNewDestination
  $null = Ensure-DataSafeDestinationMarker -BaseRoot $baseRoot -Config $config -ExistingMarker $existingMarker
  Test-DataSafeMediaReadWrite $baseRoot
  New-Item -ItemType Directory -Force -Path $snapshotsRoot | Out-Null
  Remove-DataSafeIncompleteSnapshots $snapshotsRoot
  $estimatedBytes = Get-BackupPlanSize $enabledJobs
  $capacity = Assert-DataSafeCapacity -BaseRoot $baseRoot -EstimatedBytes $estimatedBytes
  if (Test-Path -LiteralPath $snapshotPath) {
    throw "A completed backup already exists for timestamp $timestamp. Wait one minute and try again."
  }

  New-Item -ItemType Directory -Path $stagingSnapshotPath | Out-Null
  Write-ProgressMarker -Phase "preparing" -JobName "" -Step 1 -TotalSteps $totalSteps -Detail "The backup drive passed identity, space, and read/write checks."

  for ($index = 0; $index -lt $enabledJobs.Count; $index++) {
    $job = $enabledJobs[$index]
    $currentStep = 2 + $index
    Write-ProgressMarker -Phase "copying-snapshot" -JobName $job.name -Step $currentStep -TotalSteps $totalSteps -Detail "Copying this item into a protected staging snapshot."
    Copy-BackupItem $job $stagingSnapshotPath
  }

  $verificationStep = 2 + $enabledJobs.Count
  Write-ProgressMarker -Phase "verifying-snapshot" -JobName "" -Step $verificationStep -TotalSteps $totalSteps -Detail "Reading copied files back and creating SHA-256 checksums."
  $integrity = New-DataSafeIntegrityIndex $stagingSnapshotPath
  $null = Write-DataSafeSnapshotMetadata -SnapshotPath $stagingSnapshotPath -SnapshotName $timestamp -Config $config -Jobs $enabledJobs -Integrity $integrity

  Write-ProgressMarker -Phase "committing-snapshot" -JobName "" -Step ($verificationStep + 1) -TotalSteps $totalSteps -Detail "Publishing the completed snapshot."
  Move-Item -LiteralPath $stagingSnapshotPath -Destination $snapshotPath
  $stagingSnapshotPath = $null

  $retentionWarning = $null
  try {
    $remainingSnapshots = @(Prune-Snapshots $snapshotsRoot $retentionPolicy)
  } catch {
    $retentionWarning = "The new snapshot is complete, but older snapshots could not be pruned. Review free space before the next backup."
    $remainingSnapshots = @(Get-SnapshotEntries $snapshotsRoot)
  }
  $remaining = @($remainingSnapshots | Select-Object -ExpandProperty Name)
  $status.lastBackupAt = (Get-Date).ToString("o")
  if ($null -ne $status.PSObject.Properties["lastBackupAttemptAt"]) {
    $status.lastBackupAttemptAt = $status.lastBackupAt
  }
  $status.lastBackupResult = if ($retentionWarning) { "warning" } else { "success" }
  $status.lastBackupMessage = if ($retentionWarning) { $retentionWarning } else { "Backup completed and verified to $baseRoot" }
  $status.destinationStatus = "Connected"
  $status.recentSnapshots = @($remaining)
  $integrityStatus = [PSCustomObject]@{
    checkedAt = $status.lastBackupAt
    level = "success"
    summary = "$($integrity.fileCount) copied files were read back and verified with SHA-256 checksums."
    snapshotName = $timestamp
    filesChecked = [int]$integrity.fileCount
  }
  if ($null -eq $status.PSObject.Properties["integrity"]) {
    $status | Add-Member -NotePropertyName "integrity" -NotePropertyValue $integrityStatus
  } else {
    $status.integrity = $integrityStatus
  }

  try {
    Write-Json $StatusPath $status
  } catch {
    throw "The backup files were copied, but DataSafe could not update its backup status. Close DataSafe completely, reopen it, and run the backup again. If this keeps happening, contact One Bite Technology."
  }
  Write-ProgressMarker -Phase "complete" -JobName "" -Step $totalSteps -TotalSteps $totalSteps -Detail "Backup completed successfully."
  $notificationLevel = if ($retentionWarning) { "Warning" } else { "Info" }
  $notificationTitle = if ($retentionWarning) { "DataSafe Backup Completed With a Warning" } else { "DataSafe Backup Complete" }
  Show-BackupNotification -Title $notificationTitle -Message $status.lastBackupMessage -Level $notificationLevel -ClickTarget $null
  Write-Output $status.lastBackupMessage
} catch {
  $message = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" }
  Write-FailedBackupStatus $StatusPath $message

  $notificationConfig = $configForNotification
  if (-not $notificationConfig) {
    try {
      $notificationConfig = Read-Json $ConfigPath
    } catch {
      $notificationConfig = $null
    }
  }

  $support = Get-SupportContact $notificationConfig
  $contactLine = Get-ContactLine $support
  $contactTarget = Get-ContactTarget $support
  $notificationMessage = "DataSafe could not complete the backup. $message"
  if ($contactLine) {
    $notificationMessage = "$notificationMessage`n$contactLine"
  }

  Show-BackupNotification -Title "DataSafe Backup Failed" -Message $notificationMessage -Level "Error" -ClickTarget $contactTarget
  Write-Error $message
  exit 1
} finally {
  if ($stagingSnapshotPath -and (Test-Path -LiteralPath $stagingSnapshotPath)) {
    try {
      Remove-Item -LiteralPath $stagingSnapshotPath -Recurse -Force -ErrorAction Stop
    } catch {
      Write-Warning "DataSafe could not remove incomplete backup folder '$stagingSnapshotPath': $($_.Exception.Message)"
    }
  }
  if ($lockHandle) {
    Release-DataSafeOperationLock $lockHandle $lockPath
  }
}

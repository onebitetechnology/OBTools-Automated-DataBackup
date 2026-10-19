param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,
  [Parameter(Mandatory = $true)]
  [string]$StatusPath,
  [switch]$AllowNewDestination,
  [switch]$ManualBetaRun,
  [string]$AppOperationId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$safetyModulePath = Join-Path $PSScriptRoot "DataSafe.Safety.ps1"
. $safetyModulePath
. (Join-Path $PSScriptRoot 'DataSafe.Repository.ps1')
. (Join-Path $PSScriptRoot 'DataSafe.Manifest.ps1')
. (Join-Path $PSScriptRoot 'DataSafe.IncrementalPlan.ps1')
. (Join-Path $PSScriptRoot 'DataSafe.Transaction.ps1')
. (Join-Path $PSScriptRoot 'DataSafe.AppIntegration.ps1')

function Read-Json([string]$Path) {
  # PowerShell 7.5+ otherwise converts ISO JSON strings to DateTime before
  # enrollment validation, unlike Windows PowerShell and JSON in Node.
  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
    return Get-Content -Raw -Path $Path | ConvertFrom-Json -DateKind String
  }
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
  Write-Verbose "DataSafe notification suppressed for the headless worker: $Title - $Message"
}

function Write-FailedBackupStatus([string]$Path, [string]$Message) {
  try {
    $status = Read-Json $Path
  } catch {
    $status = New-DefaultStatus
  }
  if ($null -ne $script:incrementalStatus) { $status = $script:incrementalStatus }

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
  }
  if ($script:appRequest) {
    $payload.operationId = $AppOperationId
    $payload.destinationId = $script:appDestinationId
    $payload.backupFormatVersion = $script:effectiveFormat
  }
  $payload = $payload | ConvertTo-Json -Compress

  Write-Output "__OB_PROGRESS__:$payload"
}

function Get-RobocopyExcludedDirectories([string]$Source) {
  return @("System Volume Information", '$RECYCLE.BIN') + @(Get-DataSafeBrowserExcludedDirectories $Source)
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
    Remove-DataSafeDirectoryTree $snapshot.FullName
  }

  return @($retainedSnapshots | Sort-Object Timestamp -Descending)
}

function Copy-BackupItem($Job, [string]$RootPath) {
  $source = Resolve-JobSourcePath $Job
  if (-not (Test-DataSafeFile $source) -and -not (Test-DataSafeDirectory $source)) {
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

  Ensure-DataSafeDirectory $destination
  $destinationFile = Join-Path $destination ([System.IO.Path]::GetFileName($source))
  Copy-DataSafeFile -SourcePath $source -DestinationPath $destinationFile
}

function Get-BackupPlanSize($Jobs) {
  $total = [int64]0
  foreach ($job in @($Jobs)) {
    $source = Resolve-JobSourcePath $job
    if (-not (Test-DataSafeFile $source) -and -not (Test-DataSafeDirectory $source)) {
      throw "Backup source missing: $source"
    }

    $total += Get-DataSafePathSize $source
    foreach ($additionalSource in @(Get-AdditionalBackupSources $job $source)) {
      $total += Get-DataSafePathSize $additionalSource
    }
  }

  return $total
}

function Invoke-IncrementalBackup($Config, $Status) {
  $script:incrementalStatus = $Status
  foreach ($field in @{
    backupFormatVersion = 2; scanCounts = [PSCustomObject]@{ files=0; directories=0; sourceErrors=0 }
    copyBytes = [long]0; historyCounts = [PSCustomObject]@{ previousVersions=0; deletedFiles=0 }
    transactionId = $null; recoveryAction = 'none'; warnings = @()
  }.GetEnumerator()) { $Status | Add-Member -NotePropertyName $field.Key -NotePropertyValue $field.Value -Force }
  $jobs = @($Config.jobs | Where-Object { $_.enabled })
  Test-BackupJobPlan $jobs
  $resolvedJobs = @(foreach ($job in $jobs) {
    # The manifest intentionally has no overlay/precedence semantics. Refuse
    # legacy merged sources explicitly; never quietly leave Public data out.
    if (-not [string]::IsNullOrWhiteSpace("$(Get-DataSafeProperty $job 'includePublicFolder' '')") -or
        (Test-TruthyJobProperty $job 'includePublicDesktop')) {
      throw 'Development incremental format does not support merged Public-folder jobs. Use the legacy backup format for this configuration.'
    }
    [PSCustomObject]@{ id=$job.id; path=(Resolve-JobSourcePath $job); relativeDestination=@(Get-BackupDestinationSegments $job) }
  })
  $driveRoot = Resolve-DataSafeDestination $Config.destination
  $capabilities = Get-DataSafeDestinationCapabilities $driveRoot
  if (-not $capabilities.Supported) { throw 'DataSafe destination filesystem is unsupported.' }
  if ($script:explicitAppV2) {
    # Re-resolve and bind immediately before the first identity/repository
    # metadata write; do not trust an earlier app or worker check.
    Assert-DataSafeAppDestination -Config $Config -ActualVolumeUniqueId (Get-DataSafeAppVolumeUniqueId $driveRoot) -ManualBetaRun ([bool]$ManualBetaRun)
  }
  # Identity belongs beside the local config, not in the friendly PC name or
  # on removable media. The repository API atomically creates/validates it.
  $identityPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))) 'incremental-computer-id.json'
  $computerId = Get-DataSafeComputerId $identityPath
  $computerName = [string](Get-DataSafeProperty $Config 'computerName' $env:COMPUTERNAME)
  $repo = Initialize-DataSafeRepository $driveRoot $computerName $computerId
  $pending = New-Object 'System.Collections.Generic.List[object]'
  $null = Read-DataSafeCurrentPointer $repo
  foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $repo.TransactionRoot))) {
    $path = ConvertFrom-DataSafeExtendedPath $extended
    Assert-DataSafeNoReparsePath $path
    $name = [IO.Path]::GetFileName($path)
    # Process termination can bypass either atomic writer's finally cleanup.
    # These exact ordinary-file names are unpublished evidence, never journals:
    # do not parse, promote, or delete them, even when their JSON looks complete.
    if ($name -cmatch '^\.(?:transaction|datasafe)-[0-9a-f]{32}\.tmp$' -and (Test-DataSafeFile $path)) {
      $Status.warnings = @($Status.warnings) + @([PSCustomObject]@{
        Code='UnpublishedJournalTemporary'; Message="Unpublished journal temporary retained for review: $path"
      })
      continue
    }
    if ($name -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$' -or -not (Test-DataSafeFile $path)) {
      throw "DataSafe found an unknown transaction entry; review is required: $path"
    }
    $tx = Read-DataSafeTransaction $path
    $retainedStaging = Join-Path $repo.StagingRoot $tx.transactionId
    Assert-DataSafeNoReparsePath $retainedStaging
    if ($tx.state -cnotin @('committed','rolledBack') -or
        (Test-DataSafeDirectory $retainedStaging) -or (Test-DataSafeFile $retainedStaging)) {
      $pending.Add([PSCustomObject]@{ Transaction=$tx; Path=$path })
    }
  }
  if ($pending.Count -gt 1) { throw 'DataSafe found multiple unresolved journals; review is required before another transaction.' }
  foreach ($item in $pending) {
    $Status.transactionId = $item.Transaction.transactionId
    $Status.recoveryAction = 'recovering'
    $recovered = Recover-DataSafeTransaction $repo $item.Path
    $Status.recoveryAction = $recovered.FinalState
    $Status.warnings = @($Status.warnings) + @($recovered.Warnings)
    # Pointer authority is re-read even when journal finalization warns. Never
    # start a second transaction over unresolved retained journal evidence.
    $pointer = Read-DataSafeCurrentPointer $repo
    $durable = Read-DataSafeTransaction $item.Path
    if ($recovered.Warnings.Count -gt 0) {
      if ($recovered.FinalState -cne 'committed' -or $null -eq $pointer -or $pointer.transactionId -ine $durable.transactionId) {
        throw "DataSafe recovery needs attention: $($recovered.Warnings.Message -join '; ')"
      }
      Complete-IncrementalStatus $Status $repo $recovered
      return
    }
    if ($durable.state -cnotin @('committed','rolledBack')) { throw 'DataSafe previous journal remains unresolved; refusing a new transaction.' }
  }
  $pointer = Read-DataSafeCurrentPointer $repo
  $previous = if ($null -ne $pointer) { Read-DataSafeManifest (Join-Path $repo.MetadataRoot $pointer.manifestPath) } else { $null }
  Write-ProgressMarker -Phase 'scanning' -JobName '' -Step 1 -TotalSteps 4 -Detail 'Scanning selected sources for the incremental development format.'
  $current = New-DataSafeSourceManifest $resolvedJobs $previous -ApplyWorkerExclusions
  $Status.scanCounts = [PSCustomObject]@{
    files=@($current.entries | Where-Object { $_.entryType -ceq 'file' }).Count
    directories=@($current.entries | Where-Object { $_.entryType -ceq 'directory' }).Count
    sourceErrors=$current.sourceErrors.Count
  }
  $plan = New-DataSafeIncrementalPlan $repo $previous $current $capabilities (Get-DataSafeFreeBytes $repo.Root)
  if ($plan.BlockingErrors.Count -gt 0) { throw ($plan.BlockingErrors -join '; ') }
  if ($plan.DeletionReviewRequired) { throw 'DataSafe deletion review is required. Development incremental backups cannot bypass this safety check.' }
  $Status.transactionId = $plan.TransactionId
  $Status.historyCounts = [PSCustomObject]@{
    previousVersions=@($plan.Operations | Where-Object { $_.kind -ceq 'replace' -and $_.oldEntry.entryType -ceq 'file' }).Count
    deletedFiles=@($plan.Operations | Where-Object { $_.kind -ceq 'delete' -and $_.oldEntry.entryType -ceq 'file' }).Count
  }
  $transaction = New-DataSafeTransaction $repo $plan
  $script:incrementalOwner = Get-DataSafeTransactionOwner $transaction
  Write-ProgressMarker -Phase 'staging' -JobName '' -Step 2 -TotalSteps 4 -Detail 'Copying and verifying changed files before any latest-tree mutation.'
  $null = Stage-DataSafeTransaction $transaction
  $Status.copyBytes = $plan.StageBytes
  Write-ProgressMarker -Phase 'applying' -JobName '' -Step 3 -TotalSteps 4 -Detail 'Applying the verified journaled transaction.'
  try { $result = Invoke-DataSafeTransaction $transaction }
  catch {
    # A terminal journal write can fail AFTER pointer publication. Only the
    # public recovery verifier may classify that as committed-with-warning.
    $committedPointer = Read-DataSafeCurrentPointer $repo
    if ($null -eq $committedPointer -or $committedPointer.transactionId -ine $transaction.transactionId) { throw }
    if ($null -ne $script:incrementalOwner.Handle) {
      Release-DataSafeOperationLock $script:incrementalOwner.Handle (ConvertTo-DataSafeExtendedPath $script:incrementalOwner.LockPath)
      $script:incrementalOwner.Handle = $null
    }
    $result = Recover-DataSafeTransaction $repo (Join-Path $repo.TransactionRoot ($transaction.transactionId + '.json'))
    $Status.recoveryAction = $result.FinalState
    $null = Read-DataSafeCurrentPointer $repo
  }
  $Status.warnings = @($Status.warnings) + @($result.Warnings)
  Complete-IncrementalStatus $Status $repo $result
}

function Complete-IncrementalStatus($Status, $Repository, $Result) {
  if ($Result.FinalState -cne 'committed') { throw 'DataSafe incremental transaction did not commit.' }
  $Status.lastBackupAt = (Get-Date).ToString('o')
  $Status | Add-Member lastBackupAttemptAt $Status.lastBackupAt -Force
  $Status.lastBackupResult = if ($Status.warnings.Count) { 'warning' } else { 'success' }
  $Status.lastBackupMessage = "Incremental backup completed and verified to $($Repository.LatestRoot)"
  if ($Status.warnings.Count) {
    $Status.lastBackupMessage += ". Recovery attention required: " + (($Status.warnings | ForEach-Object { "$($_.Code): $($_.Message)" }) -join '; ')
  }
  $Status.destinationStatus = 'Connected'
}

$lockPath = "$StatusPath.lock"
$lockHandle = $null
$configForNotification = $null
$stagingSnapshotPath = $null
$operationBusyMessage = "A DataSafe backup or restore is already running. Wait for it to finish before starting another operation."
$script:incrementalStatus = $null
$script:incrementalOwner = $null
$script:appRequest = $ManualBetaRun -or $PSBoundParameters.ContainsKey('AppOperationId')
$script:appDestinationId = $null
$script:effectiveFormat = $null
$script:explicitAppV2 = $false
$appPreflight = $true

try {
  $config = Read-Json $ConfigPath
  $configForNotification = $config
  $destination = Get-DataSafeProperty $config 'destination'
  if ($null -ne $destination -and $null -ne $destination.PSObject.Properties['id']) {
    $script:appDestinationId = $destination.PSObject.Properties['id'].Value
  }
  $script:explicitAppV2 = $null -ne $destination -and $null -ne $destination.PSObject.Properties['backupFormatVersion'] -and
    $destination.backupFormatVersion -is [ValueType] -and $destination.backupFormatVersion -eq 2
  if ($script:explicitAppV2) { $script:appRequest = $true }
  $script:effectiveFormat = Get-DataSafeBackupFormat $config
  if ($script:explicitAppV2 -or $script:appRequest) {
    $operationUuid = [guid]::Empty
    if (-not [guid]::TryParseExact($AppOperationId, 'D', [ref]$operationUuid) -or $operationUuid -eq [guid]::Empty) {
      throw 'Manual app backup requires a valid AppOperationId UUID.'
    }
  }
  if ($script:explicitAppV2) {
    Assert-DataSafeAppDestination -Config $config -ActualVolumeUniqueId (Get-DataSafeAppVolumeUniqueId (Resolve-DataSafeDestination $destination)) -ManualBetaRun ([bool]$ManualBetaRun)
  }
  $lockHandle = Acquire-DataSafeOperationLock $lockPath
  $appPreflight = $false
  $status = Read-Json $StatusPath

  if ($script:effectiveFormat -eq 2) {
    Invoke-IncrementalBackup $config $status
    Write-Json $StatusPath $status
    Write-ProgressMarker -Phase 'complete' -JobName '' -Step 4 -TotalSteps 4 -Detail $status.lastBackupMessage
    Write-Output $status.lastBackupMessage
    if ($script:appRequest) {
      $outcome = if ($status.warnings.Count) { 'committed-with-warning' } else { 'committed' }
      Write-DataSafeAppBackupResult $AppOperationId $script:appDestinationId $outcome $status $status.lastBackupMessage
    }
  } else {

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
  }
} catch {
  $message = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" }
  if ($message -eq $operationBusyMessage) {
    if ($script:appRequest) { Write-DataSafeAppBackupResult $AppOperationId $script:appDestinationId 'busy' $null $message }
    Write-Output $message
    exit 0
  }

  if ($script:appRequest) {
    $outcome = if ($appPreflight) { 'blocked' } else { 'failed' }
    Write-DataSafeAppBackupResult $AppOperationId $script:appDestinationId $outcome $script:incrementalStatus $message
  }
  # A registered background worker must not overwrite existing committed
  # status when explicit v2 enrollment forbids its nonmanual invocation.
  if (-not $appPreflight -or -not $script:appRequest) { Write-FailedBackupStatus $StatusPath $message }

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
  if ($null -ne $script:incrementalOwner -and $null -ne $script:incrementalOwner.Handle) {
    Release-DataSafeOperationLock $script:incrementalOwner.Handle (ConvertTo-DataSafeExtendedPath $script:incrementalOwner.LockPath)
    $script:incrementalOwner.Handle = $null
  }
  if ($stagingSnapshotPath -and (Test-Path -LiteralPath $stagingSnapshotPath)) {
    try {
      Remove-DataSafeDirectoryTree $stagingSnapshotPath
    } catch {
      Write-Warning "DataSafe could not remove incomplete backup folder '$stagingSnapshotPath': $($_.Exception.Message)"
    }
  }
  if ($lockHandle) {
    Release-DataSafeOperationLock $lockHandle $lockPath
  }
}

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

function New-DefaultStatus {
  [PSCustomObject]@{
    lastBackupAt = $null
    lastBackupResult = $null
    lastBackupMessage = "No backups have been run yet."
    destinationStatus = "Unknown"
    recentSnapshots = @()
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

function Acquire-BackupLock([string]$LockPath) {
  if (Test-Path -LiteralPath $LockPath) {
    $existing = Get-Item -LiteralPath $LockPath -ErrorAction SilentlyContinue
    $ageHours = if ($existing) { ((Get-Date) - $existing.LastWriteTime).TotalHours } else { 0 }
    if ($ageHours -lt 12) {
      throw "A DataSafe backup is already running. Wait for it to finish before starting another backup."
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
    throw "A DataSafe backup is already running. Wait for it to finish before starting another backup."
  }
}

function Release-BackupLock($Handle, [string]$LockPath) {
  if ($Handle) {
    $Handle.Dispose()
  }

  Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}

function Write-FailedBackupStatus([string]$Path, [string]$Message) {
  try {
    $status = Read-Json $Path
  } catch {
    $status = New-DefaultStatus
  }

  $status.lastBackupAt = (Get-Date).ToString("o")
  $status.lastBackupResult = "error"
  $status.lastBackupMessage = $Message
  if ($Message -match "Destination drive is not available" -or $Message -match "No destination drive could be resolved") {
    $status.destinationStatus = "Drive Not Connected"
  } else {
    $status.destinationStatus = "Issue Detected"
  }

  Write-Json $Path $status
}

function Write-DestinationMarker([string]$BaseRoot, $Config) {
  $markerPath = Join-Path $BaseRoot ".datasafe-backup.json"
  $marker = [ordered]@{
    installId = if ($null -ne $Config.PSObject.Properties["installId"]) { "$($Config.installId)" } else { "" }
    destinationId = if ($null -ne $Config.destination.PSObject.Properties["id"]) { "$($Config.destination.id)" } else { "" }
    businessName = if ($null -ne $Config.PSObject.Properties["businessName"]) { "$($Config.businessName)" } else { "" }
    createdAt = (Get-Date).ToString("o")
    machineName = $env:COMPUTERNAME
  }

  Write-Json $markerPath $marker
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

    $source = Expand-WindowsPath $rawPath
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

  $destination = Get-BackupItemTargetPath $Job $RootPath

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

$lockPath = "$StatusPath.lock"
$lockHandle = $null
$configForNotification = $null

try {
  $lockHandle = Acquire-BackupLock $lockPath
  $config = Read-Json $ConfigPath
  $configForNotification = $config
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
  Test-BackupJobPlan $enabledJobs

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
  Write-DestinationMarker $baseRoot $config
  $status.lastBackupAt = (Get-Date).ToString("o")
  $status.lastBackupResult = "success"
  $status.lastBackupMessage = "Backup completed to $baseRoot"
  $status.destinationStatus = "Connected"
  $status.recentSnapshots = @($remaining)

  Write-Json $StatusPath $status
  Write-ProgressMarker -Phase "complete" -JobName "" -Step $totalSteps -TotalSteps $totalSteps -Detail "Backup completed successfully."
  Show-BackupNotification -Title "DataSafe Backup Complete" -Message "Backup completed successfully to $baseRoot." -Level "Info" -ClickTarget $null
  Write-Output "Backup completed successfully."
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
  if ($lockHandle) {
    Release-BackupLock $lockHandle $lockPath
  }
}

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

function Copy-BackupItem($Job, [string]$RootPath) {
  $source = Expand-WindowsPath $Job.path
  if (-not (Test-Path -LiteralPath $source)) {
    throw "Backup source missing: $source"
  }

  $safeName = ($Job.name -replace '[^a-zA-Z0-9_-]', '-').Trim('-')
  $destination = Join-Path $RootPath $safeName

  if ($Job.type -eq "folder") {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $robocopyOutput = @(robocopy $source $destination /MIR /FFT /R:1 /W:1 /XJ /XD "System Volume Information" '$RECYCLE.BIN' 2>&1)
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
$keep = [Math]::Max([int]$config.retentionCount, 1)
$enabledJobs = @($config.jobs | Where-Object { $_.enabled })
$totalSteps = [Math]::Max(($enabledJobs.Count * 2) + 1, 1)

New-Item -ItemType Directory -Force -Path $currentRoot | Out-Null
New-Item -ItemType Directory -Force -Path $snapshotsRoot | Out-Null

$existingSnapshots = @(Get-ChildItem -Path $snapshotsRoot -Directory | Sort-Object CreationTime)
Write-ProgressMarker -Phase "preparing" -JobName "" -Step 1 -TotalSteps $totalSteps -Detail "Preparing the backup destination."
if ($existingSnapshots.Count -ge $keep) {
  $removeCount = ($existingSnapshots.Count - $keep) + 1
  $existingSnapshots | Select-Object -First $removeCount | Remove-Item -Recurse -Force
}

for ($index = 0; $index -lt $enabledJobs.Count; $index++) {
  $job = $enabledJobs[$index]
  $currentStep = 2 + ($index * 2)

  Write-ProgressMarker -Phase "copying-current" -JobName $job.name -Step $currentStep -TotalSteps $totalSteps -Detail "Copying to the current backup set."
  Copy-BackupItem $job $currentRoot

  Write-ProgressMarker -Phase "copying-snapshot" -JobName $job.name -Step ($currentStep + 1) -TotalSteps $totalSteps -Detail "Creating the dated snapshot copy."
  Copy-BackupItem $job $snapshotPath
}

$allSnapshots = @(Get-ChildItem -Path $snapshotsRoot -Directory | Sort-Object CreationTime -Descending)
if ($allSnapshots.Count -gt $keep) {
  $allSnapshots | Select-Object -Skip $keep | Remove-Item -Recurse -Force
}

$remaining = Get-ChildItem -Path $snapshotsRoot -Directory | Sort-Object CreationTime -Descending | Select-Object -ExpandProperty Name
$status.lastBackupAt = (Get-Date).ToString("o")
$status.lastBackupResult = "success"
$status.lastBackupMessage = "Backup completed to $baseRoot"
$status.destinationStatus = "Connected"
$status.recentSnapshots = @($remaining)

Write-Json $StatusPath $status
Write-ProgressMarker -Phase "complete" -JobName "" -Step $totalSteps -TotalSteps $totalSteps -Detail "Backup completed successfully."
Write-Output "Backup completed successfully."

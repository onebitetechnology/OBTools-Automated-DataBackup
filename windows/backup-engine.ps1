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
  $Value | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
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

function Copy-BackupItem($Job, [string]$RootPath) {
  $source = Expand-WindowsPath $Job.path
  if (-not (Test-Path -LiteralPath $source)) {
    throw "Backup source missing: $source"
  }

  $safeName = ($Job.name -replace '[^a-zA-Z0-9_-]', '-').Trim('-')
  $destination = Join-Path $RootPath $safeName

  if ($Job.type -eq "folder") {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    robocopy $source $destination /MIR /FFT /R:1 /W:1 /XD "System Volume Information" '$RECYCLE.BIN' | Out-Null
    if ($LASTEXITCODE -ge 8) {
      throw "Robocopy failed for $source with exit code $LASTEXITCODE"
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

New-Item -ItemType Directory -Force -Path $currentRoot | Out-Null
New-Item -ItemType Directory -Force -Path $snapshotsRoot | Out-Null

foreach ($job in $config.jobs) {
  if ($job.enabled) {
    Copy-BackupItem $job $currentRoot
    Copy-BackupItem $job $snapshotPath
  }
}

$allSnapshots = Get-ChildItem -Path $snapshotsRoot -Directory | Sort-Object CreationTime -Descending
$keep = [Math]::Max([int]$config.retentionCount, 1)
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
Write-Output "Backup completed successfully."

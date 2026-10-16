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
  if (-not $Destination) {
    return $null
  }

  if ($Destination.mode -eq "label" -and $Destination.label) {
    $volume = Get-Volume | Where-Object { $_.FileSystemLabel -eq $Destination.label } | Select-Object -First 1
    if ($volume -and $volume.DriveLetter) {
      return "$($volume.DriveLetter):\"
    }
  }

  if ($Destination.driveLetter) {
    return "$($Destination.driveLetter.TrimEnd(':')):\"
  }

  return $null
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

$config = Read-Json $ConfigPath
$status = Read-Json $StatusPath
$support = Get-SupportContact $config
$contactTarget = Get-ContactTarget $support
$contactLine = Get-ContactLine $support

if (-not $config.reminders) {
  $config | Add-Member -NotePropertyName reminders -NotePropertyValue ([PSCustomObject]@{
    enabled = $true
    staleDays = 7
  }) -Force
}

if (-not $config.destination) {
  $config | Add-Member -NotePropertyName destination -NotePropertyValue ([PSCustomObject]@{}) -Force
}

if (-not $config.reminders.enabled) {
  Write-Output "Reminders are disabled."
  exit 0
}

$driveRoot = Resolve-Destination $config.destination
$driveMissing = $false
if ($driveRoot) {
  $driveMissing = -not (Test-Path -LiteralPath $driveRoot)
  $status.destinationStatus = if ($driveMissing) { "Drive Not Connected" } else { "Connected" }
  Write-Json $StatusPath $status
}

if ($driveMissing) {
  $message = "The configured backup drive is not connected. Reconnect the drive and open DataSafe to run your next backup."
  if ($contactLine) {
    $message = "$message`n$contactLine"
  }
  Show-BackupNotification -Title "Backup Drive Missing" -Message $message -Level "Warning" -ClickTarget $contactTarget
  Write-Output "Missing-drive reminder shown."
  exit 0
}

if (-not $status.lastBackupAt) {
  $message = "DataSafe has not completed its first backup yet. Connect the backup drive and run the app to finish setup."
  if ($contactLine) {
    $message = "$message`n$contactLine"
  }
  Show-BackupNotification -Title "First Backup Needed" -Message $message -Level "Warning" -ClickTarget $contactTarget
  Write-Output "Reminder shown for missing first backup."
  exit 0
}

$last = [DateTime]::Parse($status.lastBackupAt)
$age = ((Get-Date) - $last).TotalDays
if ($age -ge [double]$config.reminders.staleDays) {
  $message = "Your last backup was $([math]::Floor($age)) day(s) ago. Connect the backup drive and open DataSafe soon."
  if ($contactLine) {
    $message = "$message`n$contactLine"
  }
  Show-BackupNotification -Title "Backup Reminder" -Message $message -Level "Warning" -ClickTarget $contactTarget
  Write-Output "Stale backup reminder shown."
  exit 0
}

Write-Output "Backup is within the reminder threshold."

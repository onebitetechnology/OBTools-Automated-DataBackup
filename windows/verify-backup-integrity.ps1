param(
  [Parameter(Mandatory = $true)]
  [string]$ConfigPath,
  [Parameter(Mandatory = $true)]
  [string]$StatusPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$safetyModulePath = Join-Path $PSScriptRoot "DataSafe.Safety.ps1"
. $safetyModulePath

function Set-IntegrityStatus($Status, $IntegrityStatus) {
  if ($null -eq $Status.PSObject.Properties["integrity"]) {
    $Status | Add-Member -NotePropertyName "integrity" -NotePropertyValue $IntegrityStatus
  } else {
    $Status.integrity = $IntegrityStatus
  }
}

function Show-IntegrityWarning([string]$Message) {
  Write-Warning $Message
}

$config = Read-DataSafeJson $ConfigPath
. (Join-Path $PSScriptRoot 'DataSafe.AppIntegration.ps1')
if (Test-DataSafeManualBetaConfig $config) {
  Write-DataSafeManualBetaSkipped 'verify-backup-integrity'
  return
}
$status = Read-DataSafeJson $StatusPath

try {
  $baseRoot = Get-DataSafeBaseRoot $config
  $null = Assert-DataSafeDestinationIdentity -BaseRoot $baseRoot -Config $config -Status $status
  Test-DataSafeMediaReadWrite $baseRoot
  $snapshots = @(Get-DataSafeCompletedSnapshots (Join-Path $baseRoot "snapshots"))
  if ($snapshots.Count -eq 0) {
    throw "No completed DataSafe snapshot is available to verify."
  }

  $latest = $snapshots[0]
  $verification = Test-DataSafeIntegrityIndex $latest.FullName
  $verificationRecord = [ordered]@{
    formatVersion = 1
    snapshotName = $latest.Name
    checkedAt = $verification.checkedAt
    level = "success"
    filesChecked = [int]$verification.filesChecked
    bytesChecked = [int64]$verification.bytesChecked
  }
  Write-DataSafeJson (Join-Path $latest.FullName $script:DataSafeVerificationFile) $verificationRecord

  Set-IntegrityStatus $status ([PSCustomObject]@{
    checkedAt = $verification.checkedAt
    level = "success"
    summary = "$($verification.filesChecked) files in snapshot $($latest.Name) passed a full checksum check."
    snapshotName = $latest.Name
    filesChecked = [int]$verification.filesChecked
  })
  Write-DataSafeJson $StatusPath $status
  Write-Output $status.integrity.summary
} catch {
  $message = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" }
  Set-IntegrityStatus $status ([PSCustomObject]@{
    checkedAt = (Get-Date).ToString("o")
    level = "error"
    summary = "Backup integrity check failed: $message"
    snapshotName = $null
    filesChecked = 0
  })
  $status.destinationStatus = if ($message -match "Destination drive is not available") { "Drive Not Connected" } else { "Issue Detected" }
  Write-DataSafeJson $StatusPath $status
  Show-IntegrityWarning $status.integrity.summary
  Write-Error $message
  exit 1
}

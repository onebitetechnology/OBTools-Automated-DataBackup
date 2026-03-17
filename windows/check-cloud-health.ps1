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

$status = Read-Json $StatusPath
$recommendations = New-Object System.Collections.Generic.List[string]
$summaryParts = New-Object System.Collections.Generic.List[string]
$level = "info"

$oneDriveExe = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\OneDrive.exe"
$oneDriveFolder = Join-Path $env:USERPROFILE "OneDrive"
$process = Get-Process OneDrive -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $oneDriveExe) {
  $summaryParts.Add("OneDrive is installed.")
} else {
  $summaryParts.Add("OneDrive is not installed.")
  $recommendations.Add("Install or re-enable OneDrive if the customer expects cloud protection.")
  $level = "warning"
}

if ($process) {
  $summaryParts.Add("The sync client is running.")
} else {
  $summaryParts.Add("The sync client is not running.")
  $recommendations.Add("Start OneDrive and confirm the user is signed in.")
  if ($level -eq "info") {
    $level = "warning"
  }
}

if (Test-Path -LiteralPath $oneDriveFolder) {
  $summaryParts.Add("A OneDrive folder exists in the user profile.")
} else {
  $summaryParts.Add("No OneDrive user folder was found.")
  $recommendations.Add("Open OneDrive setup and confirm a local sync folder has been created.")
  $level = "warning"
}

$desktop = [Environment]::GetFolderPath("Desktop")
$documents = [Environment]::GetFolderPath("MyDocuments")
if ($desktop -like "*OneDrive*" -or $documents -like "*OneDrive*") {
  $summaryParts.Add("Known folders appear to be redirected into OneDrive.")
} else {
  $recommendations.Add("Consider enabling OneDrive Known Folder Backup for Desktop and Documents.")
}

$status.cloud = [ordered]@{
  checkedAt = (Get-Date).ToString("o")
  summary = ($summaryParts -join " ")
  level = $level
  recommendations = @($recommendations)
}

Write-Json $StatusPath $status
Write-Output $status.cloud.summary

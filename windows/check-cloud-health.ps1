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

function Add-Recommendation([System.Collections.Generic.List[string]]$Recommendations, [string]$Message) {
  if (-not [string]::IsNullOrWhiteSpace($Message) -and -not $Recommendations.Contains($Message)) {
    $Recommendations.Add($Message)
  }
}

function Test-ExistingPath([string]$Path) {
  return -not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)
}

function Normalize-PathText([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  try {
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return ([System.IO.Path]::GetFullPath($expanded).TrimEnd('\')).ToLowerInvariant()
  } catch {
    return ($Path.TrimEnd('\')).ToLowerInvariant()
  }
}

function Test-PathInsideRoot([string]$Path, [string[]]$Roots) {
  $normalizedPath = Normalize-PathText $Path
  if (-not $normalizedPath) {
    return $false
  }

  foreach ($root in @($Roots)) {
    $normalizedRoot = Normalize-PathText $root
    if (-not $normalizedRoot) {
      continue
    }

    if ($normalizedPath -eq $normalizedRoot -or $normalizedPath.StartsWith("$normalizedRoot\")) {
      return $true
    }
  }

  return $false
}

function Get-RegistryValue($Path, [string]$Name) {
  try {
    $props = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    if ($null -ne $props.PSObject.Properties[$Name]) {
      return [string]$props.PSObject.Properties[$Name].Value
    }
  } catch {
    return ""
  }

  return ""
}

function Get-OneDriveAccounts {
  $accountsRoot = "HKCU:\Software\Microsoft\OneDrive\Accounts"
  if (-not (Test-Path -LiteralPath $accountsRoot)) {
    return @()
  }

  $accounts = New-Object System.Collections.Generic.List[object]
  foreach ($accountKey in @(Get-ChildItem -LiteralPath $accountsRoot -ErrorAction SilentlyContinue)) {
    $props = Get-ItemProperty -LiteralPath $accountKey.PSPath -ErrorAction SilentlyContinue
    if (-not $props) {
      continue
    }

    $email = if ($null -ne $props.PSObject.Properties["UserEmail"]) { [string]$props.UserEmail } else { "" }
    $folder = if ($null -ne $props.PSObject.Properties["UserFolder"]) { [string]$props.UserFolder } else { "" }
    $displayName = if ($null -ne $props.PSObject.Properties["DisplayName"]) { [string]$props.DisplayName } else { "" }
    $cid = if ($null -ne $props.PSObject.Properties["cid"]) { [string]$props.cid } else { "" }
    $configured = -not [string]::IsNullOrWhiteSpace($email) -or -not [string]::IsNullOrWhiteSpace($folder) -or -not [string]::IsNullOrWhiteSpace($cid)

    if (-not $configured) {
      continue
    }

    $accounts.Add([PSCustomObject]@{
      Name = $accountKey.PSChildName
      Email = $email
      DisplayName = $displayName
      Folder = $folder
      FolderExists = Test-ExistingPath $folder
    })
  }

  return @($accounts)
}

function Get-OneDriveSyncRoots($Accounts) {
  $roots = New-Object System.Collections.Generic.List[string]

  foreach ($envName in @("OneDrive", "OneDriveConsumer", "OneDriveCommercial")) {
    $value = [Environment]::GetEnvironmentVariable($envName, "User")
    if (Test-ExistingPath $value -and -not $roots.Contains($value)) {
      $roots.Add($value)
    }
  }

  foreach ($account in @($Accounts)) {
    if (Test-ExistingPath $account.Folder -and -not $roots.Contains($account.Folder)) {
      $roots.Add($account.Folder)
    }
  }

  return @($roots)
}

function Get-KnownFolderPath([string]$RegistryName, [string]$FallbackFolderName) {
  $registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
  $registryValue = Get-RegistryValue $registryPath $RegistryName
  if (-not [string]::IsNullOrWhiteSpace($registryValue)) {
    return [Environment]::ExpandEnvironmentVariables($registryValue)
  }

  if ($FallbackFolderName -eq "Documents") {
    return [Environment]::GetFolderPath("MyDocuments")
  }

  if ($FallbackFolderName -eq "Desktop") {
    return [Environment]::GetFolderPath("Desktop")
  }

  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    return ""
  }

  return Join-Path $env:USERPROFILE $FallbackFolderName
}

$status = Read-Json $StatusPath
$recommendations = New-Object System.Collections.Generic.List[string]
$summaryParts = New-Object System.Collections.Generic.List[string]
$healthy = $true

$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { "" }
$oneDriveExe = if ($localAppData) { Join-Path $localAppData "Microsoft\OneDrive\OneDrive.exe" } else { "" }
$accounts = @(Get-OneDriveAccounts)
$syncRoots = @(Get-OneDriveSyncRoots $accounts)
$process = Get-Process OneDrive -ErrorAction SilentlyContinue

if (Test-ExistingPath $oneDriveExe) {
  $summaryParts.Add("OneDrive is installed.")
} else {
  $summaryParts.Add("OneDrive is not installed.")
  Add-Recommendation $recommendations "Install or repair OneDrive before treating cloud backup as active."
  $healthy = $false
}

if ($accounts.Count -gt 0) {
  $accountLabels = @($accounts | ForEach-Object {
    if ($_.Email) {
      $_.Email
    } elseif ($_.DisplayName) {
      $_.DisplayName
    } else {
      $_.Name
    }
  })
  $summaryParts.Add("Signed-in OneDrive account detected: $($accountLabels -join ', ').")
} else {
  $summaryParts.Add("No signed-in OneDrive account was found.")
  Add-Recommendation $recommendations "Sign into OneDrive with the customer account, then confirm sync finishes before relying on cloud backup."
  $healthy = $false
}

if ($process) {
  $summaryParts.Add("The OneDrive sync client is running.")
} else {
  $summaryParts.Add("The OneDrive sync client is not running.")
  Add-Recommendation $recommendations "Start OneDrive and confirm it stays signed in."
  $healthy = $false
}

if ($syncRoots.Count -gt 0) {
  $summaryParts.Add("Active OneDrive sync folder found: $($syncRoots -join ', ').")
} else {
  $summaryParts.Add("No active OneDrive sync folder was found.")
  Add-Recommendation $recommendations "Complete OneDrive setup so it creates a real synced folder for the signed-in account."
  $healthy = $false
}

$folderChecks = @(
  [PSCustomObject]@{ Name = "Desktop"; Path = Get-KnownFolderPath "Desktop" "Desktop" },
  [PSCustomObject]@{ Name = "Documents"; Path = Get-KnownFolderPath "Personal" "Documents" }
)

$protectedFolders = New-Object System.Collections.Generic.List[string]
$unprotectedFolders = New-Object System.Collections.Generic.List[string]
foreach ($folder in $folderChecks) {
  if (Test-PathInsideRoot $folder.Path $syncRoots) {
    $protectedFolders.Add("$($folder.Name): $($folder.Path)")
  } else {
    $unprotectedFolders.Add("$($folder.Name): $($folder.Path)")
  }
}

if ($protectedFolders.Count -gt 0) {
  $summaryParts.Add("Known folders inside OneDrive: $($protectedFolders -join '; ').")
}

if ($unprotectedFolders.Count -gt 0) {
  $summaryParts.Add("Known folders not protected by OneDrive: $($unprotectedFolders -join '; ').")
  Add-Recommendation $recommendations "Enable OneDrive backup for Desktop and Documents, or add those local folders to DataSafe's local backup list."
  $healthy = $false
}

$level = if ($healthy -and $recommendations.Count -eq 0) { "success" } else { "warning" }
if ($level -eq "success") {
  $summaryParts.Add("OneDrive appears signed in, running, and protecting Desktop/Documents.")
}

$status.cloud = [ordered]@{
  checkedAt = (Get-Date).ToString("o")
  summary = ($summaryParts -join " ")
  level = $level
  recommendations = @($recommendations)
}

Write-Json $StatusPath $status
Write-Output $status.cloud.summary

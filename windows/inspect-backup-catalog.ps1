param(
  [Parameter(Mandatory=$true)][string]$ConfigPath,
  [Parameter(Mandatory=$true)][string]$StatusPath,
  [ValidateSet('Inspect','InspectVolume','ResolveLocation')][string]$Action='Inspect',
  [string]$ComputerId,
  [string]$LocationId
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DataSafe.Transaction.ps1')
. (Join-Path $PSScriptRoot 'DataSafe.AppIntegration.ps1')

# StatusPath is accepted for the common app protocol but deliberately never
# read or written: historical status is not repository commit authority.
try {
  Assert-DataSafeNoReparsePath $ConfigPath
  $json=[IO.File]::ReadAllText($ConfigPath); Assert-DataSafeIdentityJsonShape $json
  $options=@{InputObject=$json;ErrorAction='Stop'}
  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind='String' }
  $config=ConvertFrom-Json @options
  if ($Action -ceq 'InspectVolume') {
    $destination=Get-DataSafeAppDestinationRecord $config
    $root=Resolve-DataSafeDestination $destination; Assert-DataSafeNoReparsePath $root
    $connected=Test-DataSafeDirectory $root
    $result=[PSCustomObject]@{connected=$connected;volumeUniqueId=$(if ($connected) {Get-DataSafeAppVolumeUniqueId $root} else {$null})}
  } else {
    $projection=Get-DataSafeAppCatalog $config $ConfigPath
    $result=$projection.Catalog
    if ($Action -ceq 'ResolveLocation') {
      if ($result.backupFormatVersion -ne 2 -or $result.connection -cne 'connected' -or $result.volumeMatch -ne $true -or $result.state -ceq 'invalid') { throw 'Destination cannot authorize browsing.' }
      $records=@($result.repositories | Where-Object {$_.computerId -ceq $ComputerId})
      if ($records.Count -ne 1 -or -not $records[0].capabilities.browse -or -not $projection.Locations.ContainsKey($LocationId)) { throw 'Location is not in the fresh validated catalog.' }
      $location=$projection.Locations[$LocationId]
      if ($location.ComputerId -cne $ComputerId) { throw 'Location belongs to another computer.' }
      $root=Resolve-DataSafeDestination (Get-DataSafeAppDestinationRecord $config)
      if ([IO.Path]::GetFullPath($root) -ine [IO.Path]::GetFullPath($projection.DriveRoot)) { throw 'Destination changed during resolution.' }
      Assert-DataSafeAppDestination $config (Get-DataSafeAppVolumeUniqueId $root) $true
      $path=[IO.Path]::GetFullPath($location.Path)
      $base=[IO.Path]::GetFullPath((Join-Path $root 'DataSafe Backups')).TrimEnd('\')+'\'
      if (-not $path.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw 'Location escaped the backup base.' }
      Assert-DataSafeNoReparsePath $path
      if (-not (Test-DataSafeDirectory $path)) { throw 'Location is no longer available.' }
      $null=@(Get-DataSafeAppTreeEntries $path)
      $result=[PSCustomObject]@{destinationId=$result.destinationId;computerId=$ComputerId;locationId=$LocationId;path=$path}
    }
  }
  Write-Output ('__OB_RESULT__:'+(ConvertTo-Json $result -Depth 32 -Compress))
} catch {
  Write-Output ('__OB_RESULT__:'+(ConvertTo-Json ([PSCustomObject]@{error='Read-only catalog request could not be validated.'}) -Compress))
  exit 1
}

Set-StrictMode -Version Latest

function Get-DataSafeAppDestinationRecord($Config) {
  $property = $null
  if ($null -ne $Config) { $property = $Config.PSObject.Properties['destination'] }
  if ($null -eq $property) { return $null }
  # Validate the raw deserialized JSON container before any pipeline can
  # unwrap a one-item array. Only an absent property permits root fallback.
  $destination = $property.Value
  if ($destination -isnot [PSCustomObject]) { throw 'Backup destination must be an object.' }
  return $destination
}

function Get-DataSafeBackupFormat($Config) {
  $destination = Get-DataSafeAppDestinationRecord $Config
  $property = if ($null -ne $destination) { $destination.PSObject.Properties['backupFormatVersion'] } else { $null }
  if ($null -eq $property -and $null -ne $Config) { $property = $Config.PSObject.Properties['incrementalFormatVersion'] }
  if ($null -eq $property) { return 1 }
  # Inspect the raw property: the pipeline must not unwrap arrays or coerce
  # strings, booleans and null into supported numeric values.
  $value = $property.Value
  if (($value -isnot [byte] -and $value -isnot [sbyte] -and $value -isnot [int16] -and $value -isnot [uint16] -and
       $value -isnot [int] -and $value -isnot [uint32] -and $value -isnot [long] -and $value -isnot [uint64] -and
       $value -isnot [single] -and $value -isnot [double] -and $value -isnot [decimal]) -or $value -notin @(1,2)) {
    throw 'Unsupported backup format version; expected numeric 1 or 2.'
  }
  return [int]$value
}

function Assert-DataSafeAppDestination($Config, [string]$ActualVolumeUniqueId, [bool]$ManualBetaRun) {
  $format = Get-DataSafeBackupFormat $Config
  $destination = Get-DataSafeAppDestinationRecord $Config
  if ($format -ne 2 -or $null -eq $destination -or $null -eq $destination.PSObject.Properties['backupFormatVersion']) { return }
  if (-not $ManualBetaRun) { throw 'Explicit incremental beta destinations require a manual app invocation.' }
  # Raw values must stay raw: the general pipeline getter unwraps singleton
  # arrays, which would let malformed JSON metadata impersonate a string.
  $id = $null
  if ($null -ne $destination.PSObject.Properties['id']) { $id = $destination.PSObject.Properties['id'].Value }
  $parsedId = [guid]::Empty
  if ($id -isnot [string] -or -not [guid]::TryParseExact($id, 'D', [ref]$parsedId) -or $parsedId -eq [guid]::Empty) {
    throw 'Incremental beta destination requires its destination-record UUID.'
  }
  $binding = $null
  if ($null -ne $destination.PSObject.Properties['volumeUniqueId']) { $binding = $destination.PSObject.Properties['volumeUniqueId'].Value }
  if ($binding -isnot [string] -or [string]::IsNullOrWhiteSpace($binding) -or
      [string]::IsNullOrWhiteSpace($ActualVolumeUniqueId) -or $binding -ine $ActualVolumeUniqueId) {
    throw 'Incremental beta destination volume identity is missing or does not match the resolved Windows volume.'
  }
  $confirmation = $null
  if ($null -ne $destination.PSObject.Properties['manualBetaConfirmedAt']) { $confirmation = $destination.PSObject.Properties['manualBetaConfirmedAt'].Value }
  $parsed = [datetime]::MinValue
  $patterns = @("yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'")
  if ($confirmation -isnot [string] -or $confirmation -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$' -or
      -not [datetime]::TryParseExact($confirmation, [string[]]$patterns, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
    throw 'Incremental beta destination requires an ISO UTC manualBetaConfirmedAt confirmation.'
  }
}

function Get-DataSafeAppVolumeUniqueId([string]$ResolvedPath) {
  # Ask Storage for the volume containing the resolved destination. A drive
  # letter/label or repository identity is not a physical-volume binding.
  $volumes = @(Get-Volume -FilePath $ResolvedPath -ErrorAction Stop)
  if ($volumes.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$volumes[0].UniqueId)) {
    throw 'Cannot resolve a unique Windows destination volume identity.'
  }
  return [string]$volumes[0].UniqueId
}

function Write-DataSafeAppBackupResult([string]$OperationId, $DestinationId, [string]$Outcome, $Status, [string]$Message) {
  $parsedId = [guid]::Empty
  $correlation = if ([guid]::TryParseExact($OperationId, 'D', [ref]$parsedId) -and $parsedId -ne [guid]::Empty) { $OperationId } else { $null }
  $destinationCorrelation = $null
  if ($DestinationId -is [string] -and [guid]::TryParseExact($DestinationId, 'D', [ref]$parsedId) -and $parsedId -ne [guid]::Empty) { $destinationCorrelation = $DestinationId }
  $result = [ordered]@{
    schema='datasafe.app-backup-result'; formatVersion=1; operationId=$correlation; destinationId=$destinationCorrelation
    backupFormatVersion=2; outcome=$Outcome
    transactionId=(Get-DataSafeProperty $Status 'transactionId'); committedAt=$null
    recoveryAction=(Get-DataSafeProperty $Status 'recoveryAction' 'none')
    scanCounts=(Get-DataSafeProperty $Status 'scanCounts'); copyBytes=(Get-DataSafeProperty $Status 'copyBytes')
    historyCounts=(Get-DataSafeProperty $Status 'historyCounts'); warnings=@(Get-DataSafeProperty $Status 'warnings' @())
    message=$Message
  }
  # Qualified metadata has no actual commit timestamp. Neither the current
  # wall clock nor manifest creation/mtime is evidence of that unavailable time.
  Write-Output ('__OB_RESULT__:' + (ConvertTo-Json $result -Depth 12 -Compress))
}

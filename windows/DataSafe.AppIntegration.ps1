Set-StrictMode -Version Latest

# Shared discovery only. Keep the worker's qualified canonical-journal versus
# exact unpublished atomic-writer temporary distinction; never repair here.
function Get-DataSafePendingTransactionEvidence($Repository) {
  $pending = New-Object 'System.Collections.Generic.List[object]'
  $transactions = New-Object 'System.Collections.Generic.List[object]'
  $warnings = New-Object 'System.Collections.Generic.List[object]'
  try {
  $null = Read-DataSafeCurrentPointer $Repository
  foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $Repository.TransactionRoot))) {
    $path = ConvertFrom-DataSafeExtendedPath $extended
    Assert-DataSafeNoReparsePath $path
    $name = [IO.Path]::GetFileName($path)
    if ($name -cmatch '^\.(?:transaction|datasafe)-[0-9a-f]{32}\.tmp$' -and (Test-DataSafeFile $path)) {
      $warnings.Add([PSCustomObject]@{ Code='UnpublishedJournalTemporary'; Message="Unpublished journal temporary retained for review: $path" })
      continue
    }
    if ($name -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$' -or -not (Test-DataSafeFile $path)) {
      throw "DataSafe found an unknown transaction entry; review is required: $path"
    }
    $tx = Read-DataSafeTransaction $path
    $item = [PSCustomObject]@{ Transaction=$tx; Path=$path }
    $transactions.Add($item)
    $retainedStaging = Join-Path $Repository.StagingRoot $tx.transactionId
    Assert-DataSafeNoReparsePath $retainedStaging
    if ($tx.state -cnotin @('committed','rolledBack') -or
        (Test-DataSafeDirectory $retainedStaging) -or (Test-DataSafeFile $retainedStaging)) { $pending.Add($item) }
  }
  if ($pending.Count -gt 1) { throw 'DataSafe found multiple unresolved journals; review is required before another transaction.' }
  return [PSCustomObject]@{ Pending=@($pending.ToArray()); Transactions=@($transactions.ToArray()); Warnings=@($warnings.ToArray()) }
  } catch {
    # The former inline worker kept warnings already observed even when a later
    # entry blocked discovery. Preserve that evidence without swallowing error.
    $_.Exception.Data['DataSafePendingWarnings']=@($warnings.ToArray())
    throw
  }
}

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

function Get-DataSafeAppOpaqueId([string]$Value) {
  $sha=[Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function New-DataSafeAppCapabilities {
  return [PSCustomObject]@{browse=$false;manualBackup=$false;legacyRestore=$false;manualVerify=$false;automaticRetention=$false}
}

function Get-DataSafeAppTreeEntries([string]$Root) {
  Assert-DataSafeNoReparsePath $Root
  $stack=New-Object 'System.Collections.Generic.Stack[string]'; $stack.Push($Root)
  while ($stack.Count) {
    $directory=$stack.Pop()
    foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $directory))) {
      $path=ConvertFrom-DataSafeExtendedPath $extended
      Assert-DataSafeNoReparsePath $path
      $path
      if (Test-DataSafeDirectory $path) { $stack.Push($path) }
    }
  }
}

function Assert-DataSafeAppKnownChildren([string]$Root,[string[]]$Names) {
  foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $Root))) {
    $path=ConvertFrom-DataSafeExtendedPath $extended; Assert-DataSafeNoReparsePath $path
    if ([IO.Path]::GetFileName($path) -cnotin $Names) { throw 'Unknown repository layout entry.' }
  }
}

function Get-DataSafeAppRepositoryProjection($Repository,$CurrentComputerId) {
  $repo=$Repository
  $record=[PSCustomObject]@{
    computerId=$repo.ComputerId; computerName=$repo.ComputerName
    ownedByCurrentComputer=($null -ne $CurrentComputerId -and $repo.ComputerId -ieq $CurrentComputerId)
    state='invalid';currentManifestId=$null;currentTransactionId=$null;committedAt=$null;backupCreatedAt=$null
    locations=@();capabilities=(New-DataSafeAppCapabilities)
  }
  $private=@{}; $warnings=@()
  try {
    Assert-DataSafeAppKnownChildren $repo.Root @('Latest Backup','Earlier Versions','.datasafe')
    Assert-DataSafeAppKnownChildren $repo.MetadataRoot @('repository.json','current-manifest.json','manifests','transactions','staging','operation.lock')
    $evidence=Get-DataSafePendingTransactionEvidence $repo
    # Public diagnostics contain no absolute filesystem paths.
    $warnings=@($evidence.Warnings | ForEach-Object { [PSCustomObject]@{Code=$_.Code;Message='Unpublished journal temporary retained for review.'} })
    $pointer=Read-DataSafeCurrentPointer $repo
    $manifest=$null
    if ($null -ne $pointer) {
      $manifest=Read-DataSafeManifest (Join-Path $repo.MetadataRoot $pointer.manifestPath)
      if ($manifest.sourceErrors.Count -gt 0) { throw 'Authoritative manifest contains source errors.' }
      foreach ($entry in $manifest.entries) { if (-not $entry.versionLocation.StartsWith('Latest Backup/',[StringComparison]::Ordinal)) { throw 'Authoritative manifest is not a latest tree.' } }
      $record.currentManifestId='sha256:'+$pointer.sha256
      $record.currentTransactionId=$pointer.transactionId
      $record.backupCreatedAt=$manifest.createdUtc
    }
    foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $repo.ManifestRoot))) {
      $path=ConvertFrom-DataSafeExtendedPath $extended; Assert-DataSafeNoReparsePath $path
      if ([IO.Path]::GetFileName($path) -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$' -or -not (Test-DataSafeFile $path)) { throw 'Unknown manifest entry.' }
      $null=Read-DataSafeManifest $path
    }
    $recovering=$evidence.Pending.Count -gt 0 -or (Test-DataSafeFile (Join-Path $repo.MetadataRoot operation.lock))
    if (Test-DataSafeDirectory (Join-Path $repo.MetadataRoot operation.lock)) { throw 'Operation lock is not an ordinary file.' }
    $latestPaths=Get-DataSafeTransactionTreePaths $repo $manifest
    # Committed paths have exactly one allowed type. During recovery the old
    # object can legitimately remain while the current manifest describes its
    # replacement, so retain both qualified types instead of overwriting one.
    # The qualified path helper includes structural ancestor directories too.
    foreach ($path in @($latestPaths.Keys)) { $latestPaths[$path]=@($latestPaths[$path].entryType) }
    if ($recovering) {
      foreach ($item in $evidence.Pending) {
        foreach ($candidate in @($item.Transaction.previousManifest,$item.Transaction.currentManifest)) {
          if ($null -ne $candidate) {
            $paths=Get-DataSafeTransactionTreePaths $repo $candidate
            foreach ($path in $paths.Keys) {
              $types=@($paths[$path].entryType)
              if ($latestPaths.ContainsKey($path)) { $types+=@($latestPaths[$path]) }
              $latestPaths[$path]=$types
            }
          }
        }
      }
    }
    # This is layout discovery, not an integrity verification. Do not rehash
    # user content or advertise an integrity pass. Unknown/reparse paths fail.
    foreach ($path in @(Get-DataSafeAppTreeEntries $repo.LatestRoot)) {
      if (-not $latestPaths.ContainsKey($path)) { throw 'Unknown latest-tree object.' }
      $actualType=if (Test-DataSafeDirectory $path) {'directory'} else {'file'}
      if ($actualType -cnotin $latestPaths[$path]) { throw 'Latest-tree object type changed.' }
    }
    if (-not $recovering) {
      foreach ($path in $latestPaths.Keys) {
        Assert-DataSafeNoReparsePath $path
        if (-not (Test-DataSafeFile $path) -and -not (Test-DataSafeDirectory $path)) { throw 'Latest-tree object is missing.' }
      }
    }
    $historyPaths=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $locations=New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $evidence.Transactions) {
      $tx=$item.Transaction
      foreach ($operation in $tx.operations) {
        if ($null -eq $operation.historyPath -or $tx.state -ceq 'rolledBack') { continue }
        $path=$operation.historyPath
        $historyPaths[$path]=$operation.oldEntry.entryType
        $path=[IO.Path]::GetDirectoryName($path)
        while ($path.Length -gt $repo.HistoryRoot.Length) { $historyPaths[$path]='directory'; $path=[IO.Path]::GetDirectoryName($path) }
      }
      if ($tx.state -ceq 'committed' -and $null -ne $tx.displayHistoryFolder) {
        foreach ($kind in @('previous','deleted')) {
          $category=if ($kind -ceq 'previous') {'Previous Versions'} else {'Deleted Files'}
          $path=Join-Path (Join-Path $repo.HistoryRoot $tx.displayHistoryFolder) $category
          if (Test-DataSafeDirectory $path) {
            $id=Get-DataSafeAppOpaqueId ($repo.ComputerId+'|'+$tx.transactionId+'|'+$kind)
            $locations.Add([PSCustomObject]@{locationId=$id;label=($tx.displayHistoryFolder+' - '+$category);kind=$kind;transactionId=$tx.transactionId;partial=$true})
            $private[$id]=$path
          }
        }
      }
    }
    foreach ($path in @(Get-DataSafeAppTreeEntries $repo.HistoryRoot)) {
      if (-not $historyPaths.ContainsKey($path)) { throw 'Unknown history object.' }
      if (($historyPaths[$path] -ceq 'directory') -ne (Test-DataSafeDirectory $path)) { throw 'History object type changed.' }
    }
    $transactionIds=@($evidence.Transactions | ForEach-Object { $_.Transaction.transactionId })
    foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $repo.StagingRoot))) {
      $path=ConvertFrom-DataSafeExtendedPath $extended; Assert-DataSafeNoReparsePath $path
      if ([IO.Path]::GetFileName($path) -cnotin $transactionIds) { throw 'Unknown staging object.' }
      if (Test-DataSafeDirectory $path) { $null=@(Get-DataSafeAppTreeEntries $path) }
    }
    if ($null -eq $pointer -and -not $recovering -and (@($evidence.Transactions | Where-Object {$_.Transaction.state -ceq 'committed'}).Count -gt 0 -or $historyPaths.Count -gt 0 -or @([IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $repo.ManifestRoot))).Count -gt 0)) { throw 'Populated repository has no authoritative pointer.' }
    $record.state=if ($recovering) {'recovery-required'} elseif ($null -eq $pointer) {'empty'} else {'committed'}
    if ($record.state -ceq 'committed') {
      $id=Get-DataSafeAppOpaqueId ($repo.ComputerId+'|'+$pointer.transactionId+'|'+$pointer.sha256+'|latest')
      $record.locations=@([PSCustomObject]@{locationId=$id;label='Latest Backup';kind='latest';transactionId=$pointer.transactionId;partial=$false})+@($locations.ToArray())
      $private[$id]=$repo.LatestRoot
      $record.capabilities.browse=$true
    }
    $record.capabilities.manualBackup=$record.ownedByCurrentComputer
    # Recheck commit identity after enumeration; a concurrent writer is not a
    # coherent catalog snapshot and cannot authorize a browse operation.
    $after=Read-DataSafeCurrentPointer $repo
    if ((ConvertTo-Json $after -Compress) -cne (ConvertTo-Json $pointer -Compress)) { throw 'Commit changed during discovery.' }
  } catch {
    if ($_.Exception.Data.Contains('DataSafePendingWarnings')) {
      $warnings+=@($_.Exception.Data['DataSafePendingWarnings'] | ForEach-Object { [PSCustomObject]@{Code=$_.Code;Message='Unpublished journal temporary retained for review.'} })
    }
    $record.state='invalid'; $record.locations=@(); $private=@{}; $record.capabilities=New-DataSafeAppCapabilities
    $warnings+=@([PSCustomObject]@{Code='InvalidRepository';Message='Repository metadata or layout requires attention.'})
  }
  return [PSCustomObject]@{Record=$record;Locations=$private;Warnings=@($warnings)}
}

function Get-DataSafeAppCatalog($Config,[string]$ConfigPath) {
  $catalog=[PSCustomObject]@{
    schema='datasafe.app-catalog';formatVersion=1;destinationId=$null;backupFormatVersion=$null
    connection='disconnected';volumeMatch=$null;state='invalid';checkedAtUtc=[datetime]::UtcNow.ToString('o');lastKnown=$false
    currentComputerId=$null;latestCommittedAt=$null;latestBackupCreatedAt=$null;repositories=@();legacySnapshots=@();warnings=@()
  }
  $private=@{}; $driveRoot=$null
  try {
    $destination=Get-DataSafeAppDestinationRecord $Config
    $catalog.backupFormatVersion=Get-DataSafeBackupFormat $Config
    $catalog.destinationId=Get-DataSafeProperty $destination 'id'
    $driveRoot=Resolve-DataSafeDestination $destination
    Assert-DataSafeNoReparsePath $driveRoot
    if (-not (Test-DataSafeDirectory $driveRoot)) { $catalog.state='disconnected'; return [PSCustomObject]@{Catalog=$catalog;Locations=$private;DriveRoot=$driveRoot} }
    $catalog.connection='connected'
    $actualVolume=Get-DataSafeAppVolumeUniqueId $driveRoot
    $binding=$null
    if ($null -ne $destination.PSObject.Properties['volumeUniqueId']) { $binding=$destination.PSObject.Properties['volumeUniqueId'].Value }
    $catalog.volumeMatch=($binding -is [string] -and $binding -ieq $actualVolume)
    if ($catalog.backupFormatVersion -eq 2) { Assert-DataSafeAppDestination $Config $actualVolume $true }
    $identityPath=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))) incremental-computer-id.json
    Assert-DataSafeNoReparsePath $identityPath
    if (Test-DataSafeDirectory $identityPath) { throw 'Identity path is not an ordinary file.' }
    if (Test-DataSafeFile $identityPath) {
      $identity=Read-DataSafeRepositoryJson $identityPath; Assert-DataSafeIdentitySchema $identity 1
      $catalog.currentComputerId=$identity.computerId
    }
    $baseRoot=Join-Path $driveRoot 'DataSafe Backups'; Assert-DataSafeNoReparsePath $baseRoot
    if (Test-DataSafeFile $baseRoot) { throw 'Repository base is not a directory.' }
    $records=New-Object 'System.Collections.Generic.List[object]'
    if (Test-DataSafeDirectory $baseRoot) {
      foreach ($extended in [IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $baseRoot))) {
        $path=ConvertFrom-DataSafeExtendedPath $extended
        try {
          Assert-DataSafeNoReparsePath $path
          if (-not (Test-DataSafeDirectory $path)) { throw 'Unknown repository entry.' }
          $repo=Read-DataSafeRepository $path
          $projection=Get-DataSafeAppRepositoryProjection $repo $catalog.currentComputerId
          $records.Add($projection.Record); $catalog.repositories=@($records.ToArray())
          $catalog.warnings+=@($projection.Warnings)
          foreach ($id in $projection.Locations.Keys) { $private[$id]=[PSCustomObject]@{ComputerId=$repo.ComputerId;Path=$projection.Locations[$id]} }
        } catch {
          $records.Add([PSCustomObject]@{computerId=$null;computerName=[IO.Path]::GetFileName($path);ownedByCurrentComputer=$false;state='invalid';currentManifestId=$null;currentTransactionId=$null;committedAt=$null;backupCreatedAt=$null;locations=@();capabilities=(New-DataSafeAppCapabilities)})
          $catalog.repositories=@($records.ToArray()); $catalog.warnings+=@([PSCustomObject]@{Code='InvalidRepository';Message='Unknown or invalid repository entry requires attention.'})
        }
      }
    }
    $duplicates=@($catalog.repositories | Where-Object {$null -ne $_.computerId} | Group-Object computerId | Where-Object {$_.Count -gt 1})
    foreach ($group in $duplicates) { foreach ($record in $group.Group) { $record.state='invalid' } }
    $catalog.state=if (@($catalog.repositories | Where-Object {$_.state -ceq 'invalid'}).Count) {'invalid'} elseif ($null -eq $catalog.currentComputerId) {'identity-missing'} elseif (@($catalog.repositories | Where-Object {$_.state -ceq 'recovery-required'}).Count) {'recovery-required'} elseif (@($catalog.repositories | Where-Object {$_.state -ceq 'committed'}).Count) {'committed'} else {'empty'}
    if ($catalog.state -ceq 'invalid') { foreach ($r in $catalog.repositories) { $r.capabilities=New-DataSafeAppCapabilities }; $private=@{} }
    if ($catalog.volumeMatch -ne $true) {
      foreach ($r in $catalog.repositories) { $r.capabilities=New-DataSafeAppCapabilities }
      $private=@{}
      $catalog.warnings+=@([PSCustomObject]@{Code='UnboundVolume';Message='Diagnostic catalog only: this destination has no matching Windows volume binding.'})
    }
    $created=@($catalog.repositories | Where-Object {$null -ne $_.backupCreatedAt} | Sort-Object backupCreatedAt -Descending)
    if ($created.Count) { $catalog.latestBackupCreatedAt=$created[0].backupCreatedAt }
  } catch {
    $catalog.state='invalid'; $private=@{}
    foreach ($record in $catalog.repositories) { $record.capabilities=New-DataSafeAppCapabilities }
    $catalog.warnings+=@([PSCustomObject]@{Code='InvalidCatalog';Message='Destination identity, policy or layout requires attention.'})
  }
  return [PSCustomObject]@{Catalog=$catalog;Locations=$private;DriveRoot=$driveRoot}
}

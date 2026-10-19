Set-StrictMode -Version Latest
$script:AppFixtureRoots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
function New-AppFixture([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows')) {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-app-' + [guid]::NewGuid().ToString('N'))
  $null = $script:AppFixtureRoots.Add([IO.Path]::GetFullPath($root))
  $bin=Join-Path $root bin; $source=Join-Path $root source; $destination=Join-Path $root drive
  foreach ($path in @($root,$bin,$source,$destination)) { $null=[IO.Directory]::CreateDirectory($path) }
  foreach ($name in @('DataSafe.Safety.ps1','DataSafe.Repository.ps1','DataSafe.Manifest.ps1','DataSafe.IncrementalPlan.ps1','DataSafe.Transaction.ps1','DataSafe.AppIntegration.ps1','backup-engine.ps1','inspect-backup-catalog.ps1','restore-snapshot.ps1')) {
    if (Test-Path -LiteralPath (Join-Path $WindowsRoot $name)) { [IO.File]::Copy((Join-Path $WindowsRoot $name),(Join-Path $bin $name)) }
  }
  $safety=Join-Path $bin 'DataSafe.Safety.ps1'
  [IO.File]::AppendAllText($safety,"`nfunction Resolve-DataSafeDestination(`$Destination) { return '$($destination.Replace("'","''"))' }`n")
  $app=Join-Path $bin 'DataSafe.AppIntegration.ps1'
  [IO.File]::AppendAllText($app,"`nfunction Get-DataSafeAppVolumeUniqueId([string]`$ResolvedPath) { return [IO.File]::ReadAllText('$((Join-Path $root volume.txt).Replace("'","''"))') }`n")
  [IO.File]::WriteAllText((Join-Path $root volume.txt),'fixture-volume')
  foreach ($name in @('a','b','c','d')) { [IO.File]::WriteAllText((Join-Path $source "$name.txt"),"original-$name") }
  $config=[PSCustomObject]@{computerName='Catalog PC';destination=[PSCustomObject]@{id=[guid]::NewGuid().ToString('D');mode='letter';driveLetter='unused';baseFolder='Legacy';backupFormatVersion=2;volumeUniqueId='fixture-volume';manualBetaConfirmedAt='2026-10-19T01:02:03.000Z'};jobs=@([PSCustomObject]@{id='docs';name='Docs';type='folder';path=$source;enabled=$true;relativeDestination=@('Docs')})}
  $f=[PSCustomObject]@{Root=$root;Bin=$bin;Source=$source;Destination=$destination;Config=$config;ConfigPath=(Join-Path $root config.json);StatusPath=(Join-Path $root status.json)}
  Write-DataSafeJson $f.ConfigPath $config; Write-DataSafeJson $f.StatusPath ([PSCustomObject]@{ sentinel='unchanged' })
  return $f
}
function Remove-AppFixture($Fixture) {
  $root=[IO.Path]::GetFullPath($Fixture.Root)
  if (-not $script:AppFixtureRoots.Contains($root) -or [IO.Path]::GetDirectoryName($root).TrimEnd('\') -ine [IO.Path]::GetTempPath().TrimEnd('\') -or [IO.Path]::GetFileName($root) -cnotmatch '^datasafe-app-[0-9a-f]{32}$') { throw 'Refusing unowned fixture cleanup.' }
  foreach ($name in @('Bin','Source','Destination','ConfigPath','StatusPath')) {
    if (-not [IO.Path]::GetFullPath($Fixture.$name).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup target escaped its recorded root.' }
  }
  Remove-DataSafeDirectoryTree $root
  $null=$script:AppFixtureRoots.Remove($root)
}
function Get-AppFixtureInventory($Fixture) {
  $rows=New-Object 'System.Collections.Generic.List[string]'
  $todo=New-Object 'System.Collections.Generic.Stack[string]'; $todo.Push($Fixture.Root)
  while ($todo.Count) {
    foreach ($path in [IO.Directory]::GetFileSystemEntries($todo.Pop())) {
      $attributes=[IO.File]::GetAttributes($path); $relative=$path.Substring($Fixture.Root.Length)
      if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $rows.Add("R|$relative"); continue }
      if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $rows.Add("D|$relative"); $todo.Push($path) }
      else { $rows.Add("F|$relative|$(Get-DataSafeSha256 $path)") }
    }
  }
  return (@($rows | Sort-Object) -join "`n")
}
function Invoke-AppCatalog($Fixture,[string]$Action='Inspect',[string]$ComputerId='',[string]$LocationId='',[int]$ExpectedExit=0) {
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=(Get-Process -Id $PID).Path; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
  $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -StatusPath "{2}" -Action {3}' -f (Join-Path $Fixture.Bin 'inspect-backup-catalog.ps1'),$Fixture.ConfigPath,$Fixture.StatusPath,$Action
  if ($ComputerId) { $start.Arguments+=' -ComputerId "'+$ComputerId+'"' }; if ($LocationId) { $start.Arguments+=' -LocationId "'+$LocationId+'"' }
  $p=[Diagnostics.Process]::Start($start); $stdout=$p.StandardOutput.ReadToEnd(); $stderr=$p.StandardError.ReadToEnd(); $p.WaitForExit()
  if ($p.ExitCode -ne $ExpectedExit) { throw "Catalog exit $($p.ExitCode), expected $ExpectedExit : $stderr $stdout" }
  $markers=@($stdout -split '\r?\n' | Where-Object { $_.StartsWith('__OB_RESULT__:') })
  if ($markers.Count -ne 1) { throw "Expected exactly one result marker: $stdout $stderr" }
  $json=$markers[0].Substring('__OB_RESULT__:'.Length)
  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json $json -DateKind String }
  return ConvertFrom-Json $json
}

# These helpers are used only in fresh fixture processes. No production module
# gains a fault switch or alternate volume provider.
function Assert-AppFixtureRoot([string]$Root) {
  $full=[IO.Path]::GetFullPath($Root)
  if ([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine [IO.Path]::GetTempPath().TrimEnd('\') -or [IO.Path]::GetFileName($full) -cnotmatch '^datasafe-app-[0-9a-f]{32}$') { throw 'Not a GUID-owned app fixture.' }
  Assert-DataSafeNoReparsePath $full
  return $full
}
function Read-AppFixtureAuthority([string]$Root) {
  $root=Assert-AppFixtureRoot $Root
  $repositories=@([IO.Directory]::GetDirectories((Join-Path $root 'drive/DataSafe Backups')))
  if ($repositories.Count -ne 1) { throw 'Expected exactly one fixture repository.' }
  $repo=Read-DataSafeRepository $repositories[0]
  $pointer=Read-DataSafeCurrentPointer $repo
  if ($null -eq $pointer) { throw 'No committed fixture authority.' }
  $manifest=Read-DataSafeManifest (Join-Path $repo.MetadataRoot $pointer.manifestPath)
  Assert-DataSafeTransactionTree $repo $manifest -Metadata
  return [PSCustomObject]@{repository=$repo;pointer=$pointer;manifest=$manifest}
}
function Invoke-AppFixtureInterruption([string]$Root,[ValidateSet('warning','rollback')][string]$Mode) {
  $root=Assert-AppFixtureRoot $Root
  $authority=Read-AppFixtureAuthority $root; $repo=$authority.repository
  $source=Join-Path $root source
  [IO.File]::WriteAllText((Join-Path $source a.txt),('interrupted-'+$Mode+'-new-bytes'))
  $manifest=New-DataSafeSourceManifest @([PSCustomObject]@{id='docs';path=$source;relativeDestination=@('Docs')})
  $plan=New-DataSafeIncrementalPlan $repo $authority.manifest $manifest (Get-DataSafeDestinationCapabilities $repo.Root) (Get-DataSafeFreeBytes $repo.Root)
  if ($plan.BlockingErrors.Count -or $plan.DeletionReviewRequired) { throw 'Interruption fixture plan blocked.' }
  $tx=New-DataSafeTransaction $repo $plan; $owner=Get-DataSafeTransactionOwner $tx; $handle=$null
  try {
    $null=Stage-DataSafeTransaction $tx
    if ($Mode -ceq 'warning') {
      $stopped=$false
      try { $null=Invoke-DataSafeTransaction $tx { param($boundary) if ($boundary.Phase -ceq 'pointer') { throw 'app fixture interrupted after pointer' } } }
      catch { if ($_.Exception.Message -notmatch 'app fixture interrupted after pointer') { throw }; $stopped=$true }
      if (-not $stopped) { throw 'Pointer interruption boundary was not reached.' }
      # Keep the real readable applying journal but prevent its atomic rename.
      # Windows sharing rules force qualified JournalFinalizationFailed recovery.
      $handle=[IO.File]::Open((Join-Path $repo.TransactionRoot ($tx.transactionId+'.json')),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    } else {
      # Reach the real archive mutation before durable rollback intent. Recovery
      # must restore prior authority while leaving journal-owned history residue.
      $stopped=$false
      try { $null=Invoke-DataSafeTransaction $tx { param($boundary) if ($boundary.Phase -ceq 'archived') { throw 'app fixture interrupted after archive' } } }
      catch { if ($_.Exception.Message -notmatch 'app fixture interrupted after archive') { throw }; $stopped=$true }
      if (-not $stopped) { throw 'Archive interruption boundary was not reached.' }
      Set-DataSafeTransactionState $tx rollingBack
    }
    if ($null -ne $owner.Handle) { Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath); $owner.Handle=$null }
    Write-DataSafeJson (Join-Path $root 'fault-ready.json') ([PSCustomObject]@{transactionId=$tx.transactionId;mode=$Mode})
    if ($Mode -ceq 'warning') {
      $deadline=[DateTime]::UtcNow.AddSeconds(120)
      while (-not [IO.File]::Exists((Join-Path $root 'fault-release'))) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Fixture fault release timed out.' }
        Start-Sleep -Milliseconds 50
      }
    }
  } finally {
    if ($null -ne $handle) { $handle.Dispose() }
    if ($null -ne $owner.Handle) { Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath); $owner.Handle=$null }
  }
}

<#
Disposable packaged-worker qualification, Windows PowerShell 5.1.
Each supplied root must already exist; only a new GUID child is written/deleted.
No formatting, task registration, installed configuration or existing backup use.
#>
param(
  [string]$NtfsRoot = ([IO.Path]::GetTempPath()),
  [string]$ExFatRoot,
  [string]$Fat32Root,
  [string]$PackagedWindowsRoot = (Join-Path $PSScriptRoot '../../dist/win-unpacked/resources/windows'),
  [string]$SourceWindowsRoot = (Join-Path $PSScriptRoot '../../windows'),
  [string]$ResultPath,
  [switch]$KeepArtifacts,
  [switch]$ManualDisconnect
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows-only qualification.' }
$PackagedWindowsRoot = [IO.Path]::GetFullPath($PackagedWindowsRoot)
$SourceWindowsRoot = [IO.Path]::GetFullPath($SourceWindowsRoot)
. (Join-Path $PackagedWindowsRoot 'DataSafe.Transaction.ps1')
$rows = New-Object 'System.Collections.Generic.List[object]'
$owned = New-Object 'System.Collections.Generic.List[string]'
$hashes = New-Object 'System.Collections.Generic.List[object]'
$mediaInventory = New-Object 'System.Collections.Generic.List[object]'
$runId = [guid]::NewGuid().ToString('N')
$control = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-media-' + $runId)
$allPassed = $false
$unresolvedLaunch = $null
function Assert-Matrix([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Add-Result([string]$Fs, [string]$Case, [string]$Result, [string]$Evidence) {
  $rows.Add([PSCustomObject]@{FileSystem=$Fs;Case=$Case;Result=$Result;Evidence=$Evidence})
  Write-Host "$Result : $Fs : $Case : $Evidence"
}
function Test-Matrix([string]$Fs, [string]$Name, [scriptblock]$Action) {
  try { & $Action; Add-Result $Fs $Name 'PASS' 'Assertions passed.' }
  catch { Add-Result $Fs $Name 'FAIL' $_.Exception.Message; throw }
}
function New-OwnedRoot([string]$Base, [string]$Leaf) {
  $basePath = [IO.Path]::GetFullPath($Base)
  Assert-DataSafeNoReparsePath $basePath
  Assert-Matrix (Test-DataSafeDirectory $basePath) 'Disposable parent must already exist.'
  $path = Join-Path $basePath $Leaf
  Assert-Matrix (-not (Test-DataSafeDirectory $path) -and -not (Test-DataSafeFile $path)) 'GUID fixture already exists.'
  Ensure-DataSafeDirectory $path
  $owned.Add($path)
  return $path
}
function Write-Fixture([string]$Path, [string]$Text) {
  Assert-DataSafeNoReparsePath $Path
  Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Path))
  [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $Path), $Text)
}
function Assert-Clean($Repository) {
  Assert-Matrix (-not (Test-DataSafeFile (Join-Path $Repository.MetadataRoot 'operation.lock'))) 'Repository lock remains.'
  Assert-Matrix (@([IO.Directory]::GetFileSystemEntries((ConvertTo-DataSafeExtendedPath $Repository.StagingRoot))).Count -eq 0) 'Per-transaction staging remains.'
}
function Assert-Latest($Fixture, $Repository) {
  # Independent literal/content expectations, not the persisted manifest as oracle.
  $expected = @{}
  foreach ($name in @('a','b','c','d')) {
    if ($name -eq 'b' -and $Fixture.Deleted) { continue }
    $expected["$name.txt"] = $(if ($name -eq 'a' -and $Fixture.Changed) {'changed-a-longer'} else {"original-$name"})
  }
  if ($Fixture.LongRelative) { $expected[$Fixture.LongRelative] = 'long-path-payload' }
  $root = Join-Path $Repository.LatestRoot 'Personal/Documents'
  $actual = @(Get-DataSafeFileEntries $Repository.LatestRoot)
  Assert-Matrix ($actual.Count -eq $expected.Count) 'Latest file count differs from independent expected tree.'
  foreach ($relative in $expected.Keys) {
    $file = ConvertTo-DataSafeExtendedPath (Join-Path $root $relative)
    Assert-Matrix ([IO.File]::ReadAllText($file) -ceq $expected[$relative]) "Latest content differs: $relative"
  }
  Assert-Clean $Repository
  Assert-Matrix (-not (Test-DataSafeFile ($Fixture.StatusPath + '.lock'))) 'Worker status lock remains.'
}
function Invoke-PackagedWorker($Fixture, [int]$ExpectedExit = 0) {
  Write-DataSafeJson $Fixture.ConfigPath $Fixture.Config
  # The packaged VBS is unmodified and owns the real hidden PowerShell launch.
  $arguments = '//B //NoLogo "{0}" "{1}" -ConfigPath "{2}" -StatusPath "{3}" -AllowNewDestination' -f (Join-Path $Fixture.Bin 'DataSafeTaskRunner.vbs'), (Join-Path $Fixture.Bin 'backup-engine.ps1'), $Fixture.ConfigPath, $Fixture.StatusPath
  # Fail closed until this owned launch is proven finished. A failed process
  # start/wait/termination must never authorize cleanup under a possible writer.
  $script:unresolvedLaunch = [PSCustomObject]@{LauncherProcessId=$null;FixtureRoot=$Fixture.Root;DestinationRoot=$Fixture.Drive;Reason='Owned launch completion has not been confirmed.'}
  $p = Start-Process (Join-Path $env:SystemRoot 'System32/wscript.exe') -WindowStyle Hidden -ArgumentList $arguments -PassThru
  $script:unresolvedLaunch.LauncherProcessId = $p.Id
  if (-not $p.WaitForExit(180000)) {
    # Stop this owned launch tree, not just WScript while its worker keeps writing.
    try {
      $kill = Start-Process (Join-Path $env:SystemRoot 'System32/taskkill.exe') -WindowStyle Hidden -ArgumentList ('/PID {0} /T /F' -f $p.Id) -Wait -PassThru -RedirectStandardOutput (Join-Path $Fixture.Root 'timeout-out.txt') -RedirectStandardError (Join-Path $Fixture.Root 'timeout-err.txt')
      if ($kill.ExitCode -ne 0) { throw "Owned tree termination exit $($kill.ExitCode)." }
      if (-not $p.WaitForExit(10000)) { throw 'Owned launcher exit was not confirmed after tree termination.' }
    } catch {
      $script:unresolvedLaunch.Reason = "Timeout termination unconfirmed: $($_.Exception.Message)"
      throw ($script:unresolvedLaunch.Reason + ' Manual process inspection required; fixture cleanup is blocked.')
    }
    $script:unresolvedLaunch = $null
    throw 'Packaged launcher timed out; owned worker tree was stopped.'
  }
  $script:unresolvedLaunch = $null
  $p.Refresh()
  $s = Read-DataSafeJson $Fixture.StatusPath
  Assert-Matrix ($p.ExitCode -eq $ExpectedExit) "Packaged launcher exit $($p.ExitCode), expected $ExpectedExit : $($s.lastBackupMessage)"
  Assert-Matrix ($s.backupFormatVersion -eq 2) 'Worker did not route internal v2.'
  if ($ExpectedExit -eq 0) { Assert-Matrix ($s.lastBackupResult -ceq 'success') "Worker warning/failure: $($s.lastBackupMessage)" }
  return $s
}
function New-MediaFixture([string]$Fs, [string]$Destination) {
  $root = New-OwnedRoot $control ($Fs + '-' + [guid]::NewGuid().ToString('N'))
  $source = Join-Path $root 'source'
  foreach ($name in @('a','b','c','d')) { Write-Fixture (Join-Path $source "$name.txt") "original-$name" }
  $bin = Join-Path $root 'windows'; Ensure-DataSafeDirectory $bin
  foreach ($h in $hashes) {
    $copy = Join-Path $bin $h.File
    [IO.File]::Copy((ConvertTo-DataSafeExtendedPath (Join-Path $PackagedWindowsRoot $h.File)), (ConvertTo-DataSafeExtendedPath $copy))
    Assert-Matrix ((Get-DataSafeSha256 $copy) -ceq $h.Sha256) "Package changed while snapshotting fixture: $($h.File)"
  }
  # ONLY destination resolution is redirected in a disposable copy of Safety.
  # Actual filesystem detection, space, identities, scan, copy and recovery remain real.
  $path = Join-Path $bin 'DataSafe.Safety.ps1'
  Write-Fixture $path ([IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $path)) + "`nfunction Resolve-DataSafeDestination(`$Destination) { return '$($Destination.Replace("'","''"))' }`n")
  $config = [PSCustomObject]@{
    computerName='Media Test PC'; installId=[guid]::NewGuid().ToString('D'); incrementalFormatVersion=2
    destination=[PSCustomObject]@{mode='letter';driveLetter='unused';baseFolder='Unused Legacy';id=[guid]::NewGuid().ToString('D')}
    jobs=@([PSCustomObject]@{id='docs';name='Documents';type='folder';enabled=$true;path=$source;relativeDestination=@('Personal','Documents')})
  }
  $f = [PSCustomObject]@{Root=$root;Source=$source;Drive=$Destination;Bin=$bin;Config=$config;ConfigPath=(Join-Path $root 'config.json');StatusPath=(Join-Path $root 'status.json');Changed=$false;Deleted=$false;LongRelative=$null}
  Write-DataSafeJson $f.StatusPath ([PSCustomObject]@{lastBackupAt=$null;lastBackupResult=$null;lastBackupMessage='';destinationStatus='Unknown';recentSnapshots=@()})
  return $f
}
function Get-MediaRepository($Fixture) {
  $roots = @([IO.Directory]::GetDirectories((ConvertTo-DataSafeExtendedPath (Join-Path $Fixture.Drive 'DataSafe Backups'))))
  Assert-Matrix ($roots.Count -eq 1) 'Expected exactly one repository in disposable destination.'
  return Read-DataSafeRepository (ConvertFrom-DataSafeExtendedPath $roots[0])
}
function Test-Fat32Candidate($Repository, $Capabilities, [string]$Source) {
  $pointerPath = Join-Path $Repository.MetadataRoot 'current-manifest.json'
  $before = Get-DataSafeSha256 $pointerPath
  $treeBefore = @(Get-DataSafeFileEntries $Repository.LatestRoot | ForEach-Object { (Get-DataSafeSha256 $_.FullName) }) -join ','
  $pointer = Read-DataSafeCurrentPointer $Repository
  $old = Read-DataSafeManifest (Join-Path $Repository.MetadataRoot $pointer.manifestPath)
  $candidate = New-DataSafeSourceManifest @([PSCustomObject]@{id='docs';path=$Source;relativeDestination=@('Personal','Documents')})
  $entry = @($candidate.entries | Where-Object { $_.entryType -ceq 'file' })[0]
  $entry.length = [long]4294967297; $entry.sha256 = 'B' * 64
  $plan = New-DataSafeIncrementalPlan $Repository $old $candidate $Capabilities (Get-DataSafeFreeBytes $Repository.Root)
  Assert-Matrix (($plan.BlockingErrors -join '|') -match 'Filesystem file limit exceeded') 'Oversize candidate lacks FAT32 preflight diagnostic.'
  Assert-Matrix ($plan.Operations.Count -eq 0) 'Blocked plan retained executable operations.'
  $rejected = $false
  try { $null = New-DataSafeTransaction $Repository $plan } catch { $rejected = $_.Exception.Message -match 'blocked|review' }
  Assert-Matrix $rejected 'Blocked plan was accepted for mutation.'
  Assert-Matrix ((Get-DataSafeSha256 $pointerPath) -ceq $before) 'Oversize preflight changed pointer.'
  $treeAfter = @(Get-DataSafeFileEntries $Repository.LatestRoot | ForEach-Object { (Get-DataSafeSha256 $_.FullName) }) -join ','
  Assert-Matrix ($treeAfter -ceq $treeBefore) 'Oversize preflight changed Latest content.'
  Assert-Clean $Repository
}
try {
  # Refuse stale/mixed packages before creating any fixture.
  foreach ($file in @('backup-engine.ps1','DataSafe.Safety.ps1','DataSafe.Repository.ps1','DataSafe.Manifest.ps1','DataSafe.IncrementalPlan.ps1','DataSafe.Transaction.ps1','DataSafeTaskRunner.vbs')) {
    $sourceHash = Get-DataSafeSha256 (Join-Path $SourceWindowsRoot $file)
    $packageHash = Get-DataSafeSha256 (Join-Path $PackagedWindowsRoot $file)
    Assert-Matrix ($sourceHash -ceq $packageHash) "Package/source mismatch: $file"
    $hashes.Add([PSCustomObject]@{File=$file;Sha256=$packageHash;SourceMatch=$true})
  }
  Add-Result 'package' 'seven packaged worker/launcher hashes match source' 'PASS' 'Before disposable Safety resolver shim; all other copied bytes unchanged.'
  $null = New-OwnedRoot ([IO.Path]::GetTempPath()) ('datasafe-media-' + $runId)
  foreach ($media in @(@{Fs='NTFS';Base=$NtfsRoot}, @{Fs='exFAT';Base=$ExFatRoot}, @{Fs='FAT32';Base=$Fat32Root})) {
    $fs = $media.Fs; $destination = $null
    if ([string]::IsNullOrWhiteSpace($media.Base)) { Add-Result $fs 'real media matrix' 'NOT RUN' 'No disposable root supplied.'; continue }
    # A supplied unavailable/wrong filesystem is a configuration failure, not a pass/skip.
    try {
      $cap = Get-DataSafeDestinationCapabilities $media.Base
      Assert-Matrix ($cap.FileSystem -ieq $fs) "Expected $fs; actual $($cap.FileSystem)."
      $destination = New-OwnedRoot $media.Base ('datasafe-media-' + $runId + '-' + $fs)
      $f = New-MediaFixture $fs $destination
      $sourceCap = Get-DataSafeDestinationCapabilities $f.Source
      $mediaInventory.Add([PSCustomObject]@{DestinationFileSystem=$cap.FileSystem;SourceFileSystem=$sourceCap.FileSystem;TotalBytes=$cap.TotalBytes;FreeBytes=(Get-DataSafeFreeBytes $destination)})
      $repo = $null
      Test-Matrix $fs 'initial ordinary complete Latest' {
        $s = Invoke-PackagedWorker $f
        Assert-Matrix ($s.copyBytes -eq 40) 'Initial copy byte count incorrect.'
        $script:repo = Get-MediaRepository $f
        Assert-Latest $f $repo
        Assert-Matrix (@(Get-DataSafeFileEntries $repo.HistoryRoot).Count -eq 0) 'Initial backup invented history.'
      }
      Test-Matrix $fs 'unchanged zero user-file bytes' {
        $s = Invoke-PackagedWorker $f
        Assert-Matrix ($s.copyBytes -eq 0) 'Unchanged run copied user-file bytes.'
        Assert-Latest $f $repo
      }
      Test-Matrix $fs 'changed file with ordinary previous version' {
        Write-Fixture (Join-Path $f.Source 'a.txt') 'changed-a-longer'; $f.Changed=$true
        $s = Invoke-PackagedWorker $f
        Assert-Matrix ($s.copyBytes -eq 16) 'Changed-file copy bytes incorrect.'
        Assert-Latest $f $repo
        $history = @(Get-DataSafeFileEntries $repo.HistoryRoot)
        Assert-Matrix ($history.Count -eq 1 -and $history[0].FullName -match 'Previous Versions' -and [IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $history[0].FullName)) -ceq 'original-a') 'Ordinary previous content missing.'
      }
      Test-Matrix $fs 'deleted file with ordinary deleted history' {
        [IO.File]::Delete((ConvertTo-DataSafeExtendedPath (Join-Path $f.Source 'b.txt'))); $f.Deleted=$true
        $s = Invoke-PackagedWorker $f
        Assert-Matrix ($s.copyBytes -eq 0) 'Deletion copied user-file bytes.'
        Assert-Latest $f $repo
        $deleted = @(Get-DataSafeFileEntries $repo.HistoryRoot | Where-Object { $_.FullName -match 'Deleted Files' })
        Assert-Matrix ($deleted.Count -eq 1 -and [IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $deleted[0].FullName)) -ceq 'original-b') 'Ordinary deleted history missing.'
        Assert-Matrix (@(Get-DataSafeFileEntries $repo.HistoryRoot).Count -eq 2) 'Unexpected history count.'
      }
      Test-Matrix $fs 'logical unavailable destination and reconnect (not physical)' {
        $pointerPath = Join-Path $repo.MetadataRoot 'current-manifest.json'; $before=Get-DataSafeSha256 $pointerPath
        $offline = $destination + '-offline'
        [IO.Directory]::Move((ConvertTo-DataSafeExtendedPath $destination), (ConvertTo-DataSafeExtendedPath $offline))
        $owned.Add($offline)
        try { $null=Invoke-PackagedWorker $f 1 }
        finally {
          if ($null -eq $unresolvedLaunch) {
            [IO.Directory]::Move((ConvertTo-DataSafeExtendedPath $offline), (ConvertTo-DataSafeExtendedPath $destination))
            [void]$owned.Remove($offline)
          }
        }
        Assert-Matrix ((Get-DataSafeSha256 $pointerPath) -ceq $before) 'Unavailable destination changed authority.'
        Assert-Latest $f $repo
        $s=Invoke-PackagedWorker $f
        Assert-Matrix ($s.copyBytes -eq 0) 'Reconnect copied unchanged user bytes.'
        Assert-Latest $f $repo
      }
      Test-Matrix $fs 'long source Latest and history paths' {
        $relative = 'deep'
        while ((Join-Path $f.Source ($relative + '/payload.txt')).Length -lt 290) { $relative += '/segment-' + ('x' * 30) }
        $f.LongRelative = $relative + '/payload.txt'
        Write-Fixture (Join-Path $f.Source $f.LongRelative) 'long-path-original'
        $null=Invoke-PackagedWorker $f
        Write-Fixture (Join-Path $f.Source $f.LongRelative) 'long-path-payload'
        $null=Invoke-PackagedWorker $f
        Assert-Latest $f $repo
        $longHistory = @(Get-DataSafeFileEntries $repo.HistoryRoot | Where-Object { $_.FullName.EndsWith('payload.txt') })
        Assert-Matrix ($longHistory.Count -eq 1 -and $longHistory[0].FullName.Length -gt 260 -and [IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $longHistory[0].FullName)) -ceq 'long-path-original') 'Long-path ordinary history missing.'
        $s=Invoke-PackagedWorker $f
        Assert-Matrix ($s.copyBytes -eq 0) 'Unchanged long-path run copied bytes.'
        Assert-Latest $f $repo
      }
      if ($fs -ieq 'FAT32') {
        Test-Matrix $fs 'compatibility mode and validated oversize schema candidate (no large file)' {
          Assert-Matrix $cap.CompatibilityMode 'Actual FAT32 destination did not report compatibility mode.'
          Test-Fat32Candidate $repo $cap $f.Source
        }
      } elseif ($fs -ieq 'NTFS') {
        Test-Matrix 'schema only / not FAT32 media' 'FAT32 oversize preflight candidate on NTFS fixture' {
          $schemaCap=Get-DataSafeFilesystemCapabilities 'FAT32'; $schemaCap | Add-Member TotalBytes $cap.TotalBytes
          Test-Fat32Candidate $repo $schemaCap $f.Source
        }
      }
      $driveInfo = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($destination))
      if ($ManualDisconnect -and $driveInfo.DriveType -eq [IO.DriveType]::Removable) {
        $pointerPath=Join-Path $repo.MetadataRoot 'current-manifest.json'; $before=Get-DataSafeSha256 $pointerPath
        $null=Read-Host "Disconnect ONLY the disposable $fs medium; press Enter when absent"
        Test-Matrix $fs 'operator physical disconnect and reconnect between runs' {
          Assert-Matrix (-not (Test-DataSafeDirectory $destination)) 'Medium remains available; not a physical disconnect test.'
          $null=Invoke-PackagedWorker $f 1
          $null=Read-Host 'Reconnect the same medium at the same letter; press Enter when ready'
          Assert-Matrix ((Get-DataSafeSha256 $pointerPath) -ceq $before) 'Physical reconnect changed pointer.'
          Assert-Latest $f $repo
          $s=Invoke-PackagedWorker $f
          Assert-Matrix ($s.copyBytes -eq 0) 'Physical reconnect copied unchanged bytes.'
          Assert-Latest $f $repo
        }
      } else { Add-Result $fs 'physical disconnect/reconnect' 'NOT RUN' 'Requires -ManualDisconnect and a disposable removable volume; logical rename is not physical evidence.' }
      Test-Matrix $fs 'same friendly name independent computer UUID' {
        $before = Get-DataSafeSha256 (Join-Path $repo.MetadataRoot 'current-manifest.json')
        $other = New-MediaFixture $fs $destination
        $null = Invoke-PackagedWorker $other
        $roots = @([IO.Directory]::GetDirectories((ConvertTo-DataSafeExtendedPath (Join-Path $destination 'DataSafe Backups'))))
        Assert-Matrix ($roots.Count -eq 2) 'Second computer did not get an isolated repository.'
        $second = @($roots | ForEach-Object { Read-DataSafeRepository (ConvertFrom-DataSafeExtendedPath $_) } | Where-Object { $_.ComputerId -ine $repo.ComputerId })
        Assert-Matrix ($second.Count -eq 1 -and $second[0].ComputerName -ceq $repo.ComputerName) 'UUID/friendly-name isolation failed.'
        Assert-Latest $other $second[0]
        Assert-Matrix ((Get-DataSafeSha256 (Join-Path $repo.MetadataRoot 'current-manifest.json')) -ceq $before) 'Second UUID changed first computer pointer.'
        Assert-Latest $f $repo
      }
      Test-Matrix $fs 'frozen launcher survives unavailable shared package path' {
        $savedPackage = $script:PackagedWindowsRoot
        try {
          # Model builder output teardown without changing actual dist. The
          # already-verified fixture must run independently of that shared path.
          $script:PackagedWindowsRoot = Join-Path $control 'absent-package-output'
          $s = Invoke-PackagedWorker $f
          Assert-Matrix ($s.copyBytes -eq 0) 'Frozen launcher retry copied unchanged bytes.'
          Assert-Latest $f $repo
        } finally { $script:PackagedWindowsRoot = $savedPackage }
      }
      Add-Result $fs 'zero visible PowerShell windows' 'NOT RUN' 'Packaged VBS executed successfully; interactive desktop observation still required (static/runtime launch is not a visible-window observation).'
    } catch {
      if (-not @($rows | Where-Object { $_.FileSystem -eq $fs -and $_.Result -eq 'FAIL' }).Count) { Add-Result $fs 'media setup/run' 'FAIL' $_.Exception.Message }
      if ($null -ne $unresolvedLaunch) { break }
      # Continue independent filesystems, preserving failure in the final exit code.
    }
  }
  $allPassed = @($rows | Where-Object { $_.Result -eq 'FAIL' }).Count -eq 0
} finally {
  # An unconfirmed writer blocks ALL cleanup and further media execution.
  # This is manual safety preservation, not a passing browsable demo; neither
  # the default nor KeepArtifacts may delete its locks/staging/source evidence.
  $cleanupBlocked = $null -ne $unresolvedLaunch
  $retain = $cleanupBlocked -or ($KeepArtifacts -and $allPassed)
  $report = [PSCustomObject]@{
    Schema='datasafe.media-matrix';FormatVersion=1;RunId=$runId;CreatedUtc=[datetime]::UtcNow.ToString('o')
    OS=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString()
    PackageVersion=(Read-DataSafeJson (Join-Path $PSScriptRoot '../../package.json')).version
    PackagedHashes=$hashes.ToArray();MediaInventory=$mediaInventory.ToArray();Results=$rows.ToArray();ArtifactsRetained=[bool]$retain
    CleanupBlocked=$cleanupBlocked;UnresolvedLaunch=$unresolvedLaunch
    OwnedRoots=@(if($retain){$owned.ToArray()})
    Phase1Complete=$false
  }
  try {
    if ($ResultPath) {
      # Evidence is not a backup source/repository. A checkout may legitimately
      # live beneath OneDrive's reparse ancestor. Never overwrite existing evidence.
      $evidencePath = [IO.Path]::GetFullPath($ResultPath)
      $stream = [IO.File]::Open((ConvertTo-DataSafeExtendedPath $evidencePath), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $report -Depth 8))
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
      } finally { $stream.Dispose() }
    }
    $report | ConvertTo-Json -Depth 8 | Write-Output
  } finally {
    if ($retain) {
      if ($cleanupBlocked) { Write-Host "MANUAL HANDLING REQUIRED: owned launcher PID=$($unresolvedLaunch.LauncherProcessId); $($unresolvedLaunch.Reason) Do not remove roots until the owned launch tree is confirmed stopped." }
      foreach($path in $owned){Write-Host "RETAINED disposable fixture: $path"}
    }
    else {
      foreach ($path in @($owned | Sort-Object Length -Descending)) {
        # Every target is the exact absolute GUID child created above, never a supplied parent.
        Assert-DataSafeNoReparsePath $path
        Remove-DataSafeDirectoryTree $path
      }
    }
  }
}
if (-not $allPassed) { exit 1 }
Write-Host "$(@($rows | Where-Object {$_.Result -eq 'PASS'}).Count) passed; 0 failed; $(@($rows | Where-Object {$_.Result -eq 'NOT RUN'}).Count) NOT RUN. Phase 1 gate remains pending."

param([string]$MatrixPath=(Join-Path $PSScriptRoot 'Run-IncrementalMediaMatrix.ps1'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'windows/DataSafe.Safety.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('datasafe-media-failure-tests-'+[guid]::NewGuid().ToString('N'))
Ensure-DataSafeDirectory $root
$wrapper=Join-Path $root 'controlled-boundary.ps1'
$passes=0; $failures=New-Object 'System.Collections.Generic.List[string]'
$preserveProbeArtifacts=$false
# Simulate only processes that the matrix would own. Real packaged prerequisites
# below exit normally; no real taskkill is started or receives the simulated PID.
$wrapperText=@'
param([string]$Matrix,[string]$Package,[string]$Source,[string]$Evidence,[string]$Mode,[switch]$Keep)
$global:matrixProbeMode=$Mode
$global:matrixProbeLaunches=0
function Start-Process {
  param([string]$FilePath,[string]$WindowStyle,[string]$ArgumentList,[switch]$PassThru,[switch]$Wait,[string]$RedirectStandardOutput,[string]$RedirectStandardError)
  if([IO.Path]::GetFileName($FilePath) -ieq 'wscript.exe') {
    $global:matrixProbeLaunches++
    if($global:matrixProbeMode -eq 'logical-kill-fails' -and $global:matrixProbeLaunches -le 4) {
      # Only this focused case runs the four real packaged prerequisites; each
      # exits normally. The fifth, unavailable-destination launch is simulated.
      return Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
    }
    $p=[PSCustomObject]@{Id=987654321;ExitCode=0;WaitCalls=0;ConfirmExit=($global:matrixProbeMode -eq 'confirmed')}
    $p | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $this.WaitCalls++; return ($this.WaitCalls -gt 1 -and $this.ConfirmExit) }
    $p | Add-Member ScriptMethod Refresh { }
    return $p
  }
  if([IO.Path]::GetFileName($FilePath) -ieq 'taskkill.exe') {
    if($ArgumentList -cne '/PID 987654321 /T /F'){throw 'Unexpected owned PID/termination arguments'}
    if($global:matrixProbeMode -eq 'kill-throws'){throw 'controlled termination launch failure'}
    return [PSCustomObject]@{ExitCode=$(if($global:matrixProbeMode -in @('kill-fails','logical-kill-fails')){1}else{0})}
  }
  throw "Unexpected process boundary: $FilePath"
}
& $Matrix -NtfsRoot ([IO.Path]::GetTempPath()) -ExFatRoot ([IO.Path]::GetTempPath()) -PackagedWindowsRoot $Package -SourceWindowsRoot $Source -ResultPath $Evidence -KeepArtifacts:$Keep
exit $LASTEXITCODE
'@
[IO.File]::WriteAllText($wrapper,$wrapperText)
function Assert-Probe([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Remove-ProbeRoots($Evidence) {
  $unresolved=$Evidence.PSObject.Properties['UnresolvedLaunch']
  if($null -ne $unresolved -and $null -ne $unresolved.Value -and $unresolved.Value.LauncherProcessId -ne 987654321) {
    $script:preserveProbeArtifacts=$true
    Write-Host "MANUAL HANDLING REQUIRED: prerequisite launch was not simulated; preserving probe evidence at $root and owned roots: $($Evidence.OwnedRoots -join ', ')"
    throw 'Cannot clean probe roots with an unconfirmed real prerequisite launch.'
  }
  $prefix=Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')) ('datasafe-media-'+$Evidence.RunId)
  # Only simulated unresolved launches may be cleaned here; any real prerequisites
  # completed normally. The test owns cleanup after asserting matrix preservation.
  foreach($path in @($Evidence.OwnedRoots | Sort-Object Length -Descending)) {
    $absolute=[IO.Path]::GetFullPath($path)
    Assert-Probe ($absolute -match ('^'+[regex]::Escape($prefix)+'(?:-NTFS(?:-offline)?|\\NTFS-[a-f0-9]{32})?$')) 'Unsafe probe cleanup target'
    Assert-DataSafeNoReparsePath $absolute
    Remove-DataSafeDirectoryTree $absolute
  }
}
try {
  foreach($case in @(
    @{Name='failed termination default';Mode='kill-fails';Keep=$false;Blocked=$true},
    @{Name='failed termination KeepArtifacts';Mode='kill-fails';Keep=$true;Blocked=$true},
    @{Name='termination launch exception';Mode='kill-throws';Keep=$false;Blocked=$true},
    @{Name='termination exit0 without confirmed launcher exit';Mode='unconfirmed';Keep=$false;Blocked=$true},
    @{Name='confirmed timeout termination permits normal cleanup';Mode='confirmed';Keep=$false;Blocked=$false},
    @{Name='unresolved logical-offline launch preserves actual alias';Mode='logical-kill-fails';Keep=$false;Blocked=$true}
  )) {
    $e=$null
    try {
      $id=[guid]::NewGuid().ToString('N'); $evidence=Join-Path $root ($id+'.json')
      $out=Join-Path $root ($id+'.out'); $err=Join-Path $root ($id+'.err')
      $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Matrix "{1}" -Package "{2}" -Source "{3}" -Evidence "{4}" -Mode {5}' -f $wrapper,[IO.Path]::GetFullPath($MatrixPath),(Join-Path $repo 'dist/win-unpacked/resources/windows'),(Join-Path $repo windows),$evidence,$case.Mode
      if($case.Keep){$arguments+=' -Keep'}
      $p=Start-Process (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
      Assert-Probe ($p.ExitCode -eq 1) "Expected failed matrix exit1, got $($p.ExitCode): $([IO.File]::ReadAllText($err))"
      $e=Read-DataSafeJson $evidence
      $control=Join-Path ([IO.Path]::GetTempPath()) ('datasafe-media-'+$e.RunId)
      if($case.Blocked) {
        Assert-Probe ([IO.Directory]::Exists($control)) 'Unresolved launch control/source root was deleted'
        Assert-Probe ($e.ArtifactsRetained -and $e.CleanupBlocked) 'Unresolved roots not explicitly reported as retained/cleanup-blocked'
        if($case.Mode -eq 'logical-kill-fails') {
          Assert-Probe (@($e.OwnedRoots).Count -eq 4) 'Logical-offline alias not listed with exact owned identities'
          Assert-Probe ([IO.Directory]::Exists($e.UnresolvedLaunch.DestinationRoot+'-offline')) 'Unresolved offline destination was renamed/removed'
          Assert-Probe (-not [IO.Directory]::Exists($e.UnresolvedLaunch.DestinationRoot)) 'Unresolved offline destination was moved back beneath possible writer'
          Assert-Probe ($e.OwnedRoots -contains ($e.UnresolvedLaunch.DestinationRoot+'-offline')) 'Actual offline root missing from manual-handling evidence'
        } else {
          Assert-Probe (@($e.OwnedRoots).Count -eq 3) 'Exact three owned root identities were not retained'
          foreach($path in $e.OwnedRoots){Assert-Probe ([IO.Directory]::Exists($path)) "Unresolved owned root deleted: $path"}
        }
        Assert-Probe ($e.UnresolvedLaunch.LauncherProcessId -eq 987654321 -and $e.UnresolvedLaunch.Reason.Length -gt 0) 'Missing unresolved owned process/reason evidence'
        Assert-Probe ($e.OwnedRoots -contains $e.UnresolvedLaunch.FixtureRoot -and $e.OwnedRoots -contains $e.UnresolvedLaunch.DestinationRoot) 'Unresolved fixture/destination identity mismatch'
        Assert-Probe (@($e.Results | Where-Object {$_.FileSystem -eq 'exFAT' -or $_.FileSystem -eq 'FAT32'}).Count -eq 0) 'Matrix continued to another medium with unresolved worker'
        Assert-Probe ([IO.File]::ReadAllText($out) -match 'MANUAL HANDLING REQUIRED') 'No manual-handling warning on output'
      } else {
        Assert-Probe (-not [IO.Directory]::Exists($control)) 'Confirmed stopped launch prevented default cleanup'
        Assert-Probe (-not $e.ArtifactsRetained -and -not $e.CleanupBlocked -and @($e.OwnedRoots).Count -eq 0 -and $null -eq $e.UnresolvedLaunch) 'Confirmed termination left unresolved/retained evidence'
        Assert-Probe (@($e.Results | Where-Object {$_.FileSystem -eq 'exFAT'}).Count -gt 0) 'Independent filesystem guard did not resume after proven stop'
      }
      $passes++; Write-Host "PASS: $($case.Name)"
    } catch { $failures.Add("$($case.Name): $($_.Exception.Message)"); Write-Host "FAIL: $($failures[$failures.Count-1])" }
    finally {
      if($null -ne $e) {
        # Also recover original buggy-runner roots when it failed to list them.
        if(-not @($e.OwnedRoots).Count) {
          $fallback=Join-Path ([IO.Path]::GetTempPath()) ('datasafe-media-'+$e.RunId)
          if([IO.Directory]::Exists($fallback)){$e.OwnedRoots=@($fallback)}
        }
        Remove-ProbeRoots $e
      }
    }
  }
} finally { if(-not $preserveProbeArtifacts){Assert-DataSafeNoReparsePath $root; Remove-DataSafeDirectoryTree $root} }
Write-Host "$passes passed; $($failures.Count) failed."
if($failures.Count){exit 1}

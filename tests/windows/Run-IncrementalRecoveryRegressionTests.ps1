param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'), [string]$CasePattern = '.')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Focused Task 5 round-3 covering suite; run alongside the existing fault suite
# in later Task 6/7 qualification. All bytes are under this disposable GUID root.
. (Join-Path $WindowsRoot 'DataSafe.Transaction.ps1')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('datasafe-recovery-regression-' + [guid]::NewGuid().ToString('N'))
Ensure-DataSafeDirectory $tempRoot
$passes = 0; $failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch {
    if ($_.Exception -is [Management.Automation.CommandNotFoundException]) { throw }
    Assert-True ($_.Exception.Message -match $Pattern) $_.Exception.Message; return
  }
  throw 'Expected rejection.'
}
function Close-TestOwners {
  foreach ($owner in @($script:DataSafeTransactionOwners.Values)) {
    if ($null -ne $owner.Handle) {
      Release-DataSafeOperationLock $owner.Handle (ConvertTo-DataSafeExtendedPath $owner.LockPath)
      $owner.Handle = $null
    }
  }
}
function Test-Case([string]$Name, [scriptblock]$Action) {
  if ($Name -notmatch $CasePattern) { return }
  try { & $Action; $script:passes++; Write-Host "PASS: $Name" }
  catch { $script:failures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL: $Name : $($_.Exception.Message)" }
  finally { Close-TestOwners }
}
function Write-File([string]$Path, [string]$Text) {
  Ensure-DataSafeDirectory ([IO.Path]::GetDirectoryName($Path))
  [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $Path), $Text)
}
function New-Plan($Repo, $Old, $New) {
  $cap = Get-DataSafeFilesystemCapabilities NTFS; $cap | Add-Member TotalBytes ([long]20GB)
  $plan = New-DataSafeIncrementalPlan $Repo $Old $New $cap 100GB
  Assert-True ($plan.BlockingErrors.Count -eq 0 -and -not $plan.DeletionReviewRequired) 'Fixture plan blocked.'
  return $plan
}
function New-Fixture {
  $root = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
  Ensure-DataSafeDirectory $root
  $repo = Initialize-DataSafeRepository $root 'Recovery Regression PC' ([guid]::NewGuid().ToString('D'))
  $source = Join-Path $root source
  Write-File (Join-Path $source keep) 'round-three-payload'
  $job = [PSCustomObject]@{ id='docs'; path=$source; name='Documents' }
  $manifest = New-DataSafeSourceManifest @($job)
  $tx = New-DataSafeTransaction $repo (New-Plan $repo $null $manifest)
  $null = Stage-DataSafeTransaction $tx
  return [PSCustomObject]@{ Root=$root; Repo=$repo; Source=$source; Job=$job; Old=$manifest; Tx=$tx; Path=(Join-Path $repo.TransactionRoot ($tx.transactionId+'.json')); Pointer=(Join-Path $repo.MetadataRoot 'current-manifest.json') }
}
function Assert-RealLease($Fixture) {
  $key = Get-DataSafeTransactionOwnerKey $Fixture.Repo.Root $Fixture.Repo.ComputerId $Fixture.Tx.transactionId
  $owner = $script:DataSafeTransactionOwners[$key]
  Assert-True ($null -ne $owner.Handle -and $owner.Handle.CanWrite) 'Recovery lost its live journal owner.'
  $opened=$null; $blocked=$false
  try { $opened=[IO.File]::Open((ConvertTo-DataSafeExtendedPath $owner.LockPath),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
  catch [IO.IOException] { $blocked=$true }
  finally { if ($null -ne $opened) { $opened.Dispose() } }
  Assert-True $blocked 'Recovery lost its actual exclusive operation lease.'
}
function Assert-ReleasedLease($Fixture) {
  $lock=Join-Path $Fixture.Repo.MetadataRoot operation.lock
  Assert-True (-not (Test-DataSafeFile $lock)) 'Recovery did not release its lease in finally.'
  $handle=Acquire-DataSafeOperationLock (ConvertTo-DataSafeExtendedPath $lock)
  Release-DataSafeOperationLock $handle (ConvertTo-DataSafeExtendedPath $lock)
}
function Assert-PublishedAuthority($Fixture, [string]$PointerText) {
  Assert-True ([IO.File]::ReadAllText($Fixture.Pointer) -ceq $PointerText) 'Published pointer authority changed.'
  Assert-True ([IO.File]::ReadAllText($Fixture.Tx.operations[0].currentPath) -ceq 'round-three-payload') 'Published ordinary bytes changed.'
  Assert-DataSafeTransactionTree $Fixture.Repo $Fixture.Old -Metadata
}
function Invoke-LegacyRecoveryCase([string]$State, [string]$Fault='none', [string]$Timing='before') {
  $f=New-Fixture
  $script:fixtureStopPhase=$(if ($State -ceq 'applying') { 'pointer' } else { 'committed' })
  Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Phase -ceq $script:fixtureStopPhase) { throw 'round3 fixture stop' } } } 'round3 fixture stop'
  Close-TestOwners
  $legacy=Read-DataSafeTransaction $f.Path
  Assert-True ($legacy.state -ceq $State) 'Wrong post-pointer fixture state.'
  $legacy.formatVersion=2; $legacy.PSObject.Properties.Remove('mutationIntent')
  Write-DataSafeTransactionJournal $legacy $f.Path
  Assert-True ((Read-DataSafeTransaction $f.Path).formatVersion -eq 2) 'Strict legacy fixture is not readable.'
  $f.Tx=$legacy
  $pointerText=[IO.File]::ReadAllText($f.Pointer)
  $staging=Join-Path $f.Repo.StagingRoot $legacy.transactionId
  Assert-True (Test-DataSafeDirectory $staging) 'Post-pointer fixture lost its staging evidence.'
  $writer=${function:Write-DataSafeTransactionJournal}; $remover=${function:Remove-DataSafeDirectoryTree}
  $script:recoveryWrites=New-Object 'System.Collections.Generic.List[string]'
  $script:recoveryCleanups=0; $script:recoveryFaulted=$false
  try {
    function Write-DataSafeTransactionJournal($Transaction,[string]$Path,[switch]$CreateOnly) {
      Assert-RealLease $f
      $script:recoveryWrites.Add("$($Transaction.formatVersion)/$($Transaction.state)")
      $isUpgrade=$Transaction.formatVersion -eq 3 -and $script:recoveryWrites.Count -eq 1
      $isCommit=$Transaction.formatVersion -eq 3 -and $Transaction.state -ceq 'committed' -and $script:recoveryWrites.Count -eq 2
      $inject=($Fault -ceq 'upgrade' -and $isUpgrade) -or ($Fault -ceq 'publication' -and $isCommit)
      if ($inject -and $Timing -ceq 'before') { $script:recoveryFaulted=$true; throw 'round3 journal finalization fault' }
      & $writer $Transaction $Path -CreateOnly:$CreateOnly
      if ($inject -and $Timing -ceq 'after') { $script:recoveryFaulted=$true; throw 'round3 journal finalization fault' }
    }
    function Remove-DataSafeDirectoryTree([string]$Path) {
      if ($Path.Equals($staging,[StringComparison]::OrdinalIgnoreCase)) { Assert-RealLease $f; $script:recoveryCleanups++ }
      & $remover $Path
    }
    $result=Recover-DataSafeTransaction $f.Repo $f.Path
  } finally { ${function:Write-DataSafeTransactionJournal}=$writer; ${function:Remove-DataSafeDirectoryTree}=$remover }
  Assert-True ($result.FinalState -ceq 'committed') 'Verified published authority was reported as pre-commit failure.'
  Assert-PublishedAuthority $f $pointerText
  Assert-ReleasedLease $f
  $disk=Read-DataSafeTransaction $f.Path
  if ($Fault -ceq 'none') {
    $expected=$(if ($State -ceq 'applying') { '3/applying,3/committed' } else { '3/committed' })
    Assert-True (($script:recoveryWrites -join ',') -ceq $expected) 'Upgrade/publication ordering changed.'
    Assert-True ($disk.formatVersion -eq 3 -and $disk.state -ceq 'committed' -and $result.Warnings.Count -eq 0) 'Healthy recovery did not finish the strict journal.'
    Assert-True ($script:recoveryCleanups -eq 1 -and -not (Test-DataSafeDirectory $staging)) 'Healthy recovery did not clean staging under its lease.'
  } else {
    Assert-True $script:recoveryFaulted 'Requested inside-finalization fault did not fire.'
    Assert-True ($result.Warnings.Count -eq 1 -and $result.Warnings[0].Code -ceq 'JournalFinalizationFailed' -and $result.Warnings[0].Message -match 'round3 journal finalization fault') 'Committed journal-finalization warning is missing.'
    Assert-True ($script:recoveryCleanups -eq 0 -and (Test-DataSafeDirectory $staging)) 'Failed finalization deleted staging evidence.'
    $expectedVersion=$(if ($Fault -ceq 'upgrade' -and $Timing -ceq 'before') { 2 } else { 3 })
    $expectedState=$(if ($State -ceq 'committed' -or ($Fault -ceq 'publication' -and $Timing -ceq 'after')) { 'committed' } else { 'applying' })
    Assert-True ($disk.formatVersion -eq $expectedVersion -and $disk.state -ceq $expectedState) 'Failed publication did not retain readable prior/durable evidence.'
    $retry=Recover-DataSafeTransaction $f.Repo $f.Path
    Assert-True ($retry.FinalState -ceq 'committed' -and $retry.Warnings.Count -eq 0 -and -not (Test-DataSafeDirectory $staging)) 'Later recovery could not finalize and clean retained evidence.'
  }
  Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Repeated committed recovery is not idempotent.'
  Assert-PublishedAuthority $f $pointerText
  Assert-ReleasedLease $f
}
function New-ParentIntentFixture([string]$Phase) {
  $f=New-Fixture
  $null=Invoke-DataSafeTransaction $f.Tx
  # Establish an explicit old parent, not merely an unversioned implicit root.
  Write-File (Join-Path $f.Source 'node/keep') 'old-child'
  [IO.Directory]::SetLastWriteTimeUtc((Join-Path $f.Source node),[datetime]'2020-01-02Z')
  $current=New-DataSafeSourceManifest @($f.Job) $f.Old
  $oldTx=New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.Old $current)
  $null=Stage-DataSafeTransaction $oldTx; $null=Invoke-DataSafeTransaction $oldTx
  $f.Old=$current
  Ensure-DataSafeDirectory (Join-Path $f.Source 'node/new')
  [IO.Directory]::SetLastWriteTimeUtc((Join-Path $f.Source 'node/new'),[datetime]'2024-02-03Z')
  [IO.Directory]::SetLastWriteTimeUtc((Join-Path $f.Source node),[datetime]'2024-01-02Z')
  $next=New-DataSafeSourceManifest @($f.Job) $f.Old
  $f.Tx=New-DataSafeTransaction $f.Repo (New-Plan $f.Repo $f.Old $next)
  $null=Stage-DataSafeTransaction $f.Tx
  $f.Path=Join-Path $f.Repo.TransactionRoot ($f.Tx.transactionId+'.json')
  $newOp=@($f.Tx.operations|Where-Object relativePath -ceq 'node/new')[0]
  $script:parentIntentSequence=$newOp.sequence; $script:parentIntentPhase=$Phase
  Assert-Throws { Invoke-DataSafeTransaction $f.Tx { param($c) if ($c.Sequence -eq $script:parentIntentSequence -and $c.Phase -ceq $script:parentIntentPhase) { throw 'round3 parent intent stop' } } } 'round3 parent intent stop'
  $f|Add-Member NewManifest $next; $f|Add-Member Child $newOp.currentPath
  $f|Add-Member Parent ([IO.Path]::GetDirectoryName($newOp.currentPath))
  $f|Add-Member OldParent (@($f.Old.entries|Where-Object relativePath -ceq node)[0])
  return $f
}
try {
  foreach ($state in @('applying','committed')) {
    Test-Case "post-pointer legacy v2 $state keeps its lease through upgrade and cleanup" { Invoke-LegacyRecoveryCase $state }
    foreach ($timing in @('before','after')) {
      Test-Case "post-pointer legacy v2 $state upgrade failure $timing preserves committed authority" { Invoke-LegacyRecoveryCase $state upgrade $timing }
    }
  }
  foreach ($timing in @('before','after')) {
    Test-Case "post-pointer legacy v2 committed publication failure $timing preserves evidence" { Invoke-LegacyRecoveryCase applying publication $timing }
  }
  Test-Case 'parent intent before create rejects unrelated old timestamp drift' {
    $f=New-ParentIntentFixture promote-intent
    Assert-True (-not (Test-DataSafeDirectory $f.Child)) 'Before-create fixture already created its intended child.'
    $before=[IO.File]::ReadAllText($f.Path); $pointer=[IO.File]::ReadAllText($f.Pointer)
    [IO.Directory]::SetLastWriteTimeUtc($f.Parent,[datetime]'2010-01-02Z')
    $externalTime=[IO.Directory]::GetLastWriteTimeUtc($f.Parent)
    Close-TestOwners
    Assert-Throws { Recover-DataSafeTransaction $f.Repo $f.Path } 'prior metadata baseline'
    Assert-True ([IO.File]::ReadAllText($f.Path) -ceq $before -and [IO.File]::ReadAllText($f.Pointer) -ceq $pointer) 'Rejected baseline recovery rewrote evidence.'
    Assert-True (-not (Test-DataSafeDirectory $f.Child)) 'Rejected recovery created its intended child.'
    Assert-True ([IO.Directory]::GetLastWriteTimeUtc($f.Parent).Ticks -eq $externalTime.Ticks) 'Rejected recovery reset external metadata.'
    Assert-ReleasedLease $f
    [IO.Directory]::SetLastWriteTimeUtc($f.Parent,[datetime]::Parse($f.OldParent.modifiedUtc).ToUniversalTime())
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Repairing the exact old timestamp did not unblock recovery.'
    Assert-DataSafeTransactionTree $f.Repo $f.NewManifest -Metadata
  }
  Test-Case 'parent intent before create preserves an unchanged old timestamp baseline' {
    $f=New-ParentIntentFixture promote-intent; Close-TestOwners
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Untouched before-create intent did not recover.'
    Assert-DataSafeTransactionTree $f.Repo $f.NewManifest -Metadata
  }
  Test-Case 'parent intent after real child creation permits bounded parent timestamp change' {
    $f=New-ParentIntentFixture promote-parent-filesystem
    Assert-True (Test-DataSafeDirectory $f.Child) 'After-create fixture has no physical intended child.'
    Assert-True ([IO.Directory]::GetLastWriteTimeUtc($f.Parent).Ticks -ne [datetime]::Parse($f.OldParent.modifiedUtc).ToUniversalTime().Ticks) 'Physical child creation did not exercise the parent timestamp waiver.'
    $owner=Get-DataSafeTransactionOwner $f.Tx
    Assert-DataSafeIntentBaseline $owner
    Close-TestOwners
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'Owned physical child creation could not recover.'
    Assert-DataSafeTransactionTree $f.Repo $f.NewManifest -Metadata
    Assert-True ((Recover-DataSafeTransaction $f.Repo $f.Path).FinalState -ceq 'committed') 'After-create repeat recovery failed.'
  }
} finally {
  Close-TestOwners
  Assert-True ($tempRoot.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($tempRoot) -match '^datasafe-recovery-regression-[a-f0-9]{32}$') 'Unsafe disposable fixture cleanup target.'
  Remove-DataSafeDirectoryTree $tempRoot
}
Write-Host "Result: $passes passed; $($failures.Count) failed."
if ($failures.Count) { exit 1 }

param(
  [string]$WindowsRoot = (Join-Path $PSScriptRoot "..\..\windows")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Assert-True([bool]$Condition, [string]$Name, [string]$FailureMessage) {
  if ($Condition) {
    $passes.Add($Name)
  } else {
    $failures.Add("$Name`: $FailureMessage")
  }
}

function Assert-ThrowsBusy([scriptblock]$Action, [string]$Name) {
  try {
    & $Action
    $failures.Add("$Name`: expected the operation-lock busy error, but acquisition succeeded.")
  } catch {
    $expected = "A DataSafe backup or restore is already running. Wait for it to finish before starting another operation."
    Assert-True ($_.Exception.Message -eq $expected) $Name "unexpected error: $($_.Exception.Message)"
  }
}

function Get-TestExtendedPath([string]$Path) {
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ($fullPath.StartsWith("\\")) {
    return "\\?\UNC\$($fullPath.Substring(2))"
  }
  return "\\?\$fullPath"
}

$safetyPath = Join-Path $WindowsRoot "DataSafe.Safety.ps1"
. $safetyPath

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("datasafe-hotfix-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
  $staleLock = Join-Path $tempRoot "stale.lock"
  [System.IO.File]::WriteAllText($staleLock, "pid=2147483000`nstartedAt=$((Get-Date).ToString('o'))`n")

  $staleHandle = $null
  try {
    $staleHandle = Acquire-DataSafeOperationLock $staleLock
    Assert-True ($null -ne $staleHandle) "recent orphaned lock is reclaimed" "acquisition returned no handle."
  } catch {
    $failures.Add("recent orphaned lock is reclaimed: $($_.Exception.Message)")
  } finally {
    if ($staleHandle) {
      Release-DataSafeOperationLock $staleHandle $staleLock
    }
  }

  $liveLock = Join-Path $tempRoot "live.lock"
  $liveHandle = Acquire-DataSafeOperationLock $liveLock
  try {
    Assert-ThrowsBusy { $secondHandle = Acquire-DataSafeOperationLock $liveLock } "exclusively held lock remains busy"
  } finally {
    Release-DataSafeOperationLock $liveHandle $liveLock
  }

  $busyStatusPath = Join-Path $tempRoot "busy-status.json"
  $busyLockPath = "$busyStatusPath.lock"
  $busyConfigPath = Join-Path $tempRoot "unused-config.json"
  $busyStdoutPath = Join-Path $tempRoot "busy-stdout.txt"
  $busyStderrPath = Join-Path $tempRoot "busy-stderr.txt"
  $busyHandle = Acquire-DataSafeOperationLock $busyLockPath
  try {
    $backupScript = Join-Path $WindowsRoot "backup-engine.ps1"
    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -StatusPath "{2}"' -f `
      $backupScript, $busyConfigPath, $busyStatusPath
    $process = Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList $arguments -RedirectStandardOutput $busyStdoutPath -RedirectStandardError $busyStderrPath -Wait -PassThru
    $busyStdout = [string]$(if (Test-Path -LiteralPath $busyStdoutPath) { Get-Content -LiteralPath $busyStdoutPath -Raw } else { "" })
    $busyStderr = [string]$(if (Test-Path -LiteralPath $busyStderrPath) { Get-Content -LiteralPath $busyStderrPath -Raw } else { "" })

    Assert-True ($process.ExitCode -eq 0) "busy backup exits successfully" "exit code was $($process.ExitCode)."
    Assert-True ([string]::IsNullOrWhiteSpace($busyStderr)) "busy backup writes no error stream" "stderr was: $busyStderr"
    Assert-True (-not (Test-Path -LiteralPath $busyStatusPath)) "busy backup does not rewrite status" "the worker created or rewrote status.json."
    Assert-True ($busyStdout -match "already running") "busy backup reports the reason" "stdout did not contain the busy message."
  } finally {
    Release-DataSafeOperationLock $busyHandle $busyLockPath
  }

  $interactivePatterns = @(
    "WScript\.Shell",
    "System\.Windows\.Forms\.NotifyIcon",
    "ShowBalloonTip\(",
    "\.Popup\("
  )
  foreach ($name in "backup-engine.ps1", "check-reminders.ps1", "check-cloud-health.ps1", "verify-backup-integrity.ps1") {
    $content = Get-Content -LiteralPath (Join-Path $WindowsRoot $name) -Raw
    foreach ($pattern in $interactivePatterns) {
      Assert-True (-not ($content -match $pattern)) "$name has no script-owned interactive UI matching $pattern" "interactive notification code is still present."
    }
  }

  $runnerPath = Join-Path $WindowsRoot "DataSafeTaskRunner.vbs"
  Assert-True (Test-Path -LiteralPath $runnerPath) "windowless scheduled-task launcher exists" "DataSafeTaskRunner.vbs is missing."

  # Capture the source installer's output at the Task Scheduler boundary. Never register
  # real tasks or depend on machine-specific exported XML in this source regression.
  $registeredTasks = @{}
  function New-ScheduledTaskAction {
    param([string]$Execute, [string]$Argument)
    return [PSCustomObject]@{ Execute = $Execute; Arguments = $Argument }
  }
  function New-ScheduledTaskSettingsSet {
    param([switch]$Hidden, [switch]$StartWhenAvailable, [switch]$WakeToRun,
      [string]$MultipleInstances, [switch]$AllowStartIfOnBatteries,
      [switch]$DontStopIfGoingOnBatteries, [TimeSpan]$ExecutionTimeLimit)
    return [PSCustomObject]@{ Hidden = $Hidden.IsPresent }
  }
  function New-ScheduledTaskPrincipal {
    param([string]$UserId, [string]$LogonType, [string]$RunLevel)
    return [PSCustomObject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
  }
  function New-ScheduledTaskTrigger {
    param([switch]$Weekly, [switch]$Daily, [switch]$AtStartup, [switch]$AtLogOn,
      [string]$DaysOfWeek, $At, [string]$User)
    return [PSCustomObject]@{ User = $User }
  }
  function Register-ScheduledTask {
    param([string]$TaskName, $Action, $Trigger, $Settings, $Principal, [switch]$Force)
    $registeredTasks[$TaskName] = [PSCustomObject]@{ Action = $Action; Settings = $Settings }
  }
  function Get-ScheduledTask { throw "Regression tests must not query installed scheduled tasks." }
  function Unregister-ScheduledTask { throw "Regression tests must not remove installed scheduled tasks." }

  $installerConfigPath = Join-Path $tempRoot "installer-config.json"
  $installerStatusPath = Join-Path $tempRoot "installer-status.json"
  Write-DataSafeJson $installerConfigPath ([PSCustomObject]@{
    schedule = [PSCustomObject]@{ enabled = $true; frequency = "weekly"; dayOfWeek = "Monday"; time = "18:30" }
    reminders = [PSCustomObject]@{ enabled = $true; staleDays = 7 }
    cloudCheck = [PSCustomObject]@{ enabled = $true }
  })
  & (Join-Path $WindowsRoot "install-scheduled-backup.ps1") -ConfigPath $installerConfigPath -StatusPath $installerStatusPath -ScriptRoot $WindowsRoot | Out-Null
  $expectedWorkers = [ordered]@{
    OneBiteBackupRun = "backup-engine.ps1"
    OneBiteBackupReminder = "check-reminders.ps1"
    OneBiteBackupCatchUp = "check-backup-catchup.ps1"
    OneBiteBackupIntegrity = "verify-backup-integrity.ps1"
    OneBiteBackupCloudHealth = "check-cloud-health.ps1"
  }
  Assert-True ($registeredTasks.Count -eq 5) "all five source tasks are registered" "expected five captured task registrations, got $($registeredTasks.Count)."
  foreach ($taskName in $expectedWorkers.Keys) {
    Assert-True ($registeredTasks.ContainsKey($taskName)) "$taskName is registered" "task registration was not captured."
    if (-not $registeredTasks.ContainsKey($taskName)) { continue }
    $taskCommand = $registeredTasks[$taskName].Action.Execute
    $taskArguments = $registeredTasks[$taskName].Action.Arguments
    $expectedArguments = '//B //NoLogo "{0}" "{1}" -ConfigPath "{2}" -StatusPath "{3}"' -f `
      $runnerPath, (Join-Path $WindowsRoot $expectedWorkers[$taskName]), $installerConfigPath, $installerStatusPath
    if ($taskName -eq "OneBiteBackupCatchUp") { $expectedArguments += ' -ScriptRoot "{0}"' -f $WindowsRoot }
    if ($taskName -eq "OneBiteBackupCloudHealth") { $expectedArguments += ' -Notify' }
    Assert-True ($taskCommand -eq "wscript.exe") "$taskName uses the windowless task host" "command was $taskCommand."
    Assert-True ($taskArguments -eq $expectedArguments) "$taskName forwards the quoted worker arguments through DataSafeTaskRunner.vbs" "arguments were $taskArguments."
    Assert-True ([bool]$registeredTasks[$taskName].Settings.Hidden) "$taskName remains hidden" "Hidden was false."
  }

  $probePath = Join-Path $PSScriptRoot "RunnerProbe.ps1"
  $markerPath = Join-Path $tempRoot "runner marker.txt"
  $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
  $probeArguments = '//B //NoLogo "{0}" "{1}" -MarkerPath "{2}"' -f $runnerPath, $probePath, $markerPath
  $probeProcess = Start-Process -FilePath $wscript -WindowStyle Hidden -ArgumentList $probeArguments -Wait -PassThru
  Assert-True ($probeProcess.ExitCode -eq 0) "windowless launcher completes the PowerShell probe" "exit code was $($probeProcess.ExitCode)."
  $probeText = if (Test-Path -LiteralPath $markerPath) { [System.IO.File]::ReadAllText($markerPath) } else { "" }
  Assert-True ($probeText -eq "runner-ok") "windowless launcher preserves a marker path containing spaces" "the probe marker was missing or incorrect."

  $longStage = Join-Path $tempRoot ".stage"
  $deepDirectory = $longStage
  while ((Join-Path $deepDirectory "payload.txt").Length -lt 280) {
    $deepDirectory = Join-Path $deepDirectory ("segment-" + ("x" * 36))
  }
  $longFile = Join-Path $deepDirectory "payload.txt"
  $payload = "long-path-payload"
  [System.IO.Directory]::CreateDirectory((Get-TestExtendedPath $deepDirectory)) | Out-Null
  [System.IO.File]::WriteAllText((Get-TestExtendedPath $longFile), $payload)

  try {
    $measuredBytes = Get-DataSafePathSize $longStage
    Assert-True ($measuredBytes -eq $payload.Length) "long-path size calculation includes deep files" "expected $($payload.Length) bytes, measured $measuredBytes."
  } catch {
    $failures.Add("long-path size calculation includes deep files: $($_.Exception.Message)")
  }

  try {
    $integrity = New-DataSafeIntegrityIndex $longStage
    Assert-True ($integrity.fileCount -eq 1) "integrity index enumerates a path longer than 260 characters" "expected one file, indexed $($integrity.fileCount)."
    Assert-True ($integrity.totalBytes -eq $payload.Length) "integrity index hashes the deep file" "expected $($payload.Length) bytes, indexed $($integrity.totalBytes)."
  } catch {
    $failures.Add("integrity index supports paths longer than 260 characters: $($_.Exception.Message)")
  }

  Remove-DataSafeIncompleteSnapshots $tempRoot
  Assert-True (-not [System.IO.Directory]::Exists((Get-TestExtendedPath $longStage))) "incomplete snapshot cleanup removes long paths" "the long-path staging tree still exists."

  $copyDestinationDirectory = Join-Path $tempRoot "copy-target"
  while ((Join-Path $copyDestinationDirectory "copied.txt").Length -lt 280) {
    $copyDestinationDirectory = Join-Path $copyDestinationDirectory ("segment-" + ("y" * 36))
  }
  $copyDestination = Join-Path $copyDestinationDirectory "copied.txt"
  $copySource = Join-Path $tempRoot "copy-source.txt"
  [System.IO.File]::WriteAllText($copySource, $payload)
  try {
    Copy-DataSafeFile -SourcePath $copySource -DestinationPath $copyDestination
    $copiedText = [System.IO.File]::ReadAllText((Get-TestExtendedPath $copyDestination))
    Assert-True ($copiedText -eq $payload) "single-file copy supports long paths" "the copied payload did not match."
  } catch {
    $failures.Add("single-file copy supports long paths: $($_.Exception.Message)")
  }

  $partialFileDirectory = Join-Path $tempRoot "partial-target"
  while ((Join-Path $partialFileDirectory "partial.txt").Length -lt 280) {
    $partialFileDirectory = Join-Path $partialFileDirectory ("segment-" + ("z" * 36))
  }
  $partialFile = Join-Path $partialFileDirectory "partial.txt"
  [System.IO.Directory]::CreateDirectory((Get-TestExtendedPath $partialFileDirectory)) | Out-Null
  [System.IO.File]::WriteAllText((Get-TestExtendedPath $partialFile), "partial")
  try {
    Remove-DataSafePath $partialFile
    Assert-True (-not [System.IO.File]::Exists((Get-TestExtendedPath $partialFile))) "failed file restore cleanup removes partial files" "the partial file still exists."
  } catch {
    $failures.Add("failed file restore cleanup removes partial files: $($_.Exception.Message)")
  }

  $snapshotName = "2026-10-16_14-30-00"
  $repositoryRoot = Join-Path $tempRoot "restore-repository"
  $snapshotRoot = Join-Path (Join-Path $repositoryRoot "snapshots") $snapshotName
  $snapshotItemRoot = Join-Path $snapshotRoot "Test File"
  New-Item -ItemType Directory -Force -Path $snapshotItemRoot | Out-Null
  $snapshotPayload = Join-Path $snapshotItemRoot "payload.txt"
  [System.IO.File]::WriteAllText($snapshotPayload, $payload)

  $restoreTargetDirectory = Join-Path $tempRoot "original-target"
  while ((Join-Path $restoreTargetDirectory "payload.txt").Length -lt 280) {
    $restoreTargetDirectory = Join-Path $restoreTargetDirectory ("segment-" + ("r" * 36))
  }
  $restoreTarget = Join-Path $restoreTargetDirectory "payload.txt"
  [System.IO.Directory]::CreateDirectory((Get-TestExtendedPath $restoreTargetDirectory)) | Out-Null
  [System.IO.File]::WriteAllText((Get-TestExtendedPath $restoreTarget), "current-target-payload")

  $driveRoot = [System.IO.Path]::GetPathRoot($repositoryRoot)
  $testJob = [PSCustomObject]@{
    id = "long-file-job"
    name = "Test File"
    path = $restoreTarget
    type = "file"
    sourceKind = "file"
    processNames = @()
    relativeDestination = @("Test File")
    enabled = $true
  }
  $testConfig = [PSCustomObject]@{
    installId = "test-install"
    destination = [PSCustomObject]@{
      id = "test-destination"
      driveLetter = $driveRoot.TrimEnd('\').TrimEnd(':')
      baseFolder = $repositoryRoot.Substring($driveRoot.Length)
    }
    jobs = @($testJob)
  }
  $testStatus = [PSCustomObject]@{
    lastBackupAt = $null
    recentSnapshots = @($snapshotName)
  }
  New-Item -ItemType Directory -Force -Path $repositoryRoot | Out-Null
  $null = Ensure-DataSafeDestinationMarker -BaseRoot $repositoryRoot -Config $testConfig
  $snapshotIntegrity = New-DataSafeIntegrityIndex $snapshotRoot
  $null = Write-DataSafeSnapshotMetadata -SnapshotPath $snapshotRoot -SnapshotName $snapshotName -Config $testConfig -Jobs @($testJob) -Integrity $snapshotIntegrity
  try {
    $verification = Test-DataSafeIntegrityIndex -SnapshotPath $snapshotRoot -RelativePrefix "Test File"
    Assert-True ($verification.filesChecked -eq 1) "completed snapshot verification reads a long-path-capable integrity index" "expected one verified file, got $($verification.filesChecked)."
  } catch {
    $failures.Add("completed snapshot verification reads a long-path-capable integrity index: $($_.Exception.Message)")
  }

  $restoreConfigPath = Join-Path $tempRoot "restore-config.json"
  $restoreStatusPath = Join-Path $tempRoot "restore-status.json"
  Write-DataSafeJson $restoreConfigPath $testConfig
  Write-DataSafeJson $restoreStatusPath $testStatus
  $restoreScript = Join-Path $WindowsRoot "restore-snapshot.ps1"
  $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

  $savedErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $planOutput = @(& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $restoreScript -ConfigPath $restoreConfigPath -StatusPath $restoreStatusPath -SnapshotName $snapshotName -JobId $testJob.id -RestoreMode original -Action plan 2>&1)
    $planExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $savedErrorActionPreference
  }
  $planLine = @($planOutput | ForEach-Object { "$_" } | Where-Object { $_.StartsWith("__OB_RESULT__:") } | Select-Object -First 1)
  Assert-True ($planExitCode -eq 0) "long-path file restore plan succeeds" "exit code was $planExitCode; output: $($planOutput -join ' | ')"
  if ($planLine.Count -gt 0) {
    $plan = $planLine[0].Substring("__OB_RESULT__:".Length) | ConvertFrom-Json
    Assert-True ($plan.newFiles -eq 0) "restore plan recognizes an existing long-path target" "newFiles was $($plan.newFiles)."
    Assert-True ($plan.conflictingFiles -eq 1) "restore plan compares the existing long-path target" "conflictingFiles was $($plan.conflictingFiles)."
    Assert-True ([bool]$plan.safetyCopyRequired) "restore plan protects an existing long-path target" "safetyCopyRequired was false."
  } else {
    $failures.Add("long-path restore plan returns structured output: no __OB_RESULT__ line was produced.")
  }

  $ErrorActionPreference = "Continue"
  try {
    $restoreOutput = @(& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $restoreScript -ConfigPath $restoreConfigPath -StatusPath $restoreStatusPath -SnapshotName $snapshotName -JobId $testJob.id -RestoreMode original -Action restore 2>&1)
    $restoreExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $savedErrorActionPreference
  }
  Assert-True ($restoreExitCode -eq 0) "single-file restore completes at a long path" "exit code was $restoreExitCode; output: $($restoreOutput -join ' | ')"
  if ([System.IO.File]::Exists((Get-TestExtendedPath $restoreTarget))) {
    $restoredText = [System.IO.File]::ReadAllText((Get-TestExtendedPath $restoreTarget))
    Assert-True ($restoredText -eq $payload) "single-file long-path restore preserves content" "the restored payload did not match."
  } else {
    $failures.Add("single-file long-path restore preserves content: the restored file is missing.")
  }

  $fakeChrome = Join-Path $tempRoot "Google\Chrome\User Data"
  $expectedChromeExclusions = @(
    "OptGuideOnDeviceModel",
    "optimization_guide_model_store",
    "component_crx_cache"
  )
  foreach ($relativePath in $expectedChromeExclusions) {
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeChrome $relativePath) | Out-Null
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeChrome "Default\Cache") | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $fakeChrome "Default\Bookmarks"), "personal-data")

  try {
    $browserExclusions = @(Get-DataSafeBrowserExcludedDirectories $fakeChrome)
    foreach ($relativePath in $expectedChromeExclusions) {
      $expectedPath = Join-Path $fakeChrome $relativePath
      Assert-True ($browserExclusions -contains $expectedPath) "Chrome excludes reproducible $relativePath data" "the exclusion list did not contain $expectedPath."
    }
    Assert-True ($browserExclusions -contains (Join-Path $fakeChrome "Default\Cache")) "Chrome still excludes profile caches" "Default\\Cache was not excluded."
    Assert-True (-not ($browserExclusions -contains (Join-Path $fakeChrome "Default"))) "Chrome keeps the profile directory" "the entire Default profile was excluded."
  } catch {
    $failures.Add("Chrome reproducible-data exclusions are available: $($_.Exception.Message)")
  }
} finally {
  $extendedTempRoot = Get-TestExtendedPath $tempRoot
  if ([System.IO.Directory]::Exists($extendedTempRoot)) {
    [System.IO.Directory]::Delete($extendedTempRoot, $true)
  }
}

foreach ($name in $passes) {
  Write-Host "PASS: $name"
}
foreach ($failure in $failures) {
  Write-Host "FAIL: $failure"
}

Write-Host "Result: $($passes.Count) passed; $($failures.Count) failed."
if ($failures.Count -gt 0) {
  exit 1
}
exit 0

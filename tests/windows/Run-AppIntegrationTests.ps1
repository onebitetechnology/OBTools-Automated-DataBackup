param([string]$WorkerRoot=(Join-Path $PSScriptRoot '../../windows'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $WorkerRoot 'DataSafe.Transaction.ps1')
. (Join-Path $PSScriptRoot 'AppIntegrationTestHelpers.ps1')
$fixture=$null
$names=@('DATASAFE_APP_FIXTURE_CONFIG','DATASAFE_APP_FIXTURE_STATUS','DATASAFE_APP_FIXTURE_BIN','DATASAFE_APP_FIXTURE_ROOT')
$saved=@{}
foreach ($name in $names) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
  $fixture=New-AppFixture $WorkerRoot
  # Catalog fixtures deliberately use a sentinel-only status. Actual workers
  # receive the existing app status fields, as the real main adapter supplies.
  Write-DataSafeJson $fixture.StatusPath ([PSCustomObject]@{lastBackupAt=$null;lastBackupAttemptAt=$null;lastBackupResult=$null;lastBackupMessage='';destinationStatus='Unknown';recentSnapshots=@()})
  [IO.File]::Copy((Join-Path $PSScriptRoot 'AppIntegrationTestHelpers.ps1'),(Join-Path $fixture.Bin 'AppIntegrationTestHelpers.ps1'))
  $hashes=@(foreach ($file in Get-ChildItem -LiteralPath $fixture.Bin -File) { [PSCustomObject]@{name=$file.Name;sha256=Get-DataSafeSha256 $file.FullName} })
  Write-DataSafeJson (Join-Path $fixture.Root 'runtime.json') ([PSCustomObject]@{powerShell=(Get-Process -Id $PID).Path;version=$PSVersionTable.PSVersion.ToString();workerSource=[IO.Path]::GetFullPath($WorkerRoot);copiedFixtureHashes=$hashes})
  foreach ($pair in @(@($names[0],$fixture.ConfigPath),@($names[1],$fixture.StatusPath),@($names[2],$fixture.Bin),@($names[3],$fixture.Root))) { [Environment]::SetEnvironmentVariable($pair[0],$pair[1],'Process') }
  & node --test --test-reporter=tap (Join-Path $PSScriptRoot '../app-worker-integration.test.js')
  if ($LASTEXITCODE -ne 0) { throw "Actual-worker app integration failed (node exit $LASTEXITCODE)." }
} finally {
  foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
  if ($null -ne $fixture) { Remove-AppFixture $fixture }
}

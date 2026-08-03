const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const test = require("node:test");

const {
  SNAPSHOT_COMPLETE_FILE,
  SNAPSHOT_INTEGRITY_FILE,
  SNAPSHOT_MANIFEST_FILE,
  inspectCompletedSnapshot,
  inspectSnapshotsAtBaseRoot
} = require("../backup-safety");

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function sha256(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex").toUpperCase();
}

function createCompletedSnapshot(baseRoot, snapshotName, completedAt) {
  const snapshotPath = path.join(baseRoot, "snapshots", snapshotName);
  fs.mkdirSync(snapshotPath, { recursive: true });
  fs.writeFileSync(path.join(snapshotPath, "customer-file.txt"), "verified backup data", "utf8");
  fs.writeFileSync(path.join(snapshotPath, SNAPSHOT_INTEGRITY_FILE), "{\"path\":\"customer-file.txt\"}\n", "utf8");

  const integritySha256 = sha256(path.join(snapshotPath, SNAPSHOT_INTEGRITY_FILE));
  const manifest = {
    formatVersion: 1,
    snapshotName,
    createdAt: completedAt,
    completedAt,
    integrity: {
      algorithm: "SHA256",
      indexFile: SNAPSHOT_INTEGRITY_FILE,
      indexSha256: integritySha256,
      fileCount: 1,
      totalBytes: 20
    }
  };
  const manifestPath = path.join(snapshotPath, SNAPSHOT_MANIFEST_FILE);
  writeJson(manifestPath, manifest);
  writeJson(path.join(snapshotPath, SNAPSHOT_COMPLETE_FILE), {
    formatVersion: 1,
    snapshotName,
    completedAt,
    manifestFile: SNAPSHOT_MANIFEST_FILE,
    manifestSha256: sha256(manifestPath),
    integrityIndexFile: SNAPSHOT_INTEGRITY_FILE,
    integrityIndexSha256: integritySha256
  });
  return snapshotPath;
}

function findPowerShell() {
  const candidates = [
    process.env.DATASAFE_POWERSHELL,
    process.platform === "win32" ? "powershell.exe" : "pwsh"
  ].filter(Boolean);

  return candidates.find((candidate) => {
    const result = spawnSync(candidate, ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"], {
      encoding: "utf8"
    });
    return result.status === 0;
  }) || null;
}

function runPowerShellScript(powerShell, script) {
  const scriptRoot = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-powershell-script-"));
  const scriptPath = path.join(scriptRoot, "test.ps1");
  fs.writeFileSync(scriptPath, script, "utf8");

  try {
    return spawnSync(powerShell, ["-NoProfile", "-File", scriptPath], { encoding: "utf8" });
  } finally {
    fs.rmSync(scriptRoot, { recursive: true, force: true });
  }
}

function powerShellLiteral(value) {
  return String(value).replace(/'/g, "''");
}

function requestPreview(port, requestPath) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      host: "127.0.0.1",
      port,
      method: "GET",
      path: requestPath
    }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        body += chunk;
      });
      response.on("end", () => resolve({ statusCode: response.statusCode, body }));
    });
    request.on("error", reject);
    request.end();
  });
}

function startPreviewServer(port) {
  const child = spawn(process.execPath, [path.join(__dirname, "..", "server.js")], {
    cwd: path.join(__dirname, ".."),
    env: { ...process.env, PORT: String(port) },
    stdio: ["ignore", "pipe", "pipe"]
  });

  return new Promise((resolve, reject) => {
    let output = "";
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error(`Preview server did not start. ${output}`));
    }, 5000);
    child.stdout.on("data", (chunk) => {
      output += chunk.toString();
      if (output.includes("running at")) {
        clearTimeout(timeout);
        resolve(child);
      }
    });
    child.stderr.on("data", (chunk) => {
      output += chunk.toString();
    });
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("exit", (code) => {
      if (!output.includes("running at")) {
        clearTimeout(timeout);
        reject(new Error(`Preview server exited with ${code}. ${output}`));
      }
    });
  });
}

function createPowerShellCompletedSnapshot(baseRoot, snapshotName, completedAt) {
  const snapshotPath = path.join(baseRoot, "snapshots", snapshotName);
  const dataPath = path.join(snapshotPath, "item", "customer-file.txt");
  fs.mkdirSync(path.dirname(dataPath), { recursive: true });
  fs.writeFileSync(dataPath, "verified backup data", "utf8");

  const integrityPath = path.join(snapshotPath, SNAPSHOT_INTEGRITY_FILE);
  fs.writeFileSync(integrityPath, `${JSON.stringify({
    path: "item/customer-file.txt",
    length: fs.statSync(dataPath).size,
    sha256: sha256(dataPath)
  })}\n`, "utf8");
  const integritySha256 = sha256(integrityPath);
  const manifest = {
    formatVersion: 1,
    snapshotName,
    createdAt: completedAt,
    completedAt,
    integrity: {
      algorithm: "SHA256",
      indexFile: SNAPSHOT_INTEGRITY_FILE,
      indexSha256: integritySha256,
      fileCount: 1,
      totalBytes: fs.statSync(dataPath).size
    }
  };
  const manifestPath = path.join(snapshotPath, SNAPSHOT_MANIFEST_FILE);
  writeJson(manifestPath, manifest);
  writeJson(path.join(snapshotPath, SNAPSHOT_COMPLETE_FILE), {
    formatVersion: 1,
    snapshotName,
    completedAt,
    manifestFile: SNAPSHOT_MANIFEST_FILE,
    manifestSha256: sha256(manifestPath),
    integrityIndexFile: SNAPSHOT_INTEGRITY_FILE,
    integrityIndexSha256: integritySha256
  });
  return snapshotPath;
}

test("only complete snapshots with matching metadata are listed", (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-snapshots-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));

  createCompletedSnapshot(root, "2026-07-28_10-00-00", "2026-07-28T16:00:00.000Z");
  fs.mkdirSync(path.join(root, "snapshots", "2026-07-28_11-00-00"), { recursive: true });
  fs.mkdirSync(path.join(root, "snapshots", ".incomplete-2026-07-28_12-00-00.incomplete"), { recursive: true });
  fs.mkdirSync(path.join(root, "snapshots", ".stage"), { recursive: true });

  const result = inspectSnapshotsAtBaseRoot(root);
  assert.deepEqual(result.snapshots.map((snapshot) => snapshot.name), ["2026-07-28_10-00-00"]);
  assert.equal(result.unverifiedCount, 1);
  assert.equal(result.incompleteCount, 2);
});

test("tampering with a completed manifest invalidates the snapshot", (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-manifest-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const snapshotPath = createCompletedSnapshot(root, "2026-07-28_10-00-00", "2026-07-28T16:00:00.000Z");
  const manifestPath = path.join(snapshotPath, SNAPSHOT_MANIFEST_FILE);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  manifest.integrity.fileCount = 999;
  writeJson(manifestPath, manifest);

  assert.equal(inspectCompletedSnapshot(snapshotPath), null);
  assert.equal(inspectSnapshotsAtBaseRoot(root).snapshots.length, 0);
});

test("tampering with the integrity index invalidates the snapshot", (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-index-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const snapshotPath = createCompletedSnapshot(root, "2026-07-28_10-00-00", "2026-07-28T16:00:00.000Z");
  fs.appendFileSync(path.join(snapshotPath, SNAPSHOT_INTEGRITY_FILE), "{\"path\":\"tampered.txt\"}\n", "utf8");

  assert.equal(inspectCompletedSnapshot(snapshotPath), null);
  assert.equal(inspectSnapshotsAtBaseRoot(root).snapshots.length, 0);
});

test("an added unindexed file invalidates the completed snapshot", (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-extra-file-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const snapshotPath = createCompletedSnapshot(root, "2026-07-28_10-00-00", "2026-07-28T16:00:00.000Z");
  fs.writeFileSync(path.join(snapshotPath, "unexpected-file.txt"), "not in the integrity index", "utf8");

  assert.equal(inspectCompletedSnapshot(snapshotPath), null);
  assert.equal(inspectSnapshotsAtBaseRoot(root).snapshots.length, 0);
});

test("PowerShell restore integrity rejects an added unindexed file", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-powershell-extra-file-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const snapshotPath = createPowerShellCompletedSnapshot(root, "2026-07-28_10-00-00", "2026-07-28T16:00:00.000Z");
  fs.writeFileSync(path.join(snapshotPath, "item", "unexpected-file.txt"), "not in the integrity index", "utf8");

  const safetyModule = path.join(__dirname, "..", "windows", "DataSafe.Safety.ps1").replace(/'/g, "''");
  const escapedSnapshotPath = snapshotPath.replace(/'/g, "''");
  const result = spawnSync(powerShell, [
    "-NoProfile",
    "-Command",
    `& { $ErrorActionPreference = 'Stop'; . '${safetyModule}'; function Get-FileHash { throw 'Get-FileHash unavailable' }; Test-DataSafeIntegrityIndex -SnapshotPath '${escapedSnapshotPath}' | Out-Null }`
  ], { encoding: "utf8" });

  assert.notEqual(result.status, 0);
  assert.match(`${result.stderr}\n${result.stdout}`, /unexpected-file\.txt/i);
});

test("PowerShell safety hashes files when Get-FileHash is unavailable", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-sha256-fallback-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const filePath = path.join(root, "customer-file.txt");
  fs.writeFileSync(filePath, "verified backup data", "utf8");

  const safetyModule = powerShellLiteral(path.join(__dirname, "..", "windows", "DataSafe.Safety.ps1"));
  const result = runPowerShellScript(powerShell, `
$ErrorActionPreference = 'Stop'
. '${safetyModule}'
function Get-FileHash { throw 'Get-FileHash unavailable' }
$actual = Get-DataSafeSha256 -Path '${powerShellLiteral(filePath)}'
if ($actual -ne '${sha256(filePath)}') { throw "Unexpected SHA-256 value: $actual" }
`);

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
});

test("short staging paths keep the reported Rockstar cache path below Windows' legacy limit", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-staging-path-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const safetyModule = powerShellLiteral(path.join(__dirname, "..", "windows", "DataSafe.Safety.ps1"));
  const snapshotsRoot = powerShellLiteral(path.join(root, "snapshots"));
  const result = runPowerShellScript(powerShell, `
$ErrorActionPreference = 'Stop'
. '${safetyModule}'
$snapshotsRoot = '${snapshotsRoot}'
New-Item -ItemType Directory -Force -Path $snapshotsRoot | Out-Null
$stagingPath = Get-DataSafeStagingSnapshotPath -SnapshotsRoot $snapshotsRoot
if ((Split-Path -Leaf $stagingPath) -ne '.stage') { throw "Unexpected staging folder: $stagingPath" }
New-Item -ItemType Directory -Force -Path $stagingPath | Out-Null
Remove-DataSafeIncompleteSnapshots -SnapshotsRoot $snapshotsRoot
if (Test-Path -LiteralPath $stagingPath) { throw 'short staging folder was not cleaned up' }
$rockstarSuffix = 'Users\\baker\\Documents\\Rockstar Games\\Social Club\\Launcher\\Renderer\\Service Worker\\CacheStorage\\7c129e28a53a20755871f994f1997209760a9724\\94089f3e-f2fd-4ba8-a2f1-6ce9be4867d9'
$legacyPath = 'E:\\DataSafe Backup\\snapshots\\.incomplete-2026-07-30_21-49-14-9ac611c5840448a2b641675ac17d3e45.incomplete\\' + $rockstarSuffix
$shortPath = 'E:\\DataSafe Backup\\snapshots\\.stage\\' + $rockstarSuffix
if ($legacyPath.Length -le 260) { throw "incident path was not over the legacy limit: $($legacyPath.Length)" }
if ($shortPath.Length -ge 260) { throw "short staging path still exceeds the legacy limit: $($shortPath.Length)" }
`);

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
});

test("incomplete staging cleanup warns when Windows cannot remove the folder", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-staging-cleanup-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const safetyModule = powerShellLiteral(path.join(__dirname, "..", "windows", "DataSafe.Safety.ps1"));
  const snapshotsRoot = powerShellLiteral(path.join(root, "snapshots"));
  const result = runPowerShellScript(powerShell, `
$ErrorActionPreference = 'Stop'
. '${safetyModule}'
$snapshotsRoot = '${snapshotsRoot}'
$stagingPath = Get-DataSafeStagingSnapshotPath -SnapshotsRoot $snapshotsRoot
New-Item -ItemType Directory -Force -Path $stagingPath | Out-Null
function Remove-Item {
  param([Parameter(ValueFromRemainingArguments = $true)]$Remaining)
  throw 'simulated locked staging folder'
}
$warnings = @(& { Remove-DataSafeIncompleteSnapshots -SnapshotsRoot $snapshotsRoot } 3>&1)
if ($warnings.Count -eq 0) { throw 'staging cleanup did not report the deletion failure' }
if ("$warnings" -notmatch 'could not remove incomplete backup folder') { throw "unexpected cleanup warning: $warnings" }
`);

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
});

test("snapshot metadata retains the source identity needed for recovery", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-manifest-source-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const safetyModule = powerShellLiteral(path.join(__dirname, "..", "windows", "DataSafe.Safety.ps1"));
  const snapshotPath = powerShellLiteral(path.join(root, "snapshot"));
  const result = runPowerShellScript(powerShell, `
$ErrorActionPreference = 'Stop'
. '${safetyModule}'
function Get-FileHash { throw 'Get-FileHash unavailable' }
New-Item -ItemType Directory -Force -Path '${snapshotPath}' | Out-Null
$config = [PSCustomObject]@{
  installId = 'install-1'
  destination = [PSCustomObject]@{ id = 'destination-1' }
}
$job = [PSCustomObject]@{
  id = 'documents'
  name = 'Documents'
  type = 'folder'
  path = 'C:\\Users\\Customer\\Documents'
  sourceKind = 'folder'
  processNames = @('example-app')
  relativeDestination = @('User folders', 'Documents')
}
$integrity = [PSCustomObject]@{ sha256 = 'ABC'; fileCount = 1; totalBytes = 10 }
$metadata = Write-DataSafeSnapshotMetadata -SnapshotPath '${snapshotPath}' -SnapshotName '2026-07-28_10-00-00' -Config $config -Jobs @($job) -Integrity $integrity
if ($metadata.manifest.jobs[0].sourcePath -ne 'C:\\Users\\Customer\\Documents') { throw 'source path missing from manifest' }
if ($metadata.manifest.jobs[0].sourceKind -ne 'folder') { throw 'source kind missing from manifest' }
`);

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
});

test("only an unchanged current job qualifies for original-location restore", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const safetyModule = powerShellLiteral(path.join(__dirname, "..", "windows", "DataSafe.Safety.ps1"));
  const result = runPowerShellScript(powerShell, `
$ErrorActionPreference = 'Stop'
. '${safetyModule}'
$snapshotJob = [PSCustomObject]@{ id = 'documents'; type = 'folder'; sourcePath = 'C:\\Users\\Customer\\Documents' }
$sameJob = [PSCustomObject]@{ id = 'documents'; type = 'folder'; path = 'C:\\Users\\Customer\\Documents' }
$changedJob = [PSCustomObject]@{ id = 'documents'; type = 'folder'; path = 'D:\\Different Documents' }
if (-not (Test-DataSafeSnapshotJobMatchesActiveJob -SnapshotJob $snapshotJob -ActiveJob $sameJob)) { throw 'matching job was rejected' }
if (Test-DataSafeSnapshotJobMatchesActiveJob -SnapshotJob $snapshotJob -ActiveJob $changedJob) { throw 'changed job was accepted' }
`);

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
});

test("alternate restores reject protected source and repository folders", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-restore-target-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const sourcePath = path.join(root, "source");
  const baseRoot = path.join(root, "backup");
  const snapshotPath = path.join(baseRoot, "snapshots", "2026-07-28_10-00-00");
  fs.mkdirSync(sourcePath, { recursive: true });
  fs.mkdirSync(snapshotPath, { recursive: true });
  const safetyModule = powerShellLiteral(path.join(__dirname, "..", "windows", "DataSafe.Safety.ps1"));
  const result = runPowerShellScript(powerShell, `
$ErrorActionPreference = 'Stop'
. '${safetyModule}'
$sourcePath = '${powerShellLiteral(sourcePath)}'
$baseRoot = '${powerShellLiteral(baseRoot)}'
$snapshotPath = '${powerShellLiteral(snapshotPath)}'
$sourceRejected = $false
try { Assert-DataSafeAlternateRestoreTarget -ChosenTarget (Join-Path $sourcePath 'restore-here') -BaseRoot $baseRoot -SnapshotRoot $snapshotPath -OriginalSourcePath $sourcePath } catch { $sourceRejected = $true }
if (-not $sourceRejected) { throw 'source folder was accepted' }
$repositoryRejected = $false
try { Assert-DataSafeAlternateRestoreTarget -ChosenTarget $baseRoot -BaseRoot $baseRoot -SnapshotRoot $snapshotPath -OriginalSourcePath $sourcePath } catch { $repositoryRejected = $true }
if (-not $repositoryRejected) { throw 'backup repository was accepted' }
Assert-DataSafeAlternateRestoreTarget -ChosenTarget (Join-Path '${powerShellLiteral(root)}' 'recovered') -BaseRoot $baseRoot -SnapshotRoot $snapshotPath -OriginalSourcePath $sourcePath
`);

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
});

test("a DataSafe operation lock rejects a concurrent backup or restore", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-operation-lock-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const safetyModule = powerShellLiteral(path.join(__dirname, "..", "windows", "DataSafe.Safety.ps1"));
  const lockPath = powerShellLiteral(path.join(root, "status.json.lock"));
  const result = runPowerShellScript(powerShell, `
$ErrorActionPreference = 'Stop'
. '${safetyModule}'
$lockPath = '${lockPath}'
$first = Acquire-DataSafeOperationLock $lockPath
try {
  $rejected = $false
  try { $second = Acquire-DataSafeOperationLock $lockPath } catch { $rejected = $true }
  if (-not $rejected) { throw 'second operation acquired the lock' }
} finally {
  Release-DataSafeOperationLock $first $lockPath
}
if (Test-Path -LiteralPath $lockPath) { throw 'lock file remained after release' }
`);

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
});

test("catch-up sign-in trigger is scoped to the current DataSafe user", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const taskModule = powerShellLiteral(path.join(__dirname, "..", "windows", "DataSafe.ScheduledTasks.ps1"));
  const result = runPowerShellScript(powerShell, `
$ErrorActionPreference = 'Stop'
function New-ScheduledTaskTrigger {
  param([switch]$AtLogOn, [string]$User)
  return [PSCustomObject]@{ AtLogOn = $AtLogOn.IsPresent; User = $User }
}
. '${taskModule}'
$trigger = New-DataSafeCatchUpLogonTrigger -TaskUser 'CONTOSO\\Customer'
if (-not $trigger.AtLogOn) { throw 'catch-up trigger is not a sign-in trigger' }
if ($trigger.User -ne 'CONTOSO\\Customer') { throw "catch-up trigger was not scoped to the current user: $($trigger.User)" }
`);

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
});

test("catch-up skips a recent completed backup that only has a retention warning", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-catchup-warning-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const configPath = path.join(root, "config.json");
  const statusPath = path.join(root, "status.json");
  writeJson(configPath, { schedule: { enabled: true, frequency: "daily", time: "00:00" } });
  writeJson(statusPath, {
    lastBackupAt: new Date().toISOString(),
    lastBackupResult: "warning",
    lastBackupMessage: "The snapshot completed, but retention needs attention."
  });

  const result = spawnSync(powerShell, [
    "-NoProfile",
    "-File",
    path.join(__dirname, "..", "windows", "check-backup-catchup.ps1"),
    "-ConfigPath",
    configPath,
    "-StatusPath",
    statusPath,
    "-ScriptRoot",
    path.join(__dirname, "..", "windows")
  ], { encoding: "utf8" });

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.match(result.stdout, /No missed DataSafe backup is due/i);
});

test("cloud checks identify local configuration rather than verified provider backup", (context) => {
  const powerShell = findPowerShell();
  if (!powerShell) {
    context.skip("PowerShell is not installed in this test environment.");
    return;
  }

  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-cloud-scope-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const configPath = path.join(root, "config.json");
  const statusPath = path.join(root, "status.json");
  writeJson(configPath, {});
  writeJson(statusPath, {});

  const result = spawnSync(powerShell, [
    "-NoProfile",
    "-File",
    path.join(__dirname, "..", "windows", "check-cloud-health.ps1"),
    "-ConfigPath",
    configPath,
    "-StatusPath",
    statusPath
  ], { encoding: "utf8" });

  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  const status = JSON.parse(fs.readFileSync(statusPath, "utf8"));
  assert.equal(status.cloud.verificationScope, "local-configuration");
  assert.match(status.cloud.summary, /does not verify cloud uploads, quota, or provider errors/i);
});

test("preview server refuses asset traversal outside the assets folder", async (context) => {
  const port = 43000 + Math.floor(Math.random() * 1000);
  const preview = await startPreviewServer(port);
  context.after(() => preview.kill());

  const response = await requestPreview(port, "/assets/../data/config.json");
  assert.equal(response.statusCode, 404);
  assert.doesNotMatch(response.body, /installId|destination/i);
});

test("completed snapshots are ordered by their recorded completion time", (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-order-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));

  createCompletedSnapshot(root, "2026-07-27_10-00-00", "2026-07-27T16:00:00.000Z");
  createCompletedSnapshot(root, "2026-07-28_10-00-00", "2026-07-28T16:00:00.000Z");

  assert.deepEqual(
    inspectSnapshotsAtBaseRoot(root).snapshots.map((snapshot) => snapshot.name),
    ["2026-07-28_10-00-00", "2026-07-27_10-00-00"]
  );
});

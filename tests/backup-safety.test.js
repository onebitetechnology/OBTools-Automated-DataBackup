const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
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

test("only complete snapshots with matching metadata are listed", (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "datasafe-snapshots-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));

  createCompletedSnapshot(root, "2026-07-28_10-00-00", "2026-07-28T16:00:00.000Z");
  fs.mkdirSync(path.join(root, "snapshots", "2026-07-28_11-00-00"), { recursive: true });
  fs.mkdirSync(path.join(root, "snapshots", ".incomplete-2026-07-28_12-00-00.incomplete"), { recursive: true });

  const result = inspectSnapshotsAtBaseRoot(root);
  assert.deepEqual(result.snapshots.map((snapshot) => snapshot.name), ["2026-07-28_10-00-00"]);
  assert.equal(result.unverifiedCount, 1);
  assert.equal(result.incompleteCount, 1);
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

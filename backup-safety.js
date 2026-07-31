const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const SNAPSHOT_NAME_PATTERN = /^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$/;
const SNAPSHOT_MANIFEST_FILE = ".datasafe-manifest.json";
const SNAPSHOT_COMPLETE_FILE = ".datasafe-complete.json";
const SNAPSHOT_INTEGRITY_FILE = ".datasafe-integrity.jsonl";
const SNAPSHOT_VERIFICATION_FILE = ".datasafe-verification.json";

function readJson(filePath) {
  const raw = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
  return JSON.parse(raw);
}

function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  const descriptor = fs.openSync(filePath, "r");
  const buffer = Buffer.allocUnsafe(1024 * 1024);

  try {
    let bytesRead = 0;
    do {
      bytesRead = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      if (bytesRead > 0) {
        hash.update(buffer.subarray(0, bytesRead));
      }
    } while (bytesRead > 0);
  } finally {
    fs.closeSync(descriptor);
  }

  return hash.digest("hex").toUpperCase();
}

function isSafeSnapshotName(value) {
  return SNAPSHOT_NAME_PATTERN.test(String(value || ""));
}

function normalizeIntegrityPath(value) {
  const normalized = String(value || "").replace(/\\/g, "/");
  if (!normalized || normalized.startsWith("/") || /^[A-Za-z]:\//.test(normalized)) {
    return null;
  }

  const parts = normalized.split("/");
  if (parts.some((part) => !part || part === "." || part === "..")) {
    return null;
  }

  return parts.join("/");
}

function listSnapshotFiles(snapshotPath, ignoredNames) {
  const files = new Set();
  const visit = (directoryPath, relativeDirectory) => {
    for (const entry of fs.readdirSync(directoryPath, { withFileTypes: true })) {
      const relativePath = relativeDirectory ? `${relativeDirectory}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        visit(path.join(directoryPath, entry.name), relativePath);
      } else if (entry.isFile() && !ignoredNames.has(relativePath)) {
        files.add(relativePath);
      }
    }
  };

  visit(snapshotPath, "");
  return files;
}

function snapshotTreeMatchesIntegrityIndex(snapshotPath, integrityPath) {
  const indexedFiles = new Set();
  const indexLines = fs.readFileSync(integrityPath, "utf8").split(/\r?\n/);
  for (const line of indexLines) {
    if (!line.trim()) {
      continue;
    }

    const relativePath = normalizeIntegrityPath(JSON.parse(line).path);
    if (!relativePath || indexedFiles.has(relativePath)) {
      return false;
    }

    indexedFiles.add(relativePath);
  }

  const metadataFiles = new Set([
    SNAPSHOT_MANIFEST_FILE,
    SNAPSHOT_COMPLETE_FILE,
    SNAPSHOT_INTEGRITY_FILE,
    SNAPSHOT_VERIFICATION_FILE
  ]);
  const snapshotFiles = listSnapshotFiles(snapshotPath, metadataFiles);
  if (snapshotFiles.size !== indexedFiles.size) {
    return false;
  }

  return [...snapshotFiles].every((relativePath) => indexedFiles.has(relativePath));
}

function inspectCompletedSnapshot(snapshotPath) {
  const snapshotName = path.basename(snapshotPath);
  if (!isSafeSnapshotName(snapshotName)) {
    return null;
  }

  const manifestPath = path.join(snapshotPath, SNAPSHOT_MANIFEST_FILE);
  const completePath = path.join(snapshotPath, SNAPSHOT_COMPLETE_FILE);
  const integrityPath = path.join(snapshotPath, SNAPSHOT_INTEGRITY_FILE);
  if (![manifestPath, completePath, integrityPath].every((filePath) => fs.existsSync(filePath))) {
    return null;
  }

  try {
    const manifest = readJson(manifestPath);
    const complete = readJson(completePath);
    if (
      Number(manifest.formatVersion) !== 1 ||
      Number(complete.formatVersion) !== 1 ||
      manifest.snapshotName !== snapshotName ||
      complete.snapshotName !== snapshotName ||
      String(complete.manifestFile || "") !== SNAPSHOT_MANIFEST_FILE ||
      String(complete.integrityIndexFile || "") !== SNAPSHOT_INTEGRITY_FILE
    ) {
      return null;
    }

    const manifestSha256 = sha256File(manifestPath);
    if (manifestSha256 !== String(complete.manifestSha256 || "").toUpperCase()) {
      return null;
    }

    if (
      String(manifest.integrity?.indexSha256 || "").toUpperCase() !==
      String(complete.integrityIndexSha256 || "").toUpperCase()
    ) {
      return null;
    }

    if (
      String(manifest.integrity?.indexFile || "") !== SNAPSHOT_INTEGRITY_FILE ||
      sha256File(integrityPath) !== String(complete.integrityIndexSha256 || "").toUpperCase()
    ) {
      return null;
    }

    if (!snapshotTreeMatchesIntegrityIndex(snapshotPath, integrityPath)) {
      return null;
    }

    let verification = null;
    const verificationPath = path.join(snapshotPath, SNAPSHOT_VERIFICATION_FILE);
    if (fs.existsSync(verificationPath)) {
      try {
        verification = readJson(verificationPath);
      } catch (_error) {
        verification = null;
      }
    }

    const completedAt = Date.parse(complete.completedAt || manifest.completedAt || manifest.createdAt || "");
    return {
      name: snapshotName,
      fullPath: snapshotPath,
      createdAt: Number.isFinite(completedAt) ? completedAt : 0,
      completedAt: complete.completedAt || manifest.completedAt || null,
      fileCount: Number(manifest.integrity?.fileCount || 0),
      totalBytes: Number(manifest.integrity?.totalBytes || 0),
      manifest,
      verification
    };
  } catch (_error) {
    return null;
  }
}

function inspectSnapshotsAtBaseRoot(baseRoot) {
  if (!baseRoot) {
    return {
      baseRoot: baseRoot || null,
      snapshots: [],
      incompleteCount: 0,
      unverifiedCount: 0
    };
  }

  const snapshotsRoot = path.join(baseRoot, "snapshots");
  if (!fs.existsSync(snapshotsRoot)) {
    return {
      baseRoot,
      snapshots: [],
      incompleteCount: 0,
      unverifiedCount: 0
    };
  }

  try {
    const snapshots = [];
    let incompleteCount = 0;
    let unverifiedCount = 0;

    for (const entry of fs.readdirSync(snapshotsRoot, { withFileTypes: true })) {
      if (!entry.isDirectory()) {
        continue;
      }

      if (/\.incomplete$/i.test(entry.name) || /^\.incomplete-/i.test(entry.name)) {
        incompleteCount += 1;
        continue;
      }

      if (!isSafeSnapshotName(entry.name)) {
        continue;
      }

      const completed = inspectCompletedSnapshot(path.join(snapshotsRoot, entry.name));
      if (completed) {
        snapshots.push(completed);
      } else {
        unverifiedCount += 1;
      }
    }

    snapshots.sort((left, right) => right.createdAt - left.createdAt || right.name.localeCompare(left.name));
    return {
      baseRoot,
      snapshots,
      incompleteCount,
      unverifiedCount
    };
  } catch (_error) {
    return {
      baseRoot,
      snapshots: [],
      incompleteCount: 0,
      unverifiedCount: 0
    };
  }
}

module.exports = {
  SNAPSHOT_COMPLETE_FILE,
  SNAPSHOT_INTEGRITY_FILE,
  SNAPSHOT_MANIFEST_FILE,
  SNAPSHOT_NAME_PATTERN,
  SNAPSHOT_VERIFICATION_FILE,
  inspectCompletedSnapshot,
  inspectSnapshotsAtBaseRoot,
  isSafeSnapshotName,
  normalizeIntegrityPath,
  sha256File
};

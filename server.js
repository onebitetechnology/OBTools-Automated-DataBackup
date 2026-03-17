const http = require("http");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const ROOT = __dirname;
const DATA_DIR = path.join(ROOT, "data");
const CONFIG_PATH = path.join(DATA_DIR, "config.json");
const STATUS_PATH = path.join(DATA_DIR, "status.json");
const WINDOWS_DIR = path.join(ROOT, "windows");
const PORT = Number(process.env.PORT || 3200);

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json"
  });
  response.end(JSON.stringify(payload));
}

function serveFile(response, filePath, type) {
  response.writeHead(200, { "Content-Type": type });
  response.end(fs.readFileSync(filePath));
}

function contentTypeFor(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  if (extension === ".css") {
    return "text/css; charset=utf-8";
  }
  if (extension === ".js") {
    return "application/javascript; charset=utf-8";
  }
  if (extension === ".jpg" || extension === ".jpeg") {
    return "image/jpeg";
  }
  if (extension === ".png") {
    return "image/png";
  }
  if (extension === ".svg") {
    return "image/svg+xml";
  }
  return "application/octet-stream";
}

function mergeStatus(patch) {
  const next = {
    ...readJson(STATUS_PATH),
    ...patch
  };
  writeJson(STATUS_PATH, next);
  return next;
}

function simulateAction(scriptName) {
  const status = readJson(STATUS_PATH);
  const now = new Date();

  if (scriptName === "backup-engine.ps1") {
    const timestamp = now.toISOString().replace(/[:.]/g, "-");
    status.lastBackupAt = now.toISOString();
    status.lastBackupResult = "success";
    status.lastBackupMessage = "Preview mode: simulated backup completed on this device.";
    status.destinationStatus = "Preview Mode";
    status.recentSnapshots = [timestamp, ...(status.recentSnapshots || [])].slice(0, 5);
    writeJson(STATUS_PATH, status);
    return { ok: true, message: status.lastBackupMessage };
  }

  if (scriptName === "check-cloud-health.ps1") {
    status.cloud = {
      checkedAt: now.toISOString(),
      summary: "Preview mode: cloud sync review completed.",
      level: "info",
      recommendations: [
        "Confirm OneDrive or another cloud sync tool is signed in on the customer PC.",
        "Keep local USB backups enabled even when cloud sync appears healthy."
      ]
    };
    writeJson(STATUS_PATH, status);
    return { ok: true, message: status.cloud.summary };
  }

  if (scriptName === "install-scheduled-backup.ps1") {
    status.automation = {
      installedAt: now.toISOString(),
      message: "Preview mode: Windows automation simulated."
    };
    writeJson(STATUS_PATH, status);
    return { ok: true, message: status.automation.message };
  }

  return { ok: true, message: `Preview mode: simulated ${scriptName}.` };
}

function runPowerShell(scriptName) {
  return new Promise((resolve) => {
    if (process.platform !== "win32") {
      resolve({
        ...simulateAction(scriptName),
        code: 0
      });
      return;
    }

    const scriptPath = path.join(WINDOWS_DIR, scriptName);
    const child = spawn("powershell.exe", [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scriptPath,
      "-ConfigPath",
      CONFIG_PATH,
      "-StatusPath",
      STATUS_PATH
    ], {
      cwd: ROOT
    });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("close", (code) => {
      resolve({
        ok: code === 0,
        code,
        message: stderr.trim() || stdout.trim() || `Exited with code ${code}.`
      });
    });
  });
}

function parseRequestBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";

    request.on("data", (chunk) => {
      body += chunk.toString();
    });

    request.on("end", () => {
      if (!body) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(body));
      } catch (error) {
        reject(error);
      }
    });

    request.on("error", reject);
  });
}

async function handleApi(request, response) {
  if (request.method === "GET" && request.url === "/api/state") {
    sendJson(response, 200, {
      config: readJson(CONFIG_PATH),
      status: readJson(STATUS_PATH)
    });
    return;
  }

  if (request.method === "POST" && request.url === "/api/config") {
    const config = await parseRequestBody(request);
    writeJson(CONFIG_PATH, config);
    sendJson(response, 200, {
      config,
      status: readJson(STATUS_PATH)
    });
    return;
  }

  if (request.method === "POST" && request.url === "/api/run-backup") {
    const result = await runPowerShell("backup-engine.ps1");
    const status = mergeStatus({
      lastBackupResult: result.ok ? "success" : "error",
      lastBackupMessage: result.message
    });
    sendJson(response, 200, { status });
    return;
  }

  if (request.method === "POST" && request.url === "/api/check-cloud") {
    const result = await runPowerShell("check-cloud-health.ps1");
    const status = mergeStatus({
      cloud: {
        ...readJson(STATUS_PATH).cloud,
        checkedAt: new Date().toISOString(),
        summary: result.message || "Cloud check completed."
      }
    });
    sendJson(response, 200, { status });
    return;
  }

  if (request.method === "POST" && request.url === "/api/install-automation") {
    const result = await runPowerShell("install-scheduled-backup.ps1");
    const status = mergeStatus({
      lastBackupMessage: result.message
    });
    sendJson(response, 200, { status });
    return;
  }

  sendJson(response, 404, { error: "Not found" });
}

const server = http.createServer(async (request, response) => {
  try {
    if (request.url === "/" || request.url === "/index.html") {
      serveFile(response, path.join(ROOT, "index.html"), "text/html; charset=utf-8");
      return;
    }

    if (request.url === "/styles.css") {
      serveFile(response, path.join(ROOT, "styles.css"), "text/css; charset=utf-8");
      return;
    }

    if (request.url === "/app.js") {
      serveFile(response, path.join(ROOT, "app.js"), "application/javascript; charset=utf-8");
      return;
    }

    if (request.url.startsWith("/assets/")) {
      const assetPath = path.join(ROOT, request.url);
      if (!fs.existsSync(assetPath) || !fs.statSync(assetPath).isFile()) {
        sendJson(response, 404, { error: "Not found" });
        return;
      }

      serveFile(response, assetPath, contentTypeFor(assetPath));
      return;
    }

    if (request.url.startsWith("/api/")) {
      await handleApi(request, response);
      return;
    }

    sendJson(response, 404, { error: "Not found" });
  } catch (error) {
    sendJson(response, 500, { error: error.message });
  }
});

server.listen(PORT, () => {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  console.log(`One Bite Technology Backup Companion running at http://localhost:${PORT}`);
});

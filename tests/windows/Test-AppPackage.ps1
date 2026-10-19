param(
  [Parameter(Mandatory=$true)][string]$PackagedRoot,
  [Parameter(Mandatory=$true)][string]$SourceRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packagePath = (Resolve-Path -LiteralPath $PackagedRoot).Path
$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$executable = Join-Path $packagePath 'DataSafe.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Packaged DataSafe.exe is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $packagePath 'resources/app.asar') -PathType Leaf)) { throw 'Packaged app.asar is missing.' }
# Run only an audit expression under the packaged Electron runtime. Do not load
# main.js, renderer entry points, or any installed-user configuration/worker.
$audit = @'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const vm = require('vm');
const { createRequire } = require('module');
if (!process.versions.electron) throw new Error('Package audit requires Electron');
const source = process.env.DATASAFE_PACKAGE_AUDIT_SOURCE;
const resources = path.join(process.env.DATASAFE_PACKAGE_AUDIT_ROOT, 'resources');
const app = path.join(resources, 'app.asar');
const loader = createRequire(path.join(app, 'package.json'));
const baselineModules = new Set(Object.keys(require.cache));
const hashes = [];
function compare(relative, target) {
  const original = fs.readFileSync(path.join(source, relative));
  const packaged = fs.readFileSync(target);
  if (!original.equals(packaged)) throw new Error('Source/resource mismatch: ' + relative);
  hashes.push({ path: relative.replaceAll('\\', '/'), sha256: crypto.createHash('sha256').update(packaged).digest('hex') });
}
const modules = ['backup-safety.js', 'backup-format.js', 'backup-catalog.js', 'backup-service.js', 'backup-view.js'];
for (const name of modules) {
  compare(name, path.join(app, name));
  const resolved = loader.resolve('./' + name);
  if (!resolved.startsWith(app + path.sep)) throw new Error('Module escaped packaged app: ' + name);
  loader('./' + name);
}
const updater = loader.resolve('electron-updater');
if (!updater.startsWith(app + path.sep)) throw new Error('Updater escaped packaged app');
// Loading updater's exports is safe; never access its lazy autoUpdater getter,
// which initializes Electron APIs and app configuration.
loader('electron-updater');
for (const resolved of Object.keys(require.cache)) {
  if (!baselineModules.has(resolved) && !resolved.startsWith(app + path.sep)) {
    throw new Error('Dependency escaped packaged app: ' + resolved);
  }
}
for (const name of ['main.js', 'preload.js', 'app.js', 'server.js']) {
  compare(name, path.join(app, name));
  new vm.Script(fs.readFileSync(path.join(app, name), 'utf8'), { filename: name });
}
for (const name of ['index.html', 'styles.css', 'professional.css']) compare(name, path.join(app, name));
const originalPackage = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'));
const packagedPackage = loader('./package.json');
for (const field of ['name', 'version', 'main']) {
  if (originalPackage[field] !== packagedPackage[field]) throw new Error('Packaged package.json mismatch: ' + field);
}
function walk(relative, targetRoot) {
  const entries = fs.readdirSync(path.join(source, relative), { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isSymbolicLink()) throw new Error('Unexpected source resource link');
    const child = path.join(relative, entry.name);
    if (entry.isDirectory()) walk(child, targetRoot);
    else compare(child, path.join(targetRoot, child));
  }
}
// Enumerate source resources, not packaged resources: omissions must fail.
walk('windows', resources);
walk('data', resources);
walk('assets', app);
const updateConfig = fs.readFileSync(path.join(resources, 'app-update.yml'), 'utf8');
if (/-beta/i.test(packagedPackage.version) && !/^channel:\s*beta\s*$/m.test(updateConfig)) throw new Error('Packaged beta feed is not beta');
console.log(JSON.stringify({ schema: 'datasafe.package-audit', formatVersion: 1,
  version: packagedPackage.version, electron: process.versions.electron,
  moduleResolution: 'packaged-electron-asar', hashes }));
'@
$names = @('ELECTRON_RUN_AS_NODE', 'DATASAFE_PACKAGE_AUDIT_SOURCE', 'DATASAFE_PACKAGE_AUDIT_ROOT', 'NODE_OPTIONS', 'NODE_PATH')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
  $env:ELECTRON_RUN_AS_NODE = '1'
  $env:DATASAFE_PACKAGE_AUDIT_SOURCE = $sourcePath
  $env:DATASAFE_PACKAGE_AUDIT_ROOT = $packagePath
  $env:NODE_OPTIONS = $null
  $env:NODE_PATH = $null
  # An explicit pipeline consumer makes Windows PowerShell wait for GUI-subsystem
  # Electron and capture its exit status as well as stdout.
  $output = & $executable -e $audit | Out-String
  if ($LASTEXITCODE -ne 0) { throw "Packaged Electron audit failed (exit $LASTEXITCODE)." }
  $result = ($output -join "`n") | ConvertFrom-Json
  if ($result.schema -ne 'datasafe.package-audit' -or $result.hashes.Count -lt 1) { throw 'Missing package audit evidence.' }
  $output
} finally {
  foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}

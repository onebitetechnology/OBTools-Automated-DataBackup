const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const yaml = require('js-yaml');
const { createUpdateInfoTasks } = require('app-builder-lib/out/publish/updateInfoBuilder');
const { Platform } = require('app-builder-lib/out/core');
const root = path.resolve(__dirname, '..');
const configSource = fs.readFileSync(path.join(root, 'electron-builder.config.js'), 'utf8');
function config(version, env = {}) {
  const context = { module: { exports: {} }, process: { env }, require: name => {
    assert.equal(name, './package.json');
    return { version };
  } };
  vm.runInNewContext(configSource, context);
  return context.module.exports;
}
async function metadataNames(configuration, version) {
  const packager = { config: configuration, platformSpecificBuildOptions: configuration.win,
    platform: Platform.WINDOWS, appInfo: { version }, getResource: async () => null,
    info: { metadata: { dependencies: { 'electron-updater': '^6.8.9' } } } };
  const tasks = await createUpdateInfoTasks({ packager, target: { outDir: 'dist' },
    file: 'dist/installer.exe', arch: 1, updateInfo: { sha512: 'fixture-hash' } }, configuration.win.publish);
  return tasks.map(task => path.basename(task.file));
}
test('beta config isolates generated metadata and keeps normal app identity', async () => {
  const beta = config('1.0.10-beta.70');
  assert.equal(beta.generateUpdatesFilesForAllChannels, false);
  assert.equal(beta.appId, 'ca.onebitetechnology.backupcompanion');
  assert.equal(beta.win.publish[0].channel, 'beta');
  assert.deepEqual(await metadataNames(beta, '1.0.10-beta.70'), ['beta.yml']);
});
test('beta channel and prerelease policy cannot be overridden to stable', () => {
  assert.throws(() => config('1.0.10-beta.70', { OBTOOLS_RELEASE_CHANNEL: 'latest' }), /beta/i);
  assert.throws(() => config('1.0.10-beta.70', { OBTOOLS_RELEASE_TYPE: 'release' }), /beta/i);
});
test('stable config preserves existing stable metadata behavior', async () => {
  const stable = config('1.0.10');
  assert.equal(stable.generateUpdatesFilesForAllChannels, true);
  assert.equal(stable.win.publish[0].channel, 'latest');
  assert.equal(stable.win.publish[0].releaseType, 'release');
  assert.deepEqual(await metadataNames(stable, '1.0.10'), ['latest.yml']);
});
test('packaging includes new policy modules and complete Windows resources', () => {
  const builder = config('1.0.10-beta.70');
  for (const name of ['backup-safety.js', 'backup-format.js', 'backup-catalog.js', 'backup-service.js', 'backup-view.js']) {
    assert.ok(builder.files.includes(name), name);
  }
  assert.ok(builder.extraResources.some(resource => resource.from === 'windows' && resource.to === 'windows' && !resource.filter));
  assert.match(require('../package.json').scripts['dist:win'], /--publish never(?:\s|$)/);
});
test('manual release command fails closed with approved exact-artifact workflow guidance', () => {
  const script = require('../package.json').scripts['release:win'];
  // Fail before execution if the historical publish command is restored.
  assert.doesNotMatch(script, /electron-builder|--publish|npm\s+run/);
  const command = /^node -e "([^"]+)"$/.exec(script);
  assert.ok(command, 'Release guard must be a single node expression');
  const result = spawnSync(process.execPath, ['-e', command[1]], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /publish-qualified/);
  assert.match(result.stderr, /verified run ID and source SHA/);
});
test('workflow has read-only verification and separate approved exact-artifact publication', () => {
  const workflow = yaml.load(fs.readFileSync(path.join(root, '.github/workflows/build-windows-installer.yml'), 'utf8'));
  assert.equal(workflow.permissions.contents, 'read');
  assert.ok(workflow.on.push.branches.includes('main'));
  assert.deepEqual(workflow.on.workflow_dispatch.inputs.mode.options, ['verify-build', 'publish-qualified']);
  const verify = workflow.jobs['verify-build'];
  const publish = workflow.jobs['publish-qualified'];
  assert.equal(publish.environment, 'incremental-beta-release');
  assert.equal(publish.permissions.contents, 'write');
  assert.match(publish.if, /workflow_dispatch/);
  assert.match(publish.if, /publish-qualified/);
  const build = verify.steps.findIndex(step => step.run?.includes('npm run dist:win'));
  assert.ok(build > 0);
  for (const suite of ['Run-AppFormatPolicyTests', 'Run-BackupCatalogTests', 'Run-BetaAutomationTests', 'Run-AppIntegrationTests', 'Run-IncrementalEngineIntegrationTests', 'Run-IncrementalRecoveryRegressionTests']) {
    assert.ok(verify.steps.slice(0, build).some(step => step.run?.includes(suite)), suite);
  }
  assert.ok(verify.steps.slice(build + 1).some(step => step.run?.includes('Test-AppPackage.ps1')));
  assert.ok(verify.steps.slice(build + 1).some(step => step.run?.includes('Run-AppIntegrationTests.ps1 -WorkerRoot')));
  assert.equal(verify.steps.at(-1).uses, 'actions/upload-artifact@v4');
  assert.ok(publish.steps.some(step => step.uses === 'actions/download-artifact@v4' && step.with['run-id']));
  for (const step of [...verify.steps, ...publish.steps]) assert.doesNotMatch(step.run || '', /release:win|--publish always/);
  for (const step of publish.steps) assert.doesNotMatch(step.run || '', /npm (?:ci|run dist)|electron-builder/);
});

function workflow() {
  return yaml.load(fs.readFileSync(path.join(root, '.github/workflows/build-windows-installer.yml'), 'utf8'));
}
test('publish selection rejects wrong workflow, SHA, failed jobs, and unavailable artifacts', async () => {
  const script = workflow().jobs['publish-qualified'].steps[0].with.script;
  const sourceSha = 'a'.repeat(40);
  const runRecord = { conclusion: 'success', status: 'completed', head_sha: sourceSha,
    path: '.github/workflows/build-windows-installer.yml', event: 'push', run_attempt: 2,
    repository: { full_name: 'fixture-owner/fixture-repo' } };
  let jobs = [{ name: 'verify-build', conclusion: 'success' }];
  let artifacts = [{ name: `qualified-beta-123-2-${sourceSha}`, expired: false }];
  const outputs = {};
  const github = { rest: { actions: {
    getWorkflowRun: async () => ({ data: runRecord }),
    listJobsForWorkflowRun: 'jobs', listWorkflowRunArtifacts: 'artifacts'
  } }, paginate: async endpoint => endpoint === 'jobs' ? jobs : artifacts };
  const run = () => vm.runInNewContext(`(async () => { ${script}\n })()`, {
    process: { env: { VERIFIED_RUN_ID: '123', SOURCE_SHA: sourceSha } }, github,
    context: { repo: { owner: 'fixture-owner', repo: 'fixture-repo' } },
    core: { setOutput: (name, value) => { outputs[name] = value; } }
  });
  await run();
  assert.equal(outputs.artifact_name, `qualified-beta-123-2-${sourceSha}`);
  assert.equal(outputs.run_attempt, '2');
  for (const [field, invalid] of [['path', 'other-workflow.yml'], ['head_sha', 'b'.repeat(40)], ['conclusion', 'failure'], ['event', 'pull_request']]) {
    const saved = runRecord[field]; runRecord[field] = invalid;
    await assert.rejects(run, /provenance mismatch/); runRecord[field] = saved;
  }
  jobs = [{ name: 'verify-build', conclusion: 'skipped' }];
  await assert.rejects(run, /No successful verification job/);
  jobs = [{ name: 'verify-build', conclusion: 'success' }];
  artifacts[0].expired = true;
  await assert.rejects(run, /artifact unavailable/);
});
test('bundle sealing excludes builder diagnostics but rejects stable metadata', { skip: process.platform !== 'win32' }, () => {
  const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'datasafe-seal-test-'));
  try {
    fs.mkdirSync(path.join(owned, 'dist'));
    fs.writeFileSync(path.join(owned, 'package.json'), JSON.stringify({ version: '1.0.10-beta.70' }));
    for (const name of ['OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe', 'OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe.blockmap', 'beta.yml', 'package-audit.json', 'builder-debug.yml']) {
      fs.writeFileSync(path.join(owned, 'dist', name), name);
    }
    const script = workflow().jobs['verify-build'].steps.find(step => step.name === 'Seal exact beta artifact').run;
    const run = () => spawnSync('pwsh', ['-NoProfile', '-Command', script], { cwd: owned, encoding: 'utf8', timeout: 30000,
      env: { ...process.env, GITHUB_SHA: 'a'.repeat(40), GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '1' } });
    const valid = run();
    assert.equal(valid.status, 0, valid.stderr);
    assert.equal(fs.existsSync(path.join(owned, 'qualified', 'builder-debug.yml')), false);
    fs.writeFileSync(path.join(owned, 'dist', 'latest.yml'), 'stable');
    const invalid = run();
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, /Unexpected release files or stable metadata/);
  } finally { fs.rmSync(owned, { recursive: true, force: true }); }
});

test('publication validates real bundle bytes before any release mutation and never overwrites', async () => {
  const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'datasafe-publish-test-'));
  const version = '1.0.10-beta.70';
  const installer = `OBTools-Automated-Backups-Setup-${version}.exe`;
  const script = workflow().jobs['publish-qualified'].steps.at(-1).with.script;
  const sourceSha = 'a'.repeat(40);
  const writes = [];
  let tagExists = false;
  const notFound = async () => { throw Object.assign(new Error('not found'), { status: 404 }); };
  const github = { rest: { git: { getRef: async () => tagExists ? { data: {} } : notFound() }, repos: {
    getContent: async () => ({ data: { content: Buffer.from(JSON.stringify({ version })).toString('base64') } }),
    getReleaseByTag: notFound,
    createRelease: async input => { writes.push(['create', input]); return { data: { id: 99 } }; },
    uploadReleaseAsset: async input => { writes.push(['upload', input]); },
    updateRelease: async input => { writes.push(['update', input]); }
  } } };
  const run = async () => {
    const fileApi = {
      readFileSync: (name, encoding) => fs.readFileSync(path.join(owned, name), encoding),
      readdirSync: name => fs.readdirSync(path.join(owned, name))
    };
    const context = { require: name => name === 'fs' ? fileApi : require(name), Buffer,
      process: { env: { SOURCE_SHA: sourceSha, VERIFIED_RUN_ID: '123', VERIFIED_RUN_ATTEMPT: '1' } }, github,
      context: { repo: { owner: 'fixture-owner', repo: 'fixture-repo' } } };
    return vm.runInNewContext(`(async () => { ${script}\n })()`, context);
  };
  try {
    fs.mkdirSync(path.join(owned, 'qualified'));
    const files = {
      [installer]: Buffer.from('fixture installer bytes'), [`${installer}.blockmap`]: Buffer.from('fixture blockmap'),
      'beta.yml': Buffer.from(`version: ${version}\npath: ${installer}\n`),
      'package-audit.json': Buffer.from(JSON.stringify({ schema: 'datasafe.package-audit', version, moduleResolution: 'packaged-electron-asar', hashes: [{ path: 'fixture', sha256: 'b'.repeat(64) }] }))
    };
    const manifest = { schema: 'datasafe.qualified-beta', formatVersion: 1, version, sourceSha, runId: '123', runAttempt: '1', files: [] };
    for (const [name, data] of Object.entries(files)) {
      fs.writeFileSync(path.join(owned, 'qualified', name), data);
      manifest.files.push({ name, sha256: crypto.createHash('sha256').update(data).digest('hex') });
    }
    const save = () => fs.writeFileSync(path.join(owned, 'qualified/qualification.json'), JSON.stringify(manifest));
    save();
    fs.appendFileSync(path.join(owned, 'qualified', installer), 'tampered');
    await assert.rejects(run, /Hash mismatch/);
    assert.equal(writes.length, 0);
    fs.writeFileSync(path.join(owned, 'qualified', installer), files[installer]);
    manifest.sourceSha = 'b'.repeat(40); save();
    await assert.rejects(run, /provenance/);
    assert.equal(writes.length, 0);
    manifest.sourceSha = sourceSha; save();
    manifest.version = '1.0.10-beta.69'; save();
    await assert.rejects(run, /provenance\/version mismatch/);
    assert.equal(writes.length, 0);
    manifest.version = version; save();
    fs.writeFileSync(path.join(owned, 'qualified/latest.yml'), 'stable');
    await assert.rejects(run, /stable metadata/);
    fs.unlinkSync(path.join(owned, 'qualified/latest.yml'));
    tagExists = true;
    await assert.rejects(run, /refusing reuse or overwrite/);
    assert.equal(writes.length, 0);
    tagExists = false;
    await run();
    assert.equal(writes[0][0], 'create');
    assert.equal(writes[0][1].draft, true);
    assert.equal(writes[0][1].target_commitish, sourceSha);
    const uploads = writes.filter(([kind]) => kind === 'upload');
    assert.equal(uploads.length, 5);
    assert.deepEqual(uploads.find(([, input]) => input.name === installer)[1].data, files[installer]);
    assert.equal(writes.at(-1)[0], 'update');
    assert.equal(writes.at(-1)[1].draft, false);
    assert.equal(writes.at(-1)[1].prerelease, true);
  } finally { fs.rmSync(owned, { recursive: true, force: true }); }
});

const electronRoot = process.env.DATASAFE_AUDIT_ELECTRON_ROOT || path.join(root, 'node_modules/electron/dist');
test('package checker uses real Electron ASAR resolution and rejects omitted or stale runtime helpers', {
  skip: process.platform !== 'win32' || !fs.existsSync(path.join(electronRoot, 'electron.exe'))
    ? 'Requires a Windows Electron runtime; set DATASAFE_AUDIT_ELECTRON_ROOT for a local fixture run' : false
}, async () => {
  const asar = require('@electron/asar');
  const owned = fs.mkdtempSync(path.join(os.tmpdir(), 'datasafe-package-checker-'));
  const source = path.join(owned, 'source');
  const packaged = path.join(owned, 'packaged');
  const app = path.join(owned, 'app');
  const resources = path.join(packaged, 'resources');
  try {
    fs.mkdirSync(source); fs.mkdirSync(app);
    fs.cpSync(electronRoot, packaged, { recursive: true, filter: name => name !== path.join(electronRoot, 'resources') });
    fs.renameSync(path.join(packaged, 'electron.exe'), path.join(packaged, 'DataSafe.exe'));
    fs.mkdirSync(resources);
    const builder = config(require('../package.json').version);
    for (const name of [...builder.files.filter(name => !name.includes('*')), 'package.json']) {
      fs.copyFileSync(path.join(root, name), path.join(source, name));
      fs.copyFileSync(path.join(root, name), path.join(app, name));
    }
    for (const name of ['assets', 'windows', 'data']) {
      fs.cpSync(path.join(root, name), path.join(source, name), { recursive: true });
      fs.cpSync(path.join(root, name), path.join(name === 'assets' ? app : resources, name), { recursive: true });
    }
    // A packaged audit must never execute either app entry point.
    for (const name of ['main.js', 'app.js', 'preload.js', 'server.js']) {
      const poison = "throw new Error('App entry point must not execute in a read-only audit');\n";
      fs.writeFileSync(path.join(source, name), poison);
      fs.writeFileSync(path.join(app, name), poison);
    }
    const lock = require('../package-lock.json');
    for (const [name, value] of Object.entries(lock.packages)) {
      if (name.startsWith('node_modules/') && !value.dev) fs.cpSync(path.join(root, name), path.join(app, name), { recursive: true });
    }
    fs.writeFileSync(path.join(resources, 'app-update.yml'), 'provider: github\nchannel: beta\n');
    const archive = path.join(resources, 'app.asar');
    await asar.createPackage(app, archive);
    const run = shell => spawnSync(shell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tests/windows/Test-AppPackage.ps1'),
      '-PackagedRoot', packaged, '-SourceRoot', source], { encoding: 'utf8', timeout: 60000,
      env: { ...process.env, NODE_PATH: path.join(root, 'node_modules'), NODE_OPTIONS: '--require=missing-audit-preload-must-not-run' } });
    for (const shell of ['powershell.exe', 'pwsh']) {
      const result = run(shell);
      assert.equal(result.status, 0, result.stderr);
      const audit = JSON.parse(result.stdout);
      assert.equal(audit.moduleResolution, 'packaged-electron-asar');
      assert.ok(audit.hashes.some(file => file.path === 'windows/DataSafe.AppIntegration.ps1'));
    }
    const helper = path.join(resources, 'windows/DataSafe.ScheduledTasks.ps1');
    fs.unlinkSync(helper);
    const omitted = run('powershell.exe');
    assert.notEqual(omitted.status, 0);
    assert.match(omitted.stderr, /DataSafe.ScheduledTasks.ps1/);
    fs.writeFileSync(helper, 'stale helper');
    const stale = run('pwsh');
    assert.notEqual(stale.status, 0);
    assert.match(stale.stderr, /Source\/resource mismatch/);
    fs.copyFileSync(path.join(source, 'windows/DataSafe.ScheduledTasks.ps1'), helper);
    const dependency = path.join(app, 'node_modules/fs-extra');
    fs.renameSync(dependency, dependency + '-omitted');
    await asar.createPackage(app, archive);
    const missingDependency = run('pwsh');
    assert.notEqual(missingDependency.status, 0);
    assert.match(missingDependency.stderr, /fs-extra/);
    fs.renameSync(dependency + '-omitted', dependency);
    // Break caught: a transitive CommonJS fallback executes outside the ASAR
    // before the audit's post-load require.cache check can reject it.
    const fallback = path.join(resources, 'node_modules', 'audit-external-fallback');
    const marker = path.join(owned, 'external-module-executed');
    fs.mkdirSync(fallback, { recursive: true });
    fs.writeFileSync(path.join(fallback, 'index.js'), `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'executed'); module.exports = {};`);
    const viewSource = fs.readFileSync(path.join(source, 'backup-view.js'));
    const fixtureView = Buffer.concat([viewSource, Buffer.from("\nrequire('audit-external-fallback');\n")]);
    fs.writeFileSync(path.join(source, 'backup-view.js'), fixtureView);
    fs.writeFileSync(path.join(app, 'backup-view.js'), fixtureView);
    await asar.createPackage(app, archive);
    for (const shell of ['powershell.exe', 'pwsh']) {
      const escaped = run(shell);
      assert.notEqual(escaped.status, 0);
      assert.match(escaped.stderr, /Dependency escaped packaged app/);
      assert.equal(fs.existsSync(marker), false, 'External transitive module executed before containment rejection');
    }
    fs.writeFileSync(path.join(source, 'backup-view.js'), viewSource);
    fs.writeFileSync(path.join(app, 'backup-view.js'), viewSource);
    fs.unlinkSync(path.join(app, 'backup-format.js'));
    await asar.createPackage(app, archive);
    const missingModule = run('pwsh');
    assert.notEqual(missingModule.status, 0);
    assert.match(missingModule.stderr, /backup-format/);
  } finally { fs.rmSync(owned, { recursive: true, force: true }); }
});

const test = require('node:test');
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');
const lock = require('../package-lock.json');
const updaterRequire = createRequire(require.resolve('electron-updater/package.json'));
const semver = updaterRequire('semver');
const { parseUpdateInfo, resolveFiles } = updaterRequire('./out/providers/Provider');

// Offline regression snapshot, 2026-10-20 npm advisories. This is not a live
// audit or an exploitability assessment. Ranges combine the cited advisories;
// no-fix sprintf-js is tracked separately in the release checklist, not waived
// by pretending that this bounded check covers every dependency.
const remediableRanges = [
  ['electron', '>=43.0.0-alpha.1 <43.5.0', 'gr2m-v5gq-v685 / j84w-jfhq-vhvj / qmv3-fv6v-rmhq / 9qh4-3jw8-366w'],
  ['js-yaml', '>=5.0.0 <=5.4.0', 'r3ph-w7gj-g6xm'],
  ['@xmldom/xmldom', '>=0.7.0 <=0.8.14', '6gmq-8vp8-gcm6 / w2rr-34g9-rvrj / 4w3w-2rp5-g8jm / c7q8-3ch8-vqpv / 27p8-2357-5qqv / 6h8r-xr42-gp59 / 8344-3jmq-59r6 / x4fp-j954-r2f4 / 965w-775f-mr7g / 93r5-fhx6-vmg9'],
  ['brace-expansion', '<1.1.21 || >=2.0.0 <2.1.7 || >=4.0.0 <5.0.12', '6j4f-fj2g-mc7p / qhr7-859c-m2p7 / q2hr-2g5m-vwhr'],
  ['fast-uri', '>=3.0.0 <3.1.8', '5jgf-p345-68v8 / f65p-4m7j-42xc / fph4-wmhf-6fwf / jqff-g426-hqxp / qw65-cvwx-89v3 / hrr3-gc8f-f4qj'],
  ['http-cache-semantics', '<=4.2.0', 'ch52-4w7c-c8xp'],
  ['undici', '<6.28.1 || >=7.0.0 <7.29.1', '3wwx-pv8p-q78v / pmjh-fq2x-6v4x / r53p-7pc4-xj5r / rfgv-xxqx-mfg5 / 3xpg-4rpp-hhhm / 2jfj-6hjv-fm6j / 2gqq-gqf2-x968 / w293-vg96-wgc3 / 8436-99hf-9mmv / rx4f-c7p8-82vq']
];

for (const [name, range, advisories] of remediableRanges) {
  test(`lock excludes known remediable vulnerable ${name} copies`, () => {
    // Break caught: a future lock regeneration reintroduces an affected copy,
    // including nested/optional/dev copies rather than only the hoisted one.
    const affected = Object.entries(lock.packages).filter(([location, info]) =>
      location.endsWith(`node_modules/${name}`) && semver.satisfies(info.version, range, { includePrerelease: true }));
    assert.deepEqual(affected.map(([location, info]) => `${location}@${info.version}`), [], `GHSA-${advisories}`);
  });
}

test('updater resolves a parser within its declared supported contract', () => {
  const declared = updaterRequire('./package.json').dependencies['js-yaml'];
  const actual = updaterRequire('js-yaml/package.json').version;
  assert.ok(semver.satisfies(actual, declared), `Updater requires ${declared}, resolved ${actual}`);
});

const feedUrl = new URL('https://example.invalid/releases/beta.yml');
const parse = text => parseUpdateInfo(text, 'beta.yml', feedUrl);

test('real updater parses beta metadata and resolves the declared installer hash and size', () => {
  const info = parse(`version: 1.0.10-beta.70
files:
  - url: OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe
    sha512: Zml4dHVyZQ==
    size: 123456
path: OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe
sha512: Zml4dHVyZQ==
releaseDate: '2026-10-20T02:20:21.000Z'
releaseNotes: |
  Incremental beta fixture.
`);
  assert.equal(info.version, '1.0.10-beta.70');
  assert.equal(info.releaseDate, '2026-10-20T02:20:21.000Z');
  assert.equal(info.releaseNotes, 'Incremental beta fixture.\n');
  const [file] = resolveFiles(info, new URL('https://example.invalid/releases/'));
  assert.equal(file.url.href, 'https://example.invalid/releases/OBTools-Automated-Backups-Setup-1.0.10-beta.70.exe');
  assert.equal(file.info.sha512, 'Zml4dHVyZQ==');
  assert.equal(file.info.size, 123456);
});

test('real updater rejects absent, malformed, duplicate-key and executable-tag feeds', () => {
  for (const feed of [null, 'files: [unterminated', 'version: one\nversion: two\n', 'value: !!js/function >\n  function () { return 1; }\n']) {
    assert.throws(() => parse(feed), { code: 'ERR_UPDATER_INVALID_UPDATE_INFO' });
  }
});

test('real updater refuses metadata without downloadable files or checksums', () => {
  assert.throws(() => resolveFiles(parse('version: 1.0.10-beta.70\n'), feedUrl), { code: 'ERR_UPDATER_NO_FILES_PROVIDED' });
  assert.throws(() => resolveFiles(parse('version: 1.0.10-beta.70\nfiles:\n  - url: installer.exe\n'), feedUrl), { code: 'ERR_UPDATER_NO_CHECKSUM' });
});

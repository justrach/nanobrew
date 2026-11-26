import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import worker from './src/index.js';
globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };
for (const path of ['/', '/v0.1.198', '/v-0.1.198', '/v0.1.209', '/v-0.1.209']) {
  const response = await worker.fetch(new Request('https://example.test' + path));
  assert.equal(response.status, 200);
  assert.match(await response.text(), /v0\.1\.209/);
  if (path === '/') assert.equal(response.headers.get('cache-control'), 'public, max-age=300');
}
for (const path of ['/v0.1.190', '/v0.1.191', '/v0.1.192', '/v0.1.193']) {
  assert.match(await (await worker.fetch(new Request('https://example.test' + path))).text(), /v0\.1\.209/);
}
for (const payload of [new Response('', { status: 503 }), Response.json({}), Response.json({ tag_name: 'unexpected' })]) {
  globalThis.fetch = async () => payload;
  const response = await worker.fetch(new Request('https://example.test/version'));
  assert.equal(await response.text(), '0.1.215');
}
globalThis.fetch = async () => Response.json({ tag_name: 'v0.1.210' });
assert.equal(await (await worker.fetch(new Request('https://example.test/version'))).text(), '0.1.210');
const installScript = await (await worker.fetch(new Request('https://example.test/install'))).text();
assert.match(installScript, /^FALLBACK_RELEASE="v0\.1\.215"$/m);

// Execute the exact served script with no network, real sudo, or host prefix.
const fixture = mkdtempSync(join(tmpdir(), 'nb-installer-'));
try {
  const script = join(fixture, 'install.sh');
  const archive = join(fixture, 'archive.tar.gz');
  const binary = '#!/bin/bash\necho fixture\n';
  writeFileSync(script, installScript);
  writeFileSync(join(fixture, 'nb'), binary);
  execFileSync('tar', ['-czf', archive, '-C', fixture, 'nb']);
  const digest = createHash('sha256').update(readFileSync(archive)).digest('hex');
  const findTool = name => execFileSync('/bin/sh', ['-c', 'command -v "$1"', 'sh', name], { encoding: 'utf8' }).trim();
  const tools = ['awk', 'grep', 'cut', 'cp', 'chmod', 'mktemp', 'mkdir', 'rm', 'gzip'];
  const toolPaths = tools.map(findTool);
  const tar = findTool('tar');
  let scenario = 0;

  function runInstaller({ os = 'Linux', arch = 'arm64', uid = '0', hash = 'sha256sum', checksum,
    curlMode = '', sudoMode = '', hashFails = false, version = '0.1.212-rc.1', dryRun = false } = {}) {
    const dir = join(fixture, String(++scenario));
    const bin = join(dir, 'bin');
    const home = join(dir, 'home');
    const tmp = join(dir, 'tmp');
    const prefix = join(dir, 'custom prefix');
    const sidecar = join(dir, 'sha256');
    const calls = join(dir, 'calls');
    for (const path of [bin, home, tmp]) mkdirSync(path, { recursive: true });
    tools.forEach((name, i) => symlinkSync(toolPaths[i], join(bin, name)));
    const stub = (name, body) => writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
    stub('uname', 'case "$1" in -s) echo "$TEST_OS";; -m) echo "$TEST_ARCH";; *) exit 1;; esac');
    stub('id', '[[ "$1" == -u ]] && echo "$TEST_UID"');
    stub('whoami', 'echo fixture');
    stub('tar', 'echo tar >> "$TEST_CALLS"; exec "$TEST_TAR" "$@"');
    if (hash) stub(hash, 'echo "digest $*" >> "$TEST_CALLS"; printf "%s  fixture\\n" "$TEST_DIGEST"; [[ "$TEST_HASH_FAILS" == 0 ]]');
    stub('sudo', `echo "sudo $*" >> "$TEST_CALLS"
[[ "$1" == -n ]] || exit 64
[[ "$2" != "$TEST_SUDO_MODE" ]] || exit 1
case "$2" in mkdir) shift 2; exec mkdir "$@";; chown) exit 0;; *) exit 64;; esac`);
    stub('curl', `echo "curl $*" >> "$TEST_CALLS"
while (( $# )); do
  case "$1" in
    -I) head=1;;
    -o) out="$2"; shift;;
    https://*) url="$1";;
  esac
  shift
done
case "$url" in
  */version) [[ "$TEST_CURL_MODE" != fallback ]] && echo 0.1.211;;
  */releases/latest) exit 22;;
  */download/*)
    [[ "$head" != 1 ]] || exit 0
    case "$url" in
      *.sha256)
        [[ "$TEST_CURL_MODE" != missing ]] || exit 22
        cp "$TEST_SIDECAR" "$out"
        [[ "$TEST_CURL_MODE" != partial ]] || exit 18;;
      *) [[ "$TEST_CURL_MODE" != timeout ]] || exit 28; cp "$TEST_ARCHIVE" "$out";;
    esac;;
  *) exit 64;;
esac`);
    const artifact = os === 'Darwin' ? `nb-${arch}-apple-darwin.tar.gz`
      : `nb-${arch === 'arm64' ? 'aarch64' : arch}-linux.tar.gz`;
    writeFileSync(sidecar, checksum?.(artifact) ?? `${digest}  ${artifact}\n`);
    const result = spawnSync('/bin/bash', [script], { encoding: 'utf8', timeout: 5000, env: {
      PATH: bin, HOME: home, TMPDIR: tmp, TEST_OS: os, TEST_ARCH: arch, TEST_UID: uid, TEST_TAR: tar,
      TEST_CALLS: calls, TEST_ARCHIVE: archive, TEST_SIDECAR: sidecar, TEST_DIGEST: digest,
      TEST_CURL_MODE: curlMode, TEST_SUDO_MODE: sudoMode, TEST_HASH_FAILS: hashFails ? '1' : '0', NANOBREW_INSTALL_DIR: prefix,
      NANOBREW_INSTALL_VERSION: version, NANOBREW_INSTALL_DRY_RUN: dryRun ? '1' : '0',
    } });
    assert.ifError(result.error);
    assert.deepEqual(readdirSync(tmp), [], 'download scratch should be cleaned');
    return { ...result, calls: readFileSync(calls, 'utf8'), prefix, artifact, home,
      installed: join(prefix, 'prefix/bin/nb') };
  }

  let run = runInstaller();
  assert.equal(run.status, 0, run.stderr);
  assert.equal(readFileSync(run.installed, 'utf8'), binary);
  assert.ok(existsSync(join(run.home, '.bashrc')));
  assert.match(run.calls, /curl -fsSL --connect-timeout 10 --max-time 30 -I .*\/download\/v0\.1\.212-rc\.1\/nb-aarch64-linux\.tar\.gz/);
  assert.equal(run.calls.match(/--max-time 120 --speed-limit 1024 --speed-time 30 --retry 2 --retry-max-time 300/g)?.length, 2);
  assert.doesNotMatch(run.calls, /^sudo /m);

  run = runInstaller({ os: 'Darwin', arch: 'x86_64', uid: '1000', hash: 'shasum',
    checksum: name => `${digest.toUpperCase()}  /build output/${name}\n` });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(readFileSync(run.installed, 'utf8'), binary);
  assert.match(run.calls, /\/nb-x86_64-apple-darwin\.tar\.gz/);
  assert.match(run.calls, /^digest -a 256 /m);
  assert.match(run.calls, /^sudo -n mkdir -p /m);
  assert.match(run.calls, /^sudo -n chown -R fixture /m);

  for (const [options, tag] of [[{ version: 'v0.1.210' }, 'v0.1.210'], [{ version: '' }, 'v0.1.211'],
    [{ version: '', curlMode: 'fallback' }, 'v0.1.215']]) {
    run = runInstaller({ ...options, dryRun: true });
    assert.equal(run.status, 0, run.stderr);
    assert.ok(run.stdout.includes(`/download/${tag}/${run.artifact}`));
    assert.ok(run.stdout.includes(`Would install nb to ${run.installed}`));
    assert.doesNotMatch(run.calls, /--retry|^sudo |^tar$/m);
    assert.ok(!existsSync(run.prefix));
    assert.deepEqual(readdirSync(run.home), []);
  }

  for (const [options, error, downloadsArchive = false] of [
    [{ curlMode: 'missing' }, /could not download SHA256 checksum/],
    [{ curlMode: 'partial' }, /could not download SHA256 checksum/],
    [{ checksum: () => '' }, /could not download SHA256 checksum/],
    [{ checksum: () => 'not-a-digest\n' }, /malformed SHA256 checksum/],
    [{ checksum: () => `${digest}  wrong.tar.gz\n` }, /malformed SHA256 checksum/],
    [{ checksum: () => `${digest}\n${digest}\n` }, /malformed SHA256 checksum/],
    [{ hash: '' }, /no sha256sum or shasum found/],
    [{ hashFails: true }, /could not compute SHA256 checksum/, true],
    [{ checksum: () => '0'.repeat(64) }, /checksum mismatch/, true],
    [{ curlMode: 'timeout' }, null, true],
  ]) {
    run = runInstaller(options);
    assert.equal(run.status, error ? 1 : 28, run.stdout + run.stderr);
    if (error) assert.match(run.stderr, error);
    assert.equal(/\.tar\.gz -o /.test(run.calls), downloadsArchive);
    assert.doesNotMatch(run.calls, /^tar$|^sudo /m);
    assert.ok(!existsSync(run.prefix));
    assert.deepEqual(readdirSync(run.home), []);
  }

  for (const [sudoMode, error] of [['mkdir', /requires root privileges/], ['chown', /could not set ownership/]]) {
    run = runInstaller({ uid: '1000', sudoMode });
    assert.equal(run.status, 1);
    assert.match(run.stderr, error);
    assert.match(run.calls, new RegExp(`^sudo -n ${sudoMode} `, 'm'));
    assert.ok(!existsSync(run.installed));
  }
} finally {
  rmSync(fixture, { recursive: true, force: true });
}
console.log('Worker: release routes, version fallback and isolated installer scenarios passed');

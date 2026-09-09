import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('./src/index.js', import.meta.url), 'utf8');
const { default: worker } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
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
  assert.equal(await response.text(), '0.1.209');
}
globalThis.fetch = async () => Response.json({ tag_name: 'v0.1.210' });
assert.equal(await (await worker.fetch(new Request('https://example.test/version'))).text(), '0.1.210');
console.log('Worker: release routes, forward navigation, cache TTL, current-version fallback and live version passed');

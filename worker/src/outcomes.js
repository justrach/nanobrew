export const UPSERT_OUTCOME = `INSERT INTO install_outcomes
    (token,kind,version,platform,sha256,probe_schema,reporter,passed,observed_at,failed_at) VALUES (?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(token,kind,version,platform,sha256,probe_schema,reporter)
    DO UPDATE SET passed=excluded.passed,observed_at=excluded.observed_at,
      failed_at=MAX(install_outcomes.failed_at,excluded.failed_at)`;
export const AGGREGATE_OUTCOMES = `SELECT token,kind,version,platform,sha256,probe_schema,
    SUM(CASE WHEN failed_at < ? THEN 1 ELSE 0 END) AS distinct_successes,
    SUM(CASE WHEN failed_at >= ? THEN 1 ELSE 0 END) AS distinct_failures,MAX(observed_at) AS observed_at
    FROM install_outcomes WHERE observed_at>=? GROUP BY token,kind,version,platform,sha256,probe_schema
    HAVING COUNT(*)>=25 ORDER BY token,version,platform LIMIT 50000`;
const platforms = new Set(['macos_arm64', 'macos_x86_64', 'linux_x86_64', 'linux_aarch64']);
const keys = new Set(['schema','token','kind','version','platform','sha256','installed','probe','probe_schema','reporter']);
export function validOutcome(v) {
  return v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).every(k => keys.has(k)) &&
    v.schema === 1 && v.probe_schema === 3 &&
    typeof v.token === 'string' && /^[a-zA-Z0-9@+_.-]{1,120}$/.test(v.token) && !v.token.includes('..') &&
    typeof v.version === 'string' && /^[a-zA-Z0-9+_.,-]{1,128}$/.test(v.version) && !v.version.includes('..') &&
    ['formula','cask'].includes(v.kind) && platforms.has(v.platform) &&
    typeof v.sha256 === 'string' && /^[a-f0-9]{64}$/i.test(v.sha256) &&
    typeof v.reporter === 'string' && /^[a-f0-9]{64}$/.test(v.reporter) &&
    typeof v.installed === 'boolean' && [true,false,null].includes(v.probe);
}
export async function handleOutcomes(request, env) {
  if (!env?.TRUST_DB) return new Response('Outcome collection unavailable', {status:503});
  if (request.method !== 'POST') return new Response('Method not allowed', {status:405});
  // Bound actual streamed bytes, not just an untrusted Content-Length header.
  const reader = request.body?.getReader();
  if (!reader) return new Response('Missing body', {status:400});
  const chunks = []; let size = 0;
  for (;;) {
    const {done,value} = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 4096) { await reader.cancel(); return new Response('Body too large',{status:413}); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size); let pos = 0;
  for (const part of chunks) { bytes.set(part,pos); pos += part.length; }
  let event;
  try { event = JSON.parse(new TextDecoder().decode(bytes)); } catch { return new Response('Invalid JSON',{status:400}); }
  if (!validOutcome(event)) return new Response('Invalid outcome',{status:400});
  // An inconclusive probe is not a success or a failure observation.
  if (event.installed && event.probe === null) return new Response(null,{status:202});
  if (env.TRUST_RATE_LIMIT) {
    const result = await env.TRUST_RATE_LIMIT.limit({key:request.headers.get('CF-Connecting-IP') || 'unknown'});
    if (!result.success) return new Response('Rate limited',{status:429});
  }
  const time = Math.floor(Date.now()/1000);
  await env.TRUST_DB.prepare(UPSERT_OUTCOME)
    .bind(event.token,event.kind,event.version,event.platform,event.sha256.toLowerCase(),event.probe_schema,event.reporter,
      event.installed && event.probe === true ? 1 : 0,time,event.installed && event.probe === true ? 0 : time).run();
  return new Response(null,{status:202,headers:{'cache-control':'no-store'}});
}
export async function aggregateOutcomes(env) {
  if (!env?.TRUST_DB) return new Response('Outcome collection unavailable',{status:503});
  const cutoff = Math.floor(Date.now()/1000)-30*86400;
  const {results} = await env.TRUST_DB.prepare(AGGREGATE_OUTCOMES).bind(cutoff,cutoff,cutoff).all();
  // No reporter identifiers are exposed by the public aggregate.
  return Response.json({schema_version:1,evidence:results},{headers:{'cache-control':'public, max-age=3600'}});
}

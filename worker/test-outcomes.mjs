import assert from 'node:assert/strict';
import { validOutcome, handleOutcomes, aggregateOutcomes } from './src/outcomes.js';
const event = {schema:1,token:'jq',kind:'formula',version:'1.8',platform:'linux_x86_64',sha256:'a'.repeat(64),installed:true,probe:true,probe_schema:3,reporter:'b'.repeat(64)};
assert(validOutcome(event));
for (const patch of [{probe_schema:2},{reporter:'host'},{hostname:'private'},{token:'../jq'},{probe:'yes'},{platform:'linux'}, {installed:1}]) assert(!validOutcome({...event,...patch}));
let calls=[];
const db = {
  prepare(sql) {
    return { bind(...args) {
      calls.push({sql,args});
      return {
        async run() {},
        async all() { return {results:[{token:'jq',distinct_successes:25,distinct_failures:0}]}; }
      };
    }};
  }
};
const env={TRUST_DB:db};
const send=v=>handleOutcomes(new Request('https://example.org/v1/install-outcomes',{method:'POST',body:JSON.stringify(v)}),env);
assert.equal((await send(event)).status,202);
assert.equal(calls[0].args[7],1);
assert(calls[0].sql.includes('MIN(install_outcomes.passed,excluded.passed)'));
await send({...event,probe:false}); assert.equal(calls.at(-1).args[7],0);
const count=calls.length;
await send({...event,probe:null}); assert.equal(calls.length,count);
assert.equal((await send({...event,reporter:'invalid'})).status,400);
assert.equal((await send({...event,extra:'x'.repeat(5000)})).status,413);
assert.equal((await handleOutcomes(new Request('https://example.org',{method:'POST',body:JSON.stringify(event)}),{...env,TRUST_RATE_LIMIT:{async limit(){return {success:false};}}})).status,429);
const aggregate=await (await aggregateOutcomes(env)).json();
assert.equal(aggregate.evidence[0].distinct_successes,25);
assert(!JSON.stringify(aggregate).includes('reporter'));
console.log('Outcome validation, deduplication, privacy and aggregate tests passed');

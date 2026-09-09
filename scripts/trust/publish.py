#!/usr/bin/env python3
"""Build an Ed25519-signed evidence envelope from reviewed/CI/field records."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

MAX_AGE = 30 * 86400
PLATFORMS = {'macos_arm64','macos_x86_64','linux_x86_64','linux_aarch64'}
IDENTITY = ('token','kind','version','platform','sha256')

def identity(e):
    return tuple(e[k] for k in IDENTITY)

def valid(e, now):
    return (isinstance(e,dict) and e.get('probe_schema') == 3
            and e.get('platform') in PLATFORMS and e.get('kind') in ('formula','cask')
            and e.get('source') in ('ci','attested','field') and e.get('result') in ('pass','fail')
            and isinstance(e.get('observed_at'),int) and now-MAX_AGE <= e['observed_at'] <= now+300
            and isinstance(e.get('sha256'),str) and re.fullmatch('[a-fA-F0-9]{64}',e['sha256']) is not None
            and isinstance(e.get('token'),str) and re.fullmatch(r'[a-zA-Z0-9@+_.-]{1,120}',e['token']) is not None
            and '..' not in e['token'] and isinstance(e.get('version'),str)
            and re.fullmatch(r'[a-zA-Z0-9+_.,-]{1,128}',e['version']) is not None and '..' not in e['version'])

def verify_envelope(path, public_key):
    wrapper=json.loads(Path(path).read_text())
    with tempfile.TemporaryDirectory() as tmp:
        root=Path(tmp)
        (root/'payload').write_text(wrapper['payload'])
        (root/'signature').write_bytes(bytes.fromhex(wrapper['signature']))
        # SubjectPublicKeyInfo prefix for an Ed25519 raw public key.
        (root/'key.der').write_bytes(bytes.fromhex('302a300506032b6570032100'+Path(public_key).read_text().strip()))
        subprocess.run(['openssl','pkeyutl','-verify','-pubin','-keyform','DER','-inkey',str(root/'key.der'),'-rawin','-in',str(root/'payload'),'-sigfile',str(root/'signature')],check=True,stdout=subprocess.DEVNULL)
    data=json.loads(wrapper['payload'])
    if data['schema_version'] != 1: raise ValueError('Unknown evidence schema')
    return data['evidence']

def combine(previous, ci, attestations, field, now, run=''):
    records=[e for e in previous if valid(e,now) and e["source"] != "field"]
    for source, entries in [('ci',ci),('attested',attestations)]:
        for original in entries:
            e={**original,'source':source}
            if source == 'ci': e['run']=run
            if not valid(e,now): raise ValueError('Invalid '+source+' evidence')
            records.append(e)
    # Aggregates never supply executable URLs or artifact metadata. Those must
    # already have been collected by trusted CI or reviewed by a maintainer.
    metadata={identity(e):e for e in records if e['source'] in ('ci','attested')}
    for row in field:
        if not all(k in row for k in IDENTITY): continue
        old=metadata.get(identity(row))
        if not old: continue
        successes=row.get('distinct_successes',0); failures=row.get('distinct_failures',0)
        if type(successes) is not int or type(failures) is not int or min(successes,failures)<0: continue
        total=successes+failures
        if total<25: continue
        passing=successes>=25 and failures*100<total*2
        if not passing and failures*100<total*2: continue
        e={**old,'source':'field','result':'pass' if passing else 'fail',
           'distinct_successes':successes,'distinct_failures':failures,
           'observed_at':row.get('observed_at',0),'probe_schema':row.get('probe_schema',0),'run':''}
        if valid(e,now): records.append(e)
    newest={}
    for e in records:
        key=(*identity(e),e['source'])
        old=newest.get(key)
        if old is None or (e['observed_at'],e['result']=='fail')>(old['observed_at'],old['result']=='fail'): newest[key]=e
    return sorted(newest.values(),key=lambda e:(*identity(e),e['source']))

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--previous');p.add_argument('--ci-dir');p.add_argument('--attestations',default='registry/attestations')
    p.add_argument('--field');p.add_argument('--run',default='');p.add_argument('--key',required=True)
    p.add_argument('--public-key',default='src/trust/public-key.txt');p.add_argument('--output',default='registry/trust-evidence.json')
    a=p.parse_args(); now=int(time.time())
    previous=verify_envelope(a.previous,a.public_key) if a.previous and Path(a.previous).exists() else []
    def records(folder):
        return [json.loads(path.read_text()) for path in sorted(Path(folder).rglob('*.json'))] if folder else []
    field=json.loads(Path(a.field).read_text())['evidence'] if a.field else []
    evidence=combine(previous,records(a.ci_dir),records(a.attestations),field,now,a.run)
    payload=json.dumps({'schema_version':1,'generated_at':now,'evidence':evidence},separators=(',',':'),sort_keys=True)
    with tempfile.TemporaryDirectory() as tmp:
        root=Path(tmp);(root/'payload').write_text(payload)
        subprocess.run(['openssl','pkeyutl','-sign','-inkey',a.key,'-rawin','-in',str(root/'payload'),'-out',str(root/'signature')],check=True)
        wrapper={'payload':payload,'signature':(root/'signature').read_bytes().hex()}
    path=Path(a.output);path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(wrapper,indent=2)+'\n');os.replace(tmp,path)
    verify_envelope(path,a.public_key)
    print(f'Published {len(evidence)} signed evidence records')
if __name__=='__main__': main()

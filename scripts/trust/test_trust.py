#!/usr/bin/env python3
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
spec=importlib.util.spec_from_file_location('publish',Path(__file__).with_name('publish.py'))
publish=importlib.util.module_from_spec(spec);spec.loader.exec_module(publish)
NB=Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 else Path('zig-out/bin/nb').resolve()

class TrustTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.key=self.root/'key';self.pub=self.root/'pub';self.output=self.root/'envelope.json'
        subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(self.key)],check=True,capture_output=True)
        der=subprocess.check_output(['openssl','pkey','-in',str(self.key),'-pubout','-outform','DER'])
        self.pub.write_text(der[-32:].hex())
        self.env={**os.environ,'NANOBREW_NO_TELEMETRY':'1','NANOBREW_TRUST_PUBLIC_KEY':self.pub.read_text(),
                  'NANOBREW_TRUST_EVIDENCE_CACHE':str(self.output),'NANOBREW_CONFIG':str(self.root/'config')}
        self.now=int(time.time())
        self.entry={'token':'fixture','kind':'formula','version':'2.0','platform':'linux_x86_64','sha256':'a'*64,
                    'result':'pass','source':'ci','observed_at':self.now,'probe_schema':3,'nb_version':'test',
                    'formula':{'name':'fixture','version':'2.0','bottle_url':'https://example.org/fixture.tar.gz','bottle_sha256':'a'*64}}
    def sign(self,entries,generated=None):
        payload=json.dumps({'schema_version':1,'generated_at':self.now if generated is None else generated,'evidence':entries})
        raw=self.root/'payload';raw.write_text(payload);sig=self.root/'sig'
        subprocess.run(['openssl','pkeyutl','-sign','-inkey',str(self.key),'-rawin','-in',str(raw),'-out',str(sig)],check=True,capture_output=True)
        self.output.write_text(json.dumps({'payload':payload,'signature':sig.read_bytes().hex()}))
    def command(self,*args):
        return subprocess.run([str(NB),*args],env=self.env,text=True,capture_output=True,timeout=30)
    def test_signature_identity_freshness(self):
        self.sign([self.entry]);self.assertEqual(self.command('trust','verify',str(self.output)).returncode,0)
        wrapper=json.loads(self.output.read_text());wrapper['payload']+=' ';self.output.write_text(json.dumps(wrapper))
        self.assertNotEqual(self.command('trust','verify',str(self.output)).returncode,0)
        bad=copy.deepcopy(self.entry);bad['formula']['bottle_sha256']='b'*64;self.sign([bad])
        self.assertNotEqual(self.command('trust','verify',str(self.output)).returncode,0)
        self.sign([],self.now-31*86400);self.assertNotEqual(self.command('trust','verify',str(self.output)).returncode,0)
    def test_gating_refuses_unsupported_and_missing_evidence(self):
        self.sign([])
        result=self.command('install','--trusted-only','--deb','fixture')
        self.assertNotEqual(result.returncode,0);self.assertIn('trust gating is unavailable',result.stderr)
        result=self.command('install','fixture@trusted')
        self.assertNotEqual(result.returncode,0);self.assertIn('no fresh signed install evidence',result.stderr)
        (self.root/'config').write_text('min_trust=bogus\n')
        result=self.command('install','fixture')
        self.assertNotEqual(result.returncode,0);self.assertIn('invalid trust configuration',result.stderr)
    def test_aggregation_and_fail_ties(self):
        row={k:self.entry[k] for k in (*publish.IDENTITY,'probe_schema','observed_at')}
        row.update(distinct_successes=25,distinct_failures=0)
        records=publish.combine([self.entry],[],[],[row],self.now)
        self.assertEqual(len(records),2);self.assertEqual(records[-1]['source'],'field')
        self.assertEqual(len(publish.combine(records,[],[],[],self.now)),1)
        row.update(distinct_successes=49,distinct_failures=1)
        self.assertEqual(publish.combine([self.entry],[],[],[row],self.now)[-1]['result'],'fail')
        self.assertEqual(publish.combine([],[],[],[row],self.now),[])
        failed={**self.entry,'result':'fail'}
        self.assertEqual(publish.combine([failed,self.entry],[],[],[],self.now)[0]['result'],'fail')
    def test_publish_roundtrip(self):
        inputs=self.root/'ci';inputs.mkdir();(inputs/'fixture.json').write_text(json.dumps(self.entry))
        subprocess.run([sys.executable,str(Path(__file__).with_name('publish.py')),'--ci-dir',str(inputs),'--attestations',str(self.root/'empty-attestations'),'--key',str(self.key),'--public-key',str(self.pub),'--output',str(self.output)],check=True,capture_output=True)
        self.assertEqual(self.command('trust','verify',str(self.output)).returncode,0)
        self.assertEqual(len(publish.verify_envelope(self.output,self.pub)),1)

if __name__=='__main__':unittest.main()

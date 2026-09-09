#!/usr/bin/env python3
"""Exercise native async delivery, scoped identifiers, and both opt-out paths."""
import http.server,json,os,stat,subprocess,sys,tempfile,threading
from pathlib import Path
reports=[]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        reports.append(json.loads(self.rfile.read(int(self.headers['content-length']))))
        self.send_response(202);self.end_headers()
    def log_message(self,*args):pass
with tempfile.TemporaryDirectory(prefix='nb-outcome-') as tmp:
    with http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler) as server:
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        env={k:v for k,v in os.environ.items() if k.lower() not in ('http_proxy','https_proxy','all_proxy','no_proxy') and k not in ('NANOBREW_NO_TELEMETRY','NANOBREW_TELEMETRY_SYNC')}
        seed=Path(tmp)/'nested'/'seed'
        env.update(NANOBREW_TELEMETRY='1',NANOBREW_OUTCOME_SEED_PATH=str(seed),NANOBREW_OUTCOME_ENDPOINT=f'http://127.0.0.1:{server.server_port}/v1/install-outcomes')
        def run(token,*args):subprocess.run([sys.argv[1],token,*args],env=env,check=True,timeout=10)
        run('fixture');run('fixture');run('different');run('fixture','failed')
        assert len(reports)==4,reports
        assert reports[0]['reporter']==reports[1]['reporter']
        assert reports[0]['reporter']!=reports[2]['reporter']
        assert reports[3]['installed'] is False and reports[3]['probe'] is None
        assert set(reports[0])=={'schema','token','kind','version','platform','sha256','installed','probe','probe_schema','reporter'}
        assert stat.S_IMODE(seed.stat().st_mode)==0o600
        env.update(NANOBREW_TELEMETRY='off',NANOBREW_OUTCOME_SEED_PATH=str(Path(tmp)/'off-seed'))
        run('disabled');assert len(reports)==4;assert not Path(env['NANOBREW_OUTCOME_SEED_PATH']).exists()
        env.update(NANOBREW_TELEMETRY='1',NANOBREW_NO_TELEMETRY='1')
        run('disabled');assert len(reports)==4;assert not Path(env['NANOBREW_OUTCOME_SEED_PATH']).exists()
        server.shutdown();thread.join()
print('Native async outcomes, artifact-scoped identifiers, failure delivery and opt-out passed')

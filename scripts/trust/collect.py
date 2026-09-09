#!/usr/bin/env python3
"""Install seeded + top-analytics packages and collect real probe outcomes."""
import argparse
import json
from pathlib import Path
import subprocess
import urllib.request

def packages(limit=10):
    seeds=json.loads(Path('registry/trust-seeds.json').read_text())
    try:
        with urllib.request.urlopen('https://formulae.brew.sh/api/analytics/install/30d.json',timeout=20) as response:
            data=json.load(response)
        seeds.extend(item['formula'] for item in data['items'][:limit])
    except (OSError,KeyError,ValueError) as exc:
        print('Analytics unavailable; using seeds:',exc)
    return list(dict.fromkeys(seeds))

def main():
    p=argparse.ArgumentParser();p.add_argument('--nb',default='./zig-out/bin/nb');p.add_argument('--output',required=True);p.add_argument('--packages',nargs='*');a=p.parse_args()
    out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
    subprocess.run([a.nb,'init'],check=True)
    for token in a.packages or packages():
        if '/' in token: continue
        print('Collecting',token,flush=True)
        try:
            install=subprocess.run([a.nb,'install',token],timeout=600)
            probe=subprocess.run([a.nb,'doctor','--probe',token],timeout=120) if install.returncode==0 else None
            failed=install.returncode!=0 or probe.returncode!=0
        except subprocess.TimeoutExpired:
            failed=True
        cmd=[a.nb,'trust','record',token,'--output',str(out/(token+'.json'))]
        if failed: cmd.append('--failed')
        # Missing metadata is inconclusive, never a fabricated pass.
        subprocess.run(cmd,timeout=120,check=False)
if __name__=='__main__':main()

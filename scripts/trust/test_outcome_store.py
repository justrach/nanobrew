#!/usr/bin/env python3
"""Run the production SQL against SQLite, including rolling failure expiry."""
import json,sqlite3,subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[2]
code='import * as q from '+json.dumps((root/'worker/src/outcomes.js').as_uri())+'; console.log(JSON.stringify([q.UPSERT_OUTCOME,q.AGGREGATE_OUTCOMES]));'
insert,aggregate=json.loads(subprocess.check_output(['node','--input-type=module','-e',code],text=True))
db=sqlite3.connect(':memory:');db.row_factory=sqlite3.Row
for path in sorted((root/'worker/migrations').glob('*.sql')):db.executescript(path.read_text())
time=1800000000
identity=('fixture','formula','1','linux_x86_64','a'*64,3)
def report(reporter,passed,when):
    db.execute(insert,(*identity,f'{reporter:064x}',passed,when,0 if passed else when))
def counts(cutoff):return [dict(row) for row in db.execute(aggregate,(cutoff,cutoff,cutoff))]
for i in range(24):report(i,True,time)
assert counts(time-1)==[]
report(24,True,time)
for _ in range(3):report(24,True,time)
assert counts(time-1)[0]['distinct_successes']==25
report(24,False,time)
for i in range(25):report(i,True,time+20*86400)
assert counts(time-1)[0]['distinct_successes']==24
assert counts(time-1)[0]['distinct_failures']==1
# The old failure expires after 30 days, despite subsequent success reports.
assert counts(time+86400)[0]['distinct_successes']==25
assert counts(time+86400)[0]['distinct_failures']==0
assert counts(time+21*86400)==[]
print('Production SQL: distinct floor, repeat deduplication, failure precedence and rolling expiry passed')

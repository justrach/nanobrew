CREATE TABLE IF NOT EXISTS install_outcomes (
  token TEXT NOT NULL,
  kind TEXT NOT NULL,
  version TEXT NOT NULL,
  platform TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  probe_schema INTEGER NOT NULL,
  reporter TEXT NOT NULL,
  passed INTEGER NOT NULL CHECK (passed IN (0,1)),
  observed_at INTEGER NOT NULL,
  PRIMARY KEY (token,kind,version,platform,sha256,probe_schema,reporter)
);
CREATE INDEX IF NOT EXISTS outcomes_age ON install_outcomes(observed_at);

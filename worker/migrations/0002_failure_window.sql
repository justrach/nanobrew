ALTER TABLE install_outcomes ADD COLUMN failed_at INTEGER NOT NULL DEFAULT 0;
UPDATE install_outcomes SET failed_at = observed_at WHERE passed = 0;

ALTER TABLE bots ADD COLUMN permission_mode TEXT CHECK (permission_mode IN ('read-only','workspace','full-access'));

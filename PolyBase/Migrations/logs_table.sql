-- =============================================================================
-- PolyLogs: Remote Log Streaming Table
-- =============================================================================
-- Run this in your PolyApps Supabase project to enable remote log streaming.
--
-- This table receives log entries from all apps using LogRemote.
-- Logs are ephemeral (4-24 hour retention recommended via pg_cron).
-- =============================================================================
-- Create the logs table
CREATE TABLE
    IF NOT EXISTS polylogs (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid (),
        -- Log content
        timestamp TIMESTAMPTZ NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        -- Optional log group
        group_identifier TEXT,
        group_emoji TEXT,
        -- Source identification
        device_id TEXT NOT NULL,
        app_bundle_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        -- Metadata
        created_at TIMESTAMPTZ NOT NULL DEFAULT now ()
    );

-- Index for time-range queries and cleanup
CREATE INDEX IF NOT EXISTS idx_polylogs_created_at ON polylogs (created_at DESC);

-- Index for filtering by device and app
CREATE INDEX IF NOT EXISTS idx_polylogs_device_app ON polylogs (device_id, app_bundle_id);

-- Index for session grouping
CREATE INDEX IF NOT EXISTS idx_polylogs_session ON polylogs (session_id);

-- Index for timestamp-based queries (log viewing)
CREATE INDEX IF NOT EXISTS idx_polylogs_timestamp ON polylogs (timestamp DESC);

-- Enable realtime subscriptions
ALTER PUBLICATION supabase_realtime ADD TABLE polylogs;

-- =============================================================================
-- Cleanup Cron Job (optional but recommended)
-- =============================================================================
-- Requires pg_cron extension. Run in Supabase SQL editor.
-- Adjust the interval as needed (4 hours shown below).
--
-- Enable pg_cron if not already enabled:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
--
-- Schedule cleanup every hour, deleting logs older than 4 hours:
-- SELECT cron.schedule(
--     'cleanup-old-logs',
--     '0 * * * *',  -- Every hour
--     $$DELETE FROM logs WHERE created_at < now() - interval '4 hours'$$
-- );
--
-- To check scheduled jobs:
-- SELECT * FROM cron.job;
--
-- To remove the cleanup job:
-- SELECT cron.unschedule('cleanup-old-logs');
-- =============================================================================
-- Grant access for authenticated and anon users (adjust based on your needs)
-- For personal debugging with anon key, this allows insert from apps:
GRANT INSERT ON polylogs TO anon;

GRANT
SELECT
    ON polylogs TO anon;

-- If you want to restrict to authenticated users only:
-- REVOKE INSERT ON polylogs FROM anon;
-- GRANT INSERT ON polylogs TO authenticated;
-- GRANT SELECT ON polylogs TO authenticated;
COMMENT ON TABLE polylogs IS 'Remote log entries from apps using PolyLog with LogRemote enabled';

COMMENT ON COLUMN polylogs.timestamp IS 'When the log was created in the source app';

COMMENT ON COLUMN polylogs.level IS 'Log level: debug, info, warning, error, fault';

COMMENT ON COLUMN polylogs.message IS 'The log message content';

COMMENT ON COLUMN polylogs.group_identifier IS 'Optional log group identifier';

COMMENT ON COLUMN polylogs.group_emoji IS 'Optional emoji for the log group';

COMMENT ON COLUMN polylogs.device_id IS 'Stable device identifier (persisted per device)';

COMMENT ON COLUMN polylogs.app_bundle_id IS 'Bundle identifier of the source app';

COMMENT ON COLUMN polylogs.session_id IS 'Unique identifier per app launch session';

COMMENT ON COLUMN polylogs.created_at IS 'When the log was inserted into Supabase';

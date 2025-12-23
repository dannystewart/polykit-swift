-- Supabase function to clean up old logs

-- 1. Create the cleanup function
CREATE OR REPLACE FUNCTION polylogs_cleanup()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    -- Delete logs older than 24 hours
    DELETE FROM polylogs
    WHERE timestamp < NOW() - INTERVAL '24 hours';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    -- Log the cleanup
    RAISE NOTICE 'Deleted % old log entries', deleted_count;
END;
$$;

-- 2. Create a cron job to run the cleanup hourly
SELECT cron.schedule(
    'polylogs-cleanup',           -- Job name
    '0 * * * *',                  -- Cron expression: every hour at :00
    'SELECT polylogs_cleanup();'  -- SQL to execute
);

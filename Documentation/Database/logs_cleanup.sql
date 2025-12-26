-- Supabase function to clean up old logs

-- 1. Create the cleanup function
CREATE OR REPLACE FUNCTION polylogs_cleanup()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    deleted_count INTEGER;
    total_count INTEGER;
    max_records CONSTANT INTEGER := 10000;
BEGIN
    -- First, delete logs older than 24 hours
    DELETE FROM polylogs
    WHERE timestamp < NOW() - INTERVAL '24 hours';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RAISE NOTICE 'Deleted % old log entries (>24h)', deleted_count;

    -- Then, if we still have more than max_records, delete oldest records
    SELECT COUNT(*) INTO total_count FROM polylogs;

    IF total_count > max_records THEN
        DELETE FROM polylogs
        WHERE id IN (
            SELECT id
            FROM polylogs
            ORDER BY timestamp ASC
            LIMIT (total_count - max_records)
        );

        GET DIAGNOSTICS deleted_count = ROW_COUNT;
        RAISE NOTICE 'Deleted % oldest log entries to maintain cap of %', deleted_count, max_records;
    END IF;
END;
$$;

-- 2. Create a cron job to run the cleanup hourly
SELECT cron.schedule(
    'polylogs-cleanup',           -- Job name
    '0 * * * *',                  -- Cron expression: every hour at :00
    'SELECT polylogs_cleanup();'  -- SQL to execute
);

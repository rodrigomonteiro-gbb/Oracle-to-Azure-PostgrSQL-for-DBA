CREATE TABLE IF NOT EXISTS public.pgbench_error_log (
    error_time TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    application_name TEXT NOT NULL,
    backend_pid INTEGER NOT NULL,
    error_type INTEGER NOT NULL,
    sqlstate TEXT NOT NULL,
    error_message TEXT NOT NULL,
    delay_seconds INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS pgbench_error_log_error_time_idx
    ON public.pgbench_error_log (error_time DESC);

CREATE INDEX IF NOT EXISTS pgbench_error_log_sqlstate_idx
    ON public.pgbench_error_log (sqlstate);

CREATE OR REPLACE FUNCTION public.demo_error_transaction(
    p_error_type INTEGER,
    p_delay_seconds INTEGER,
    p_personid INTEGER,
    p_productid INTEGER,
    p_customerid INTEGER
)
RETURNS TABLE(
    error_type INTEGER,
    sqlstate TEXT,
    error_message TEXT,
    delay_seconds INTEGER
) AS $$
DECLARE
    v_sqlstate TEXT;
    v_message TEXT;
BEGIN
    IF p_error_type NOT BETWEEN 1 AND 8 THEN
        RAISE EXCEPTION 'p_error_type must be between 1 and 8';
    END IF;

    IF p_delay_seconds NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'p_delay_seconds must be between 1 and 5';
    END IF;

    BEGIN
        UPDATE person.person
        SET modifieddate = CURRENT_TIMESTAMP
        WHERE businessentityid = p_personid;

        UPDATE production.product
        SET modifieddate = CURRENT_TIMESTAMP
        WHERE productid = p_productid;

        UPDATE sales.customer
        SET modifieddate = CURRENT_TIMESTAMP
        WHERE customerid = p_customerid;

        PERFORM pg_sleep(p_delay_seconds);

        CASE p_error_type
            WHEN 1 THEN
                EXECUTE 'SELECT * FROM public.nonexistent_error_demo_table';
            WHEN 2 THEN
                EXECUTE 'SELECT public.nonexistent_error_demo_function()';
            WHEN 3 THEN
                PERFORM 1 / 0;
            WHEN 4 THEN
                PERFORM 'not-an-integer'::INTEGER;
            WHEN 5 THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23502',
                    MESSAGE = 'intentional not_null_violation';
            WHEN 6 THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23503',
                    MESSAGE = 'intentional foreign_key_violation';
            WHEN 7 THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23505',
                    MESSAGE = 'intentional unique_violation';
            WHEN 8 THEN
                RAISE EXCEPTION USING
                    ERRCODE = '22007',
                    MESSAGE = 'intentional invalid_datetime_format';
        END CASE;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_sqlstate = RETURNED_SQLSTATE,
            v_message = MESSAGE_TEXT;
    END;

    INSERT INTO public.pgbench_error_log (
        application_name,
        backend_pid,
        error_type,
        sqlstate,
        error_message,
        delay_seconds
    )
    VALUES (
        current_setting('application_name'),
        pg_backend_pid(),
        p_error_type,
        v_sqlstate,
        v_message,
        p_delay_seconds
    );

    RAISE WARNING 'Intentional workload error [%]: %', v_sqlstate, v_message;

    RETURN QUERY
    SELECT p_error_type, v_sqlstate, v_message, p_delay_seconds;
END;
$$ LANGUAGE plpgsql;

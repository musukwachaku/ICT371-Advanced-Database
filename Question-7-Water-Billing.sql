
-- =========================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 7: WATER METER READINGS AND BILLING
-- Database: ICT371_Q7
-- =========================================================

-- 1. CLEAN UP OLD TABLES

DROP VIEW IF EXISTS v_overdue_bills CASCADE;
DROP TABLE IF EXISTS receivable_snapshot CASCADE;
DROP TABLE IF EXISTS bills CASCADE;
DROP TABLE IF EXISTS readings CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

-- =========================================================
-- 2. CREATE TABLES
-- =========================================================

CREATE TABLE customers (
    customer_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL
        CHECK (previous_reading >= 0),
    current_reading NUMERIC(12,2) NOT NULL
        CHECK (current_reading >= 0),

    CONSTRAINT uq_customer_reading_month
        UNIQUE (customer_id, reading_month),

    CONSTRAINT chk_reading_month_start
        CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

CREATE TABLE bills (
    bill_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id INTEGER NOT NULL UNIQUE
        REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0
        CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(14,2) NOT NULL CHECK (total_due >= 0)
);

-- =========================================================
-- 3. INSERT CUSTOMERS
-- =========================================================

INSERT INTO customers (full_name)
VALUES
('John Banda'),
('Mary Phiri'),
('Peter Zulu');

-- =========================================================
-- 4. TRIGGER FUNCTION
-- Prevents current meter reading from being below previous.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_validate_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION
            'Current reading (%) cannot be below previous reading (%).',
            NEW.current_reading,
            NEW.previous_reading;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_validate_reading();

-- =========================================================
-- 5. INSERT SIX VALID METER READINGS
-- Includes zero, exactly 10 and above 10 consumption.
-- =========================================================

INSERT INTO readings (
    customer_id,
    reading_month,
    previous_reading,
    current_reading
)
VALUES
-- Customer 1
(1, DATE_TRUNC('month', CURRENT_DATE)::DATE, 100, 100),
(1, (DATE_TRUNC('month', CURRENT_DATE)
    - INTERVAL '1 month')::DATE, 80, 90),

-- Customer 2
(2, DATE_TRUNC('month', CURRENT_DATE)::DATE, 150, 160),
(2, (DATE_TRUNC('month', CURRENT_DATE)
    - INTERVAL '1 month')::DATE, 130, 145),

-- Customer 3
(3, DATE_TRUNC('month', CURRENT_DATE)::DATE, 200, 225),
(3, (DATE_TRUNC('month', CURRENT_DATE)
    - INTERVAL '1 month')::DATE, 180, 180);

-- =========================================================
-- 6. FUNCTION: fn_water_charge
-- First 10 units: K5 per unit.
-- Units above 10: K8 per unit.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_water_charge(
    p_units NUMERIC
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12,2);
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption cannot be NULL.';
    END IF;

    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be negative.';
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := (10 * 5) + ((p_units - 10) * 8);
    END IF;

    RETURN v_charge;
END;
$$;

-- Test the water tariff function.
SELECT
    fn_water_charge(0) AS zero_units,
    fn_water_charge(10) AS ten_units,
    fn_water_charge(15) AS fifteen_units;

-- Expected:
-- 0 units  = K0.00
-- 10 units = K50.00
-- 15 units = K90.00

-- =========================================================
-- 7. PROCEDURE: pr_generate_bill
-- Generates a bill for a meter reading.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous NUMERIC(12,2);
    v_current NUMERIC(12,2);
    v_units NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    SELECT previous_reading, current_reading
    INTO v_previous, v_current
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Reading ID % does not exist.',
            p_reading_id;
    END IF;

    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM bills
        WHERE reading_id = p_reading_id
    ) THEN
        RAISE EXCEPTION
            'A bill already exists for reading ID %.',
            p_reading_id;
    END IF;

    v_units := v_current - v_previous;

    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (
        reading_id,
        charge,
        amount_paid,
        due_on
    )
    VALUES (
        p_reading_id,
        v_charge,
        0,
        p_due_on
    );

    RAISE NOTICE
        'Bill generated for reading %. Consumption: % units. Charge: K%.',
        p_reading_id, v_units, v_charge;
END;
$$;

-- =========================================================
-- 8. GENERATE SIX BILLS
-- =========================================================

CALL pr_generate_bill(1, CURRENT_DATE - 5);
CALL pr_generate_bill(2, CURRENT_DATE + 15);
CALL pr_generate_bill(3, CURRENT_DATE - 3);
CALL pr_generate_bill(4, CURRENT_DATE + 20);
CALL pr_generate_bill(5, CURRENT_DATE - 2);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

-- Inspect generated bills.
SELECT * FROM bills ORDER BY bill_id;

-- =========================================================
-- 9. TEST A PAYMENT
-- =========================================================

-- Record a partial payment against the first bill.
UPDATE bills
SET amount_paid = 20.00
WHERE bill_id = 1;

-- Inspect payments and outstanding balances.
SELECT
    bill_id,
    charge,
    amount_paid,
    charge - amount_paid AS outstanding_amount,
    due_on
FROM bills
ORDER BY bill_id;

-- =========================================================
-- 10. VIEW: v_overdue_bills
-- Shows unpaid or partly paid overdue bills.
-- =========================================================

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name,
    b.due_on,
    b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r
    ON b.reading_id = r.reading_id
JOIN customers c
    ON r.customer_id = c.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- Query overdue bills.
SELECT *
FROM v_overdue_bills
ORDER BY due_on;

-- =========================================================
-- 11. INDEX FOR OVERDUE BILL SEARCHES
-- Partial index supports searches for unpaid bills by due date.
-- =========================================================

CREATE INDEX idx_unpaid_bills_due_on
ON bills(due_on)
WHERE amount_paid < charge;

-- Matching query.
SELECT
    bill_id,
    due_on,
    charge - amount_paid AS outstanding_amount
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge
ORDER BY due_on;

-- Execution plan.
EXPLAIN ANALYZE
SELECT
    bill_id,
    due_on,
    charge - amount_paid AS outstanding_amount
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge
ORDER BY due_on;

-- =========================================================
-- 12. PROCEDURE: pr_refresh_receivables
-- Stores today's total unpaid bill balances.
-- Rerunning updates the same date's snapshot.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(14,2);
BEGIN
    SELECT COALESCE(
        SUM(charge - amount_paid),
        0
    )
    INTO v_total_due
    FROM bills;

    INSERT INTO receivable_snapshot (
        snapshot_date,
        total_due
    )
    VALUES (
        CURRENT_DATE,
        v_total_due
    )
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        total_due = EXCLUDED.total_due;

    RAISE NOTICE
        'Receivables refreshed for %. Total due: K%.',
        CURRENT_DATE, v_total_due;
END;
$$;

-- Run the snapshot procedure.
CALL pr_refresh_receivables();

-- Verify snapshot.
SELECT *
FROM receivable_snapshot
ORDER BY snapshot_date;

-- =========================================================
-- 13. SCHEDULED JOB
-- Requires pg_cron to be installed and configured.
-- Schedule daily at 00:30.
-- =========================================================

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- SELECT cron.schedule(
--     'daily-water-receivables',
--     '30 0 * * *',
--     'CALL pr_refresh_receivables();'
-- );

-- Inspect scheduled jobs:
-- SELECT * FROM cron.job;

-- Inspect execution history:
-- SELECT *
-- FROM cron.job_run_details
-- ORDER BY start_time DESC;

-- =========================================================
-- END OF QUESTION 7
-- =========================================================

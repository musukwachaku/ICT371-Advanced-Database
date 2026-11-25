
-- =========================================================
-- ICT371 - QUESTION 9
-- FARMER COOPERATIVE MAIZE DELIVERIES
-- Database: ICT371_Q9
-- =========================================================

-- 1. CLEAN UP OLD OBJECTS
DROP VIEW IF EXISTS v_farmer_amount_due CASCADE;
DROP TABLE IF EXISTS daily_purchases CASCADE;
DROP TABLE IF EXISTS deliveries CASCADE;
DROP TABLE IF EXISTS farmers CASCADE;

DROP PROCEDURE IF EXISTS pr_receive_delivery(INTEGER, CHAR, NUMERIC, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_purchases(DATE);
DROP FUNCTION IF EXISTS fn_maize_rate(CHAR);
DROP FUNCTION IF EXISTS fn_prepare_delivery();


-- =========================================================
-- 2. CREATE TABLES
-- =========================================================

CREATE TABLE farmers (
    farmer_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_id INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg NUMERIC(12,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate NUMERIC(10,2) NOT NULL CHECK (unit_rate >= 0),
    total_value NUMERIC(14,2) NOT NULL CHECK (total_value >= 0),
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_value NUMERIC(14,2) NOT NULL DEFAULT 0
);


-- =========================================================
-- 3. INSERT THREE FARMERS
-- =========================================================

INSERT INTO farmers (farmer_number, full_name)
VALUES
('F001', 'John Banda'),
('F002', 'Mary Phiri'),
('F003', 'Peter Zulu');


-- =========================================================
-- 4. FUNCTION: fn_maize_rate
-- Returns the price per kilogram based on maize grade
-- =========================================================

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate NUMERIC(10,2);
    v_grade CHAR(1);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL';
    END IF;

    v_grade := UPPER(BTRIM(p_grade::TEXT));

    CASE v_grade
        WHEN 'A' THEN
            v_rate := 5.00;
        WHEN 'B' THEN
            v_rate := 4.00;
        WHEN 'C' THEN
            v_rate := 3.00;
        ELSE
            RAISE EXCEPTION 'Invalid maize grade: %. Use A, B or C.',
                p_grade;
    END CASE;

    RETURN v_rate;
END;
$$;


-- Test the function
SELECT fn_maize_rate('A') AS grade_a_rate;
SELECT fn_maize_rate('B') AS grade_b_rate;
SELECT fn_maize_rate('C') AS grade_c_rate;


-- =========================================================
-- 5. TRIGGER FUNCTION
-- Automatically calculates unit_rate and total_value
-- =========================================================

CREATE OR REPLACE FUNCTION fn_prepare_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight must be greater than zero';
    END IF;

    IF NEW.grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL';
    END IF;

    NEW.grade := UPPER(BTRIM(NEW.grade::TEXT));

    NEW.unit_rate := fn_maize_rate(NEW.grade);

    NEW.total_value := ROUND(
        NEW.weight_kg * NEW.unit_rate,
        2
    );

    RETURN NEW;
END;
$$;


-- =========================================================
-- 6. CREATE BEFORE INSERT OR UPDATE TRIGGER
-- =========================================================

CREATE TRIGGER trg_prepare_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_prepare_delivery();


-- =========================================================
-- 7. PROCEDURE: pr_receive_delivery
-- Validates the farmer and delivery information.
-- The trigger calculates the rate and total value.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade CHAR,
    p_weight NUMERIC,
    p_date DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_farmer_id IS NULL THEN
        RAISE EXCEPTION 'Farmer ID cannot be NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM farmers
        WHERE farmer_id = p_farmer_id
    ) THEN
        RAISE EXCEPTION 'Farmer ID % does not exist', p_farmer_id;
    END IF;

    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL';
    END IF;

    IF UPPER(BTRIM(p_grade::TEXT)) NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid maize grade. Use A, B or C.';
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero';
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL';
    END IF;

    INSERT INTO deliveries (
        farmer_id,
        grade,
        weight_kg,
        unit_rate,
        total_value,
        delivered_on,
        is_paid
    )
    VALUES (
        p_farmer_id,
        UPPER(BTRIM(p_grade::TEXT)),
        p_weight,
        0,
        0,
        p_date,
        FALSE
    );

    -- The BEFORE trigger supplies unit_rate and total_value.
END;
$$;


-- =========================================================
-- 8. SEED SIX DELIVERIES
-- All records are inserted after installing the trigger.
-- All three grades and both payment states are represented.
-- =========================================================

CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 5);
CALL pr_receive_delivery(1, 'B', 50,  CURRENT_DATE - 4);

CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE - 3);
CALL pr_receive_delivery(2, 'A', 75,  CURRENT_DATE - 2);

CALL pr_receive_delivery(3, 'B', 120, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C', 80,  CURRENT_DATE);


-- Mark three deliveries as paid
UPDATE deliveries
SET is_paid = TRUE
WHERE delivery_id IN (2, 4, 6);


-- =========================================================
-- 9. VIEW: v_farmer_amount_due
-- Includes farmers with no unpaid deliveries.
-- =========================================================

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(
        CASE
            WHEN d.is_paid = FALSE THEN d.total_value
            ELSE 0
        END
    ), 0)::NUMERIC(14,2) AS total_amount_due
FROM farmers f
LEFT JOIN deliveries d
    ON f.farmer_id = d.farmer_id
GROUP BY
    f.farmer_id,
    f.farmer_number,
    f.full_name;


-- View results
SELECT *
FROM v_farmer_amount_due
ORDER BY farmer_number;


-- =========================================================
-- 10. COMPOSITE INDEX
-- Supports searches for one farmer within a date range.
-- =========================================================

CREATE INDEX idx_deliveries_farmer_date
ON deliveries (farmer_id, delivered_on);


-- Matching query
SELECT
    delivery_id,
    farmer_id,
    grade,
    weight_kg,
    total_value,
    delivered_on
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
ORDER BY delivered_on;


-- Display the execution plan
EXPLAIN ANALYZE
SELECT
    delivery_id,
    farmer_id,
    grade,
    weight_kg,
    total_value,
    delivered_on
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
ORDER BY delivered_on;


-- =========================================================
-- 11. PROCEDURE: pr_refresh_purchases
-- Stores the total weight and value purchased on a date.
-- Repeated execution replaces the existing date's totals.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_weight NUMERIC(14,2);
    v_total_value NUMERIC(14,2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Purchase date cannot be NULL';
    END IF;

    SELECT
        COALESCE(SUM(weight_kg), 0),
        COALESCE(SUM(total_value), 0)
    INTO
        v_total_weight,
        v_total_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (
        purchase_date,
        total_weight,
        total_value
    )
    VALUES (
        p_day,
        v_total_weight,
        v_total_value
    )
    ON CONFLICT (purchase_date)
    DO UPDATE SET
        total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;
END;
$$;


-- =========================================================
-- 12. TEST THE DAILY PURCHASE SUMMARY
-- =========================================================

CALL pr_refresh_purchases(CURRENT_DATE);

SELECT *
FROM daily_purchases
ORDER BY purchase_date;


-- Test rerunning the procedure
CALL pr_refresh_purchases(CURRENT_DATE);

SELECT *
FROM daily_purchases
WHERE purchase_date = CURRENT_DATE;


-- =========================================================
-- 13. OPTIONAL AUTOMATIC SCHEDULING WITH pg_cron
-- Runs daily at 01:30 for the previous day.
-- Uncomment only if pg_cron is installed and configured.
-- =========================================================

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- SELECT cron.schedule(
--     'refresh-daily-maize-purchases',
--     '30 1 * * *',
--     $$CALL pr_refresh_purchases(CURRENT_DATE - 1);$$
-- );


-- =========================================================
-- 14. FINAL VERIFICATION QUERIES
-- =========================================================

-- Check farmers
SELECT * FROM farmers;

-- Check all deliveries and automatically calculated values
SELECT * FROM deliveries
ORDER BY delivery_id;

-- Check farmer amounts due
SELECT * FROM v_farmer_amount_due
ORDER BY farmer_number;

-- Check daily purchase summaries
SELECT * FROM daily_purchases
ORDER BY purchase_date;

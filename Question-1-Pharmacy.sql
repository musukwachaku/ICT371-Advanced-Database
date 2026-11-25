
/* =========================================================
   ICT371 - ADVANCED DATABASE
   QUESTION 1: PHARMACY STOCK AND DAILY SALES
   Database: ICT371_Q1
   ========================================================= */


/* =========================================================
   (a) DATABASE TABLES AND SEED DATA STRUCTURE
   ========================================================= */

-- Medicines table
CREATE TABLE medicines (
    medicine_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);

-- Sales table
CREATE TABLE sales (
    sale_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INTEGER NOT NULL
        REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);

-- Stock audit table
CREATE TABLE stock_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INTEGER NOT NULL
        REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Daily sales summary table
CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);


/* =========================================================
   (b) FUNCTION: fn_sale_value
   Returns current unit price multiplied by quantity.
   ========================================================= */

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_medicine_id IS NULL OR p_quantity IS NULL
       OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid medicine ID or quantity';
    END IF;

    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist',
            p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;


/* =========================================================
   (c) PROCEDURE: pr_record_sale
   Checks stock, records sale and deducts stock once.
   ========================================================= */

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_medicine_id IS NULL OR p_quantity IS NULL
       OR p_quantity <= 0 OR p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Invalid sale information';
    END IF;

    -- Lock medicine row to prevent concurrent overselling.
    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist',
            p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION
            'Insufficient stock. Available: %, Requested: %',
            v_stock, p_quantity;
    END IF;

    -- Calculate sale value using the function.
    PERFORM fn_sale_value(p_medicine_id, p_quantity);

    -- Record sale using current medicine price.
    INSERT INTO sales (
        medicine_id,
        quantity,
        unit_price,
        sold_on
    )
    VALUES (
        p_medicine_id,
        p_quantity,
        v_price,
        p_sold_on
    );

    -- Deduct stock exactly once.
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;

END;
$$;


/* =========================================================
   (d) TRIGGER: Stock Audit
   Records actual changes in stock quantities.
   ========================================================= */

CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (
        medicine_id,
        old_qty,
        new_qty,
        changed_at
    )
    VALUES (
        OLD.medicine_id,
        OLD.stock_qty,
        NEW.stock_qty,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION fn_stock_audit();


/* =========================================================
   SEED DATA
   Three medicines and six valid sales.
   Sales are loaded through the completed procedure.
   ========================================================= */

INSERT INTO medicines (
    medicine_name,
    unit_price,
    stock_qty
)
VALUES
    ('Paracetamol', 5.00, 100),
    ('Amoxicillin', 15.00, 50),
    ('Ibuprofen', 8.50, 75);

-- Six valid sales through the procedure.
CALL pr_record_sale(1, 10, DATE '2026-11-20');
CALL pr_record_sale(2, 5, DATE '2026-11-20');
CALL pr_record_sale(3, 8, DATE '2026-11-20');

CALL pr_record_sale(1, 15, DATE '2026-11-21');
CALL pr_record_sale(2, 4, DATE '2026-11-21');
CALL pr_record_sale(3, 12, DATE '2026-11-21');


/* =========================================================
   (e) VIEW: v_low_stock
   Displays medicines with fewer than 10 units remaining.
   ========================================================= */

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty
FROM medicines
WHERE stock_qty < 10;

-- Query the view after a sale.
SELECT * FROM v_low_stock;


/* =========================================================
   (f) INDEX
   Supports medicine-specific sales date-range searches.
   ========================================================= */

CREATE INDEX idx_sales_medicine_sold_on
ON sales (medicine_id, sold_on);

-- Matching query.
SELECT
    sale_id,
    medicine_id,
    quantity,
    unit_price,
    sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN DATE '2026-11-20'
                  AND DATE '2026-11-30';

-- Display the execution plan.
EXPLAIN
SELECT
    sale_id,
    medicine_id,
    quantity,
    unit_price,
    sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN DATE '2026-11-20'
                  AND DATE '2026-11-30';


/* =========================================================
   (g) DAILY SALES REFRESH PROCEDURE
   Replaces the daily total instead of adding duplicates.
   ========================================================= */

CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Sales date cannot be NULL';
    END IF;

    INSERT INTO daily_sales (
        sales_date,
        total_qty,
        total_amount
    )
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day

    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;


-- Test the daily refresh procedure.
CALL pr_refresh_sales(DATE '2026-11-20');

-- Verify the daily totals.
SELECT * FROM daily_sales;


/* =========================================================
   SCHEDULED JOB: DAILY AT 00:15
   Requires pg_cron to be installed and configured.
   Run this section separately if pg_cron is available.
   ========================================================= */

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Remove an existing job with the same name before rescheduling.
-- SELECT cron.unschedule(jobid)
-- FROM cron.job
-- WHERE jobname = 'refresh-daily-sales';

-- Schedule daily refresh for the previous day.
-- SELECT cron.schedule(
--     'refresh-daily-sales',
--     '15 0 * * *',
--     'CALL pr_refresh_sales(CURRENT_DATE - 1);'
-- );



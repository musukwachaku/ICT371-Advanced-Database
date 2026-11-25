
/* =========================================================
   ICT371 - ADVANCED DATABASE
   QUESTION 2: UNIVERSITY FEE PAYMENTS
   Database: ICT371_Q2
   ========================================================= */


/* =========================================================
   (a) DATABASE TABLES AND CONSTRAINTS
   ========================================================= */

-- Students table
CREATE TABLE students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

-- Payments table
CREATE TABLE payments (
    payment_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INTEGER NOT NULL
        REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);

-- Payment audit table
CREATE TABLE payment_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id INTEGER NOT NULL
        REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL
        REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Daily collections summary table
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);


/* =========================================================
   (b) FUNCTION: fn_fee_balance
   Returns outstanding fee balance for a student.
   ========================================================= */

CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_total_paid NUMERIC(12,2);
BEGIN
    IF p_student_id IS NULL THEN
        RAISE EXCEPTION 'Student ID cannot be NULL';
    END IF;

    SELECT fee_due
    INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist',
            p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0)
    INTO v_total_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee_due - v_total_paid;
END;
$$;


/* =========================================================
   (c) PROCEDURE: pr_receive_payment
   Rejects invalid payments and payments above balance.
   Does not modify students.fee_due.
   ========================================================= */

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC(12,2),
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_student_id INTEGER;
    v_balance NUMERIC(12,2);
BEGIN
    IF p_student_id IS NULL
       OR p_amount IS NULL
       OR p_paid_on IS NULL
       OR p_amount <= 0 THEN
        RAISE EXCEPTION
            'Invalid payment details. Check student ID, amount and date';
    END IF;

    -- Lock the student record to prevent concurrent
    -- payments from exceeding the outstanding balance.
    SELECT student_id
    INTO v_student_id
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist',
            p_student_id;
    END IF;

    -- Calculate outstanding balance.
    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION
            'Payment exceeds outstanding balance. Balance: %, Payment: %',
            v_balance, p_amount;
    END IF;

    -- Insert valid payment.
    -- The trigger will automatically create the audit record.
    INSERT INTO payments (
        student_id,
        amount,
        paid_on
    )
    VALUES (
        p_student_id,
        p_amount,
        p_paid_on
    );

END;
$$;


/* =========================================================
   (d) TRIGGER: PAYMENT AUDIT
   Automatically records every inserted payment.
   ========================================================= */

CREATE OR REPLACE FUNCTION fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (
        payment_id,
        student_id,
        amount,
        logged_at
    )
    VALUES (
        NEW.payment_id,
        NEW.student_id,
        NEW.amount,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_payment_audit();


/* =========================================================
   SEED DATA
   Three students and six valid payments.
   Student 3 initially has no payments.
   ========================================================= */

INSERT INTO students (
    student_number,
    full_name,
    fee_due
)
VALUES
    ('MU2026001', 'John Banda', 1000.00),
    ('MU2026002', 'Mary Phiri', 1500.00),
    ('MU2026003', 'Peter Zulu', 800.00);


-- Six payments through the completed procedure.

-- John Banda: three payments.
CALL pr_receive_payment(1, 200.00, DATE '2026-11-20');
CALL pr_receive_payment(1, 150.00, DATE '2026-11-21');
CALL pr_receive_payment(1, 100.00, DATE '2026-11-22');

-- Mary Phiri: three payments.
CALL pr_receive_payment(2, 300.00, DATE '2026-11-20');
CALL pr_receive_payment(2, 250.00, DATE '2026-11-21');
CALL pr_receive_payment(2, 200.00, DATE '2026-11-22');

-- Peter Zulu intentionally has no payments.


/* =========================================================
   (e) VIEW: v_fee_balances
   Shows students who still owe fees.
   Fully settled students are excluded.
   ========================================================= */

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;


-- Display outstanding student balances.
SELECT * FROM v_fee_balances;


/* =========================================================
   (f) COMPOSITE INDEX
   Supports student-specific payment date-range searches.
   ========================================================= */

CREATE INDEX idx_payments_student_paid_on
ON payments (student_id, paid_on);


-- Matching query.
SELECT
    payment_id,
    student_id,
    amount,
    paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-11-20'
                  AND DATE '2026-11-30';


-- Display execution plan.
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    payment_id,
    student_id,
    amount,
    paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-11-20'
                  AND DATE '2026-11-30';


/* =========================================================
   (g) DAILY COLLECTIONS REFRESH PROCEDURE
   Stores payment count and total amount for a given date.
   Rerunning replaces the previous summary.
   ========================================================= */

CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Collection date cannot be NULL';
    END IF;

    INSERT INTO daily_collections (
        collection_date,
        payment_count,
        total_amount
    )
    SELECT
        p_day,
        COUNT(*)::INTEGER,
        COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day

    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;


-- Test the daily collection procedure.
CALL pr_refresh_collections(DATE '2026-11-20');

-- Verify daily collections.
SELECT * FROM daily_collections;


/* =========================================================
   SCHEDULED JOB: DAILY AT 01:00
   Requires pg_cron to be installed and configured.
   Run separately when pg_cron is available.
   ========================================================= */

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Remove existing job with the same name if necessary.
-- SELECT cron.unschedule(jobid)
-- FROM cron.job
-- WHERE jobname = 'refresh-daily-collections';

-- Schedule daily at 01:00 for the previous day.
-- SELECT cron.schedule(
--     'refresh-daily-collections',
--     '0 1 * * *',
--     'CALL pr_refresh_collections(CURRENT_DATE - 1);'
-- );


/* =========================================================
   FINAL VERIFICATION QUERIES
   ========================================================= */

-- View all students.
SELECT * FROM students;

-- View all payments.
SELECT * FROM payments;

-- View automatically generated audit records.
SELECT * FROM payment_audit;

-- Check balances.
SELECT
    student_number,
    full_name,
    fn_fee_balance(student_id) AS balance
FROM students;

-- Check fee balance view.
SELECT * FROM v_fee_balances;

-- Check daily collections.
SELECT * FROM daily_collections;

-- End of Question 2

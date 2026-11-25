
-- =========================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 6: MONTHLY PAYROLL PROCESSING
-- Database: ICT371_Q6
-- =========================================================

-- 1. CLEAN UP OLD TABLES

DROP VIEW IF EXISTS v_payroll_report CASCADE;
DROP TABLE IF EXISTS salary_audit CASCADE;
DROP TABLE IF EXISTS payroll CASCADE;
DROP TABLE IF EXISTS employees CASCADE;

-- =========================================================
-- 2. CREATE TABLES
-- =========================================================

CREATE TABLE employees (
    employee_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL,
    gross_pay NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),

    CONSTRAINT uq_employee_pay_month
        UNIQUE (employee_id, pay_month),

    CONSTRAINT chk_pay_month_start
        CHECK (EXTRACT(DAY FROM pay_month) = 1)
);

CREATE TABLE salary_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2) NOT NULL,
    new_salary NUMERIC(12,2) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- =========================================================
-- 3. INSERT EMPLOYEE DATA
-- Includes active and inactive employees.
-- =========================================================

INSERT INTO employees (
    full_name,
    basic_salary,
    allowance,
    deduction,
    active
)
VALUES
('John Banda', 5000.00, 1000.00, 500.00, TRUE),
('Mary Phiri', 6500.00, 1500.00, 700.00, TRUE),
('Peter Zulu', 4000.00, 800.00, 300.00, TRUE),
('Grace Mwila', 5500.00, 1000.00, 600.00, FALSE),
('James Chanda', 7000.00, 1200.00, 900.00, TRUE);

-- =========================================================
-- 4. FUNCTION: fn_net_pay
-- Calculates an employee's current net pay.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_net_pay(
    p_employee_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic_salary NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net_pay NUMERIC(12,2);
BEGIN
    SELECT
        basic_salary,
        allowance,
        deduction
    INTO
        v_basic_salary,
        v_allowance,
        v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Employee ID % does not exist.',
            p_employee_id;
    END IF;

    v_net_pay :=
        (v_basic_salary + v_allowance) - v_deduction;

    IF v_net_pay < 0 THEN
        RAISE EXCEPTION
            'Invalid net pay for employee ID %. Net pay cannot be negative.',
            p_employee_id;
    END IF;

    RETURN v_net_pay;
END;
$$;

-- Test the function.
SELECT employee_id, full_name, fn_net_pay(employee_id) AS net_pay
FROM employees
ORDER BY employee_id;

-- =========================================================
-- 5. PROCEDURE: pr_process_payroll
-- Processes payroll for active employees.
-- Existing records are not changed.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_process_payroll(
    p_month DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    employee_record RECORD;
    v_gross_pay NUMERIC(12,2);
    v_net_pay NUMERIC(12,2);
BEGIN
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'Payroll month cannot be NULL.';
    END IF;

    IF EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION
            'The payroll date must be the first day of a month.';
    END IF;

    FOR employee_record IN
        SELECT
            employee_id,
            basic_salary,
            allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP

        -- Calculate net pay using the function.
        v_net_pay := fn_net_pay(employee_record.employee_id);

        -- Calculate gross pay.
        v_gross_pay :=
            employee_record.basic_salary
            + employee_record.allowance;

        -- Insert only if the employee/month record is missing.
        -- Existing payroll records remain unchanged.
        INSERT INTO payroll (
            employee_id,
            pay_month,
            gross_pay,
            net_pay
        )
        VALUES (
            employee_record.employee_id,
            p_month,
            v_gross_pay,
            v_net_pay
        )
        ON CONFLICT (employee_id, pay_month)
        DO NOTHING;

    END LOOP;

    RAISE NOTICE
        'Payroll processing completed for %.',
        p_month;
END;
$$;

-- =========================================================
-- 6. PROCESS TWO PAYROLL MONTHS
-- Uses the first day of the current and previous months.
-- =========================================================

CALL pr_process_payroll(
    DATE_TRUNC('month', CURRENT_DATE)::DATE
);

CALL pr_process_payroll(
    (DATE_TRUNC('month', CURRENT_DATE)
        - INTERVAL '1 month')::DATE
);

-- Check payroll records.
SELECT *
FROM payroll
ORDER BY pay_month, employee_id;

-- =========================================================
-- 7. TRIGGER FUNCTION: SALARY AUDIT
-- Records actual changes to basic_salary.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_log_salary_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN

        INSERT INTO salary_audit (
            employee_id,
            old_salary,
            new_salary,
            changed_at
        )
        VALUES (
            OLD.employee_id,
            OLD.basic_salary,
            NEW.basic_salary,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;
END;
$$;

-- Create the AFTER UPDATE trigger.

CREATE TRIGGER trg_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION fn_log_salary_change();

-- =========================================================
-- 8. TEST THE SALARY AUDIT TRIGGER
-- =========================================================

-- Change John's basic salary.
UPDATE employees
SET basic_salary = 5200.00
WHERE employee_id = 1;

-- Check the audit record.
SELECT *
FROM salary_audit
ORDER BY audit_id;

-- Updating with the same salary should create no new audit.
UPDATE employees
SET basic_salary = 5200.00
WHERE employee_id = 1;

-- Check again.
SELECT *
FROM salary_audit
ORDER BY audit_id;

-- =========================================================
-- 9. VIEW: v_payroll_report
-- Includes historical records even for inactive employees.
-- =========================================================

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.employee_id,
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM employees e
INNER JOIN payroll p
    ON e.employee_id = p.employee_id;

-- Display payroll report.
SELECT *
FROM v_payroll_report
ORDER BY pay_month, employee_id;

-- =========================================================
-- 10. INDEX FOR PAYROLL MONTH REPORTS
-- =========================================================

CREATE INDEX idx_payroll_pay_month
ON payroll(pay_month);

-- Matching report query.
SELECT
    employee_id,
    pay_month,
    gross_pay,
    net_pay
FROM payroll
WHERE pay_month BETWEEN
    (DATE_TRUNC('month', CURRENT_DATE)
        - INTERVAL '1 month')::DATE
    AND DATE_TRUNC('month', CURRENT_DATE)::DATE;

-- Execution plan.
EXPLAIN ANALYZE
SELECT
    employee_id,
    pay_month,
    gross_pay,
    net_pay
FROM payroll
WHERE pay_month BETWEEN
    (DATE_TRUNC('month', CURRENT_DATE)
        - INTERVAL '1 month')::DATE
    AND DATE_TRUNC('month', CURRENT_DATE)::DATE;

-- =========================================================
-- 11. SCHEDULED JOB
-- Requires pg_cron to be installed and configured.
-- =========================================================

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Run at 02:00 on the first day of every month.
-- Processes payroll for the previous month.

-- SELECT cron.schedule(
--     'monthly-payroll-processing',
--     '0 2 1 * *',
--     $job$
--         CALL pr_process_payroll(
--             (DATE_TRUNC('month', CURRENT_DATE)
--                 - INTERVAL '1 month')::DATE
--         );
--     $job$
-- );

-- Inspect scheduled jobs:
-- SELECT * FROM cron.job;

-- Inspect job execution history:
-- SELECT *
-- FROM cron.job_run_details
-- ORDER BY start_time DESC;

-- =========================================================
-- END OF QUESTION 6
-- =========================================================

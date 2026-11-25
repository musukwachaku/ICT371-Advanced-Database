
-- =========================================================
-- ICT371 - QUESTION 10
-- SCHOLARSHIP APPLICATION ASSESSMENT
-- Database: ICT371_Q10
-- =========================================================


-- 1. CLEAN UP OLD OBJECTS

DROP VIEW IF EXISTS v_approved_applicants CASCADE;

DROP TABLE IF EXISTS decision_audit CASCADE;
DROP TABLE IF EXISTS applications CASCADE;
DROP TABLE IF EXISTS students CASCADE;

DROP PROCEDURE IF EXISTS pr_assess_pending();
DROP PROCEDURE IF EXISTS pr_assess_application(INTEGER);

DROP FUNCTION IF EXISTS fn_scholarship_eligible(INTEGER, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS fn_audit_decision();


-- =========================================================
-- 2. CREATE TABLES
-- =========================================================

CREATE TABLE students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);


CREATE TABLE applications (
    application_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    student_id INTEGER NOT NULL
        REFERENCES students(student_id),

    age_at_application INTEGER NOT NULL
        CHECK (age_at_application > 0),

    monthly_income NUMERIC(12,2) NOT NULL
        CHECK (monthly_income >= 0),

    average_mark NUMERIC(5,2) NOT NULL
        CHECK (average_mark BETWEEN 0 AND 100),

    submitted_on DATE NOT NULL,

    status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);


CREATE TABLE decision_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    application_id INTEGER NOT NULL
        REFERENCES applications(application_id),

    old_status VARCHAR(10) NOT NULL,

    new_status VARCHAR(10) NOT NULL,

    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- =========================================================
-- 3. INSERT THREE STUDENTS
-- =========================================================

INSERT INTO students (student_number, full_name)
VALUES
('MU2026001', 'John Banda'),
('MU2026002', 'Mary Phiri'),
('MU2026003', 'Peter Zulu');


-- =========================================================
-- 4. INSERT SIX PENDING APPLICATIONS
-- Includes qualifying, non-qualifying and boundary cases.
-- =========================================================

INSERT INTO applications (
    student_id,
    age_at_application,
    monthly_income,
    average_mark,
    submitted_on,
    status
)
VALUES

-- Boundary case: age 18, income K3000, mark 70
(1, 18, 3000.00, 70.00, CURRENT_DATE - 10, 'PENDING'),

-- Qualifies: age 25, income K3000, mark 85
(1, 25, 3000.00, 85.00, CURRENT_DATE - 8, 'PENDING'),

-- Does not qualify: age below 18
(2, 17, 2500.00, 90.00, CURRENT_DATE - 6, 'PENDING'),

-- Does not qualify: income above K3000
(2, 22, 3001.00, 90.00, CURRENT_DATE - 4, 'PENDING'),

-- Does not qualify: mark below 70
(3, 21, 2000.00, 69.00, CURRENT_DATE - 2, 'PENDING'),

-- Does not qualify: age above 25
(3, 26, 3000.00, 70.00, CURRENT_DATE, 'PENDING');


-- =========================================================
-- 5. FUNCTION: fn_scholarship_eligible
-- Checks all three scholarship eligibility conditions.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INTEGER,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_age IS NULL
       OR p_income IS NULL
       OR p_mark IS NULL THEN

        RAISE EXCEPTION 'Eligibility inputs cannot be NULL';

    END IF;


    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be greater than zero';
    END IF;


    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative';
    END IF;


    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100';
    END IF;


    RETURN (
        p_age BETWEEN 18 AND 25
        AND p_income <= 3000
        AND p_mark >= 70
    );

END;
$$;


-- Test the eligibility function

SELECT fn_scholarship_eligible(18, 3000, 70)
AS boundary_case;

SELECT fn_scholarship_eligible(17, 2500, 90)
AS underage_case;

SELECT fn_scholarship_eligible(22, 3001, 90)
AS high_income_case;

SELECT fn_scholarship_eligible(21, 2000, 69)
AS low_mark_case;


-- =========================================================
-- 6. TRIGGER FUNCTION: fn_audit_decision
-- Records actual application status changes.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_audit_decision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    IF OLD.status IS DISTINCT FROM NEW.status THEN

        INSERT INTO decision_audit (
            application_id,
            old_status,
            new_status,
            changed_at
        )
        VALUES (
            NEW.application_id,
            OLD.status,
            NEW.status,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;


-- =========================================================
-- 7. CREATE AFTER UPDATE TRIGGER
-- =========================================================

CREATE TRIGGER trg_audit_decision
AFTER UPDATE OF status ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_audit_decision();


-- =========================================================
-- 8. PROCEDURE: pr_assess_application
-- Assesses one application and updates its status.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age INTEGER;
    v_income NUMERIC(12,2);
    v_mark NUMERIC(5,2);
    v_status VARCHAR(10);
    v_eligible BOOLEAN;
BEGIN

    -- Lock the application while assessing it.
    SELECT
        age_at_application,
        monthly_income,
        average_mark,
        status
    INTO
        v_age,
        v_income,
        v_mark,
        v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;


    -- Check whether the application exists.
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Application ID % does not exist',
            p_application_id;
    END IF;


    -- Only pending applications can be assessed.
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION
            'Application % has already been assessed. Current status: %',
            p_application_id,
            v_status;
    END IF;


    -- Check scholarship eligibility.
    v_eligible := fn_scholarship_eligible(
        v_age,
        v_income,
        v_mark
    );


    -- Update the application status.
    IF v_eligible THEN

        UPDATE applications
        SET status = 'APPROVED'
        WHERE application_id = p_application_id;

    ELSE

        UPDATE applications
        SET status = 'REJECTED'
        WHERE application_id = p_application_id;

    END IF;

END;
$$;


-- =========================================================
-- 9. VIEW: v_approved_applicants
-- Shows approved applicants only.
-- Household income is deliberately excluded.
-- =========================================================

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM students s
INNER JOIN applications a
    ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';


-- =========================================================
-- 10. COMPOSITE INDEX
-- Supports searches by application status and submission date.
-- =========================================================

CREATE INDEX idx_applications_status_date
ON applications (status, submitted_on);


-- Matching query

SELECT
    application_id,
    student_id,
    submitted_on,
    status
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
ORDER BY submitted_on;


-- Execution plan

EXPLAIN ANALYZE
SELECT
    application_id,
    student_id,
    submitted_on,
    status
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
ORDER BY submitted_on;


-- =========================================================
-- 11. PROCEDURE: pr_assess_pending
-- Processes all pending applications using a FOR loop.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    v_application RECORD;
BEGIN

    FOR v_application IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP

        CALL pr_assess_application(
            v_application.application_id
        );

    END LOOP;

END;
$$;


-- =========================================================
-- 12. RUN THE AUTOMATIC ASSESSMENT
-- =========================================================

CALL pr_assess_pending();


-- =========================================================
-- 13. VERIFY APPLICATION RESULTS
-- =========================================================

SELECT
    application_id,
    student_id,
    age_at_application,
    monthly_income,
    average_mark,
    status
FROM applications
ORDER BY application_id;


-- =========================================================
-- 14. VERIFY APPROVED APPLICANTS VIEW
-- =========================================================

SELECT *
FROM v_approved_applicants
ORDER BY student_number;


-- =========================================================
-- 15. VERIFY AUDIT RECORDS
-- =========================================================

SELECT *
FROM decision_audit
ORDER BY audit_id;


-- =========================================================
-- 16. TEST RERUNNING THE BATCH PROCEDURE
-- Completed applications should not be assessed again.
-- =========================================================

CALL pr_assess_pending();


-- Audit count should remain unchanged.
SELECT COUNT(*) AS total_audit_records
FROM decision_audit;


-- =========================================================
-- 17. OPTIONAL SCHEDULED JOB
-- Every Monday at 08:00.
-- Uncomment only if pg_cron is installed and configured.
-- =========================================================

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- SELECT cron.schedule(
--     'assess-pending-scholarship-applications',
--     '0 8 * * 1',
--     $$CALL pr_assess_pending();$$
-- );


-- =========================================================
-- 18. FINAL VERIFICATION
-- =========================================================

SELECT
    status,
    COUNT(*) AS application_count
FROM applications
GROUP BY status
ORDER BY status;

SELECT *
FROM decision_audit
ORDER BY audit_id;

SELECT *
FROM v_approved_applicants
ORDER BY student_number;

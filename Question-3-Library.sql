
/* =========================================================
   ICT371 - ADVANCED DATABASE
   QUESTION 3: LIBRARY RETURNS AND OVERDUE FINES
   Database: ICT371_Q3
   ========================================================= */


/* =========================================================
   (a) DATABASE TABLES
   ========================================================= */

-- Books table
CREATE TABLE books (
    book_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

-- Loans table
CREATE TABLE loans (
    loan_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0
        CHECK (fine_amount >= 0),

    CONSTRAINT chk_loan_dates
        CHECK (due_on >= borrowed_on),

    CONSTRAINT chk_return_date
        CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

-- Loan audit table
CREATE TABLE loan_audit (
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Overdue summary table
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine NUMERIC(12,2) NOT NULL DEFAULT 0
);


/* =========================================================
   (b) FUNCTION: fn_loan_fine
   Calculates K2 per overdue day.
   A returned loan stops accumulating fines.
   ========================================================= */

CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of DATE
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_end_date DATE;
    v_overdue_days INTEGER;
BEGIN
    IF p_loan_id IS NULL OR p_as_of IS NULL THEN
        RAISE EXCEPTION 'Loan ID and calculation date cannot be NULL';
    END IF;

    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % does not exist', p_loan_id;
    END IF;

    -- Use the earlier of the calculation date and return date.
    v_end_date := LEAST(
        p_as_of,
        COALESCE(v_returned_on, p_as_of)
    );

    v_overdue_days := GREATEST(
        0,
        v_end_date - v_due_on
    );

    RETURN (v_overdue_days * 2)::NUMERIC(10,2);
END;
$$;


/* =========================================================
   SEED DATA
   Three books and six loans.
   Includes overdue, on-time and returned loans.
   ========================================================= */

INSERT INTO books (title)
VALUES
    ('Introduction to Database Systems'),
    ('Computer Networks'),
    ('Programming with SQL');


INSERT INTO loans (
    book_id,
    borrower_name,
    borrowed_on,
    due_on,
    returned_on,
    fine_amount
)
VALUES
    -- Open overdue loan.
    (1, 'John Banda', '2026-11-10', '2026-11-20', NULL, 0),

    -- Open loan due today.
    (2, 'Mary Phiri', '2026-11-15', '2026-11-25', NULL, 0),

    -- Returned late: 2 overdue days = K4.
    (3, 'Peter Zulu', '2026-11-01', '2026-11-10',
     '2026-11-12', 4.00),

    -- Another open overdue loan.
    (1, 'Sarah Mwansa', '2026-11-05', '2026-11-18', NULL, 0),

    -- Returned on time: no fine.
    (2, 'David Tembo', '2026-11-02', '2026-11-15',
     '2026-11-15', 0),

    -- Open loan with a future due date.
    (3, 'Grace Phiri', '2026-11-20', '2026-11-30', NULL, 0);


/* =========================================================
   (d) TRIGGER: LOAN AUDIT
   Records actual changes to returned_on.
   ========================================================= */

CREATE OR REPLACE FUNCTION fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (
        loan_id,
        old_returned_on,
        new_returned_on,
        changed_at
    )
    VALUES (
        NEW.loan_id,
        OLD.returned_on,
        NEW.returned_on,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION fn_loan_audit();


/* =========================================================
   (c) PROCEDURE: pr_return_loan
   Records a book return and its final fine.
   ========================================================= */

CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INTEGER,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_current_return DATE;
    v_final_fine NUMERIC(10,2);
BEGIN
    IF p_loan_id IS NULL OR p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Loan ID and return date cannot be NULL';
    END IF;

    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_current_return
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % does not exist', p_loan_id;
    END IF;

    IF v_current_return IS NOT NULL THEN
        RAISE EXCEPTION 'This loan has already been returned';
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION
            'Return date cannot be before borrowed date';
    END IF;

    -- Calculate final fine using the return date.
    v_final_fine := fn_loan_fine(
        p_loan_id,
        p_returned_on
    );

    -- Store return date and final fine together.
    -- The trigger automatically creates the audit record.
    UPDATE loans
    SET
        returned_on = p_returned_on,
        fine_amount = v_final_fine
    WHERE loan_id = p_loan_id;

END;
$$;


/* =========================================================
   TEST THE RETURN PROCEDURE
   Return the first loan on 2026-11-25.
   ========================================================= */

CALL pr_return_loan(1, DATE '2026-11-25');


/* =========================================================
   (e) VIEW: v_overdue_loans
   Shows currently unreturned overdue loans.
   ========================================================= */

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b
    ON l.book_id = b.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;


-- Display overdue loans.
SELECT * FROM v_overdue_loans;


/* =========================================================
   (f) INDEX
   Supports searches for a given book's unreturned loans.
   ========================================================= */

CREATE INDEX idx_loans_unreturned_book
ON loans (book_id)
WHERE returned_on IS NULL;


-- Matching query.
SELECT
    loan_id,
    book_id,
    borrower_name,
    borrowed_on,
    due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;


-- Display execution plan.
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    loan_id,
    book_id,
    borrower_name,
    borrowed_on,
    due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;


/* =========================================================
   (g) PROCEDURE: pr_refresh_overdue
   Counts loans still unreturned as of a given date.
   Replaces existing snapshot instead of duplicating it.
   ========================================================= */

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Snapshot date cannot be NULL';
    END IF;

    INSERT INTO overdue_summary (
        snapshot_date,
        overdue_count,
        total_fine
    )
    SELECT
        p_as_of,
        COUNT(*)::INTEGER,
        COALESCE(
            SUM(fn_loan_fine(loan_id, p_as_of)),
            0
        )
    FROM loans
    WHERE returned_on IS NULL
       OR returned_on > p_as_of

    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;


/* =========================================================
   TEST THE OVERDUE SUMMARY PROCEDURE
   ========================================================= */

CALL pr_refresh_overdue(DATE '2026-11-25');

SELECT * FROM overdue_summary;


/* =========================================================
   SCHEDULED JOB: DAILY AT 00:10
   Requires pg_cron to be installed and configured.
   ========================================================= */

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Remove existing job with the same name if necessary.
-- SELECT cron.unschedule(jobid)
-- FROM cron.job
-- WHERE jobname = 'refresh-overdue-summary';

-- Schedule daily at 00:10 for the current date.
-- SELECT cron.schedule(
--     'refresh-overdue-summary',
--     '10 0 * * *',
--     'CALL pr_refresh_overdue(CURRENT_DATE);'
-- );


/* =========================================================
   FINAL VERIFICATION QUERIES
   ========================================================= */

-- View all books.
SELECT * FROM books;

-- View all loans.
SELECT * FROM loans;

-- Check calculated fines.
SELECT
    loan_id,
    borrower_name,
    due_on,
    returned_on,
    fine_amount,
    fn_loan_fine(loan_id, CURRENT_DATE) AS calculated_fine
FROM loans;

-- Check automatically generated audit records.
SELECT * FROM loan_audit;

-- Check overdue loans.
SELECT * FROM v_overdue_loans;

-- Check overdue summary.
SELECT * FROM overdue_summary;

-- End of Question 3

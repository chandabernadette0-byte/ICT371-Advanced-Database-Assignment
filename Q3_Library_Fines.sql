-- ICT371 Q3: Library Returns and Overdue Fines   (PostgreSQL 14+, pg_cron)
DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path = q3_library, public;

-- (a) Tables ----------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER      NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE         NOT NULL,
    due_on        DATE         NOT NULL,
    returned_on   DATE,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE,
    new_returned_on  DATE,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'), ('Operating Systems'), ('Computer Networks');

-- (b) Function ----------------------------------------------------------------
-- K2 per day after due date; a return on the due date costs nothing;
-- a returned loan stops accumulating fines (use the earlier of as-of and return date).
CREATE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql STABLE
SET search_path = q3_library, public AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date is required';
    END IF;
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));
    RETURN (2 * GREATEST(v_end - v_due, 0))::NUMERIC(10,2);
END $$;

-- (c) Procedure ---------------------------------------------------------------
-- Return date and final fine are written in ONE UPDATE statement (atomic).
CREATE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql SET search_path = q3_library, public AS $$
DECLARE v_borrowed DATE; v_returned DATE;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;
    -- returned_on is still NULL when fn_loan_fine runs, so it uses p_returned_on as the end date
    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
     WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger -----------------------------------------------------------------
CREATE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q3_library, public AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- (a, continued) Six loans: dates are relative to today so the view always has data
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Chanda Mwila',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue
    (2, 'Mutale Banda',  CURRENT_DATE - 2,  CURRENT_DATE + 12),  -- 2 open, not yet due (on time)
    (3, 'Temwani Phiri', CURRENT_DATE - 60, CURRENT_DATE - 46),  -- 3 will be returned late
    (1, 'Natasha Zulu',  CURRENT_DATE - 50, CURRENT_DATE - 36),  -- 4 will be returned ON due date
    (2, 'Joseph Tembo',  CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 5 open, overdue
    (3, 'Grace Lungu',   CURRENT_DATE - 20, CURRENT_DATE - 6);   -- 6 will be returned early

CALL pr_return_loan(3, CURRENT_DATE - 40);   -- 6 days late  -> K12
CALL pr_return_loan(4, CURRENT_DATE - 36);   -- on due date  -> K0
CALL pr_return_loan(6, CURRENT_DATE - 10);   -- early        -> K0

-- Rejection tests
DO $$ BEGIN CALL q3_library.pr_return_loan(3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL q3_library.pr_return_loan(1, CURRENT_DATE - 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

SELECT loan_id, due_on, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;

-- (e) View ----------------------------------------------------------------------
CREATE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index -------------------------------------------------------------------
-- Partial index: contains only unreturned loans (a small, shrinking set) keyed by book.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------------
-- "Unreturned as of p_as_of" = borrowed by then and not returned on/before that date;
-- only those already past due are counted as overdue.
CREATE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql SET search_path = q3_library, public AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND due_on < p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET overdue_count = EXCLUDED.overdue_count,
                  total_fine    = EXCLUDED.total_fine;
END $$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces the same snapshot_date
SELECT * FROM overdue_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q3_refresh_overdue', '10 0 * * *',
       $$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$$);

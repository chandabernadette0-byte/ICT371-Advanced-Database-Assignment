-- ICT371 Q7: Water Meter Readings and Billing   (PostgreSQL 14+, pg_cron)
DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path = q7_water, public;

-- (a) Tables ----------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_reading_customer_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Chanda Mwila'), ('Mutale Banda'), ('Temwani Phiri');

-- (b) Function: first 10 units K5, units above 10 at K8 -----------------------------
CREATE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must be non-negative)', p_units;
    END IF;
    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END $$;

-- (d) Trigger: reject current < previous, also for direct SQL imports -------------
-- A BEFORE trigger raising an exception aborts the statement, so nothing is stored.
CREATE FUNCTION trg_fn_check_reading() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_check_reading();

-- (a, continued) Six readings: zero, exactly 10 and above 10 units ----------------
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100, 100),    -- 0 units   -> K0
    (1, DATE '2026-10-01', 100, 110),    -- 10 units  -> K50
    (2, DATE '2026-09-01',  50,  75),    -- 25 units  -> K170
    (2, DATE '2026-10-01',  75,  86),    -- 11 units  -> K58
    (3, DATE '2026-09-01',  10,  20),    -- 10 units  -> K50
    (3, DATE '2026-10-01',  20,  42);    -- 22 units  -> K154

DO $$ BEGIN
    INSERT INTO q7_water.readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (3, DATE '2026-11-01', 42, 40);                         -- rejected by trigger
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_stored FROM readings;                  -- still 6

-- (c) Procedure ---------------------------------------------------------------
CREATE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql SET search_path = q7_water, public AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;
    SELECT previous_reading, current_reading INTO v_prev, v_curr
      FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END $$;

CALL pr_generate_bill(1, CURRENT_DATE - 40);   -- K0, overdue but fully paid (zero charge)
CALL pr_generate_bill(2, CURRENT_DATE - 20);   -- overdue, unpaid
CALL pr_generate_bill(3, CURRENT_DATE - 10);   -- overdue, will be part-paid
CALL pr_generate_bill(4, CURRENT_DATE + 10);   -- not yet due
CALL pr_generate_bill(5, CURRENT_DATE - 30);   -- overdue, will be fully paid
CALL pr_generate_bill(6, CURRENT_DATE + 5);    -- not yet due
UPDATE bills SET amount_paid = 100 WHERE reading_id = 3;
UPDATE bills SET amount_paid = charge WHERE reading_id = 5;

DO $$ BEGIN CALL q7_water.pr_generate_bill(1, CURRENT_DATE);       -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL q7_water.pr_generate_bill(999, CURRENT_DATE);     -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

SELECT fn_water_charge(0), fn_water_charge(10), fn_water_charge(10.5), fn_water_charge(25);

-- (e) View --------------------------------------------------------------------
CREATE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) Index -------------------------------------------------------------------
-- Partial index on due_on for unpaid bills only: fully paid bills (the majority over
-- time) are left out, so date-range searches for overdue bills stay small and fast.
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------------
CREATE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql SET search_path = q7_water, public AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills WHERE amount_paid < charge
    ON CONFLICT (snapshot_date)
    DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();     -- rerun replaces today's total
SELECT * FROM receivable_snapshot;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q7_refresh_receivables', '30 0 * * *',
       $$CALL q7_water.pr_refresh_receivables()$$);

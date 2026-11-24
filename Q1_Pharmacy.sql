-- ICT371 Q1: Pharmacy Stock and Daily Sales   (PostgreSQL 14+, pg_cron for scheduling)
DROP SCHEMA IF EXISTS q1_pharmacy CASCADE;
CREATE SCHEMA q1_pharmacy;
SET search_path = q1_pharmacy, public;

-- (a) Tables ----------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL
);
CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00, 50),
    ('Ibuprofen 200mg',   4.00, 12);

-- (b) Function ----------------------------------------------------------------
CREATE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql STABLE
SET search_path = q1_pharmacy, public AS $$
DECLARE v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be positive)', p_quantity;
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    RETURN v_price * p_quantity;
END $$;

-- (c) Procedure ---------------------------------------------------------------
-- All checks happen before any write, so an invalid sale changes nothing.
-- Stock is deducted only here (once); the audit trigger only records it.
CREATE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql SET search_path = q1_pharmacy, public AS $$
DECLARE v_price NUMERIC(10,2); v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;
    SELECT unit_price, stock_qty INTO v_price, v_stock
      FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;   -- lock the row
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
                        p_medicine_id, v_stock, p_quantity;
    END IF;
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
    UPDATE medicines SET stock_qty = stock_qty - p_quantity WHERE medicine_id = p_medicine_id;
END $$;

-- (d) Trigger -----------------------------------------------------------------
CREATE FUNCTION trg_fn_stock_audit() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q1_pharmacy, public AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a, continued) Six valid sales loaded through the procedure ------------------
CALL pr_record_sale(1, 10, DATE '2026-11-20');
CALL pr_record_sale(1, 20, DATE '2026-11-21');
CALL pr_record_sale(2,  5, DATE '2026-11-21');
CALL pr_record_sale(2, 10, DATE '2026-11-22');
CALL pr_record_sale(3,  3, DATE '2026-11-22');
CALL pr_record_sale(3,  2, DATE '2026-11-23');

-- Invalid sale test: raises an error and leaves both tables unchanged
DO $$ BEGIN
    CALL q1_pharmacy.pr_record_sale(3, 999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

SELECT fn_sale_value(2, 3) AS sale_value;      -- 24.00
SELECT * FROM stock_audit ORDER BY audit_id;   -- one row per stock change

-- (e) View --------------------------------------------------------------------
CREATE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;                      -- Ibuprofen (12 - 3 - 2 = 7)

-- (f) Index -------------------------------------------------------------------
-- Equality on medicine_id first, then the range on sold_on: one contiguous index
-- range answers "one medicine's sales between two dates" without scanning the table.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;
SET enable_seqscan = off;     -- tiny table: force the planner to show the index plan
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-22';
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------------
-- Upsert on the primary key: reruns replace the day's totals, never add to them.
CREATE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql SET search_path = q1_pharmacy, public AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date)
    DO UPDATE SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;

CALL pr_refresh_sales(DATE '2026-11-21');
CALL pr_refresh_sales(DATE '2026-11-21');       -- rerun: still one row, same totals
SELECT * FROM daily_sales;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q1_refresh_sales', '15 0 * * *',
       $$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1)$$);

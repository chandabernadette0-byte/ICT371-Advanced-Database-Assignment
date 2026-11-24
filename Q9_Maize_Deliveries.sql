-- ICT371 Q9: Farmer Cooperative Maize Deliveries   (PostgreSQL 14+, pg_cron)
DROP SCHEMA IF EXISTS q9_maize CASCADE;
CREATE SCHEMA q9_maize;
SET search_path = q9_maize, public;

-- (a) Tables ----------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(10,2) NOT NULL,      -- supplied by the trigger
    total_value  NUMERIC(14,2) NOT NULL,      -- supplied by the trigger
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Chanda Mwila'), ('F002', 'Mutale Banda'), ('F003', 'Temwani Phiri');

-- (b) Function ----------------------------------------------------------------
CREATE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;
    IF p_grade = 'A' THEN RETURN 5;
    ELSIF p_grade = 'B' THEN RETURN 4;
    ELSIF p_grade = 'C' THEN RETURN 3;
    END IF;
    RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
END $$;

-- (d) Trigger: one pricing rule for procedure AND direct SQL ----------------------
CREATE FUNCTION trg_fn_price_delivery() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q9_maize, public AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade::TEXT);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_deliveries_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_price_delivery();

-- (c) Procedure: inserts basic fields only, the trigger prices the delivery ----------
CREATE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql SET search_path = q9_maize, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    PERFORM fn_maize_rate(p_grade);          -- rejects NULL / unsupported grades early
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- (a, continued) Six deliveries, all grades, both payment states -------------------
-- Loaded by direct INSERT (after the trigger): rate and value are NOT supplied.
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100, DATE '2026-11-20', TRUE),
    (1, 'B', 200, DATE '2026-11-21', FALSE),
    (2, 'C', 150, DATE '2026-11-21', FALSE),
    (2, 'A',  80, DATE '2026-11-22', TRUE),
    (3, 'B',  50, DATE '2026-11-22', TRUE),
    (3, 'C', 120, DATE '2026-11-23', TRUE);        -- farmer 3 owes nothing

-- Procedure usage and rejections
CALL pr_receive_delivery(3, 'A', 60, DATE '2026-11-23');
DO $$ BEGIN CALL q9_maize.pr_receive_delivery(1, 'D', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL q9_maize.pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO q9_maize.deliveries (farmer_id, grade, weight_kg, delivered_on)
            VALUES (1, 'A', -5, CURRENT_DATE);                -- direct SQL, trigger rejects
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected by trigger: %', SQLERRM; END $$;

SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, is_paid
FROM deliveries ORDER BY delivery_id;

-- (e) View: includes farmers with no unpaid deliveries (amount 0) -------------------
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Index -------------------------------------------------------------------
-- farmer_id (equality) then delivered_on (range) for one farmer's deliveries between dates.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-22';
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------------
CREATE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql SET search_path = q9_maize, public AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date)
    DO UPDATE SET total_weight = EXCLUDED.total_weight,
                  total_value  = EXCLUDED.total_value;      -- replace, never add
END $$;

CALL pr_refresh_purchases(DATE '2026-11-22');
CALL pr_refresh_purchases(DATE '2026-11-22');               -- rerun: same totals
SELECT * FROM daily_purchases;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q9_refresh_purchases', '30 1 * * *',
       $$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1)$$);

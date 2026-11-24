/* =====================================================================
   Full 
   Student number : 202400653
   Course code    : ICT371 Advanced Database
   Assignment     : Activity 7b - PostgreSQL Triggers and Views Scenario
                    (Campus ICT Equipment Inventory)
   Due            : 19 November 2026, 23:59 Hrs
   Currency       : Zambian kwacha (ZMW)
  

/* =====================================================================
   TASK 1 - CREATE AND SEED THE DATABASE
   ===================================================================== */

-- Re-runnable: removes only the assignment's own schema (nothing outside it).
DROP SCHEMA IF EXISTS ict372_inventory CASCADE;
CREATE SCHEMA ict372_inventory;

-- Every object below lives in ict372_inventory.
SET search_path TO ict372_inventory;

-- ---------- categories ----------
CREATE TABLE ict372_inventory.categories (
    category_id    integer     PRIMARY KEY,
    category_name  varchar(60) NOT NULL UNIQUE
);

-- ---------- inventory_items ----------
CREATE TABLE ict372_inventory.inventory_items (
    item_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_code      varchar(12)   NOT NULL UNIQUE,
    item_name      varchar(80)   NOT NULL,
    category_id    integer       NOT NULL
                   REFERENCES ict372_inventory.categories (category_id),
    quantity       integer       NOT NULL,
    unit_cost      numeric(10,2) NOT NULL,
    reorder_level  integer       NOT NULL,
    stock_value    numeric(14,2) NOT NULL,
    CONSTRAINT ck_items_quantity_nonneg      CHECK (quantity      >= 0),
    CONSTRAINT ck_items_unit_cost_nonneg     CHECK (unit_cost     >= 0),
    CONSTRAINT ck_items_reorder_level_nonneg CHECK (reorder_level >= 0),
    CONSTRAINT ck_items_stock_value_nonneg   CHECK (stock_value   >= 0)
);

-- ---------- inventory_audit ----------
-- No foreign key to inventory_items on purpose: when an item is deleted its
-- audit history must remain, so the audit table only stores the item_code.
CREATE TABLE ict372_inventory.inventory_audit (
    audit_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_code       varchar(12)   NOT NULL,
    operation       varchar(6)    NOT NULL,
    old_quantity    integer,
    new_quantity    integer,
    old_unit_cost   numeric(10,2),
    new_unit_cost   numeric(10,2),
    old_stock_value numeric(14,2),
    new_stock_value numeric(14,2),
    changed_by      text          NOT NULL DEFAULT current_user,   -- database user
    changed_at      timestamptz   NOT NULL DEFAULT now(),          -- time-zone aware
    CONSTRAINT ck_audit_operation CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    CONSTRAINT ck_audit_old_qty   CHECK (old_quantity    >= 0),
    CONSTRAINT ck_audit_new_qty   CHECK (new_quantity    >= 0),
    CONSTRAINT ck_audit_old_cost  CHECK (old_unit_cost   >= 0),
    CONSTRAINT ck_audit_new_cost  CHECK (new_unit_cost   >= 0),
    CONSTRAINT ck_audit_old_value CHECK (old_stock_value >= 0),
    CONSTRAINT ck_audit_new_value CHECK (new_stock_value >= 0)
);

-- Helper table used only to keep evidence of the handled-error tests (5 and 6),
-- because RAISE NOTICE messages are not stored in a result grid.


-- ---------- seed categories (Printing stays empty) ----------
INSERT INTO ict372_inventory.categories (category_id, category_name) VALUES
    (1, 'Computing'),
    (2, 'Networking'),
    (3, 'Printing');

-- ---------- seed items (triggers do not exist yet, so stock_value is supplied) ----------
INSERT INTO ict372_inventory.inventory_items
    (item_code, item_name, category_id, quantity, unit_cost, reorder_level, stock_value)
VALUES
    ('I001', 'Laptop',           1,  5, 12500.00,  5, 62500.00),  -- 5  x 12500 
    ('I002', 'Desktop computer', 1,  8, 10000.00,  3, 80000.00),  -- 8  x 10000
    ('I003', 'Projector',        1, 10,  6500.00,  2, 65000.00),  -- 10 x 6500
    ('I004', 'Router',           2,  3,  1500.00,  5,  4500.00),  -- 3  x 1500
    ('I005', 'Network switch',   2, 12,  2400.00,  4, 28800.00),  -- 12 x 2400
    ('I006', 'Network cable',    2, 20,    50.00, 10,  1000.00);  -- 20 x 50

-- ---------- initial checks ----------
-- Check 1.1: seeded categories (3 rows; Printing has no items).
SELECT * FROM ict372_inventory.categories ORDER BY category_id;

-- Check 1.2: seeded items (6 rows).
SELECT * FROM ict372_inventory.inventory_items ORDER BY item_id;

-- Check 1.3: seeded stock_value agrees with quantity * unit_cost (expected: 0 mismatches).
SELECT count(*) AS mismatched_seed_rows
FROM   ict372_inventory.inventory_items
WHERE  stock_value <> quantity * unit_cost;

-- Check 1.4: audit table is empty because the triggers do not exist yet (expected: 0).
SELECT count(*) AS audit_rows_initially FROM ict372_inventory.inventory_audit;


/* =====================================================================
   TASK 2 - TRIGGER FUNCTIONS AND TRIGGERS
   ===================================================================== */

-- 2.1 Prepare/validate function (BEFORE trigger).
-- It runs BEFORE the row is written so it can change NEW (trim the name,
-- recalculate stock_value).  NOT NULL / CHECK constraints are tested only
-- after BEFORE triggers, so NULLs and negatives are rejected here explicitly
-- to give clear error messages.
CREATE OR REPLACE FUNCTION ict372_inventory.prepare_inventory_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Required numeric inputs must not be NULL.
    IF NEW.quantity IS NULL THEN
        RAISE EXCEPTION 'quantity is required and cannot be NULL'
              USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.unit_cost IS NULL THEN
        RAISE EXCEPTION 'unit_cost is required and cannot be NULL'
              USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.reorder_level IS NULL THEN
        RAISE EXCEPTION 'reorder_level is required and cannot be NULL'
              USING ERRCODE = 'check_violation';
    END IF;

    -- Reject negative values (quantity/reorder_level are integers, so they are already whole numbers).
    IF NEW.quantity < 0 THEN
        RAISE EXCEPTION 'quantity must be zero or more (got %)', NEW.quantity
              USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.unit_cost < 0 THEN
        RAISE EXCEPTION 'unit_cost must be zero or more (got %)', NEW.unit_cost
              USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.reorder_level < 0 THEN
        RAISE EXCEPTION 'reorder_level must be zero or more (got %)', NEW.reorder_level
              USING ERRCODE = 'check_violation';
    END IF;

    -- Trim spaces (also tabs/newlines) from the name; reject NULL or blank names.
    IF NEW.item_name IS NULL THEN
        RAISE EXCEPTION 'item_name is required and cannot be NULL'
              USING ERRCODE = 'check_violation';
    END IF;
    NEW.item_name := btrim(NEW.item_name, E' \t\r\n');
    IF NEW.item_name = '' THEN
        RAISE EXCEPTION 'item_name cannot be blank'
              USING ERRCODE = 'check_violation';
    END IF;

    -- Always derive stock_value; any value supplied (or edited) by the user is overwritten.
    NEW.stock_value := NEW.quantity * NEW.unit_cost;

    RETURN NEW;   -- BEFORE ROW trigger must return the (modified) row
END;
$$;

-- 2.2 Attach the BEFORE trigger.
CREATE TRIGGER trg_prepare_inventory_item
    BEFORE INSERT OR UPDATE
    ON ict372_inventory.inventory_items
    FOR EACH ROW
    EXECUTE FUNCTION ict372_inventory.prepare_inventory_item();

-- 2.3 Audit function (AFTER trigger).
-- Row values:  INSERT -> only NEW exists (old_* columns are NULL)
--              UPDATE -> old_* come from OLD, new_* come from NEW
--              DELETE -> only OLD exists (new_* columns are NULL)
CREATE OR REPLACE FUNCTION ict372_inventory.audit_inventory_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO ict372_inventory.inventory_audit
            (item_code, operation,
             old_quantity, new_quantity,
             old_unit_cost, new_unit_cost,
             old_stock_value, new_stock_value)
        VALUES
            (NEW.item_code, TG_OP,              -- item code from NEW
             NULL,          NEW.quantity,       -- no OLD row on INSERT
             NULL,          NEW.unit_cost,
             NULL,          NEW.stock_value);

    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO ict372_inventory.inventory_audit
            (item_code, operation,
             old_quantity, new_quantity,
             old_unit_cost, new_unit_cost,
             old_stock_value, new_stock_value)
        VALUES
            (NEW.item_code, TG_OP,              -- item code from NEW (the row after the update)
             OLD.quantity,    NEW.quantity,     -- before values from OLD, after values from NEW
             OLD.unit_cost,   NEW.unit_cost,
             OLD.stock_value, NEW.stock_value);

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO ict372_inventory.inventory_audit
            (item_code, operation,
             old_quantity, new_quantity,
             old_unit_cost, new_unit_cost,
             old_stock_value, new_stock_value)
        VALUES
            (OLD.item_code, TG_OP,              -- item code from OLD (NEW does not exist on DELETE)
             OLD.quantity,    NULL,
             OLD.unit_cost,   NULL,
             OLD.stock_value, NULL);
    END IF;

    -- Returning NULL is fine here: the return value of a row-level AFTER trigger
    -- is ignored by PostgreSQL (the row change has already happened), so NULL
    -- does not cancel the INSERT/UPDATE/DELETE.
    RETURN NULL;
END;
$$;

-- 2.4 Attach the AFTER trigger (one audit row per affected row).
CREATE TRIGGER trg_audit_inventory_item
    AFTER INSERT OR UPDATE OR DELETE
    ON ict372_inventory.inventory_items
    FOR EACH ROW
    EXECUTE FUNCTION ict372_inventory.audit_inventory_item();


/* =====================================================================
   TASK 3 - CREATE AND APPLY THREE VIEWS
   ===================================================================== */

-- v_low_stock_items: simple single-table view => automatically updatable.
-- WITH LOCAL CHECK OPTION blocks changes through the view that would make
-- a row leave the view (quantity > reorder_level).
CREATE OR REPLACE VIEW ict372_inventory.v_low_stock_items AS
SELECT item_code, item_name, category_id, quantity, unit_cost,
       reorder_level, stock_value
FROM   ict372_inventory.inventory_items
WHERE  quantity <= reorder_level
WITH LOCAL CHECK OPTION;

-- v_inventory_details: reporting view (join, not intended for updates).
CREATE OR REPLACE VIEW ict372_inventory.v_inventory_details AS
SELECT i.item_code, i.item_name, c.category_name, i.quantity,
       i.unit_cost, i.reorder_level, i.stock_value
FROM   ict372_inventory.inventory_items i
JOIN   ict372_inventory.categories      c ON c.category_id = i.category_id;

-- v_category_summary: reporting view (aggregate).
-- LEFT JOIN keeps empty categories (Printing).  count(i.item_id) counts only
-- real items (count(*) would count 1 for the NULL-extended empty category).
-- COALESCE turns the NULL SUM of an empty category into 0.
CREATE OR REPLACE VIEW ict372_inventory.v_category_summary AS
SELECT c.category_id,
       c.category_name,
       count(i.item_id)                          AS item_count,
       COALESCE(sum(i.quantity), 0)              AS total_quantity,
       COALESCE(sum(i.stock_value), 0)::numeric(14,2) AS total_stock_value,
       count(i.item_id) FILTER (WHERE i.quantity <= i.reorder_level) AS low_stock_count
FROM   ict372_inventory.categories c
LEFT JOIN ict372_inventory.inventory_items i ON i.category_id = c.category_id
GROUP BY c.category_id, c.category_name;

-- ---------- applying the views ----------
-- View demo 3.1: items needing replenishment, most urgent (largest shortfall) first.
SELECT item_code, item_name, quantity, reorder_level,
       (reorder_level - quantity) AS shortfall
FROM   ict372_inventory.v_low_stock_items
ORDER  BY shortfall DESC, item_code;

-- View demo 3.2: Networking items with stock value above K2,000, highest value first.
SELECT item_code, item_name, category_name, quantity, unit_cost, stock_value
FROM   ict372_inventory.v_inventory_details
WHERE  category_name = 'Networking'
  AND  stock_value > 2000
ORDER  BY stock_value DESC;

-- View demo 3.3: category summary, highest stock value first (Printing shows zeros).
SELECT *
FROM   ict372_inventory.v_category_summary
ORDER  BY total_stock_value DESC, category_id;

-- View demo 3.4: only categories that currently have low-stock items.
SELECT category_name, item_count, low_stock_count
FROM   ict372_inventory.v_category_summary
WHERE  low_stock_count > 0
ORDER  BY low_stock_count DESC, category_name;


/* =====================================================================
   TASK 4 - TESTS (executed in the required order)
   ===================================================================== */

-- ---------------------------------------------------------------------
-- TEST 1: Insert I007 with spaces around the name and NO stock_value.
-- Expected: name trimmed to 'Webcam', stock_value = 6 x 800 = 4800.00,
--           one INSERT audit row (old_* NULL).
-- ---------------------------------------------------------------------
INSERT INTO ict372_inventory.inventory_items
    (item_code, item_name, category_id, quantity, unit_cost, reorder_level)
VALUES
    ('I007', '   Webcam   ', 1, 6, 800.00, 2);

SELECT item_code,
       item_name,
       '[' || item_name || ']' AS name_with_brackets,   -- proves no leading/trailing spaces
       length(item_name)       AS name_length,
       quantity, unit_cost, stock_value
FROM   ict372_inventory.inventory_items
WHERE  item_code = 'I007';

SELECT audit_id, item_code, operation, old_quantity, new_quantity,
       old_unit_cost, new_unit_cost, old_stock_value, new_stock_value,
       changed_by, changed_at
FROM   ict372_inventory.inventory_audit
WHERE  item_code = 'I007'
ORDER  BY audit_id;

-- ---------------------------------------------------------------------
-- TEST 2: Update I003 quantity from 10 to 2 through inventory_items.
-- Expected: stock_value recalculated 65000.00 -> 13000.00 (2 x 6500),
--           one UPDATE audit row; I003 now qualifies as low stock (2 <= 2).
-- ---------------------------------------------------------------------
UPDATE ict372_inventory.inventory_items
SET    quantity = 2
WHERE  item_code = 'I003';

SELECT item_code, item_name, quantity, unit_cost, reorder_level, stock_value
FROM   ict372_inventory.inventory_items
WHERE  item_code = 'I003';

SELECT audit_id, item_code, operation, old_quantity, new_quantity,
       old_stock_value, new_stock_value, changed_by, changed_at
FROM   ict372_inventory.inventory_audit
WHERE  item_code = 'I003'
ORDER  BY audit_id;

-- ---------------------------------------------------------------------
-- TEST 3: Delete I007.
-- Expected: I007 is gone from inventory_items, but its INSERT and DELETE
--           audit rows remain (no FK from the audit table).
-- ---------------------------------------------------------------------
DELETE FROM ict372_inventory.inventory_items
WHERE  item_code = 'I007';

SELECT count(*) AS i007_rows_in_inventory_items      -- expected 0
FROM   ict372_inventory.inventory_items
WHERE  item_code = 'I007';

SELECT audit_id, item_code, operation, old_quantity, new_quantity,
       old_stock_value, new_stock_value
FROM   ict372_inventory.inventory_audit
WHERE  item_code = 'I007'
ORDER  BY audit_id;                                   -- expected INSERT then DELETE

-- ---------------------------------------------------------------------
-- TEST 4: Update I001 quantity 5 -> 4 THROUGH the view v_low_stock_items.
-- I001 is in the view (5 <= 5) and stays in it after the change (4 <= 5),
-- so WITH CHECK OPTION allows it.  The BEFORE trigger still recalculates
-- stock_value = 4 x 12500 = 50000.00 and the AFTER trigger audits it.
-- ---------------------------------------------------------------------
UPDATE ict372_inventory.v_low_stock_items
SET    quantity = 4
WHERE  item_code = 'I001';

-- Base table:
SELECT item_code, quantity, unit_cost, stock_value
FROM   ict372_inventory.inventory_items
WHERE  item_code = 'I001';

-- Reporting views:
SELECT item_code, quantity, stock_value
FROM   ict372_inventory.v_low_stock_items
ORDER  BY item_code;

SELECT item_code, item_name, category_name, quantity, stock_value
FROM   ict372_inventory.v_inventory_details
WHERE  item_code = 'I001';

SELECT * FROM ict372_inventory.v_category_summary ORDER BY category_id;

-- Audit row for this change:
SELECT audit_id, item_code, operation, old_quantity, new_quantity,
       old_stock_value, new_stock_value
FROM   ict372_inventory.inventory_audit
WHERE  item_code = 'I001'
ORDER  BY audit_id;

-- ---------------------------------------------------------------------
-- TEST 5: Attempt to set I004 unit_cost to -50.00.
-- Expected: prepare_inventory_item() raises an exception (SQLSTATE 23514),
--           the UPDATE is rolled back, I004 keeps unit_cost 1500.00 and
--           the audit row count does not change.
-- The error is caught in a nested block so the script keeps running.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_before bigint;
    v_msg    text;
BEGIN
    SELECT count(*) INTO v_before FROM ict372_inventory.inventory_audit;
    BEGIN
        UPDATE ict372_inventory.inventory_items
        SET    unit_cost = -50.00
        WHERE  item_code = 'I004';

        INSERT INTO ict372_inventory.test_log (test_no, outcome, audit_rows_before)
        VALUES (5, 'UNEXPECTED: update succeeded', v_before);
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        INSERT INTO ict372_inventory.test_log
            (test_no, outcome, sqlstate_code, error_message, audit_rows_before, audit_rows_after)
        VALUES
            (5, 'Expected validation error caught', SQLSTATE, v_msg, v_before,
             (SELECT count(*) FROM ict372_inventory.inventory_audit));
    END;
END;
$$;

SELECT * FROM ict372_inventory.test_log WHERE test_no = 5;   -- caught error + before/after audit counts

SELECT item_code, unit_cost, stock_value                      -- expected 1500.00 / 4500.00
FROM   ict372_inventory.inventory_items
WHERE  item_code = 'I004';

SELECT count(*) AS audit_rows_now FROM ict372_inventory.inventory_audit;  -- expected 4

-- ---------------------------------------------------------------------
-- TEST 6: Attempt to set I001 quantity to 20 through v_low_stock_items.
-- 20 > reorder_level 5, so the new row would leave the view.  WITH LOCAL
-- CHECK OPTION rejects it (SQLSTATE 44000) AFTER the BEFORE trigger but
-- BEFORE the AFTER trigger, so no audit row is written.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_before bigint;
    v_msg    text;
BEGIN
    SELECT count(*) INTO v_before FROM ict372_inventory.inventory_audit;
    BEGIN
        UPDATE ict372_inventory.v_low_stock_items
        SET    quantity = 20
        WHERE  item_code = 'I001';

        INSERT INTO ict372_inventory.test_log (test_no, outcome, audit_rows_before)
        VALUES (6, 'UNEXPECTED: update succeeded', v_before);
    EXCEPTION WHEN with_check_option_violation THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        INSERT INTO ict372_inventory.test_log
            (test_no, outcome, sqlstate_code, error_message, audit_rows_before, audit_rows_after)
        VALUES
            (6, 'Expected CHECK OPTION error caught', SQLSTATE, v_msg, v_before,
             (SELECT count(*) FROM ict372_inventory.inventory_audit));
    END;
END;
$$;

SELECT * FROM ict372_inventory.test_log WHERE test_no = 6;

SELECT item_code, quantity, stock_value                       -- expected quantity 4, value 50000.00
FROM   ict372_inventory.inventory_items
WHERE  item_code = 'I001';

SELECT count(*) AS audit_rows_now FROM ict372_inventory.inventory_audit;  -- expected 4 (unchanged)

-- ---------------------------------------------------------------------
-- TEST 7: Explicit transaction + ROLLBACK.
-- Inside the transaction I001 -> 20, so it leaves the low-stock view and a
-- temporary extra audit row exists.  ROLLBACK undoes both the table change
-- and the audit row (the trigger runs in the same transaction).
-- ---------------------------------------------------------------------
BEGIN;

UPDATE ict372_inventory.inventory_items
SET    quantity = 20
WHERE  item_code = 'I001';

-- 7a (inside the transaction): I001 has quantity 20 and is ABSENT from the low-stock view.
SELECT item_code, quantity, stock_value
FROM   ict372_inventory.inventory_items WHERE item_code = 'I001';

SELECT item_code, quantity
FROM   ict372_inventory.v_low_stock_items ORDER BY item_code;   -- I001 missing

-- 7b (inside the transaction): temporary extra audit row (expected count 5).
SELECT count(*) AS audit_rows_inside_transaction FROM ict372_inventory.inventory_audit;

SELECT audit_id, item_code, operation, old_quantity, new_quantity,
       old_stock_value, new_stock_value
FROM   ict372_inventory.inventory_audit
WHERE  item_code = 'I001'
ORDER  BY audit_id;

ROLLBACK;

-- 7c (after the rollback): quantity back to 4, I001 back in the view, audit count back to 4.
SELECT item_code, quantity, stock_value
FROM   ict372_inventory.inventory_items WHERE item_code = 'I001';

SELECT item_code, quantity
FROM   ict372_inventory.v_low_stock_items ORDER BY item_code;   -- I001 present again

SELECT count(*) AS audit_rows_after_rollback FROM ict372_inventory.inventory_audit;  -- expected 4

-- ---------------------------------------------------------------------
-- TEST 8: Metadata inspection (triggers, enabled state, view updatability).
-- ---------------------------------------------------------------------

-- 8a: trigger definitions as rebuilt by PostgreSQL; tgenabled 'O' = enabled.
SELECT t.tgname                       AS trigger_name,
       c.relname                      AS table_name,
       CASE t.tgenabled WHEN 'O' THEN 'enabled' WHEN 'D' THEN 'DISABLED' ELSE t.tgenabled::text END AS status,
       pg_get_triggerdef(t.oid)       AS definition
FROM   pg_trigger t
JOIN   pg_class c     ON c.oid = t.tgrelid
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  n.nspname = 'ict372_inventory'
  AND  NOT t.tgisinternal
ORDER  BY t.tgname;

-- 8b: the same triggers from information_schema (timing, event, per-row).
SELECT trigger_name, event_manipulation, event_object_table,
       action_timing, action_orientation
FROM   information_schema.triggers
WHERE  trigger_schema = 'ict372_inventory'
ORDER  BY trigger_name, event_manipulation;

-- 8c: view updatability. Expected: v_low_stock_items = YES / check_option LOCAL;
--     v_inventory_details and v_category_summary = NO / NONE.
SELECT table_name AS view_name, is_updatable, is_insertable_into, check_option
FROM   information_schema.views
WHERE  table_schema = 'ict372_inventory'
ORDER  BY table_name;

-- ---------- final verification queries ----------
-- F1: all inventory items (6 original items; I007 was deleted; I001 = 4, I003 = 2).
SELECT * FROM ict372_inventory.inventory_items ORDER BY item_code;

-- F2: full audit trail (expected 4 rows: I007 INSERT, I003 UPDATE, I007 DELETE, I001 UPDATE).
SELECT * FROM ict372_inventory.inventory_audit ORDER BY audit_id;

-- F3-F5: the three views.
SELECT * FROM ict372_inventory.v_low_stock_items   ORDER BY item_code;
SELECT * FROM ict372_inventory.v_inventory_details ORDER BY item_code;
SELECT * FROM ict372_inventory.v_category_summary  ORDER BY category_id;

-- F6: handled-error evidence.
SELECT * FROM ict372_inventory.test_log ORDER BY log_id;


/* =====================================================================
   SHORT ANSWERS (SQL COMMENTS)
   =====================================================================
   Q1. Why is stock_value calculated in a BEFORE trigger?
       A BEFORE ROW trigger can modify NEW before the row is stored, so the
       stored value is always quantity x unit_cost, even if a user tries to
       type stock_value directly.

   Q2. Why is the audit done in an AFTER trigger?
       It runs only after the change has succeeded and sees the final row
       (trimmed name, recalculated value), so failed operations (tests 5
       and 6) leave no audit row.

   Q3. Why can audit_inventory_item() return NULL?
       The return value of a row-level AFTER trigger is ignored, so NULL
       does not cancel the operation.

   Q4. Why is there no foreign key from inventory_audit to inventory_items?
       A foreign key would block deleting an item (or force deletion of its
       history).  Storing only item_code keeps the audit trail after DELETE.

   Q5. What does WITH LOCAL CHECK OPTION do on v_low_stock_items?
       It rejects INSERT/UPDATE through the view if the new row would not
       satisfy quantity <= reorder_level (test 6).  Changes made directly
       on the base table (test 7) are not checked by the view.

   Q6. Why count(i.item_id) and COALESCE in v_category_summary?
       With a LEFT JOIN the empty Printing category produces one row with
       NULL item columns; count(*) would wrongly give 1, while
       count(i.item_id) gives 0.  SUM over no rows is NULL, so COALESCE
       converts it to 0.

   Q7. Why did the test 7 audit row disappear after ROLLBACK?
       The trigger's INSERT into inventory_audit is part of the same
       transaction as the UPDATE, so ROLLBACK undoes both.
   ===================================================================== */
-- END OF FILE

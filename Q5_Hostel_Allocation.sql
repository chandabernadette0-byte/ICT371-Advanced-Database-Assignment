-- ICT371 Q5: Hostel Room Allocation   (PostgreSQL 14+, pg_cron)
DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path = q5_hostel, public;

-- (a) Tables ----------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('2024101', 'Chanda Mwila'), ('2024102', 'Mutale Banda'), ('2024103', 'Temwani Phiri'),
    ('2024104', 'Natasha Zulu'), ('2024105', 'Joseph Tembo'), ('2024106', 'Grace Lungu');
INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),    -- will be full
    ('R102', 3),    -- partly occupied
    ('R103', 2);    -- empty (history only)

-- (b) Function ----------------------------------------------------------------
CREATE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER LANGUAGE plpgsql STABLE
SET search_path = q5_hostel, public AS $$
DECLARE v_cap INTEGER; v_active INTEGER;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    SELECT COUNT(*) INTO v_active FROM allocations
     WHERE room_id = p_room_id AND status = 'ACTIVE';     -- ENDED rows do not occupy beds
    RETURN v_cap - v_active;
END $$;

-- (d) Trigger (guards direct SQL as well as the procedure) ----------------------
CREATE FUNCTION trg_fn_allocation_rules() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q5_hostel, public AS $$
DECLARE v_cap INTEGER; v_occupied INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- lock the room row so two sessions cannot both take the last bed
        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;

        IF EXISTS (SELECT 1 FROM allocations
                   WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                     AND allocation_id <> NEW.allocation_id) THEN        -- exclude row being updated
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT COUNT(*) INTO v_occupied FROM allocations
         WHERE room_id = NEW.room_id AND status = 'ACTIVE'
           AND allocation_id <> NEW.allocation_id;                       -- exclude row being updated
        IF v_occupied >= v_cap THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_allocation_rules();

-- (c) Procedure ---------------------------------------------------------------
CREATE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql SET search_path = q5_hostel, public AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (a, continued) Allocations: R101 full, R102 partly occupied, R103 empty ------
CALL pr_allocate_room(1, 1, DATE '2026-09-01');
CALL pr_allocate_room(2, 1, DATE '2026-09-01');
CALL pr_allocate_room(3, 2, DATE '2026-09-02');
CALL pr_allocate_room(4, 2, DATE '2026-09-03');
-- history rows (ENDED) in the empty room R103
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (5, 3, DATE '2026-01-15', DATE '2026-06-30', 'ENDED'),
    (6, 3, DATE '2026-01-15', DATE '2026-06-30', 'ENDED');

-- Rejection tests
DO $$ BEGIN CALL q5_hostel.pr_allocate_room(5, 1, CURRENT_DATE);   -- room full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL q5_hostel.pr_allocate_room(1, 3, CURRENT_DATE);   -- already ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO q5_hostel.allocations (student_id, room_id, allocated_on, status)
            VALUES (5, 1, CURRENT_DATE, 'ACTIVE');                  -- direct SQL, trigger blocks it
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected by trigger: %', SQLERRM; END $$;

SELECT fn_free_beds(1) AS r101, fn_free_beds(2) AS r102, fn_free_beds(3) AS r103;

-- (e) View: every room, including rooms with no allocations ----------------------
CREATE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;

-- (f) Index -------------------------------------------------------------------
-- Partial index holds only ACTIVE rows (the only ones that count toward capacity),
-- so it stays small and serves both the trigger's count and the occupancy view.
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------------
CREATE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql SET search_path = q5_hostel, public AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET occupied_beds = EXCLUDED.occupied_beds,
                  free_beds     = EXCLUDED.free_beds;
END $$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();     -- rerun replaces values, no duplicate rows
SELECT * FROM occupancy_snapshot ORDER BY room_id;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q5_refresh_occupancy', '55 23 * * *',
       $$CALL q5_hostel.pr_refresh_occupancy()$$);

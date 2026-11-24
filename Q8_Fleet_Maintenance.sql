-- ICT371 Q8: Transport Fleet Maintenance   (PostgreSQL 14+, pg_cron)
DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path = q8_fleet, public;

-- (a) Tables ----------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1234', 12000,  8500),     -- 3,500 km since service (will reach 4,500)
    ('BCD 2345', 20000, 14000),     -- 6,000 km: already due
    ('CDE 3456',  5000,  5000);     -- freshly serviced

-- (b) Function ----------------------------------------------------------------
CREATE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE
SET search_path = q8_fleet, public AS $$
DECLARE v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
      FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END $$;

-- (d) Trigger: the ONLY place that updates current_odometer --------------------------
CREATE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q8_fleet, public AS $$
DECLARE v_current INTEGER;
BEGIN
    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end % (end must exceed start)',
                        NEW.start_odometer, NEW.end_odometer;
    END IF;

    SELECT current_odometer INTO v_current
      FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;   -- lock vehicle row
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at current odometer % (got %)', v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- (c) Procedure: validates and inserts only; it does NOT touch the odometer -------
CREATE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql SET search_path = q8_fleet, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (a, continued) Six trips through the procedure, after the trigger exists --------
CALL pr_record_trip(1, DATE '2026-11-10', 12000, 12500);
CALL pr_record_trip(1, DATE '2026-11-12', 12500, 13000);
CALL pr_record_trip(2, DATE '2026-11-11', 20000, 20300);
CALL pr_record_trip(2, DATE '2026-11-13', 20300, 20800);
CALL pr_record_trip(3, DATE '2026-11-14',  5000,  5400);
CALL pr_record_trip(3, DATE '2026-11-15',  5400,  6200);

-- Rejection tests
DO $$ BEGIN CALL q8_fleet.pr_record_trip(1, CURRENT_DATE, 12999, 13100);    -- wrong start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL q8_fleet.pr_record_trip(1, CURRENT_DATE, 13000, 13000);    -- end not > start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL q8_fleet.pr_record_trip(99, CURRENT_DATE, 0, 10);          -- unknown vehicle
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

SELECT vehicle_id, registration, current_odometer, last_service_odometer,
       current_odometer - last_service_odometer AS km_since_service,
       fn_service_due(vehicle_id) AS service_due
FROM vehicles ORDER BY vehicle_id;

-- (e) View --------------------------------------------------------------------
CREATE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) Index -------------------------------------------------------------------
-- vehicle_id (equality) then trip_on (range): one contiguous index range per vehicle.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------------
-- Insert/update an alert for each due vehicle (original flagged_on is kept when the
-- alert already exists); delete alerts for vehicles that are no longer due.
CREATE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql SET search_path = q8_fleet, public AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id)
    DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts a
    WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                      WHERE v.vehicle_id = a.vehicle_id
                        AND v.current_odometer - v.last_service_odometer >= 5000);
END $$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                   -- vehicle 2 only
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;  -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                   -- alert removed

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q8_refresh_service_alerts', '0 6 * * 1',   -- every Monday 06:00
       $$CALL q8_fleet.pr_refresh_service_alerts()$$);

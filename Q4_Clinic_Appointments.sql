-- ICT371 Q4: Clinic Appointment Scheduling   (PostgreSQL 14+, pg_cron)
DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path = q4_clinic, public;

-- (a) Tables ----------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL
        CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);
CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Chanda Mwila'), ('Mutale Banda'), ('Temwani Phiri');
INSERT INTO doctors  (full_name) VALUES ('Dr. Zulu'), ('Dr. Tembo'), ('Dr. Lungu');

-- (d) Trigger (installed before the seed data so it guards every insert) --------
CREATE FUNCTION trg_fn_no_slot_clash() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q4_clinic, public AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (SELECT 1
                   FROM appointments a
                   WHERE a.doctor_id       = NEW.doctor_id
                     AND a.appointment_day = NEW.appointment_day
                     AND a.slot_time       = NEW.slot_time
                     AND a.status         <> 'CANCELLED'
                     AND a.appointment_id <> NEW.appointment_id) THEN   -- exclude the row being changed
            RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_fn_no_slot_clash();

-- Extra safety net against two concurrent sessions racing past the trigger
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time) WHERE status <> 'CANCELLED';

-- (a, continued) Six appointments (note #6 is CANCELLED in the same slot as #1: allowed)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE + 1, '11:00', 'BOOKED'),
    (2, 3, CURRENT_DATE - 1, '12:00', 'ATTENDED'),
    (3, 1, CURRENT_DATE,     '09:00', 'CANCELLED');

-- (b) Function ----------------------------------------------------------------
CREATE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER LANGUAGE plpgsql STABLE
SET search_path = q4_clinic, public AS $$
DECLARE v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    SELECT COUNT(*) INTO v_count
      FROM appointments
     WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
    RETURN v_count;                      -- COUNT(*) is 0 when there are no bookings
END $$;

-- (c) Procedure ---------------------------------------------------------------
CREATE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER,
                                     p_day DATE, p_slot TIME)
LANGUAGE plpgsql SET search_path = q4_clinic, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is missing or in the past', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;
    -- the BEFORE trigger rejects a clash with another non-cancelled appointment
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END $$;

CALL pr_book_appointment(2, 3, CURRENT_DATE + 2, '09:00');       -- valid
DO $$ BEGIN CALL q4_clinic.pr_book_appointment(2, 1, CURRENT_DATE, '09:00');  -- clash with #1
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL q4_clinic.pr_book_appointment(2, 1, CURRENT_DATE - 1, '09:00');  -- past
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL q4_clinic.pr_book_appointment(2, 1, CURRENT_DATE + 1, '13:00');  -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

SELECT fn_daily_load(1, CURRENT_DATE) AS dr1_today, fn_daily_load(3, CURRENT_DATE + 30) AS no_bookings;

-- (e) View: only what reception needs, no other patient data -------------------
CREATE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED'
ORDER BY a.slot_time;

SELECT * FROM v_today_appointments;

-- (f) Index -------------------------------------------------------------------
-- Non-unique; the day is the more selective equality filter for a daily schedule, then doctor.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------------
CREATE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql SET search_path = q4_clinic, public AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date)
    DO UPDATE SET booked_count    = EXCLUDED.booked_count,
                  attended_count  = EXCLUDED.attended_count,
                  cancelled_count = EXCLUDED.cancelled_count;
END $$;

CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);   -- rerun replaces
SELECT * FROM clinic_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q4_refresh_clinic_summary', '0 1 * * *',
       $$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

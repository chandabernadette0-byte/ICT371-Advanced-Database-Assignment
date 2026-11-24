-- ICT371 Q6: Monthly Payroll Processing   (PostgreSQL 14+, pg_cron)
DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path = q6_payroll, public;

-- (a) Tables ----------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),  -- first of month
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chanda Mwila',  8000, 1500, 1200, TRUE),
    ('Mutale Banda',  6500, 1000,  900, TRUE),
    ('Temwani Phiri', 5000,  800,  700, TRUE),
    ('Natasha Zulu',  7000, 1200, 1000, TRUE),
    ('Joseph Tembo',  4500,  500,  600, FALSE);   -- inactive from the start

-- (b) Function ----------------------------------------------------------------
CREATE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql STABLE
SET search_path = q6_payroll, public AS $$
DECLARE v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
      FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END $$;

-- (d) Trigger -----------------------------------------------------------------
CREATE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q6_payroll, public AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (c) Procedure (query FOR loop) -------------------------------------------------
-- If any calculation raises, the whole CALL is rolled back (nothing partial is kept).
-- ON CONFLICT DO NOTHING leaves an existing employee/month row unchanged.
CREATE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql SET search_path = q6_payroll, public AS $$
DECLARE
    rec     RECORD;
    v_net   NUMERIC;
    v_gross NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Payroll month must be the first day of a month (got %)', p_month;
    END IF;

    FOR rec IN SELECT employee_id, basic_salary, allowance
               FROM employees WHERE active ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(rec.employee_id);          -- raises for invalid/negative net
        v_gross := rec.basic_salary + rec.allowance;
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END $$;

-- (a, continued) Two (three) payroll months ----------------------------------------
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 4;   -- becomes inactive later
CALL pr_process_payroll(DATE '2026-11-01');
CALL pr_process_payroll(DATE '2026-11-01');                   -- rerun: nothing changes

-- Tests
DO $$ BEGIN CALL q6_payroll.pr_process_payroll(DATE '2026-11-15');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- audited
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- unchanged: no audit row
SELECT * FROM salary_audit;
SELECT pay_month, COUNT(*) FROM payroll GROUP BY pay_month ORDER BY pay_month;

-- (e) View: history is kept for employees who later become inactive -------------
CREATE VIEW v_payroll_report AS
SELECT e.employee_id, e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;     -- no filter on e.active

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

-- (f) Index -------------------------------------------------------------------
-- The unique index starts with employee_id, so it cannot efficiently answer
-- "all employees for one month". An index led by pay_month can, and it is not a
-- duplicate of (employee_id, pay_month) because the column order is different.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on the 1st, processing the previous month ------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q6_monthly_payroll', '0 2 1 * *',
       $$CALL q6_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6_monthly_payroll';
SELECT d.jobid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'q6_monthly_payroll'
ORDER BY d.start_time DESC;

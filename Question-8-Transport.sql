
-- =========================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 8: TRANSPORT FLEET MAINTENANCE
-- Database: ICT371_Q8
-- =========================================================

-- 1. CLEAN UP OLD TABLES

DROP VIEW IF EXISTS v_service_due CASCADE;
DROP TABLE IF EXISTS service_alerts CASCADE;
DROP TABLE IF EXISTS trips CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;

-- =========================================================
-- 2. CREATE TABLES
-- =========================================================

CREATE TABLE vehicles (
    vehicle_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration VARCHAR(30) NOT NULL UNIQUE,
    current_odometer NUMERIC(12,2) NOT NULL
        CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12,2) NOT NULL
        CHECK (last_service_odometer >= 0),

    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer NUMERIC(12,2) NOT NULL
        CHECK (start_odometer >= 0),
    end_odometer NUMERIC(12,2) NOT NULL
        CHECK (end_odometer >= 0),

    CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12,2) NOT NULL
        CHECK (km_since_service >= 0),
    flagged_on DATE NOT NULL
);

-- =========================================================
-- 3. INSERT THREE VEHICLES
-- Different service positions.
-- =========================================================

INSERT INTO vehicles (
    registration,
    current_odometer,
    last_service_odometer
)
VALUES
('BAX 1234', 10000, 6000),
('BAZ 5678', 20000, 14000),
('BBC 9012', 30000, 28000);

-- =========================================================
-- 4. FUNCTION: fn_service_due
-- Returns TRUE when distance since service >= 5000 km.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_service_due(
    p_vehicle_id INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC(12,2);
    v_last_service NUMERIC(12,2);
BEGIN
    SELECT
        current_odometer,
        last_service_odometer
    INTO
        v_current,
        v_last_service
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Vehicle ID % does not exist.',
            p_vehicle_id;
    END IF;

    RETURN (v_current - v_last_service) >= 5000;
END;
$$;

-- Test the function.
SELECT
    vehicle_id,
    registration,
    fn_service_due(vehicle_id) AS service_due
FROM vehicles
ORDER BY vehicle_id;

-- =========================================================
-- 5. TRIGGER FUNCTION
-- Checks trip starting odometer and updates vehicle odometer.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_validate_trip()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_odometer NUMERIC(12,2);
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION
            'Trip ending odometer must be greater than starting odometer.';
    END IF;

    SELECT current_odometer
    INTO v_current_odometer
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Vehicle ID % does not exist.',
            NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current_odometer THEN
        RAISE EXCEPTION
            'Invalid starting odometer. Vehicle current reading is %, but trip starts at %.',
            v_current_odometer,
            NEW.start_odometer;
    END IF;

    -- Update the vehicle's odometer exactly once.
    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_trip
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_validate_trip();

-- =========================================================
-- 6. PROCEDURE: pr_record_trip
-- Records a trip. The trigger updates the vehicle odometer.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on DATE,
    p_start NUMERIC,
    p_end NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM vehicles
        WHERE vehicle_id = p_vehicle_id
    ) THEN
        RAISE EXCEPTION
            'Vehicle ID % does not exist.',
            p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date cannot be NULL.';
    END IF;

    IF p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Odometer readings cannot be NULL.';
    END IF;

    IF p_start < 0 OR p_end < 0 THEN
        RAISE EXCEPTION 'Odometer readings cannot be negative.';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION
            'Ending odometer must be greater than starting odometer.';
    END IF;

    INSERT INTO trips (
        vehicle_id,
        trip_on,
        start_odometer,
        end_odometer
    )
    VALUES (
        p_vehicle_id,
        p_trip_on,
        p_start,
        p_end
    );

    RAISE NOTICE
        'Trip successfully recorded for vehicle ID %.',
        p_vehicle_id;
END;
$$;

-- =========================================================
-- 7. INSERT SIX TRIPS THROUGH THE PROCEDURE
-- The trigger automatically updates current_odometer.
-- =========================================================

-- Vehicle 1: 500 km travelled, 4500 km since service.

CALL pr_record_trip(1, CURRENT_DATE - 5, 10000, 10200);
CALL pr_record_trip(1, CURRENT_DATE - 2, 10200, 10500);

-- Vehicle 2: 700 km travelled, 6700 km since service.

CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20300, 20700);

-- Vehicle 3: 300 km travelled, 2300 km since service.

CALL pr_record_trip(3, CURRENT_DATE - 5, 30000, 30100);
CALL pr_record_trip(3, CURRENT_DATE - 2, 30100, 30300);

-- Inspect trips.
SELECT *
FROM trips
ORDER BY vehicle_id, trip_id;

-- Inspect updated vehicle odometers.
SELECT *
FROM vehicles
ORDER BY vehicle_id;

-- =========================================================
-- 8. VIEW: v_service_due
-- Shows vehicles that have reached the service threshold.
-- =========================================================

CREATE OR REPLACE VIEW v_service_due AS
SELECT
    vehicle_id,
    registration,
    current_odometer,
    last_service_odometer,
    current_odometer - last_service_odometer
        AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- Query service-due vehicles.
SELECT *
FROM v_service_due
ORDER BY vehicle_id;

-- =========================================================
-- 9. INDEX FOR VEHICLE TRIP DATE SEARCHES
-- =========================================================

CREATE INDEX idx_trips_vehicle_date
ON trips(vehicle_id, trip_on);

-- Matching query.
SELECT *
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
ORDER BY trip_on;

-- Execution plan.
EXPLAIN ANALYZE
SELECT *
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
ORDER BY trip_on;

-- =========================================================
-- 10. PROCEDURE: pr_refresh_service_alerts
-- Adds or updates alerts for due vehicles.
-- Removes alerts for vehicles that are no longer due.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Insert or update alerts for vehicles that are due.
    INSERT INTO service_alerts (
        vehicle_id,
        km_since_service,
        flagged_on
    )
    SELECT
        vehicle_id,
        current_odometer - last_service_odometer,
        CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000

    ON CONFLICT (vehicle_id)
    DO UPDATE SET
        km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;

    -- Remove alerts for vehicles that are no longer due.
    DELETE FROM service_alerts
    WHERE vehicle_id IN (
        SELECT vehicle_id
        FROM vehicles
        WHERE current_odometer - last_service_odometer < 5000
    );

    RAISE NOTICE
        'Service alerts refreshed for %.',
        CURRENT_DATE;
END;
$$;

-- =========================================================
-- 11. RUN AND VERIFY SERVICE ALERTS
-- =========================================================

CALL pr_refresh_service_alerts();

SELECT *
FROM service_alerts
ORDER BY vehicle_id;

-- =========================================================
-- 12. TEST SERVICE COMPLETION
-- Updating the last service odometer to the current value
-- means the vehicle is no longer due.
-- =========================================================

-- Mark vehicle 2 as serviced.
UPDATE vehicles
SET last_service_odometer = current_odometer
WHERE vehicle_id = 2;

-- Refresh alerts after service.
CALL pr_refresh_service_alerts();

-- Vehicle 2 should no longer have an alert.
SELECT *
FROM service_alerts
ORDER BY vehicle_id;

-- =========================================================
-- 13. SCHEDULED JOB
-- Requires pg_cron to be installed and configured.
-- Runs every Monday at 06:00.
-- =========================================================

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- SELECT cron.schedule(
--     'weekly-service-alerts',
--     '0 6 * * 1',
--     'CALL pr_refresh_service_alerts();'
-- );

-- Inspect scheduled jobs:
-- SELECT * FROM cron.job;

-- Inspect execution history:
-- SELECT *
-- FROM cron.job_run_details
-- ORDER BY start_time DESC;

-- =========================================================
-- END OF QUESTION 8
-- =========================================================

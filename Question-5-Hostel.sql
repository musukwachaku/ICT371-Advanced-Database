
-- =========================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 5: HOSTEL ROOM ALLOCATION
-- Database: ICT371_Q5
-- =========================================================

-- 2. CREATE TABLES
-- =========================================================

CREATE TABLE students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL
        CHECK (status IN ('ACTIVE', 'ENDED')),

    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    ),

    CHECK (
        released_on IS NULL OR released_on >= allocated_on
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds INTEGER NOT NULL CHECK (free_beds >= 0),

    PRIMARY KEY (snapshot_date, room_id)
);

-- =========================================================
-- 3. INSERT STUDENTS AND ROOMS
-- =========================================================

INSERT INTO students (student_number, full_name)
VALUES
('MU2026001', 'John Banda'),
('MU2026002', 'Mary Phiri'),
('MU2026003', 'Peter Zulu'),
('MU2026004', 'Grace Mwila'),
('MU2026005', 'James Chanda');

INSERT INTO rooms (room_number, capacity)
VALUES
('R101', 2),
('R102', 3),
('R103', 2);

-- =========================================================
-- 4. FUNCTION: fn_free_beds
-- Returns the number of available beds in a room.
-- ENDED allocations are not counted.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    SELECT capacity
    INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist.', p_room_id;
    END IF;

    SELECT COUNT(*)
    INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;

-- =========================================================
-- 5. TRIGGER FUNCTION
-- Enforces room capacity and one ACTIVE allocation per student.
-- Also protects direct INSERT and UPDATE statements.
-- =========================================================

CREATE OR REPLACE FUNCTION fn_check_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
    v_student_allocations INTEGER;
BEGIN
    -- ENDED allocations do not occupy beds.
    IF NEW.status = 'ENDED' THEN
        RETURN NEW;
    END IF;

    SELECT capacity
    INTO v_capacity
    FROM rooms
    WHERE room_id = NEW.room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist.', NEW.room_id;
    END IF;

    -- Count other ACTIVE allocations in this room.
    -- Exclude the current row when updating.
    SELECT COUNT(*)
    INTO v_occupied
    FROM allocations a
    WHERE a.room_id = NEW.room_id
      AND a.status = 'ACTIVE'
      AND a.allocation_id <> COALESCE(NEW.allocation_id, -1);

    IF v_occupied >= v_capacity THEN
        RAISE EXCEPTION
            'Room % is full. Capacity: %.',
            NEW.room_id, v_capacity;
    END IF;

    -- Check whether this student already has an ACTIVE allocation.
    SELECT COUNT(*)
    INTO v_student_allocations
    FROM allocations a
    WHERE a.student_id = NEW.student_id
      AND a.status = 'ACTIVE'
      AND a.allocation_id <> COALESCE(NEW.allocation_id, -1);

    IF v_student_allocations > 0 THEN
        RAISE EXCEPTION
            'Student % already has an ACTIVE allocation.',
            NEW.student_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_allocation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_check_allocation();

-- =========================================================
-- 6. PROCEDURE: pr_allocate_room
-- Allocates a student to a room.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INTEGER,
    p_room_id INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM students
        WHERE student_id = p_student_id
    ) THEN
        RAISE EXCEPTION
            'Student ID % does not exist.', p_student_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM rooms
        WHERE room_id = p_room_id
    ) THEN
        RAISE EXCEPTION
            'Room ID % does not exist.', p_room_id;
    END IF;

    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM allocations
        WHERE student_id = p_student_id
          AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
            'Student % already has an ACTIVE allocation.',
            p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION
            'Room % has no free beds.', p_room_id;
    END IF;

    INSERT INTO allocations (
        student_id,
        room_id,
        allocated_on,
        released_on,
        status
    )
    VALUES (
        p_student_id,
        p_room_id,
        p_allocated_on,
        NULL,
        'ACTIVE'
    );

    RAISE NOTICE
        'Student % successfully allocated to room %.',
        p_student_id, p_room_id;
END;
$$;

-- =========================================================
-- 7. SEED ALLOCATIONS
-- IMPORTANT: Do not manually insert allocation_id.
-- PostgreSQL generates it automatically.
-- =========================================================

-- R101 will be FULL (2 out of 2 beds).

INSERT INTO allocations (
    student_id, room_id, allocated_on, released_on, status
)
VALUES
(1, 1, CURRENT_DATE - 20, NULL, 'ACTIVE'),
(2, 1, CURRENT_DATE - 15, NULL, 'ACTIVE');

-- R102 will initially be PARTLY OCCUPIED.

INSERT INTO allocations (
    student_id, room_id, allocated_on, released_on, status
)
VALUES
(3, 2, CURRENT_DATE - 10, NULL, 'ACTIVE');

-- R103 will have an ENDED allocation.
-- This does not occupy a bed, so R103 remains EMPTY.

INSERT INTO allocations (
    student_id, room_id, allocated_on, released_on, status
)
VALUES
(4, 3, CURRENT_DATE - 30, CURRENT_DATE - 5, 'ENDED');

-- Allocate student 4 to R102.
-- This also demonstrates that an ENDED allocation does not
-- prevent the student from receiving a new ACTIVE allocation.

CALL pr_allocate_room(4, 2, CURRENT_DATE);

-- =========================================================
-- 8. VIEW: v_room_occupancy
-- Shows every room, including empty rooms.
-- =========================================================

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) FILTER (
        WHERE a.status = 'ACTIVE'
    ) AS occupied_beds,

    r.capacity - COUNT(a.allocation_id) FILTER (
        WHERE a.status = 'ACTIVE'
    ) AS free_beds

FROM rooms r
LEFT JOIN allocations a
    ON r.room_id = a.room_id
GROUP BY
    r.room_id,
    r.room_number,
    r.capacity;

-- View results.
SELECT * FROM v_room_occupancy
ORDER BY room_id;

-- =========================================================
-- 9. INDEX FOR ACTIVE ALLOCATIONS
-- =========================================================

CREATE INDEX idx_active_allocations_room
ON allocations(room_id)
WHERE status = 'ACTIVE';

-- Matching query.
SELECT *
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';

-- Execution plan.
EXPLAIN ANALYZE
SELECT *
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';

-- =========================================================
-- 10. PROCEDURE: pr_refresh_occupancy
-- Stores occupancy for every room for the current date.
-- Rerunning replaces the existing snapshot.
-- =========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (
        snapshot_date,
        room_id,
        occupied_beds,
        free_beds
    )
    SELECT
        CURRENT_DATE,
        room_id,
        occupied_beds,
        free_beds
    FROM v_room_occupancy

    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;

    RAISE NOTICE
        'Occupancy snapshot refreshed for %.', CURRENT_DATE;
END;
$$;

-- Run the snapshot procedure.
CALL pr_refresh_occupancy();

-- Check saved snapshots.
SELECT *
FROM occupancy_snapshot
ORDER BY snapshot_date, room_id;

-- =========================================================
-- 11. SCHEDULED JOB
-- Requires pg_cron to be installed and configured.
-- Run this separately only if pg_cron is available.
-- =========================================================

-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- SELECT cron.schedule(
--     'daily-hostel-occupancy',
--     '55 23 * * *',
--     'CALL pr_refresh_occupancy();'
-- );

-- Inspect scheduled jobs:
-- SELECT * FROM cron.job;

-- Inspect job execution history:
-- SELECT *
-- FROM cron.job_run_details
-- ORDER BY start_time DESC;

-- =========================================================
-- END OF QUESTION 5
-- =========================================================

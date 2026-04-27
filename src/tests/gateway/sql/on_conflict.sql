-- ON CONFLICT DO NOTHING and DO UPDATE

CREATE TABLE t_conflict (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);

-- DO NOTHING non-conflict succeeds
INSERT INTO t_conflict (id, val) VALUES (1, 10) ON CONFLICT DO NOTHING;
-- @rows 1
SELECT id, val FROM t_conflict ORDER BY id;
-- @result
-- @  1 | 10

-- DO NOTHING conflict: original unchanged, rows_affected = 0
INSERT INTO t_conflict (id, val) VALUES (1, 99) ON CONFLICT DO NOTHING;
-- @rows 0
SELECT id, val FROM t_conflict ORDER BY id;
-- @result
-- @  1 | 10

-- Only conflicting row skipped, others inserted
INSERT INTO t_conflict (id, val) VALUES (2, 20);
-- @rows 1
-- Two inserts via transaction: id=1 conflicts (skipped), id=3 is new (inserted)
TRANSACTION (a_id INT64, a_val INT64, b_id INT64, b_val INT64) {
    INSERT INTO t_conflict (id, val) VALUES ($a_id, $a_val) ON CONFLICT DO NOTHING;
    INSERT INTO t_conflict (id, val) VALUES ($b_id, $b_val) ON CONFLICT DO NOTHING;
};
-- @call (1, 999, 3, 30)
-- @rows 1
SELECT id, val FROM t_conflict ORDER BY id;
-- @result
-- @  1 | 10
-- @  2 | 20
-- @  3 | 30

-- DO UPDATE: non-conflicting insert succeeds normally
CREATE TABLE t_conflict_upd (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_conflict_upd (id, val) VALUES (1, 10) ON CONFLICT DO UPDATE SET val = 10;
-- @rows 1
SELECT id, val FROM t_conflict_upd ORDER BY id;
-- @result
-- @  1 | 10

-- DO UPDATE: conflicting insert updates the row
INSERT INTO t_conflict_upd (id, val) VALUES (1, 42) ON CONFLICT DO UPDATE SET val = 42;
-- @rows 1
SELECT id, val FROM t_conflict_upd ORDER BY id;
-- @result
-- @  1 | 42

-- DO UPDATE: SET can reference old column value (increment pattern)
-- First insert: val=5; second: val = val + 3 = 8; third: val = val + 2 = 10
CREATE TABLE t_conflict_inc (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_conflict_inc (id, val) VALUES (1, 5) ON CONFLICT DO UPDATE SET val = val + 5;
-- @rows 1
INSERT INTO t_conflict_inc (id, val) VALUES (1, 3) ON CONFLICT DO UPDATE SET val = val + 3;
-- @rows 1
INSERT INTO t_conflict_inc (id, val) VALUES (1, 2) ON CONFLICT DO UPDATE SET val = val + 2;
-- @rows 1
SELECT id, val FROM t_conflict_inc ORDER BY id;
-- @result
-- @  1 | 10

-- DO UPDATE: row count stays same after multiple upserts
INSERT INTO t_conflict_upd (id, val) VALUES (2, 2) ON CONFLICT DO UPDATE SET val = 2;
-- @rows 1
INSERT INTO t_conflict_upd (id, val) VALUES (1, 9) ON CONFLICT DO UPDATE SET val = 9;
-- @rows 1
SELECT COUNT(*) FROM t_conflict_upd;
-- @result
-- @  2

-- DO UPDATE + RETURNING returns updated row
-- Seed: insert id=10 val=10 without RETURNING
INSERT INTO t_conflict_upd (id, val) VALUES (10, 10);
-- @rows 1
-- Conflict on id=10: update val = 10+5=15 and return
INSERT INTO t_conflict_upd (id, val) VALUES (10, 5) ON CONFLICT DO UPDATE SET val = val + 5 RETURNING id, val;
-- @result
-- @  10 | 15

-- DO NOTHING + RETURNING produces no rows on conflict
INSERT INTO t_conflict_upd (id, val) VALUES (10, 99) ON CONFLICT DO NOTHING RETURNING id, val;
-- @result

-- DO UPDATE multi-column update
CREATE TABLE t_conflict_kv (id INT64 NOT NULL PRIMARY KEY, v1 INT64 NOT NULL, v2 INT64 NOT NULL);
INSERT INTO t_conflict_kv (id, v1, v2) VALUES (1, 10, 20);
-- @rows 1
INSERT INTO t_conflict_kv (id, v1, v2) VALUES (1, 5, 7) ON CONFLICT DO UPDATE SET v1 = 5, v2 = v2 + 7;
-- @rows 1
SELECT id, v1, v2 FROM t_conflict_kv ORDER BY id;
-- @result
-- @  1 | 5 | 27

DROP TABLE t_conflict;
DROP TABLE t_conflict_upd;
DROP TABLE t_conflict_inc;
DROP TABLE t_conflict_kv;

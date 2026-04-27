-- DML: INSERT, UPDATE, DELETE basics and edge cases

-- Basic INSERT
CREATE TABLE t_dml_basic (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_dml_basic (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_dml_basic (id, val) VALUES (2, 20);
-- @rows 1
INSERT INTO t_dml_basic (id, val) VALUES (3, 30);
-- @rows 1
SELECT id, val FROM t_dml_basic ORDER BY id;
-- @result
-- @  1 | 10
-- @  2 | 20
-- @  3 | 30

-- Basic UPDATE
UPDATE t_dml_basic SET val = 99 WHERE id = 2;
-- @rows 1
SELECT id, val FROM t_dml_basic ORDER BY id;
-- @result
-- @  1 | 10
-- @  2 | 99
-- @  3 | 30

-- Basic DELETE
DELETE FROM t_dml_basic WHERE id = 3;
-- @rows 1
SELECT id, val FROM t_dml_basic ORDER BY id;
-- @result
-- @  1 | 10
-- @  2 | 99

-- UPDATE with WHERE (matching multiple rows)
CREATE TABLE t_dml_multi (id INT64 NOT NULL PRIMARY KEY, grp INT64 NOT NULL, val INT64 NOT NULL);
INSERT INTO t_dml_multi (id, grp, val) VALUES (1, 1, 10);
-- @rows 1
INSERT INTO t_dml_multi (id, grp, val) VALUES (2, 1, 20);
-- @rows 1
INSERT INTO t_dml_multi (id, grp, val) VALUES (3, 2, 30);
-- @rows 1
UPDATE t_dml_multi SET val = 0 WHERE grp = 1;
-- @rows 2
SELECT id, val FROM t_dml_multi ORDER BY id;
-- @result
-- @  1 | 0
-- @  2 | 0
-- @  3 | 30

-- DELETE with WHERE (matching multiple rows)
DELETE FROM t_dml_multi WHERE grp = 1;
-- @rows 2
SELECT id, val FROM t_dml_multi ORDER BY id;
-- @result
-- @  3 | 30

-- UPDATE no match returns 0 rows affected
UPDATE t_dml_basic SET val = 777 WHERE id = 999;
-- @rows 0

-- DELETE no match returns 0 rows affected
DELETE FROM t_dml_basic WHERE id = 999;
-- @rows 0

-- Duplicate PK rejected
CREATE TABLE t_dml_pk (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_dml_pk (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_dml_pk (id, val) VALUES (1, 20);
-- @error constraint

-- Original row unchanged after duplicate PK rejection
SELECT id, val FROM t_dml_pk ORDER BY id;
-- @result
-- @  1 | 10

-- INSERT after DELETE succeeds (key freed)
DELETE FROM t_dml_pk WHERE id = 1;
-- @rows 1
INSERT INTO t_dml_pk (id, val) VALUES (1, 42);
-- @rows 1
SELECT id, val FROM t_dml_pk ORDER BY id;
-- @result
-- @  1 | 42

DROP TABLE t_dml_basic;
DROP TABLE t_dml_multi;
DROP TABLE t_dml_pk;

-- NULL behaviour: storage, retrieval, predicates, constraints, aggregates, joins

-- Basic null storage and retrieval
CREATE TABLE t_null_basic (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL);
INSERT INTO t_null_basic (id, val) VALUES (1, 42);
-- @rows 1
INSERT INTO t_null_basic (id, val) VALUES (2, NULL);
-- @rows 1
SELECT id, val FROM t_null_basic ORDER BY id;
-- @result
-- @  1 | 42
-- @  2 | NULL
DROP TABLE t_null_basic;

-- IS NULL / IS NOT NULL filters on stored null_t
CREATE TABLE t_null_pred (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL);
INSERT INTO t_null_pred (id, val) VALUES (1, 42);
-- @rows 1
INSERT INTO t_null_pred (id, val) VALUES (2, NULL);
-- @rows 1
SELECT id FROM t_null_pred WHERE val IS NULL ORDER BY id;
-- @result
-- @  2
SELECT id FROM t_null_pred WHERE val IS NOT NULL ORDER BY id;
-- @result
-- @  1
DROP TABLE t_null_pred;

-- NOT NULL column rejects NULL literal
CREATE TABLE t_null_reject (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_null_reject (id, val) VALUES (1, NULL);
-- @error not-null
DROP TABLE t_null_reject;

-- NULL with DEFAULT: omitted column gets default; explicit NULL stores null_t
CREATE TABLE t_null_default (id INT64 NOT NULL PRIMARY KEY, val INT64 DEFAULT 99 NULL);
INSERT INTO t_null_default (id) VALUES (1);
-- @rows 1
INSERT INTO t_null_default (id, val) VALUES (2, NULL);
-- @rows 1
SELECT id, val FROM t_null_default ORDER BY id;
-- @result
-- @  1 | 99
-- @  2 | NULL
DROP TABLE t_null_default;

-- NULL in UPDATE SET: store null_t via UPDATE
CREATE TABLE t_null_update (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL);
INSERT INTO t_null_update (id, val) VALUES (1, 100);
-- @rows 1
UPDATE t_null_update SET val = NULL WHERE id = 1;
-- @rows 1
SELECT id, val FROM t_null_update ORDER BY id;
-- @result
-- @  1 | NULL
DROP TABLE t_null_update;

-- NULL propagates through arithmetic: NULL + integer = NULL
CREATE TABLE t_null_arith (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL);
INSERT INTO t_null_arith (id, val) VALUES (1, NULL);
-- @rows 1
SELECT id, val + 1 FROM t_null_arith ORDER BY id;
-- @result
-- @  1 | NULL
DROP TABLE t_null_arith;

-- COUNT(*) counts all rows including those with NULL; COUNT(col) and SUM skip NULLs
CREATE TABLE t_null_agg (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL);
INSERT INTO t_null_agg (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_null_agg (id, val) VALUES (2, NULL);
-- @rows 1
INSERT INTO t_null_agg (id, val) VALUES (3, 20);
-- @rows 1
SELECT COUNT(*) FROM t_null_agg;
-- @result
-- @  3
SELECT COUNT(val) FROM t_null_agg;
-- @result
-- @  2
SELECT SUM(val) FROM t_null_agg;
-- @result
-- @  30
DROP TABLE t_null_agg;

-- INNER JOIN: NULL FK does not match any parent row
CREATE TABLE t_null_parent (id INT64 NOT NULL PRIMARY KEY);
CREATE TABLE t_null_child (id INT64 NOT NULL PRIMARY KEY, parent_id INT64 NULL);
INSERT INTO t_null_parent (id) VALUES (1);
-- @rows 1
INSERT INTO t_null_child (id, parent_id) VALUES (1, 1);
-- @rows 1
INSERT INTO t_null_child (id, parent_id) VALUES (2, NULL);
-- @rows 1
SELECT c.id FROM t_null_child c INNER JOIN t_null_parent p ON c.parent_id = p.id ORDER BY c.id;
-- @result
-- @  1
DROP TABLE t_null_child;
DROP TABLE t_null_parent;

-- UNIQUE constraint: multiple NULLs are allowed (NULLs are not considered duplicates)
CREATE TABLE t_null_unique (id INT64 NOT NULL PRIMARY KEY, code STRING UNIQUE NULL);
INSERT INTO t_null_unique (id, code) VALUES (1, NULL);
-- @rows 1
INSERT INTO t_null_unique (id, code) VALUES (2, NULL);
-- @rows 1
INSERT INTO t_null_unique (id, code) VALUES (3, 'abc');
-- @rows 1
INSERT INTO t_null_unique (id, code) VALUES (4, 'abc');
-- @error constraint
SELECT id FROM t_null_unique ORDER BY id;
-- @result
-- @  1
-- @  2
-- @  3
DROP TABLE t_null_unique;

-- CHECK constraint with NOT NULL column: negative value violates CHECK
CREATE TABLE t_null_check (id INT64 NOT NULL PRIMARY KEY, age INT64 NOT NULL CHECK (age >= 0));
INSERT INTO t_null_check (id, age) VALUES (1, 0);
-- @rows 1
INSERT INTO t_null_check (id, age) VALUES (2, 25);
-- @rows 1
INSERT INTO t_null_check (id, age) VALUES (3, -1);
-- @error constraint
SELECT id FROM t_null_check ORDER BY id;
-- @result
-- @  1
-- @  2
DROP TABLE t_null_check;

-- CASE WHEN IS NULL works as COALESCE-equivalent
CREATE TABLE t_null_coalesce (id INT64 NOT NULL PRIMARY KEY, val INT64 NULL);
INSERT INTO t_null_coalesce (id, val) VALUES (1, NULL);
-- @rows 1
INSERT INTO t_null_coalesce (id, val) VALUES (2, 42);
-- @rows 1
SELECT id, CASE WHEN val IS NULL THEN 0 ELSE val END FROM t_null_coalesce ORDER BY id;
-- @result
-- @  1 | 0
-- @  2 | 42
DROP TABLE t_null_coalesce;

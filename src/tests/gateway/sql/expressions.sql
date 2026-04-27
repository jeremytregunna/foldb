-- Expressions: CASE WHEN, arithmetic, IS NULL, IS NOT NULL, string concat, BETWEEN, IN, comparisons

CREATE TABLE t_expr (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_expr (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_expr (id, val) VALUES (2, 20);
-- @rows 1
INSERT INTO t_expr (id, val) VALUES (3, 30);
-- @rows 1
INSERT INTO t_expr (id, val) VALUES (4, 40);
-- @rows 1
INSERT INTO t_expr (id, val) VALUES (5, 50);
-- @rows 1

-- CASE WHEN basic (two branches)
SELECT id, CASE WHEN val = 10 THEN 1 ELSE 0 END FROM t_expr WHERE id = 1;
-- @result
-- @  1 | 1

-- CASE WHEN multi-branch
SELECT id, CASE WHEN val < 20 THEN 1 WHEN val < 40 THEN 2 ELSE 3 END FROM t_expr ORDER BY id;
-- @result
-- @  1 | 1
-- @  2 | 2
-- @  3 | 2
-- @  4 | 3
-- @  5 | 3

-- CASE WHEN with ELSE
SELECT id, CASE WHEN val > 100 THEN 99 ELSE 0 END FROM t_expr WHERE id = 1;
-- @result
-- @  1 | 0

-- CASE WHEN no match and no ELSE returns NULL
SELECT id, CASE WHEN val > 100 THEN 99 END FROM t_expr WHERE id = 1;
-- @result
-- @  1 | NULL

-- Arithmetic: addition
SELECT id, val + 5 FROM t_expr WHERE id = 1;
-- @result
-- @  1 | 15

-- Arithmetic: subtraction
SELECT id, val - 5 FROM t_expr WHERE id = 2;
-- @result
-- @  2 | 15

-- Arithmetic: multiplication
SELECT id, val * 3 FROM t_expr WHERE id = 3;
-- @result
-- @  3 | 90

-- Arithmetic: division
SELECT id, val / 4 FROM t_expr WHERE id = 4;
-- @result
-- @  4 | 10

-- IS NULL and IS NOT NULL via ALTER TABLE (inserting literal NULL fails with TypeMismatch)
CREATE TABLE t_expr_null (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_expr_null (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_expr_null (id, val) VALUES (2, 20);
-- @rows 1
ALTER TABLE t_expr_null ADD COLUMN opt INT64 NULL;
-- Insert new row with opt set; old rows have opt = NULL
INSERT INTO t_expr_null (id, val, opt) VALUES (3, 30, 42);
-- @rows 1

-- IS NULL: rows 1 and 2 have null opt
SELECT id FROM t_expr_null WHERE opt IS NULL ORDER BY id;
-- @result
-- @  1
-- @  2

-- IS NOT NULL: row 3 has opt=42
SELECT id FROM t_expr_null WHERE opt IS NOT NULL ORDER BY id;
-- @result
-- @  3

-- String concat
CREATE TABLE t_expr_str (id INT64 NOT NULL PRIMARY KEY, label STRING NOT NULL);
INSERT INTO t_expr_str (id, label) VALUES (1, 'hello');
-- @rows 1
SELECT id, label || ' world' FROM t_expr_str WHERE id = 1;
-- @result
-- @  1 | hello world

-- BETWEEN inclusive bounds
SELECT id FROM t_expr WHERE val BETWEEN 20 AND 40 ORDER BY id;
-- @result
-- @  2
-- @  3
-- @  4

-- BETWEEN exclusive outside
SELECT COUNT(*) FROM t_expr WHERE val BETWEEN 100 AND 200;
-- @result
-- @  0

-- IN list match
SELECT id FROM t_expr WHERE id IN (1, 3, 5) ORDER BY id;
-- @result
-- @  1
-- @  3
-- @  5

-- NOT IN list
SELECT id FROM t_expr WHERE id NOT IN (2, 4) ORDER BY id;
-- @result
-- @  1
-- @  3
-- @  5

-- Comparison operators in WHERE: =, !=, >, <, >=, <=
SELECT id FROM t_expr WHERE val = 30 ORDER BY id;
-- @result
-- @  3

SELECT id FROM t_expr WHERE val != 30 ORDER BY id;
-- @result
-- @  1
-- @  2
-- @  4
-- @  5

SELECT id FROM t_expr WHERE val > 30 ORDER BY id;
-- @result
-- @  4
-- @  5

SELECT id FROM t_expr WHERE val < 30 ORDER BY id;
-- @result
-- @  1
-- @  2

SELECT id FROM t_expr WHERE val >= 30 ORDER BY id;
-- @result
-- @  3
-- @  4
-- @  5

SELECT id FROM t_expr WHERE val <= 30 ORDER BY id;
-- @result
-- @  1
-- @  2
-- @  3

DROP TABLE t_expr;
DROP TABLE t_expr_null;
DROP TABLE t_expr_str;

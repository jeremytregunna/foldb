-- SELECT: basic queries, WHERE clauses, ORDER BY, LIMIT, OFFSET, expressions

CREATE TABLE t_sel (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL, label STRING NOT NULL);
INSERT INTO t_sel (id, val, label) VALUES (1, 10, 'alpha');
-- @rows 1
INSERT INTO t_sel (id, val, label) VALUES (2, 20, 'beta');
-- @rows 1
INSERT INTO t_sel (id, val, label) VALUES (3, 30, 'gamma');
-- @rows 1
INSERT INTO t_sel (id, val, label) VALUES (4, 40, 'delta');
-- @rows 1
INSERT INTO t_sel (id, val, label) VALUES (5, 50, 'epsilon');
-- @rows 1

-- Basic scan with ORDER BY
SELECT id, val FROM t_sel ORDER BY id;
-- @result
-- @  1 | 10
-- @  2 | 20
-- @  3 | 30
-- @  4 | 40
-- @  5 | 50

-- WHERE equality
SELECT id, val FROM t_sel WHERE id = 3 ORDER BY id;
-- @result
-- @  3 | 30

-- WHERE comparison: >
SELECT id, val FROM t_sel WHERE val > 30 ORDER BY id;
-- @result
-- @  4 | 40
-- @  5 | 50

-- WHERE comparison: <
SELECT id, val FROM t_sel WHERE val < 20 ORDER BY id;
-- @result
-- @  1 | 10

-- WHERE comparison: >=
SELECT id, val FROM t_sel WHERE val >= 30 ORDER BY id;
-- @result
-- @  3 | 30
-- @  4 | 40
-- @  5 | 50

-- WHERE comparison: <=
SELECT id, val FROM t_sel WHERE val <= 20 ORDER BY id;
-- @result
-- @  1 | 10
-- @  2 | 20

-- WHERE comparison: !=
SELECT id, val FROM t_sel WHERE id != 3 ORDER BY id;
-- @result
-- @  1 | 10
-- @  2 | 20
-- @  4 | 40
-- @  5 | 50

-- WHERE with AND
SELECT id, val FROM t_sel WHERE val > 10 AND val < 40 ORDER BY id;
-- @result
-- @  2 | 20
-- @  3 | 30

-- WHERE with OR
SELECT id, val FROM t_sel WHERE id = 1 OR id = 5 ORDER BY id;
-- @result
-- @  1 | 10
-- @  5 | 50

-- ORDER BY ASC (explicit)
SELECT id FROM t_sel ORDER BY id ASC;
-- @result
-- @  1
-- @  2
-- @  3
-- @  4
-- @  5

-- ORDER BY DESC
SELECT id FROM t_sel ORDER BY id DESC;
-- @result
-- @  5
-- @  4
-- @  3
-- @  2
-- @  1

-- ORDER BY multiple columns
CREATE TABLE t_sel_ord (id INT64 NOT NULL PRIMARY KEY, grp INT64 NOT NULL, rank INT64 NOT NULL);
INSERT INTO t_sel_ord (id, grp, rank) VALUES (1, 2, 3);
-- @rows 1
INSERT INTO t_sel_ord (id, grp, rank) VALUES (2, 1, 2);
-- @rows 1
INSERT INTO t_sel_ord (id, grp, rank) VALUES (3, 1, 1);
-- @rows 1
INSERT INTO t_sel_ord (id, grp, rank) VALUES (4, 2, 1);
-- @rows 1
SELECT id, grp, rank FROM t_sel_ord ORDER BY grp ASC, rank ASC;
-- @result
-- @  3 | 1 | 1
-- @  2 | 1 | 2
-- @  4 | 2 | 1
-- @  1 | 2 | 3

-- LIMIT
SELECT id FROM t_sel ORDER BY id LIMIT 3;
-- @result
-- @  1
-- @  2
-- @  3

-- OFFSET
SELECT id FROM t_sel ORDER BY id OFFSET 2;
-- @result
-- @  3
-- @  4
-- @  5

-- LIMIT + OFFSET
SELECT id FROM t_sel ORDER BY id LIMIT 2 OFFSET 1;
-- @result
-- @  2
-- @  3

-- CASE WHEN THEN ELSE END
SELECT id, CASE WHEN val >= 40 THEN 1 ELSE 0 END FROM t_sel ORDER BY id;
-- @result
-- @  1 | 0
-- @  2 | 0
-- @  3 | 0
-- @  4 | 1
-- @  5 | 1

-- Arithmetic expressions
SELECT id, val + 5 FROM t_sel WHERE id = 1 ORDER BY id;
-- @result
-- @  1 | 15

SELECT id, val - 5 FROM t_sel WHERE id = 2 ORDER BY id;
-- @result
-- @  2 | 15

SELECT id, val * 2 FROM t_sel WHERE id = 3 ORDER BY id;
-- @result
-- @  3 | 60

SELECT id, val / 2 FROM t_sel WHERE id = 4 ORDER BY id;
-- @result
-- @  4 | 20

-- String concatenation
SELECT id, label || '-suffix' FROM t_sel WHERE id = 1 ORDER BY id;
-- @result
-- @  1 | alpha-suffix

-- BETWEEN (inclusive)
SELECT id FROM t_sel WHERE val BETWEEN 20 AND 40 ORDER BY id;
-- @result
-- @  2
-- @  3
-- @  4

-- IN list
SELECT id FROM t_sel WHERE id IN (1, 3, 5) ORDER BY id;
-- @result
-- @  1
-- @  3
-- @  5

-- NOT IN list
SELECT id FROM t_sel WHERE id NOT IN (2, 4) ORDER BY id;
-- @result
-- @  1
-- @  3
-- @  5

-- IS NULL and IS NOT NULL
-- Use ALTER TABLE so old rows get NULL for the new column
CREATE TABLE t_sel_null (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_sel_null (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_sel_null (id, val) VALUES (2, 99);
-- @rows 1
ALTER TABLE t_sel_null ADD COLUMN opt INT64 NULL;
-- Old rows have opt = NULL; insert a new row with opt set
INSERT INTO t_sel_null (id, val, opt) VALUES (3, 30, 42);
-- @rows 1

-- IS NULL: rows 1 and 2 have null opt
SELECT id FROM t_sel_null WHERE opt IS NULL ORDER BY id;
-- @result
-- @  1
-- @  2

-- IS NOT NULL: row 3 has opt=42
SELECT id FROM t_sel_null WHERE opt IS NOT NULL ORDER BY id;
-- @result
-- @  3

DROP TABLE t_sel;
DROP TABLE t_sel_ord;
DROP TABLE t_sel_null;

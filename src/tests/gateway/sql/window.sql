-- Window functions: LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE, ROW_NUMBER, SUM OVER, COUNT OVER

CREATE TABLE t_win_sales (id INT64 NOT NULL PRIMARY KEY, dept INT64 NOT NULL, amount INT64 NOT NULL);
INSERT INTO t_win_sales (id, dept, amount) VALUES (1, 10, 100);
-- @rows 1
INSERT INTO t_win_sales (id, dept, amount) VALUES (2, 10, 200);
-- @rows 1
INSERT INTO t_win_sales (id, dept, amount) VALUES (3, 10, 300);
-- @rows 1
INSERT INTO t_win_sales (id, dept, amount) VALUES (4, 20, 50);
-- @rows 1
INSERT INTO t_win_sales (id, dept, amount) VALUES (5, 20, 60);
-- @rows 1

-- LAG previous row within partition: id=1 gets NULL, id=2 gets 100, id=3 gets 200
SELECT id, LAG(amount) OVER (PARTITION BY dept ORDER BY id) FROM t_win_sales WHERE dept = 10 ORDER BY id;
-- @result
-- @  1 | NULL
-- @  2 | 100
-- @  3 | 200

-- LAG with offset 2
CREATE TABLE t_win_lag2 (id INT64 NOT NULL PRIMARY KEY, dept INT64 NOT NULL, amount INT64 NOT NULL);
INSERT INTO t_win_lag2 (id, dept, amount) VALUES (1, 10, 10);
-- @rows 1
INSERT INTO t_win_lag2 (id, dept, amount) VALUES (2, 10, 20);
-- @rows 1
INSERT INTO t_win_lag2 (id, dept, amount) VALUES (3, 10, 30);
-- @rows 1
INSERT INTO t_win_lag2 (id, dept, amount) VALUES (4, 10, 40);
-- @rows 1
SELECT id, LAG(amount, 2) OVER (PARTITION BY dept ORDER BY id) FROM t_win_lag2 ORDER BY id;
-- @result
-- @  1 | NULL
-- @  2 | NULL
-- @  3 | 10
-- @  4 | 20

-- LAG default value for out-of-bounds
CREATE TABLE t_win_lag_def (id INT64 NOT NULL PRIMARY KEY, dept INT64 NOT NULL, amount INT64 NOT NULL);
INSERT INTO t_win_lag_def (id, dept, amount) VALUES (1, 10, 100);
-- @rows 1
INSERT INTO t_win_lag_def (id, dept, amount) VALUES (2, 10, 200);
-- @rows 1
SELECT id, LAG(amount, 1, -1) OVER (PARTITION BY dept ORDER BY id) FROM t_win_lag_def ORDER BY id;
-- @result
-- @  1 | -1
-- @  2 | 100

-- LAG partition isolation: first row of each partition has null LAG
SELECT id, LAG(amount) OVER (PARTITION BY dept ORDER BY id) FROM t_win_sales ORDER BY id;
-- @result
-- @  1 | NULL
-- @  2 | 100
-- @  3 | 200
-- @  4 | NULL
-- @  5 | 50

-- LEAD next row within partition
SELECT id, LEAD(amount) OVER (PARTITION BY dept ORDER BY id) FROM t_win_sales WHERE dept = 10 ORDER BY id;
-- @result
-- @  1 | 200
-- @  2 | 300
-- @  3 | NULL

-- LEAD default value for out-of-bounds
CREATE TABLE t_win_lead_def (id INT64 NOT NULL PRIMARY KEY, dept INT64 NOT NULL, amount INT64 NOT NULL);
INSERT INTO t_win_lead_def (id, dept, amount) VALUES (1, 10, 100);
-- @rows 1
INSERT INTO t_win_lead_def (id, dept, amount) VALUES (2, 10, 200);
-- @rows 1
SELECT id, LEAD(amount, 1, 0) OVER (PARTITION BY dept ORDER BY id) FROM t_win_lead_def ORDER BY id;
-- @result
-- @  1 | 200
-- @  2 | 0

-- FIRST_VALUE in partition: all rows in dept=10 see first amount=100
SELECT id, FIRST_VALUE(amount) OVER (PARTITION BY dept ORDER BY id) FROM t_win_sales WHERE dept = 10 ORDER BY id;
-- @result
-- @  1 | 100
-- @  2 | 100
-- @  3 | 100

-- FIRST_VALUE partitioned: each dept sees its own first
SELECT id, FIRST_VALUE(amount) OVER (PARTITION BY dept ORDER BY id) FROM t_win_sales ORDER BY id;
-- @result
-- @  1 | 100
-- @  2 | 100
-- @  3 | 100
-- @  4 | 50
-- @  5 | 50

-- LAST_VALUE in partition (with ROWS BETWEEN frame)
SELECT id, LAST_VALUE(amount) OVER (PARTITION BY dept ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM t_win_sales WHERE dept = 10 ORDER BY id;
-- @result
-- @  1 | 300
-- @  2 | 300
-- @  3 | 300

-- NTH_VALUE: 2nd value in partition = 200 for dept=10
SELECT id, NTH_VALUE(amount, 2) OVER (PARTITION BY dept ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM t_win_sales WHERE dept = 10 ORDER BY id;
-- @result
-- @  1 | 200
-- @  2 | 200
-- @  3 | 200

-- NTH_VALUE beyond size returns null
SELECT id, NTH_VALUE(amount, 5) OVER (PARTITION BY dept ORDER BY id) FROM t_win_sales WHERE dept = 10 ORDER BY id;
-- @result
-- @  1 | NULL
-- @  2 | NULL
-- @  3 | NULL

-- NTH_VALUE N=1 matches FIRST_VALUE
SELECT id, NTH_VALUE(amount, 1) OVER (PARTITION BY dept ORDER BY id) FROM t_win_sales WHERE dept = 10 ORDER BY id;
-- @result
-- @  1 | 100
-- @  2 | 100
-- @  3 | 100

-- ROW_NUMBER global (no PARTITION BY)
CREATE TABLE t_win_rn (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_win_rn (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_win_rn (id, val) VALUES (2, 20);
-- @rows 1
INSERT INTO t_win_rn (id, val) VALUES (3, 30);
-- @rows 1
SELECT id, ROW_NUMBER() OVER (ORDER BY id) FROM t_win_rn ORDER BY id;
-- @result
-- @  1 | 1
-- @  2 | 2
-- @  3 | 3

-- Additional LEAD partition isolation test (supplements global window coverage above)
-- Verify that partition=10 last row has null lead, partition=20 last row has null lead
SELECT id, LEAD(amount) OVER (PARTITION BY dept ORDER BY id) FROM t_win_sales ORDER BY id;
-- @result
-- @  1 | 200
-- @  2 | 300
-- @  3 | NULL
-- @  4 | 60
-- @  5 | NULL

-- SUM OVER partition (running aggregate: default frame is RANGE UNBOUNDED PRECEDING TO CURRENT ROW)
CREATE TABLE t_wsum (id INT64 NOT NULL PRIMARY KEY, dept INT64 NOT NULL, amount INT64 NOT NULL);
INSERT INTO t_wsum (id, dept, amount) VALUES (1, 10, 100);
-- @rows 1
INSERT INTO t_wsum (id, dept, amount) VALUES (2, 10, 200);
-- @rows 1
INSERT INTO t_wsum (id, dept, amount) VALUES (3, 20, 50);
-- @rows 1

SELECT id, SUM(amount) OVER (PARTITION BY dept ORDER BY id) FROM t_wsum ORDER BY id;
-- @result
-- @  1 | 100
-- @  2 | 300
-- @  3 | 50

-- COUNT OVER global window (no PARTITION BY) — running count
SELECT id, COUNT(id) OVER (ORDER BY id) FROM t_wsum ORDER BY id;
-- @result
-- @  1 | 1
-- @  2 | 2
-- @  3 | 3

-- AVG OVER partition (running average, integer division)
SELECT id, AVG(amount) OVER (PARTITION BY dept ORDER BY id) FROM t_wsum ORDER BY id;
-- @result
-- @  1 | 100
-- @  2 | 150
-- @  3 | 50

DROP TABLE t_wsum;

DROP TABLE t_win_sales;
DROP TABLE t_win_lag2;
DROP TABLE t_win_lag_def;
DROP TABLE t_win_lead_def;
DROP TABLE t_win_rn;

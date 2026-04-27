-- Aggregates: COUNT, SUM, AVG, MIN, MAX, GROUP BY, HAVING, ARRAY_AGG, STRING_AGG, FILTER

CREATE TABLE t_agg_main (id INT64 NOT NULL PRIMARY KEY, category INT64 NOT NULL, score INT64 NOT NULL);
INSERT INTO t_agg_main (id, category, score) VALUES (1, 10, 5);
-- @rows 1
INSERT INTO t_agg_main (id, category, score) VALUES (2, 10, 3);
-- @rows 1
INSERT INTO t_agg_main (id, category, score) VALUES (3, 20, 7);
-- @rows 1
INSERT INTO t_agg_main (id, category, score) VALUES (4, 20, 2);
-- @rows 1
INSERT INTO t_agg_main (id, category, score) VALUES (5, 10, 9);
-- @rows 1

-- COUNT(*)
SELECT COUNT(*) FROM t_agg_main;
-- @result
-- @  5

-- COUNT(col)
SELECT COUNT(score) FROM t_agg_main;
-- @result
-- @  5

-- SUM
SELECT SUM(score) FROM t_agg_main;
-- @result
-- @  26

-- MIN
SELECT MIN(score) FROM t_agg_main;
-- @result
-- @  2

-- MAX
SELECT MAX(score) FROM t_agg_main;
-- @result
-- @  9

-- GROUP BY single column
SELECT category, COUNT(*) FROM t_agg_main GROUP BY category ORDER BY category;
-- @result
-- @  10 | 3
-- @  20 | 2

-- SUM with GROUP BY
SELECT category, SUM(score) FROM t_agg_main GROUP BY category ORDER BY category;
-- @result
-- @  10 | 17
-- @  20 | 9

-- HAVING filter: only categories with count > 2
SELECT category, COUNT(*) FROM t_agg_main GROUP BY category HAVING COUNT(*) > 2 ORDER BY category;
-- @result
-- @  10 | 3

-- GROUP BY multi-column
CREATE TABLE t_agg_mc (id INT64 NOT NULL PRIMARY KEY, cat INT64 NOT NULL, sub INT64 NOT NULL, val INT64 NOT NULL);
INSERT INTO t_agg_mc (id, cat, sub, val) VALUES (1, 1, 1, 10);
-- @rows 1
INSERT INTO t_agg_mc (id, cat, sub, val) VALUES (2, 1, 1, 20);
-- @rows 1
INSERT INTO t_agg_mc (id, cat, sub, val) VALUES (3, 1, 2, 30);
-- @rows 1
INSERT INTO t_agg_mc (id, cat, sub, val) VALUES (4, 2, 1, 40);
-- @rows 1
SELECT cat, sub, SUM(val) FROM t_agg_mc GROUP BY cat, sub ORDER BY cat, sub;
-- @result
-- @  1 | 1 | 30
-- @  1 | 2 | 30
-- @  2 | 1 | 40

-- Aggregate on empty table: COUNT(*) = 0
CREATE TABLE t_agg_empty (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
SELECT COUNT(*) FROM t_agg_empty;
-- @result
-- @  0

-- Combination: GROUP BY + HAVING + ORDER BY
SELECT category, SUM(score) FROM t_agg_main GROUP BY category HAVING SUM(score) > 10 ORDER BY category;
-- @result
-- @  10 | 17

-- FILTER tests use their own table to avoid query hash interference
CREATE TABLE t_agg_filter (id INT64 NOT NULL PRIMARY KEY, category INT64 NOT NULL, score INT64 NOT NULL);
INSERT INTO t_agg_filter (id, category, score) VALUES (1, 10, 10);
-- @rows 1
INSERT INTO t_agg_filter (id, category, score) VALUES (2, 10, 5);
-- @rows 1
INSERT INTO t_agg_filter (id, category, score) VALUES (3, 10, 8);
-- @rows 1
INSERT INTO t_agg_filter (id, category, score) VALUES (4, 20, 9);
-- @rows 1
INSERT INTO t_agg_filter (id, category, score) VALUES (5, 20, 4);
-- @rows 1

-- FILTER with COUNT: score > 7 → scores 10, 8, 9 = 3 rows
SELECT COUNT(*) FILTER (WHERE score > 7) FROM t_agg_filter;
-- @result
-- @  3

-- FILTER with SUM: score >= 8 → scores 10, 8, 9 = 27
SELECT SUM(score) FILTER (WHERE score >= 8) FROM t_agg_filter;
-- @result
-- @  27

-- FILTER with GROUP BY: per-category count of score > 7
-- cat 10: score 10 and 8 → 2; cat 20: score 9 → 1
SELECT category, COUNT(*) FILTER (WHERE score > 7) FROM t_agg_filter GROUP BY category ORDER BY category;
-- @result
-- @  10 | 2
-- @  20 | 1

DROP TABLE t_agg_main;
DROP TABLE t_agg_mc;
DROP TABLE t_agg_empty;
DROP TABLE t_agg_filter;

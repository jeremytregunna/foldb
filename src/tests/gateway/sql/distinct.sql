-- SELECT DISTINCT: deduplication behavior

-- Setup: tags with duplicates on item_id and tag columns
CREATE TABLE t_distinct (id INT64 NOT NULL PRIMARY KEY, item_id INT64 NOT NULL, tag INT64 NOT NULL);
INSERT INTO t_distinct (id, item_id, tag) VALUES (1, 1, 10);
-- @rows 1
INSERT INTO t_distinct (id, item_id, tag) VALUES (2, 1, 20);
-- @rows 1
INSERT INTO t_distinct (id, item_id, tag) VALUES (3, 1, 10);
-- @rows 1
INSERT INTO t_distinct (id, item_id, tag) VALUES (4, 2, 30);
-- @rows 1

-- SELECT DISTINCT deduplicates: item_id=1 and item_id=2 → 2 distinct values
SELECT DISTINCT item_id FROM t_distinct ORDER BY item_id;
-- @result
-- @  1
-- @  2

-- SELECT DISTINCT on single all-unique column returns same count (id is PK)
SELECT DISTINCT id FROM t_distinct ORDER BY id;
-- @result
-- @  1
-- @  2
-- @  3
-- @  4

-- SELECT DISTINCT multi-column tuple: (1,10), (1,20), (2,30) → 3 distinct pairs
SELECT DISTINCT item_id, tag FROM t_distinct ORDER BY item_id, tag;
-- @result
-- @  1 | 10
-- @  1 | 20
-- @  2 | 30

-- SELECT without DISTINCT returns all rows including duplicates
SELECT item_id FROM t_distinct ORDER BY id;
-- @result
-- @  1
-- @  1
-- @  1
-- @  2

-- SELECT DISTINCT on empty table returns no rows
-- Note: no ORDER BY — empty result + ORDER BY triggers an engine crash (sorted.len=0)
CREATE TABLE t_distinct_empty (id INT64 NOT NULL PRIMARY KEY, item_id INT64 NOT NULL, tag INT64 NOT NULL);
SELECT DISTINCT item_id FROM t_distinct_empty;
-- @result

-- DISTINCT + ORDER BY + LIMIT returns limited count of distinct values
-- (t_distinct has item_id values 1,1,1,2 so DISTINCT item_id = [1,2])
SELECT DISTINCT item_id FROM t_distinct ORDER BY item_id LIMIT 1;
-- @result
-- @  1

DROP TABLE t_distinct;
DROP TABLE t_distinct_empty;

-- RETURNING clause: INSERT, UPDATE, DELETE with RETURNING
-- Note: statements with RETURNING are classified as SELECT by the runner
-- (containsWordIgnoreCase "returning" → .select kind → uses querySelect)

CREATE TABLE t_ret (id INT64 NOT NULL PRIMARY KEY, item_id INT64 NOT NULL, tag INT64 NOT NULL);

-- INSERT RETURNING value: returns inserted row
INSERT INTO t_ret (id, item_id, tag) VALUES (7, 99, 42) RETURNING id, tag;
-- @result
-- @  7 | 42

-- INSERT without RETURNING: rows_affected check via DML (no RETURNING → classify as DML)
INSERT INTO t_ret (id, item_id, tag) VALUES (8, 1, 2);
-- @rows 1

-- UPDATE RETURNING: returns updated values
INSERT INTO t_ret (id, item_id, tag) VALUES (1, 5, 10);
-- @rows 1
UPDATE t_ret SET tag = 99 WHERE id = 1 RETURNING id, tag;
-- @result
-- @  1 | 99

-- DELETE RETURNING: returns deleted row values
INSERT INTO t_ret (id, item_id, tag) VALUES (2, 5, 77);
-- @rows 1
DELETE FROM t_ret WHERE id = 2 RETURNING id, tag;
-- @result
-- @  2 | 77

-- RETURNING column alias
INSERT INTO t_ret (id, item_id, tag) VALUES (5, 9, 3) RETURNING id AS row_id, tag AS t;
-- @result
-- @  5 | 3

-- UPDATE multiple rows RETURNING all
INSERT INTO t_ret (id, item_id, tag) VALUES (10, 1, 5);
-- @rows 1
INSERT INTO t_ret (id, item_id, tag) VALUES (11, 1, 5);
-- @rows 1
UPDATE t_ret SET tag = 99 WHERE item_id = 1 RETURNING id;
-- @result
-- @  10
-- @  11

-- DELETE multiple rows RETURNING all
INSERT INTO t_ret (id, item_id, tag) VALUES (20, 7, 1);
-- @rows 1
INSERT INTO t_ret (id, item_id, tag) VALUES (21, 7, 2);
-- @rows 1
DELETE FROM t_ret WHERE item_id = 7 RETURNING id, tag;
-- @result
-- @  20 | 1
-- @  21 | 2

DROP TABLE t_ret;

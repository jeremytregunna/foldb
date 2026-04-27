-- Subqueries: EXISTS, NOT EXISTS, IN, NOT IN, scalar subqueries

-- Setup: users (id, name_val), orders (id, user_id, amount)
-- users 1, 2, 3; orders for users 1 (x2) and 2 (x1)
CREATE TABLE t_sq_users (id INT64 NOT NULL PRIMARY KEY, name_val INT64 NOT NULL);
CREATE TABLE t_sq_orders (id INT64 NOT NULL PRIMARY KEY, user_id INT64 NOT NULL, amount INT64 NOT NULL);
INSERT INTO t_sq_users (id, name_val) VALUES (1, 100);
-- @rows 1
INSERT INTO t_sq_users (id, name_val) VALUES (2, 200);
-- @rows 1
INSERT INTO t_sq_users (id, name_val) VALUES (3, 300);
-- @rows 1
INSERT INTO t_sq_orders (id, user_id, amount) VALUES (1, 1, 50);
-- @rows 1
INSERT INTO t_sq_orders (id, user_id, amount) VALUES (2, 1, 80);
-- @rows 1
INSERT INTO t_sq_orders (id, user_id, amount) VALUES (3, 2, 20);
-- @rows 1

-- EXISTS true: user_id=1 has orders → all users returned
SELECT COUNT(*) FROM t_sq_users WHERE EXISTS (SELECT 1 FROM t_sq_orders WHERE user_id = 1);
-- @result
-- @  3

-- EXISTS false: user_id=99 has no orders → no users returned
SELECT COUNT(*) FROM t_sq_users WHERE EXISTS (SELECT 1 FROM t_sq_orders WHERE user_id = 99);
-- @result
-- @  0

-- NOT EXISTS filter: non-matching subquery → all users pass NOT EXISTS
SELECT COUNT(*) FROM t_sq_users WHERE NOT EXISTS (SELECT 1 FROM t_sq_orders WHERE user_id = 99);
-- @result
-- @  3

-- IN subquery: users who have orders (users 1 and 2)
SELECT id FROM t_sq_users WHERE id IN (SELECT user_id FROM t_sq_orders) ORDER BY id;
-- @result
-- @  1
-- @  2

-- NOT IN subquery: users with no orders (user 3 only)
SELECT id FROM t_sq_users WHERE id NOT IN (SELECT user_id FROM t_sq_orders) ORDER BY id;
-- @result
-- @  3

-- Scalar subquery in SELECT list: total order count alongside each user
SELECT id, (SELECT COUNT(*) FROM t_sq_orders) FROM t_sq_users WHERE id = 1 ORDER BY id;
-- @result
-- @  1 | 3

-- Scalar subquery in WHERE: orders with amount > MIN(amount); min=20, so amounts 50 and 80 qualify
SELECT id FROM t_sq_orders WHERE amount > (SELECT MIN(amount) FROM t_sq_orders) ORDER BY id;
-- @result
-- @  1
-- @  2

-- COUNT scalar returns 0 on empty (user_id=99 has no orders) → all users returned
SELECT COUNT(*) FROM t_sq_users WHERE (SELECT COUNT(*) FROM t_sq_orders WHERE user_id = 99) = 0;
-- @result
-- @  3

-- IN with empty subquery returns no rows
-- Note: no ORDER BY here — empty result + ORDER BY triggers an engine crash
SELECT COUNT(*) FROM t_sq_users WHERE id IN (SELECT user_id FROM t_sq_orders WHERE user_id = 99);
-- @result
-- @  0

-- NOT IN with empty returns all rows
SELECT id FROM t_sq_users WHERE id NOT IN (SELECT user_id FROM t_sq_orders WHERE user_id = 99) ORDER BY id;
-- @result
-- @  1
-- @  2
-- @  3

-- Multiple subqueries in same WHERE: id IN {1,2} AND id NOT IN {2} → only user 1
SELECT id FROM t_sq_users WHERE id IN (SELECT user_id FROM t_sq_orders) AND id NOT IN (SELECT user_id FROM t_sq_orders WHERE user_id = 2) ORDER BY id;
-- @result
-- @  1

-- Nested subquery: IN containing scalar — users whose orders have amount > MIN(amount)
-- MIN=20; orders with amount>20: user_id=1 (50, 80). So IN set = {1}
SELECT id FROM t_sq_users WHERE id IN (SELECT user_id FROM t_sq_orders WHERE amount > (SELECT MIN(amount) FROM t_sq_orders)) ORDER BY id;
-- @result
-- @  1

-- Scalar subquery returns NULL when source empty (MIN on no-match)
SELECT id, (SELECT MIN(amount) FROM t_sq_orders WHERE user_id = 99) FROM t_sq_users WHERE id = 1 ORDER BY id;
-- @result
-- @  1 | NULL

DROP TABLE t_sq_users;
DROP TABLE t_sq_orders;

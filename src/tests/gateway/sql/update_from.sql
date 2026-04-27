-- UPDATE FROM: update rows joined from another table

CREATE TABLE t_uf_orders (id INT64 NOT NULL PRIMARY KEY, status INT64 NOT NULL, customer_id INT64 NOT NULL);
CREATE TABLE t_uf_customers (id INT64 NOT NULL PRIMARY KEY, tier INT64 NOT NULL);
INSERT INTO t_uf_orders (id, status, customer_id) VALUES (1, 0, 10);
-- @rows 1
INSERT INTO t_uf_orders (id, status, customer_id) VALUES (2, 0, 20);
-- @rows 1
INSERT INTO t_uf_customers (id, tier) VALUES (10, 1);
-- @rows 1
INSERT INTO t_uf_customers (id, tier) VALUES (20, 2);
-- @rows 1

-- UPDATE FROM matching rows: order 1 (customer=10, tier=1) gets status=1
UPDATE t_uf_orders SET status = 1 FROM t_uf_customers WHERE t_uf_orders.customer_id = t_uf_customers.id AND t_uf_customers.tier = 1;
-- @rows 1
SELECT id, status FROM t_uf_orders ORDER BY id;
-- @result
-- @  1 | 1
-- @  2 | 0

-- UPDATE FROM no match leaves unchanged: reset first, then update with impossible tier
UPDATE t_uf_orders SET status = 0 WHERE id = 1;
-- @rows 1
UPDATE t_uf_orders SET status = 1 FROM t_uf_customers WHERE t_uf_orders.customer_id = t_uf_customers.id AND t_uf_customers.tier = 99;
-- @rows 0
SELECT id, status FROM t_uf_orders ORDER BY id;
-- @result
-- @  1 | 0
-- @  2 | 0

-- UPDATE SET value from FROM table column: set order status = customer.tier
UPDATE t_uf_orders SET status = t_uf_customers.tier FROM t_uf_customers WHERE t_uf_orders.customer_id = t_uf_customers.id;
-- @rows 2
SELECT id, status FROM t_uf_orders ORDER BY id;
-- @result
-- @  1 | 1
-- @  2 | 2

-- Multiple FROM rows match same target (first match wins, rows_affected=1)
CREATE TABLE t_uf_tgt (id INT64 NOT NULL PRIMARY KEY, status INT64 NOT NULL, priority INT64 NOT NULL);
CREATE TABLE t_uf_mods (id INT64 NOT NULL PRIMARY KEY, priority INT64 NOT NULL, new_status INT64 NOT NULL);
INSERT INTO t_uf_tgt (id, status, priority) VALUES (1, 0, 5);
-- @rows 1
INSERT INTO t_uf_mods (id, priority, new_status) VALUES (1, 5, 7);
-- @rows 1
INSERT INTO t_uf_mods (id, priority, new_status) VALUES (2, 5, 99);
-- @rows 1
UPDATE t_uf_tgt SET status = t_uf_mods.new_status FROM t_uf_mods WHERE t_uf_tgt.priority = t_uf_mods.priority;
-- @rows 1
-- Status will be 7 or 99, just confirm exactly one update occurred (row exists with non-zero status)
SELECT COUNT(*) FROM t_uf_tgt WHERE status != 0;
-- @result
-- @  1

DROP TABLE t_uf_orders;
DROP TABLE t_uf_customers;
DROP TABLE t_uf_tgt;
DROP TABLE t_uf_mods;

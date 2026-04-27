-- DELETE USING: delete rows joined from another table

CREATE TABLE t_du_items (id INT64 NOT NULL PRIMARY KEY, category_id INT64 NOT NULL);
CREATE TABLE t_du_categories (id INT64 NOT NULL PRIMARY KEY, active INT64 NOT NULL);
INSERT INTO t_du_items (id, category_id) VALUES (1, 10);
-- @rows 1
INSERT INTO t_du_items (id, category_id) VALUES (2, 20);
-- @rows 1
INSERT INTO t_du_categories (id, active) VALUES (10, 0);
-- @rows 1
INSERT INTO t_du_categories (id, active) VALUES (20, 1);
-- @rows 1

-- DELETE USING matched rows deleted: item 1 (cat 10 inactive) deleted, item 2 kept
DELETE FROM t_du_items USING t_du_categories WHERE t_du_items.category_id = t_du_categories.id AND t_du_categories.active = 0;
-- @rows 1
SELECT id FROM t_du_items ORDER BY id;
-- @result
-- @  2

-- No matching join leaves intact: insert a new item with a category that doesn't match any in nocat table
CREATE TABLE t_du_nocat (id INT64 NOT NULL PRIMARY KEY, active INT64 NOT NULL);
INSERT INTO t_du_nocat (id, active) VALUES (99, 0);
-- @rows 1
DELETE FROM t_du_items USING t_du_nocat WHERE t_du_items.category_id = t_du_nocat.id;
-- @rows 0
SELECT id FROM t_du_items ORDER BY id;
-- @result
-- @  2

-- Deletes all matched when multiple items share a category
-- Insert two new items in inactive cat 10
INSERT INTO t_du_items (id, category_id) VALUES (3, 10);
-- @rows 1
INSERT INTO t_du_items (id, category_id) VALUES (4, 10);
-- @rows 1
-- Now items 2 (cat=20, active), 3 (cat=10, inactive), 4 (cat=10, inactive)
DELETE FROM t_du_items USING t_du_categories WHERE t_du_items.category_id = t_du_categories.id AND t_du_categories.active = 0;
-- @rows 2
SELECT id FROM t_du_items ORDER BY id;
-- @result
-- @  2

-- Two USING tables cross-product: only row matching both banned_cats and banned_regions is deleted
CREATE TABLE t_du_products (id INT64 NOT NULL PRIMARY KEY, cat_id INT64 NOT NULL, region_id INT64 NOT NULL);
CREATE TABLE t_du_banned_cats (id INT64 NOT NULL PRIMARY KEY);
CREATE TABLE t_du_banned_regions (id INT64 NOT NULL PRIMARY KEY);
-- product 1: cat=10, region=100 — both banned → DELETE
-- product 2: cat=10, region=200 — cat banned but region not → KEEP
-- product 3: cat=20, region=100 — region banned but cat not → KEEP
INSERT INTO t_du_products (id, cat_id, region_id) VALUES (1, 10, 100);
-- @rows 1
INSERT INTO t_du_products (id, cat_id, region_id) VALUES (2, 10, 200);
-- @rows 1
INSERT INTO t_du_products (id, cat_id, region_id) VALUES (3, 20, 100);
-- @rows 1
INSERT INTO t_du_banned_cats (id) VALUES (10);
-- @rows 1
INSERT INTO t_du_banned_regions (id) VALUES (100);
-- @rows 1
DELETE FROM t_du_products USING t_du_banned_cats, t_du_banned_regions WHERE t_du_products.cat_id = t_du_banned_cats.id AND t_du_products.region_id = t_du_banned_regions.id;
-- @rows 1
SELECT id FROM t_du_products ORDER BY id;
-- @result
-- @  2
-- @  3

DROP TABLE t_du_items;
DROP TABLE t_du_categories;
DROP TABLE t_du_nocat;
DROP TABLE t_du_products;
DROP TABLE t_du_banned_cats;
DROP TABLE t_du_banned_regions;

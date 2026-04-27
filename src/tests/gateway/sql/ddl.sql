-- DDL: ALTER TABLE ADD COLUMN, DROP COLUMN, error cases

-- ALTER TABLE ADD COLUMN: new column readable on subsequent inserts
CREATE TABLE t_ddl_items (id INT64 NOT NULL PRIMARY KEY, price INT64 NOT NULL);
ALTER TABLE t_ddl_items ADD COLUMN discount INT64 NULL;
INSERT INTO t_ddl_items (id, price, discount) VALUES (1, 100, 10);
-- @rows 1
SELECT discount FROM t_ddl_items WHERE id = 1;
-- @result
-- @  10

-- ALTER TABLE ADD COLUMN: existing rows return NULL for new column
CREATE TABLE t_ddl_old (id INT64 NOT NULL PRIMARY KEY, price INT64 NOT NULL);
INSERT INTO t_ddl_old (id, price) VALUES (1, 50);
-- @rows 1
ALTER TABLE t_ddl_old ADD COLUMN discount INT64 NULL;
SELECT discount FROM t_ddl_old WHERE id = 1;
-- @result
-- @  NULL

-- ALTER TABLE DROP COLUMN: column no longer accessible
CREATE TABLE t_ddl_drop (id INT64 NOT NULL PRIMARY KEY, price INT64 NOT NULL, extra INT64 NULL);
ALTER TABLE t_ddl_drop DROP COLUMN extra;
SELECT extra FROM t_ddl_drop WHERE id = 1;
-- @error ColumnNotFound

-- ALTER TABLE ADD duplicate column rejected
CREATE TABLE t_ddl_dup (id INT64 NOT NULL PRIMARY KEY, price INT64 NOT NULL);
ALTER TABLE t_ddl_dup ADD COLUMN price INT64 NULL;
-- @error ColumnAlreadyExists

DROP TABLE t_ddl_items;
DROP TABLE t_ddl_old;
DROP TABLE t_ddl_drop;
DROP TABLE t_ddl_dup;

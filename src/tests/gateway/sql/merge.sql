-- MERGE: matched row updated, unmatched row inserted
CREATE TABLE t_merge_target (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
CREATE TABLE t_merge_source (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_merge_target (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_merge_source (id, val) VALUES (1, 99);
-- @rows 1
INSERT INTO t_merge_source (id, val) VALUES (2, 42);
-- @rows 1

MERGE INTO t_merge_target USING t_merge_source ON t_merge_target.id = t_merge_source.id
WHEN MATCHED THEN UPDATE SET val = t_merge_source.val
WHEN NOT MATCHED THEN INSERT (id, val) VALUES (t_merge_source.id, t_merge_source.val);

SELECT id, val FROM t_merge_target ORDER BY id;
-- @result
-- @  1 | 99
-- @  2 | 42

DROP TABLE t_merge_target;
DROP TABLE t_merge_source;

-- MERGE: only matched branch fires when all source rows match
CREATE TABLE t_merge_upd (id INT64 NOT NULL PRIMARY KEY, n INT64 NOT NULL);
CREATE TABLE t_merge_delta (id INT64 NOT NULL PRIMARY KEY, n INT64 NOT NULL);
INSERT INTO t_merge_upd (id, n) VALUES (1, 5);
-- @rows 1
INSERT INTO t_merge_upd (id, n) VALUES (2, 10);
-- @rows 1
INSERT INTO t_merge_delta (id, n) VALUES (1, 50);
-- @rows 1
INSERT INTO t_merge_delta (id, n) VALUES (2, 100);
-- @rows 1

MERGE INTO t_merge_upd USING t_merge_delta ON t_merge_upd.id = t_merge_delta.id
WHEN MATCHED THEN UPDATE SET n = t_merge_delta.n;

SELECT id, n FROM t_merge_upd ORDER BY id;
-- @result
-- @  1 | 50
-- @  2 | 100

DROP TABLE t_merge_upd;
DROP TABLE t_merge_delta;

-- MERGE: only not-matched branch (all source rows are new)
CREATE TABLE t_merge_ins (id INT64 NOT NULL PRIMARY KEY, label STRING NOT NULL);
CREATE TABLE t_merge_new (id INT64 NOT NULL PRIMARY KEY, label STRING NOT NULL);
INSERT INTO t_merge_new (id, label) VALUES (1, 'alpha');
-- @rows 1
INSERT INTO t_merge_new (id, label) VALUES (2, 'beta');
-- @rows 1

MERGE INTO t_merge_ins USING t_merge_new ON t_merge_ins.id = t_merge_new.id
WHEN NOT MATCHED THEN INSERT (id, label) VALUES (t_merge_new.id, t_merge_new.label);

SELECT id, label FROM t_merge_ins ORDER BY id;
-- @result
-- @  1 | alpha
-- @  2 | beta

DROP TABLE t_merge_ins;
DROP TABLE t_merge_new;

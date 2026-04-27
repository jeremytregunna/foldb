-- DEFAULT value applied when column omitted
CREATE TABLE t_default1 (id INT64 NOT NULL PRIMARY KEY, val INT64 DEFAULT 42 NOT NULL);
INSERT INTO t_default1 (id) VALUES (1);
-- @rows 1
SELECT id, val FROM t_default1 ORDER BY id;
-- @result
-- @  1 | 42
DROP TABLE t_default1;

-- DEFAULT 0 for integer
CREATE TABLE t_default2 (id INT64 NOT NULL PRIMARY KEY, n INT64 DEFAULT 0 NOT NULL);
INSERT INTO t_default2 (id) VALUES (1);
-- @rows 1
INSERT INTO t_default2 (id) VALUES (2);
-- @rows 1
SELECT id, n FROM t_default2 ORDER BY id;
-- @result
-- @  1 | 0
-- @  2 | 0
DROP TABLE t_default2;

-- Explicit value overrides DEFAULT
CREATE TABLE t_default3 (id INT64 NOT NULL PRIMARY KEY, val INT64 DEFAULT 99 NOT NULL);
INSERT INTO t_default3 (id, val) VALUES (1, 7);
-- @rows 1
SELECT id, val FROM t_default3;
-- @result
-- @  1 | 7
DROP TABLE t_default3;

-- Duplicate PK rejected
CREATE TABLE t_pk (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_pk (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_pk (id, val) VALUES (1, 20);
-- @error constraint
SELECT id, val FROM t_pk;
-- @result
-- @  1 | 10
DROP TABLE t_pk;

-- NOT NULL without default is rejected when column omitted
CREATE TABLE t_notnull (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_notnull (id) VALUES (1);
-- @error not-null
DROP TABLE t_notnull;

-- UNIQUE constraint: duplicate non-PK value rejected
CREATE TABLE t_unique (id INT64 NOT NULL PRIMARY KEY, code STRING UNIQUE NOT NULL);
INSERT INTO t_unique (id, code) VALUES (1, 'abc');
-- @rows 1
INSERT INTO t_unique (id, code) VALUES (2, 'abc');
-- @error constraint
INSERT INTO t_unique (id, code) VALUES (2, 'def');
-- @rows 1
SELECT id, code FROM t_unique ORDER BY id;
-- @result
-- @  1 | abc
-- @  2 | def
DROP TABLE t_unique;

-- CHECK constraint: accepted when expression is true
CREATE TABLE t_check1 (id INT64 NOT NULL PRIMARY KEY, age INT64 NOT NULL CHECK (age >= 0));
INSERT INTO t_check1 (id, age) VALUES (1, 25);
-- @rows 1
SELECT id, age FROM t_check1;
-- @result
-- @  1 | 25
DROP TABLE t_check1;

-- CHECK constraint: rejected when expression is false
CREATE TABLE t_check2 (id INT64 NOT NULL PRIMARY KEY, age INT64 NOT NULL CHECK (age >= 0));
INSERT INTO t_check2 (id, age) VALUES (1, -1);
-- @error constraint
DROP TABLE t_check2;

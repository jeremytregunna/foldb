-- JSON column operators: ->, ->>, @>, <@

CREATE TABLE t_json_docs (id INT64 NOT NULL PRIMARY KEY, data JSON NOT NULL);

-- INSERT JSON column values
INSERT INTO t_json_docs (id, data) VALUES (1, '{"name":"Alice","age":30}');
-- @rows 1
INSERT INTO t_json_docs (id, data) VALUES (2, '{"name":"Bob","age":25}');
-- @rows 1
INSERT INTO t_json_docs (id, data) VALUES (3, '{"user":{"name":"Carol"}}');
-- @rows 1
INSERT INTO t_json_docs (id, data) VALUES (4, '{"x":1}');
-- @rows 1

-- ->> extracts a field as text (in SELECT list)
SELECT id, data->>'name' FROM t_json_docs WHERE id = 1;
-- @result
-- @  1 | Alice

-- ->> on integer field returns text representation
SELECT id, data->>'age' FROM t_json_docs WHERE id = 1;
-- @result
-- @  1 | 30

-- ->> on missing key returns NULL
SELECT id, data->>'missing' FROM t_json_docs WHERE id = 1;
-- @result
-- @  1 | NULL

-- -> then ->> chains field access (nested object)
SELECT data->'user'->>'name' FROM t_json_docs WHERE id = 3;
-- @result
-- @  Carol

-- @> contains operator: data contains {"age":30}
SELECT id FROM t_json_docs WHERE data @> '{"age":30}' ORDER BY id;
-- @result
-- @  1

-- @> does not match when value differs
SELECT id FROM t_json_docs WHERE data @> '{"age":99}' ORDER BY id;
-- @result

-- @> filter using name field
SELECT id FROM t_json_docs WHERE data @> '{"name":"Bob"}' ORDER BY id;
-- @result
-- @  2

-- <@ contained-by: {"x":1} is subset of {"x":1,"y":2}
SELECT id FROM t_json_docs WHERE data <@ '{"x":1,"y":2}' ORDER BY id;
-- @result
-- @  4

-- <@ not matched when data has extra keys not in RHS
SELECT id FROM t_json_docs WHERE data <@ '{"name":"Alice"}' ORDER BY id;
-- @result

DROP TABLE t_json_docs;

-- Foreign key constraint enforcement

-- Schema: fk_parents(id STRING NOT NULL PK)
--         fk_children(id STRING NOT NULL PK, parent_id STRING NOT NULL FK->fk_parents(id))
CREATE TABLE fk_parents (id STRING NOT NULL PRIMARY KEY);
CREATE TABLE fk_children (
    id STRING NOT NULL PRIMARY KEY,
    parent_id STRING NOT NULL,
    CONSTRAINT fk_parent FOREIGN KEY (parent_id) REFERENCES fk_parents (id)
);

-- INSERT into child with valid parent succeeds
INSERT INTO fk_parents (id) VALUES ('p1');
-- @rows 1
INSERT INTO fk_children (id, parent_id) VALUES ('c1', 'p1');
-- @rows 1

SELECT id FROM fk_children ORDER BY id;
-- @result
-- @  c1

-- INSERT into child with missing parent fails (FK violation)
INSERT INTO fk_children (id, parent_id) VALUES ('c2', 'nobody');
-- @error constraint

-- child count unchanged
SELECT id FROM fk_children ORDER BY id;
-- @result
-- @  c1

-- DELETE parent with no children succeeds
INSERT INTO fk_parents (id) VALUES ('p2');
-- @rows 1
DELETE FROM fk_parents WHERE id = 'p2';
-- @rows 1

SELECT id FROM fk_parents ORDER BY id;
-- @result
-- @  p1

-- DELETE parent referenced by child fails (FK violation)
DELETE FROM fk_parents WHERE id = 'p1';
-- @error constraint

-- parent still present
SELECT id FROM fk_parents ORDER BY id;
-- @result
-- @  p1

-- DELETE child then parent succeeds
DELETE FROM fk_children WHERE id = 'c1';
-- @rows 1
DELETE FROM fk_parents WHERE id = 'p1';
-- @rows 1

SELECT id FROM fk_parents ORDER BY id;
-- @result

-- UPDATE child FK column to valid parent succeeds
INSERT INTO fk_parents (id) VALUES ('p3');
-- @rows 1
INSERT INTO fk_parents (id) VALUES ('p4');
-- @rows 1
INSERT INTO fk_children (id, parent_id) VALUES ('c3', 'p3');
-- @rows 1
UPDATE fk_children SET parent_id = 'p4' WHERE id = 'c3';
-- @rows 1

SELECT id, parent_id FROM fk_children ORDER BY id;
-- @result
-- @  c3 | p4

-- UPDATE child FK column to missing parent fails
UPDATE fk_children SET parent_id = 'ghost' WHERE id = 'c3';
-- @error constraint

SELECT id, parent_id FROM fk_children ORDER BY id;
-- @result
-- @  c3 | p4

DROP TABLE fk_children;
DROP TABLE fk_parents;

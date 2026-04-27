-- Bitwise operators: AND, OR, XOR, NOT, left shift, right shift

CREATE TABLE t_bit_flags (id INT64 NOT NULL PRIMARY KEY, mask INT64 NOT NULL);
INSERT INTO t_bit_flags (id, mask) VALUES (1, 15);
-- @rows 1
INSERT INTO t_bit_flags (id, mask) VALUES (2, 5);
-- @rows 1
INSERT INTO t_bit_flags (id, mask) VALUES (3, 12);
-- @rows 1
INSERT INTO t_bit_flags (id, mask) VALUES (4, 0);
-- @rows 1
INSERT INTO t_bit_flags (id, mask) VALUES (5, 1);
-- @rows 1
INSERT INTO t_bit_flags (id, mask) VALUES (6, 16);
-- @rows 1
INSERT INTO t_bit_flags (id, mask) VALUES (7, 7);
-- @rows 1
INSERT INTO t_bit_flags (id, mask) VALUES (8, 8);
-- @rows 1

-- AND: 0b1111 & 0b0110 = 6
SELECT mask & 6 FROM t_bit_flags WHERE id = 1;
-- @result
-- @  6

-- OR: 0b0101 | 0b0010 = 7
SELECT mask | 2 FROM t_bit_flags WHERE id = 2;
-- @result
-- @  7

-- XOR: 0b1100 ^ 0b1010 = 6
SELECT mask ^ 10 FROM t_bit_flags WHERE id = 3;
-- @result
-- @  6

-- NOT: ~0 = -1 (two's complement)
SELECT ~mask FROM t_bit_flags WHERE id = 4;
-- @result
-- @  -1

-- Left shift: 1 << 3 = 8
SELECT mask << 3 FROM t_bit_flags WHERE id = 5;
-- @result
-- @  8

-- Right shift: 16 >> 2 = 4
SELECT mask >> 2 FROM t_bit_flags WHERE id = 6;
-- @result
-- @  4

-- AND in WHERE: only rows where bit 0 is set (id=1 mask=7, id=5 mask=1, id=7 mask=7)
SELECT id FROM t_bit_flags WHERE mask & 1 = 1 ORDER BY id;
-- @result
-- @  1
-- @  2
-- @  5
-- @  7

DROP TABLE t_bit_flags;

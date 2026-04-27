-- Basic transaction: transfer between accounts
CREATE TABLE accounts (id INT PRIMARY KEY, balance INT64 NOT NULL);
INSERT INTO accounts (id, balance) VALUES (1, 1000);
-- @rows 1
INSERT INTO accounts (id, balance) VALUES (2, 0);
-- @rows 1

TRANSACTION (src INT, dst INT, amt INT64) {
    UPDATE accounts SET balance = balance - $amt WHERE id = $src;
    UPDATE accounts SET balance = balance + $amt WHERE id = $dst;
    ASSERT (SELECT balance FROM accounts WHERE id = $src) >= 0;
    ASSERT (SELECT balance FROM accounts WHERE id = $dst) >= 0;
};
-- @call (1, 2, 400)
-- @rows 2

SELECT id, balance FROM accounts ORDER BY id;
-- @result
-- @  1 | 600
-- @  2 | 400

-- Assert catches overdraft (read-your-own-writes: assert sees post-update balance)
-- @call (1, 2, 700)
-- @error constraint

-- Balances unchanged after aborted transaction
SELECT id, balance FROM accounts ORDER BY id;
-- @result
-- @  1 | 600
-- @  2 | 400

DROP TABLE accounts;

-- ASSERT with DEFAULT: account inserted with default balance
CREATE TABLE accounts (id INT PRIMARY KEY, balance INT64 DEFAULT 0 NOT NULL);
INSERT INTO accounts (id) VALUES (1);
-- @rows 1
INSERT INTO accounts (id, balance) VALUES (2, 500);
-- @rows 1

TRANSACTION (src INT, dst INT, amt INT64) {
    UPDATE accounts SET balance = balance - $amt WHERE id = $src;
    UPDATE accounts SET balance = balance + $amt WHERE id = $dst;
    ASSERT (SELECT balance FROM accounts WHERE id = $src) >= 0;
};
-- @call (2, 1, 300)
-- @rows 2

SELECT id, balance FROM accounts ORDER BY id;
-- @result
-- @  1 | 300
-- @  2 | 200

DROP TABLE accounts;

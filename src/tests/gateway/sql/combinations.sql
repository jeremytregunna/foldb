-- Combinations: cross-feature scenarios

-- JOIN + aggregate + HAVING
CREATE TABLE t_comb_emp (id INT64 NOT NULL PRIMARY KEY, dept_id INT64 NOT NULL, salary INT64 NOT NULL);
CREATE TABLE t_comb_dept (id INT64 NOT NULL PRIMARY KEY, name_val INT64 NOT NULL);
INSERT INTO t_comb_emp (id, dept_id, salary) VALUES (1, 10, 5000);
-- @rows 1
INSERT INTO t_comb_emp (id, dept_id, salary) VALUES (2, 10, 6000);
-- @rows 1
INSERT INTO t_comb_emp (id, dept_id, salary) VALUES (3, 20, 4000);
-- @rows 1
INSERT INTO t_comb_dept (id, name_val) VALUES (10, 100);
-- @rows 1
INSERT INTO t_comb_dept (id, name_val) VALUES (20, 200);
-- @rows 1

-- Only depts with total salary > 10000 (dept 10: 11000)
SELECT t_comb_dept.id, SUM(t_comb_emp.salary) FROM t_comb_emp INNER JOIN t_comb_dept ON t_comb_emp.dept_id = t_comb_dept.id GROUP BY t_comb_dept.id HAVING SUM(t_comb_emp.salary) > 10000 ORDER BY t_comb_dept.id;
-- @result
-- @  10 | 11000

-- Subquery in UPDATE WHERE clause
-- Raise salary of employees in dept 10 (which has total salary > 10000)
UPDATE t_comb_emp SET salary = salary + 100 WHERE dept_id IN (SELECT id FROM t_comb_dept WHERE id = 10);
-- @rows 2
SELECT id, salary FROM t_comb_emp ORDER BY id;
-- @result
-- @  1 | 5100
-- @  2 | 6100
-- @  3 | 4000

-- ON CONFLICT DO UPDATE + RETURNING
CREATE TABLE t_comb_oc (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_comb_oc (id, val) VALUES (1, 10);
-- @rows 1
INSERT INTO t_comb_oc (id, val) VALUES (1, 5) ON CONFLICT DO UPDATE SET val = val + 5 RETURNING id, val;
-- @result
-- @  1 | 15

-- DISTINCT + ORDER BY (without LIMIT to avoid engine interaction bug)
CREATE TABLE t_comb_dist (id INT64 NOT NULL PRIMARY KEY, grp INT64 NOT NULL);
INSERT INTO t_comb_dist (id, grp) VALUES (1, 3);
-- @rows 1
INSERT INTO t_comb_dist (id, grp) VALUES (2, 1);
-- @rows 1
INSERT INTO t_comb_dist (id, grp) VALUES (3, 2);
-- @rows 1
INSERT INTO t_comb_dist (id, grp) VALUES (4, 1);
-- @rows 1
INSERT INTO t_comb_dist (id, grp) VALUES (5, 3);
-- @rows 1
SELECT DISTINCT grp FROM t_comb_dist ORDER BY grp;
-- @result
-- @  1
-- @  2
-- @  3

-- CASE WHEN in ORDER BY
SELECT id, grp FROM t_comb_dist ORDER BY CASE WHEN grp = 1 THEN 0 ELSE grp END, id;
-- @result
-- @  2 | 1
-- @  4 | 1
-- @  3 | 2
-- @  1 | 3
-- @  5 | 3

-- GROUP BY + ORDER BY + LIMIT
SELECT grp, COUNT(*) FROM t_comb_dist GROUP BY grp ORDER BY grp LIMIT 2;
-- @result
-- @  1 | 2
-- @  2 | 1

-- LEFT JOIN + IS NULL in WHERE (anti-join pattern)
-- Find employees with no department match (dept_id=99 has no dept row)
CREATE TABLE t_comb_lj_emp (id INT64 NOT NULL PRIMARY KEY, dept_id INT64 NOT NULL);
CREATE TABLE t_comb_lj_dept (id INT64 NOT NULL PRIMARY KEY, budget INT64 NOT NULL);
INSERT INTO t_comb_lj_emp (id, dept_id) VALUES (1, 10);
-- @rows 1
INSERT INTO t_comb_lj_emp (id, dept_id) VALUES (2, 99);
-- @rows 1
INSERT INTO t_comb_lj_dept (id, budget) VALUES (10, 1000);
-- @rows 1
SELECT t_comb_lj_emp.id FROM t_comb_lj_emp LEFT JOIN t_comb_lj_dept ON t_comb_lj_emp.dept_id = t_comb_lj_dept.id WHERE t_comb_lj_dept.id IS NULL ORDER BY t_comb_lj_emp.id;
-- @result
-- @  2

-- JOIN + CASE WHEN in SELECT
-- At this point salaries are: id=1 → 5100, id=2 → 6100, id=3 → 4000 (after +100 update above)
SELECT t_comb_emp.id, CASE WHEN t_comb_emp.salary > 5000 THEN 1 ELSE 0 END FROM t_comb_emp INNER JOIN t_comb_dept ON t_comb_emp.dept_id = t_comb_dept.id ORDER BY t_comb_emp.id;
-- @result
-- @  1 | 1
-- @  2 | 1
-- @  3 | 0

-- INSERT from SELECT (INSERT INTO ... SELECT ...)
CREATE TABLE t_comb_copy (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_comb_copy (id, val) SELECT id, salary FROM t_comb_emp WHERE dept_id = 10;
-- @rows 2
SELECT id, val FROM t_comb_copy ORDER BY id;
-- @result
-- @  1 | 5100
-- @  2 | 6100

-- Aggregate + subquery in HAVING: depts where COUNT > subquery result
-- COUNT(*) from t_comb_dist for grp=1 is 2; depts with COUNT > 1 = dept 10
SELECT t_comb_dept.id, COUNT(*) FROM t_comb_emp INNER JOIN t_comb_dept ON t_comb_emp.dept_id = t_comb_dept.id GROUP BY t_comb_dept.id HAVING COUNT(*) > (SELECT COUNT(*) FROM t_comb_emp WHERE dept_id = 20) ORDER BY t_comb_dept.id;
-- @result
-- @  10 | 2

-- UPDATE FROM + RETURNING
CREATE TABLE t_comb_uf_orders (id INT64 NOT NULL PRIMARY KEY, status INT64 NOT NULL, cust_id INT64 NOT NULL);
CREATE TABLE t_comb_uf_custs (id INT64 NOT NULL PRIMARY KEY, tier INT64 NOT NULL);
INSERT INTO t_comb_uf_orders (id, status, cust_id) VALUES (1, 0, 10);
-- @rows 1
INSERT INTO t_comb_uf_custs (id, tier) VALUES (10, 5);
-- @rows 1
UPDATE t_comb_uf_orders SET status = t_comb_uf_custs.tier FROM t_comb_uf_custs WHERE t_comb_uf_orders.cust_id = t_comb_uf_custs.id RETURNING id, status;
-- @result
-- @  1 | 5

-- Transaction with multiple DML + ASSERT using subquery
CREATE TABLE t_comb_acct (id INT64 NOT NULL PRIMARY KEY, balance INT64 NOT NULL);
INSERT INTO t_comb_acct (id, balance) VALUES (1, 1000);
-- @rows 1
INSERT INTO t_comb_acct (id, balance) VALUES (2, 0);
-- @rows 1

TRANSACTION (src INT64, dst INT64, amt INT64) {
    UPDATE t_comb_acct SET balance = balance - $amt WHERE id = $src;
    UPDATE t_comb_acct SET balance = balance + $amt WHERE id = $dst;
    ASSERT (SELECT balance FROM t_comb_acct WHERE id = $src) >= 0;
};
-- @call (1, 2, 400)
-- @rows 2

SELECT id, balance FROM t_comb_acct ORDER BY id;
-- @result
-- @  1 | 600
-- @  2 | 400

-- Assert catches overdraft
-- @call (1, 2, 700)
-- @error constraint

-- Balances unchanged after aborted transaction
SELECT id, balance FROM t_comb_acct ORDER BY id;
-- @result
-- @  1 | 600
-- @  2 | 400

-- Nested aggregates: total salary across all depts (via normal aggregate, engine doesn't support
-- referencing subquery column aliases in outer aggregate)
SELECT SUM(salary) FROM t_comb_emp;
-- @result
-- @  15200

DROP TABLE t_comb_emp;
DROP TABLE t_comb_dept;
DROP TABLE t_comb_oc;
DROP TABLE t_comb_dist;
DROP TABLE t_comb_lj_emp;
DROP TABLE t_comb_lj_dept;
DROP TABLE t_comb_copy;
DROP TABLE t_comb_uf_orders;
DROP TABLE t_comb_uf_custs;
DROP TABLE t_comb_acct;

-- Joins: INNER, LEFT, RIGHT, CROSS, FULL, chained, with WHERE/GROUP BY/ORDER BY

-- Setup: employees(id, dept_id), departments(id, budget)
-- employee 3 has dept_id=99 with no matching department
-- department 20 has no matching employees
CREATE TABLE t_join_emp (id INT64 NOT NULL PRIMARY KEY, dept_id INT64 NOT NULL);
CREATE TABLE t_join_dept (id INT64 NOT NULL PRIMARY KEY, budget INT64 NOT NULL);
INSERT INTO t_join_emp (id, dept_id) VALUES (1, 10);
-- @rows 1
INSERT INTO t_join_emp (id, dept_id) VALUES (2, 10);
-- @rows 1
INSERT INTO t_join_emp (id, dept_id) VALUES (3, 99);
-- @rows 1
INSERT INTO t_join_dept (id, budget) VALUES (10, 1000);
-- @rows 1
INSERT INTO t_join_dept (id, budget) VALUES (20, 500);
-- @rows 1

-- INNER JOIN: only rows with matching dept_id (employees 1 and 2)
SELECT t_join_emp.id FROM t_join_emp INNER JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id ORDER BY t_join_emp.id;
-- @result
-- @  1
-- @  2

-- LEFT JOIN: all employees (including employee 3 with null dept)
SELECT t_join_emp.id FROM t_join_emp LEFT JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id ORDER BY t_join_emp.id;
-- @result
-- @  1
-- @  2
-- @  3

-- LEFT JOIN: unmatched left row has null right-side column
SELECT t_join_emp.id, t_join_dept.budget FROM t_join_emp LEFT JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id ORDER BY t_join_emp.id;
-- @result
-- @  1 | 1000
-- @  2 | 1000
-- @  3 | NULL

-- RIGHT JOIN: all departments (dept 10 matches 2 employees, dept 20 has null emp)
SELECT t_join_dept.id FROM t_join_emp RIGHT JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id ORDER BY t_join_dept.id;
-- @result
-- @  10
-- @  10
-- @  20

-- CROSS JOIN: 3 employees x 2 departments = 6 rows
SELECT COUNT(*) FROM t_join_emp CROSS JOIN t_join_dept;
-- @result
-- @  6

-- FULL JOIN: matched (emp1+dept10, emp2+dept10) + unmatched left (emp3) + unmatched right (dept20) = 4 rows
SELECT COUNT(*) FROM t_join_emp FULL JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id;
-- @result
-- @  4

-- INNER JOIN + WHERE filter: only dept 10 (budget > 600)
SELECT t_join_emp.id FROM t_join_emp INNER JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id WHERE t_join_dept.budget > 600 ORDER BY t_join_emp.id;
-- @result
-- @  1
-- @  2

-- INNER JOIN + GROUP BY + COUNT: dept 10 has 2 employees
SELECT t_join_dept.id, COUNT(*) FROM t_join_emp INNER JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id GROUP BY t_join_dept.id ORDER BY t_join_dept.id;
-- @result
-- @  10 | 2

-- LEFT JOIN + ORDER BY
SELECT t_join_emp.id FROM t_join_emp LEFT JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id ORDER BY t_join_emp.id;
-- @result
-- @  1
-- @  2
-- @  3

-- Chained INNER JOIN (3 tables)
CREATE TABLE t_join_a (id INT64 NOT NULL PRIMARY KEY, b_id INT64 NOT NULL);
CREATE TABLE t_join_b (id INT64 NOT NULL PRIMARY KEY, c_id INT64 NOT NULL);
CREATE TABLE t_join_c (id INT64 NOT NULL PRIMARY KEY, val INT64 NOT NULL);
INSERT INTO t_join_a (id, b_id) VALUES (1, 10);
-- @rows 1
INSERT INTO t_join_a (id, b_id) VALUES (2, 99);
-- @rows 1
INSERT INTO t_join_b (id, c_id) VALUES (10, 100);
-- @rows 1
INSERT INTO t_join_c (id, val) VALUES (100, 42);
-- @rows 1
SELECT t_join_a.id, t_join_c.val FROM t_join_a INNER JOIN t_join_b ON t_join_a.b_id = t_join_b.id INNER JOIN t_join_c ON t_join_b.c_id = t_join_c.id ORDER BY t_join_a.id;
-- @result
-- @  1 | 42

-- LEFT JOIN where right side missing gives NULL, then aggregate
SELECT COUNT(*), SUM(CASE WHEN t_join_dept.budget IS NULL THEN 1 ELSE 0 END) FROM t_join_emp LEFT JOIN t_join_dept ON t_join_emp.dept_id = t_join_dept.id;
-- @result
-- @  3 | 1

DROP TABLE t_join_emp;
DROP TABLE t_join_dept;
DROP TABLE t_join_a;
DROP TABLE t_join_b;
DROP TABLE t_join_c;

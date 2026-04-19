/// Comprehensive parser tests covering all SQL constructs.
const std = @import("std");
const sql = @import("sql.zig");
const parser_mod = sql.parser;
const ast_mod = sql.ast;

fn parse(src: []const u8, arena: std.mem.Allocator) !ast_mod.ParsedQuery {
    return parser_mod.parse(src, arena);
}

fn expectStmt(src: []const u8, comptime tag: std.meta.Tag(ast_mod.Stmt)) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parser_mod.parse(src, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), q.stmts.len);
    try std.testing.expect(q.stmts[0] == tag);
}

// ─── SELECT ───────────────────────────────────────────────────────────────────

test "parse simple select" {
    try expectStmt("SELECT id, name FROM users WHERE id = $1", .select);
}

test "parse SELECT with ORDER BY" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse("SELECT id FROM users ORDER BY id DESC", arena.allocator());
    const s = q.stmts[0].select;
    try std.testing.expectEqual(@as(usize, 1), s.order_by.len);
    try std.testing.expect(!s.order_by[0].asc);
}

test "parse SELECT with LIMIT and OFFSET" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse("SELECT id FROM users LIMIT 10 OFFSET 5", arena.allocator());
    const s = q.stmts[0].select;
    try std.testing.expect(s.limit != null);
    try std.testing.expect(s.offset != null);
}

test "parse SELECT DISTINCT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse("SELECT DISTINCT name FROM users", arena.allocator());
    try std.testing.expect(q.stmts[0].select.distinct);
}

test "parse SELECT with GROUP BY and HAVING" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "SELECT id, COUNT(*) FROM users GROUP BY id HAVING id > 0",
        arena.allocator(),
    );
    const s = q.stmts[0].select;
    try std.testing.expectEqual(@as(usize, 1), s.group_by.len);
    try std.testing.expect(s.having != null);
}

test "parse SELECT with INNER JOIN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "SELECT u.id, o.amount FROM users u INNER JOIN orders o ON u.id = o.user_id",
        arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), q.stmts[0].select.joins.len);
}

test "parse SELECT with LEFT JOIN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "SELECT u.id FROM users u LEFT JOIN orders o ON u.id = o.user_id",
        arena.allocator(),
    );
    try std.testing.expectEqual(ast_mod.JoinKind.left, q.stmts[0].select.joins[0].kind);
}

test "parse SELECT with subquery in WHERE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "SELECT id FROM users WHERE id IN (SELECT user_id FROM orders WHERE amount > 100.0)",
        arena.allocator(),
    );
    _ = q;
}

test "parse SELECT with EXISTS subquery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "SELECT id FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE user_id = users.id)",
        arena.allocator(),
    );
    _ = q;
}

test "parse CTE (WITH clause)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "WITH active AS (SELECT id FROM users WHERE id > 0) SELECT id FROM active",
        arena.allocator(),
    );
    try std.testing.expect(q.stmts[0].select.with.len > 0);
}

test "parse RECURSIVE CTE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // RECURSIVE flag on CTE is parsed; UNION ALL (set operations) are M6+
    _ = try parse(
        "WITH RECURSIVE t(n) AS (SELECT id FROM users WHERE id > 0) SELECT n FROM t",
        arena.allocator(),
    );
}

test "parse SELECT with window function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "SELECT id, ROW_NUMBER() OVER (PARTITION BY name ORDER BY id) FROM users",
        arena.allocator(),
    );
}

test "parse SELECT with CASE searched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "SELECT CASE WHEN id > 0 THEN 'pos' WHEN id < 0 THEN 'neg' ELSE 'zero' END FROM users",
        arena.allocator(),
    );
}

test "parse SELECT with CASE simple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "SELECT CASE id WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'other' END FROM users",
        arena.allocator(),
    );
}

test "parse SELECT with BETWEEN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT id FROM users WHERE id BETWEEN 1 AND 100", arena.allocator());
}

test "parse SELECT with LIKE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT id FROM users WHERE name LIKE '%alice%'", arena.allocator());
}

test "parse SELECT with CAST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT CAST(id AS STRING) FROM users", arena.allocator());
}

test "parse SELECT with :: cast operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT id::string FROM users", arena.allocator());
}

test "parse SELECT * (valid for non-registered)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse("SELECT * FROM users", arena.allocator());
    try std.testing.expect(q.stmts[0].select.items[0] == .star);
}

// ─── INSERT ───────────────────────────────────────────────────────────────────

test "parse INSERT with VALUES" {
    try expectStmt(
        "INSERT INTO users (id, name) VALUES ($1, $2)",
        .insert,
    );
}

test "parse INSERT with multiple rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "INSERT INTO users (id, name) VALUES (1, 'a'), (2, 'b'), (3, 'c')",
        arena.allocator(),
    );
    const ins = q.stmts[0].insert;
    try std.testing.expectEqual(@as(usize, 3), ins.source.values.len);
}

test "parse INSERT ON CONFLICT DO NOTHING" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "INSERT INTO users (id, name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        arena.allocator(),
    );
}

test "parse INSERT ON CONFLICT DO UPDATE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "INSERT INTO users (id, name) VALUES ($1, $2) ON CONFLICT DO UPDATE SET name = $2",
        arena.allocator(),
    );
}

test "parse INSERT with RETURNING" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "INSERT INTO users (id, name) VALUES ($1, $2) RETURNING id",
        arena.allocator(),
    );
}

// ─── UPDATE ───────────────────────────────────────────────────────────────────

test "parse UPDATE" {
    try expectStmt("UPDATE users SET name = $1 WHERE id = $2", .update);
}

test "parse UPDATE with multiple SET clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "UPDATE users SET name = $1, score = $2 WHERE id = $3",
        arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 2), q.stmts[0].update.sets.len);
}

test "parse UPDATE with RETURNING" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "UPDATE users SET name = $1 WHERE id = $2 RETURNING id, name",
        arena.allocator(),
    );
}

// ─── DELETE ───────────────────────────────────────────────────────────────────

test "parse DELETE" {
    try expectStmt("DELETE FROM users WHERE id = $1", .delete);
}

test "parse DELETE with RETURNING" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("DELETE FROM users WHERE id = $1 RETURNING id", arena.allocator());
}

// ─── MERGE ────────────────────────────────────────────────────────────────────

test "parse MERGE statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        \\MERGE INTO users USING orders ON users.id = orders.user_id
        \\WHEN MATCHED THEN UPDATE SET name = 'updated'
        \\WHEN NOT MATCHED THEN INSERT (id, name) VALUES (orders.user_id, 'new')
    ,
        arena.allocator(),
    );
}

// ─── DDL ──────────────────────────────────────────────────────────────────────

test "parse CREATE TABLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        "CREATE TABLE users (id INT64 NOT NULL, name STRING NOT NULL, PRIMARY KEY (id))",
        arena.allocator(),
    );
    try std.testing.expect(q.stmts[0] == .create_table);
    try std.testing.expectEqualStrings("users", q.stmts[0].create_table.name);
    try std.testing.expectEqual(@as(usize, 2), q.stmts[0].create_table.columns.len);
}

test "parse CREATE TABLE IF NOT EXISTS" {
    try expectStmt(
        "CREATE TABLE IF NOT EXISTS t (id INT64 NOT NULL, PRIMARY KEY (id))",
        .create_table,
    );
}

test "parse CREATE INDEX" {
    try expectStmt(
        "CREATE ORDERED INDEX idx_name ON users (name)",
        .create_index,
    );
}

test "parse CREATE UNIQUE INDEX" {
    try expectStmt(
        "CREATE UNIQUE ORDERED INDEX idx_name ON users (name)",
        .create_index,
    );
}

test "parse ALTER TABLE ADD COLUMN" {
    try expectStmt(
        "ALTER TABLE users ADD COLUMN email STRING NULL",
        .alter_table,
    );
}

test "parse ALTER TABLE DROP COLUMN" {
    try expectStmt(
        "ALTER TABLE users DROP COLUMN score",
        .alter_table,
    );
}

// ─── TRANSACTION blocks ───────────────────────────────────────────────────────

test "parse TRANSACTION block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(
        \\TRANSACTION (uid INT64, uname STRING) {
        \\  INSERT INTO users (id, name) VALUES ($1, $2);
        \\  ASSERT (SELECT COUNT(*) FROM users WHERE id = $1) = 1;
        \\}
    ,
        arena.allocator(),
    );
    try std.testing.expect(q.stmts[0] == .transaction);
    const txn = q.stmts[0].transaction;
    try std.testing.expectEqual(@as(usize, 2), txn.params.len);
    try std.testing.expectEqual(@as(usize, 2), txn.stmts.len);
}

test "parse TRANSACTION with multiple DML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        \\TRANSACTION (uid INT64) {
        \\  UPDATE users SET name = 'deleted' WHERE id = $1;
        \\  DELETE FROM orders WHERE user_id = $1;
        \\}
    ,
        arena.allocator(),
    );
}

// ─── Types ────────────────────────────────────────────────────────────────────

test "parse all integer types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        \\CREATE TABLE types (
        \\  a INT8 NOT NULL, b INT16 NOT NULL, c INT32 NOT NULL, d INT64 NOT NULL,
        \\  e UINT8 NOT NULL, f UINT16 NOT NULL, g UINT32 NOT NULL, h UINT64 NOT NULL,
        \\  PRIMARY KEY (a)
        \\)
    ,
        arena.allocator(),
    );
}

test "parse float and decimal types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "CREATE TABLE t (a FLOAT32 NOT NULL, b FLOAT64 NOT NULL, c DECIMAL(10,2) NOT NULL, PRIMARY KEY (a))",
        arena.allocator(),
    );
}

test "parse WRAPPING integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "CREATE TABLE t (n INT64 WRAPPING NOT NULL, PRIMARY KEY (n))",
        arena.allocator(),
    );
}

test "parse TIMESTAMP and UUID types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "CREATE TABLE t (ts TIMESTAMP NOT NULL, uid UUID NOT NULL, PRIMARY KEY (uid))",
        arena.allocator(),
    );
}

test "parse VECTOR type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "CREATE TABLE t (v VECTOR(128) NOT NULL, PRIMARY KEY (v))",
        arena.allocator(),
    );
}

test "parse ARRAY type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "CREATE TABLE t (tags ARRAY<STRING> NOT NULL, PRIMARY KEY (tags))",
        arena.allocator(),
    );
}

// ─── Expressions ─────────────────────────────────────────────────────────────

test "parse arithmetic expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT id + 1, id * 2, id / 3, id % 4 FROM users", arena.allocator());
}

test "parse string concatenation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT name || ' suffix' FROM users", arena.allocator());
}

test "parse IS NULL / IS NOT NULL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT id FROM users WHERE score IS NULL OR score IS NOT NULL", arena.allocator());
}

test "parse IS DISTINCT FROM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT id FROM users WHERE id IS DISTINCT FROM $1", arena.allocator());
}

test "parse NOT IN list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT id FROM users WHERE id NOT IN (1, 2, 3)", arena.allocator());
}

test "parse nondeterministic functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT NOW(), RANDOM(), UUID() FROM users", arena.allocator());
}

test "parse parameters $1 through $9" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9 FROM users",
        arena.allocator(),
    );
}

test "parse ORDER BY NULLS FIRST / LAST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(
        "SELECT id FROM users ORDER BY score ASC NULLS FIRST",
        arena.allocator(),
    );
}

// ─── Error cases ─────────────────────────────────────────────────────────────

test "parse rejects ISOLATION LEVEL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = parser_mod.parse(
        "SELECT id FROM users ISOLATION LEVEL SERIALIZABLE",
        arena.allocator(),
    );
    const err = result catch |e| switch (e) {
        error.UnsupportedSyntax, error.UnexpectedToken => return,
        else => return e,
    };
    _ = err;
    return error.TestExpectedError;
}

test "parse defaults column without nullability to nullable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parser_mod.parse(
        "CREATE TABLE t (id INT64)",
        arena.allocator(),
    );
    // No explicit nullability — parser now defaults to nullable.
    try std.testing.expectEqual(result.stmts[0].create_table.columns[0].nullable, .nullable);
}

test "parse rejects unterminated string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = parser_mod.parse(
        "SELECT 'unterminated FROM users",
        arena.allocator(),
    );
    try std.testing.expectError(error.UnterminatedString, result);
}

test "parse handles escaped quotes in strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT 'it''s fine' FROM users", arena.allocator());
}

test "parse handles hex byte literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse("SELECT x'deadbeef' FROM users", arena.allocator());
}

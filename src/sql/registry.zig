/// SQL query registry: parse → typecheck → plan → canonicalize → store.
const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const schema_mod = @import("schema.zig");
const tc_mod = @import("type_checker.zig");
const plan_mod = @import("plan.zig");
const canon = @import("canon.zig");
const wasm_mod = @import("wasm.zig");

pub const QueryHash = [32]u8;

pub const RegistryError = error{
    ParseError,
    TypeCheckError,
    PlanError,
    SelectStarInRegisteredQuery,
    SchemaBreakingChange,
    QueryNotFound,
    WasmValidationError,
    OutOfMemory,
} || parser_mod.ParseError || tc_mod.TypeCheckError || plan_mod.PlanError || wasm_mod.WasmError || schema_mod.SchemaError;

/// A registered query, ready for execution.
pub const RegisteredQuery = struct {
    hash: QueryHash,
    sql_text: []const u8,
    plan: plan_mod.ExecutionPlan,
    param_types: []const ast.SqlType,
    nondet_count: u32,
    /// Schema version at registration time (for invalidation on DDL changes).
    schema_seq: u64,
    /// Arena that owns all AST/plan allocations for this query.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *RegisteredQuery) void {
        self.arena.deinit();
    }
};

pub const SqlRegistry = struct {
    queries: std.AutoHashMap(QueryHash, *RegisteredQuery),
    schema: *schema_mod.SchemaRegistry,
    alloc: std.mem.Allocator,
    /// Monotonically increasing schema version; bumped on any DDL.
    schema_seq: u64,

    pub fn init(alloc: std.mem.Allocator, schema: *schema_mod.SchemaRegistry) SqlRegistry {
        return .{
            .queries = std.AutoHashMap(QueryHash, *RegisteredQuery).init(alloc),
            .schema = schema,
            .alloc = alloc,
            .schema_seq = 0,
        };
    }

    pub fn deinit(self: *SqlRegistry) void {
        var it = self.queries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.queries.deinit();
    }

    /// Register a SQL string, returning its QueryHash.
    /// Rejects SELECT * in registered queries.
    /// Idempotent: registering the same SQL twice returns the same hash.
    pub fn register(self: *SqlRegistry, sql: []const u8) RegistryError!QueryHash {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        const arena_alloc = arena.allocator();

        // Dupe sql into the arena BEFORE parsing so all AST string slices
        // (identifiers, literals) reference arena-owned memory and remain valid
        // for the lifetime of the RegisteredQuery even after the caller frees sql.
        const sql_copy = arena_alloc.dupe(u8, sql) catch |e| {
            arena.deinit();
            return e;
        };

        const parsed = parser_mod.parse(sql_copy, arena_alloc) catch |e| {
            arena.deinit();
            return e;
        };

        const h = canon.canonicalize(parsed, arena_alloc) catch |e| {
            arena.deinit();
            return e;
        };

        if (self.queries.contains(h)) {
            arena.deinit();
            return h;
        }

        const param_types = extractParamTypes(parsed, arena_alloc) catch |e| {
            arena.deinit();
            return e;
        };

        var checker = tc_mod.TypeChecker.init(arena_alloc, self.schema);
        for (parsed.stmts) |stmt| {
            checker.checkStmt(stmt, param_types, true) catch |e| {
                arena.deinit();
                return e;
            };
        }

        var planner = plan_mod.Planner.init(arena_alloc, self.schema);
        const exec_plan = if (parsed.stmts.len == 1 and parsed.stmts[0] == .transaction)
            planner.planTransaction(parsed.stmts[0].transaction) catch |e| {
                arena.deinit();
                return e;
            }
        else blk: {
            var stmts: std.ArrayList(plan_mod.StmtPlan) = .empty;
            for (parsed.stmts) |s| {
                const sp = planner.planAstStmt(s) catch |e| {
                    arena.deinit();
                    return e;
                };
                stmts.append(arena_alloc, sp) catch |e| {
                    arena.deinit();
                    return e;
                };
            }
            const owned = stmts.toOwnedSlice(arena_alloc) catch |e| {
                arena.deinit();
                return e;
            };
            break :blk plan_mod.ExecutionPlan{
                .stmts = owned,
                .param_types = param_types,
                .nondet_count = planner.nondet_idx,
            };
        };

        const rq = self.alloc.create(RegisteredQuery) catch |e| {
            arena.deinit();
            return e;
        };
        rq.* = .{
            .hash = h,
            .sql_text = sql_copy,
            .plan = exec_plan,
            .param_types = param_types,
            .nondet_count = exec_plan.nondet_count,
            .schema_seq = self.schema_seq,
            .arena = arena,
        };

        self.queries.put(h, rq) catch |e| {
            rq.arena.deinit();
            self.alloc.destroy(rq);
            return e;
        };
        return h;
    }

    pub fn lookup(self: *const SqlRegistry, h: QueryHash) ?*const RegisteredQuery {
        return self.queries.get(h);
    }

    /// Apply DDL to the schema registry, bumping schema_seq.
    /// Validates that no registered queries would break.
    pub fn applyDdl(self: *SqlRegistry, stmt: ast.Stmt) RegistryError!void {
        // Apply the DDL to the schema
        switch (stmt) {
            .create_table => |s| {
                _ = try self.schema.createTable(s);
            },
            .create_index => |s| {
                try self.schema.createIndex(s);
            },
            .alter_table => |s| {
                switch (s.action) {
                    .add_column => |col| try self.schema.addColumn(s.table, col),
                    .drop_column => |col| try self.schema.dropColumn(s.table, col),
                }
            },
            else => return error.TypeCheckError,
        }
        self.schema_seq += 1;

        // Re-validate all registered queries against new schema
        var it = self.queries.iterator();
        while (it.next()) |entry| {
            const rq = entry.value_ptr.*;
            // Re-parse and re-typecheck
            var tmp_arena = std.heap.ArenaAllocator.init(self.alloc);
            defer tmp_arena.deinit();
            const parsed = parser_mod.parse(rq.sql_text, tmp_arena.allocator()) catch {
                return error.SchemaBreakingChange;
            };
            var checker = tc_mod.TypeChecker.init(tmp_arena.allocator(), self.schema);
            for (parsed.stmts) |s| {
                checker.checkStmt(s, rq.param_types, true) catch {
                    return error.SchemaBreakingChange;
                };
            }
        }
    }

    /// Register a WASM module for use in transactions.
    /// Returns its hash (BLAKE3 of the module bytes).
    pub fn registerWasm(self: *SqlRegistry, wasm_bytes: []const u8) RegistryError!QueryHash {
        const module = wasm_mod.validate(wasm_bytes, self.alloc) catch return error.WasmValidationError;
        defer {
            var m = module;
            m.deinit();
        }
        return module.hash;
    }
};

fn extractParamTypes(parsed: ast.ParsedQuery, alloc: std.mem.Allocator) ![]const ast.SqlType {
    // If there's a TRANSACTION block, params come from it
    for (parsed.stmts) |stmt| {
        if (stmt == .transaction) {
            const txn = stmt.transaction;
            var types: std.ArrayList(ast.SqlType) = .empty;
            for (txn.params) |p| {
                try types.append(alloc, p.typ);
            }
            return types.toOwnedSlice(alloc);
        }
    }
    // No transaction block — no declared params
    return &.{};
}

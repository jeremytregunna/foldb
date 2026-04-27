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
    /// Database this query belongs to. Used to scope DDL re-validation.
    db_id: u32,
    /// Schema version at registration time (for invalidation on DDL changes).
    schema_seq: u64,
    /// Output column names for SELECT queries, pre-computed at registration time using
    /// the schema as of registration. Empty for non-SELECT queries and DESCRIBE TABLE.
    /// Owned by the arena — freed automatically with it.
    output_column_names: []const []const u8,
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

    /// Validate a SQL string and return its db-scoped QueryHash without registering it.
    /// target_schema is the SchemaRegistry for db_id — callers resolve this via ClusterSchema.
    pub fn validateQueryForDb(self: *SqlRegistry, sql: []const u8, db_id: u32, target_schema: *schema_mod.SchemaRegistry) RegistryError!QueryHash {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const sql_copy = try arena_alloc.dupe(u8, sql);
        const parsed = try parser_mod.parse(sql_copy, arena_alloc);
        const h = try canon.canonicalizeForDb(parsed, db_id, arena_alloc);

        if (self.queries.contains(h)) return h;

        const param_types = try extractParamTypes(parsed, arena_alloc);

        var checker = tc_mod.TypeChecker.init(arena_alloc, target_schema);
        for (parsed.stmts) |stmt| {
            try checker.checkStmt(stmt, param_types, true);
        }

        var planner = plan_mod.Planner.init(arena_alloc, target_schema);
        if (parsed.stmts.len == 1 and parsed.stmts[0] == .transaction) {
            _ = try planner.planTransaction(parsed.stmts[0].transaction);
        } else {
            for (parsed.stmts) |s| {
                _ = try planner.planAstStmt(s);
            }
        }

        return h;
    }

    /// Validate a SQL string using the default database scope.
    pub fn validateQuery(self: *SqlRegistry, sql: []const u8) RegistryError!QueryHash {
        return self.validateQueryForDb(sql, schema_mod.default_database_id, self.schema);
    }

    /// Register a SQL string, returning its QueryHash.
    /// Rejects SELECT * in registered queries.
    /// Idempotent: registering the same SQL twice returns the same hash.
    // This is the SQL frontend domain boundary — raw client SQL enters here and must pass
    // parse, canonicalization, type-checking, and planning before entering the domain core.
    // All data past this point is validated; the resulting ExecutionPlan is a pure domain type.
    /// Register a SQL string scoped to a database. The hash incorporates the
    /// database_id so the same SQL in two databases gets different hashes.
    /// target_schema is the SchemaRegistry for db_id — callers resolve this via ClusterSchema.
    pub fn registerForDb(self: *SqlRegistry, sql: []const u8, db_id: u32, target_schema: *schema_mod.SchemaRegistry) RegistryError!QueryHash {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        const arena_alloc = arena.allocator();

        const sql_copy = arena_alloc.dupe(u8, sql) catch |e| { arena.deinit(); return e; };
        const parsed = parser_mod.parse(sql_copy, arena_alloc) catch |e| { arena.deinit(); return e; };
        const h = canon.canonicalizeForDb(parsed, db_id, arena_alloc) catch |e| { arena.deinit(); return e; };

        if (self.queries.contains(h)) { arena.deinit(); return h; }

        const param_types = extractParamTypes(parsed, arena_alloc) catch |e| { arena.deinit(); return e; };

        var checker = tc_mod.TypeChecker.init(arena_alloc, target_schema);
        for (parsed.stmts) |stmt| {
            checker.checkStmt(stmt, param_types, true) catch |e| { arena.deinit(); return e; };
        }

        var planner = plan_mod.Planner.init(arena_alloc, target_schema);
        const exec_plan = if (parsed.stmts.len == 1 and parsed.stmts[0] == .transaction)
            planner.planTransaction(parsed.stmts[0].transaction) catch |e| { arena.deinit(); return e; }
        else blk: {
            var stmts: std.ArrayList(plan_mod.StmtPlan) = .empty;
            for (parsed.stmts) |s| {
                const sp = planner.planAstStmt(s) catch |e| { arena.deinit(); return e; };
                stmts.append(arena_alloc, sp) catch |e| { arena.deinit(); return e; };
            }
            break :blk plan_mod.ExecutionPlan{
                .stmts = stmts.toOwnedSlice(arena_alloc) catch |e| { arena.deinit(); return e; },
                .param_types = param_types,
                .nondet_count = planner.nondet_idx,
            };
        };

        const output_column_names: []const []const u8 = if (exec_plan.stmts.len > 0 and exec_plan.stmts[0] == .select)
            extractPlanColumnNames(exec_plan.stmts[0].select, target_schema, arena_alloc) catch &.{}
        else
            &.{};

        const rq = self.alloc.create(RegisteredQuery) catch |e| { arena.deinit(); return e; };
        rq.* = .{
            .hash = h,
            .sql_text = sql_copy,
            .plan = exec_plan,
            .param_types = param_types,
            .nondet_count = exec_plan.nondet_count,
            .db_id = db_id,
            .schema_seq = self.schema_seq,
            .output_column_names = output_column_names,
            .arena = arena,
        };
        self.queries.put(h, rq) catch |e| {
            rq.arena.deinit();
            self.alloc.destroy(rq);
            return e;
        };
        return h;
    }

    /// Register a SQL string in the default database. Delegates to registerForDb.
    pub fn register(self: *SqlRegistry, sql: []const u8) RegistryError!QueryHash {
        return self.registerForDb(sql, schema_mod.default_database_id, self.schema);
    }

    pub fn lookup(self: *const SqlRegistry, h: QueryHash) ?*const RegisteredQuery {
        return self.queries.get(h);
    }

    /// Remove all queries registered under the given database id.
    /// Called when a database is dropped so its query memory is reclaimed.
    pub fn evictQueriesForDb(self: *SqlRegistry, db_id: u32) void {
        var to_evict: std.ArrayListUnmanaged(QueryHash) = .empty;
        defer to_evict.deinit(self.alloc);
        var it = self.queries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.db_id == db_id)
                to_evict.append(self.alloc, entry.key_ptr.*) catch continue;
        }
        for (to_evict.items) |h| {
            if (self.queries.fetchRemove(h)) |kv| {
                kv.value.deinit();
                self.alloc.destroy(kv.value);
            }
        }
    }

    /// Remove a registered query by hash. No-op if the hash is not registered.
    pub fn unregister(self: *SqlRegistry, h: QueryHash) void {
        if (self.queries.fetchRemove(h)) |entry| {
            entry.value.deinit();
            self.alloc.destroy(entry.value);
        }
    }

    /// Apply DDL to the schema registry, bumping schema_seq.
    /// Validates that no registered queries would break.
    pub fn applyDdl(self: *SqlRegistry, stmt: ast.Stmt) RegistryError!void {
        return self.applyDdlForDbSchema(stmt, schema_mod.default_database_id, self.schema);
    }

    /// Apply DDL to a specific SchemaRegistry (may differ from self.schema for multi-db).
    /// Only re-validates queries belonging to target_db_id so cross-db DDL never incorrectly
    /// evicts or rejects queries from other databases.
    pub fn applyDdlToSchema(self: *SqlRegistry, stmt: ast.Stmt, target: *schema_mod.SchemaRegistry) RegistryError!void {
        return self.applyDdlForDbSchema(stmt, schema_mod.default_database_id, target);
    }

    /// Internal: apply DDL to target, re-validating only queries with matching db_id.
    pub fn applyDdlForDbSchema(self: *SqlRegistry, stmt: ast.Stmt, target_db_id: u32, target: *schema_mod.SchemaRegistry) RegistryError!void {
        switch (stmt) {
            .create_table => |s| {
                _ = try target.createTable(s);
            },
            .create_index => |s| {
                try target.createIndex(s);
            },
            .alter_table => |s| {
                switch (s.action) {
                    .add_column => |col| try target.addColumn(s.table, col),
                    .drop_column => |col| try target.dropColumn(s.table, col),
                }
            },
            .drop_table => |s| {
                _ = try target.dropTable(s.name);
            },
            else => return error.TypeCheckError,
        }
        self.schema_seq += 1;

        // Re-validate registered queries that belong to this database against the new schema.
        // DROP TABLE evicts broken queries; other DDL rejects if queries would break.
        const evict_broken = (stmt == .drop_table);
        var to_evict: std.ArrayList(QueryHash) = .empty;
        defer to_evict.deinit(self.alloc);
        var it = self.queries.iterator();
        while (it.next()) |entry| {
            const rq = entry.value_ptr.*;
            if (rq.db_id != target_db_id) continue; // skip queries from other databases
            var tmp_arena = std.heap.ArenaAllocator.init(self.alloc);
            defer tmp_arena.deinit();
            const parsed = parser_mod.parse(rq.sql_text, tmp_arena.allocator()) catch {
                if (evict_broken) {
                    try to_evict.append(self.alloc, entry.key_ptr.*);
                    continue;
                }
                return error.SchemaBreakingChange;
            };
            var checker = tc_mod.TypeChecker.init(tmp_arena.allocator(), target);
            var broken = false;
            for (parsed.stmts) |s| {
                checker.checkStmt(s, rq.param_types, true) catch {
                    broken = true;
                    break;
                };
            }
            if (broken) {
                if (evict_broken) {
                    try to_evict.append(self.alloc, entry.key_ptr.*);
                } else return error.SchemaBreakingChange;
            }
        }
        for (to_evict.items) |h| {
            if (self.queries.fetchRemove(h)) |kv| {
                kv.value.deinit();
                self.alloc.destroy(kv.value);
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

/// Compute the canonical hash of a SQL string without storing it in the registry.
/// Safe to call from any thread — pure computation with no shared state.
pub fn computeQueryHash(sql: []const u8, alloc: std.mem.Allocator) !QueryHash {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const sql_copy = try arena_alloc.dupe(u8, sql);
    const parsed = try parser_mod.parse(sql_copy, arena_alloc);
    return canon.canonicalize(parsed, arena_alloc);
}

/// Extract output column names from a SELECT plan node using the schema at registration time.
/// Returns an arena-allocated slice; caller must ensure the arena outlives the slice.
fn extractPlanColumnNames(
    node: *const plan_mod.PlanNode,
    schema: *const schema_mod.SchemaRegistry,
    alloc: std.mem.Allocator,
) ![]const []const u8 {
    switch (node.*) {
        .project => |p| {
            const names = try alloc.alloc([]const u8, p.exprs.len);
            for (p.exprs, 0..) |item, i| names[i] = try alloc.dupe(u8, item.alias);
            return names;
        },
        .scan => |s| {
            const tbl = schema.getTableById(s.table_id) orelse return &.{};
            const names = try alloc.alloc([]const u8, s.columns.len);
            for (s.columns, 0..) |col_id, i| {
                const col = tbl.columnById(col_id);
                names[i] = if (col) |c| try alloc.dupe(u8, c.name) else try std.fmt.allocPrint(alloc, "col{d}", .{i});
            }
            return names;
        },
        .ann_scan => |s| {
            const tbl = schema.getTableById(s.table_id) orelse return &.{};
            const names = try alloc.alloc([]const u8, s.columns.len);
            for (s.columns, 0..) |col_id, i| {
                const col = tbl.columnById(col_id);
                names[i] = if (col) |c| try alloc.dupe(u8, c.name) else try std.fmt.allocPrint(alloc, "col{d}", .{i});
            }
            return names;
        },
        .pk_lookup => |pk| {
            const tbl = schema.getTableById(pk.table_id) orelse return &.{};
            const names = try alloc.alloc([]const u8, pk.columns.len);
            for (pk.columns, 0..) |col_id, i| {
                const col = tbl.columnById(col_id);
                names[i] = if (col) |c| try alloc.dupe(u8, c.name) else try std.fmt.allocPrint(alloc, "col{d}", .{i});
            }
            return names;
        },
        .filter => |f| return extractPlanColumnNames(f.input, schema, alloc),
        .sort => |s| return extractPlanColumnNames(s.input, schema, alloc),
        .limit => |l| return extractPlanColumnNames(l.input, schema, alloc),
        else => return &.{},
    }
}

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

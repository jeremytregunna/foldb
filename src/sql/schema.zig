/// Schema registry: tracks tables, columns, and indexes.
const std = @import("std");
const ast = @import("ast.zig");

const assert = std.debug.assert;

pub const TableId = u32;
pub const IndexId = u32;
pub const ColumnId = u16;

/// Literal default value for a column. Owned by the schema allocator.
pub const ColumnDefault = union(enum) {
    int_val: i128,
    float_val: ast.Decimal,
    string_val: []const u8,
    bool_val: bool,
    null_val: void,
};

pub const ColumnSchema = struct {
    id: ColumnId,
    name: []const u8,
    typ: ast.SqlType,
    nullable: ast.NullConstraint,
    /// Schema-defined default value (literal only). Owned.
    default_value: ?ColumnDefault = null,
    /// Column-level UNIQUE constraint.
    unique: bool = false,
    /// CHECK constraint expression. Deep-copied into schema allocator.
    check_expr: ?*ast.Expr = null,
};

/// Deep-copy an Expr tree into alloc. The result is owned by alloc.
pub fn dupeExpr(alloc: std.mem.Allocator, expr: *const ast.Expr) std.mem.Allocator.Error!*ast.Expr {
    const copy = try alloc.create(ast.Expr);
    copy.* = switch (expr.*) {
        .lit_int, .lit_float, .lit_bool, .lit_null, .param, .nondet => expr.*,
        .lit_string => |s| .{ .lit_string = try alloc.dupe(u8, s) },
        .lit_bytes => |b| .{ .lit_bytes = try alloc.dupe(u8, b) },
        .column_ref => |r| .{ .column_ref = .{
            .table = if (r.table) |t| try alloc.dupe(u8, t) else null,
            .column = try alloc.dupe(u8, r.column),
        } },
        .binary => |b| .{ .binary = .{
            .op = b.op,
            .left = try dupeExpr(alloc, b.left),
            .right = try dupeExpr(alloc, b.right),
        } },
        .unary => |u| .{ .unary = .{ .op = u.op, .expr = try dupeExpr(alloc, u.expr) } },
        .is_null => |e| .{ .is_null = try dupeExpr(alloc, e) },
        .is_not_null => |e| .{ .is_not_null = try dupeExpr(alloc, e) },
        .is_distinct => |d| .{ .is_distinct = .{
            .left = try dupeExpr(alloc, d.left),
            .right = try dupeExpr(alloc, d.right),
        } },
        .is_not_distinct => |d| .{ .is_not_distinct = .{
            .left = try dupeExpr(alloc, d.left),
            .right = try dupeExpr(alloc, d.right),
        } },
        .between => |b| .{ .between = .{
            .expr = try dupeExpr(alloc, b.expr),
            .low = try dupeExpr(alloc, b.low),
            .high = try dupeExpr(alloc, b.high),
        } },
        .in_list => |il| blk: {
            const vals = try alloc.alloc(*ast.Expr, il.values.len);
            for (il.values, 0..) |v, i| vals[i] = try dupeExpr(alloc, v);
            break :blk .{ .in_list = .{ .expr = try dupeExpr(alloc, il.expr), .values = vals } };
        },
        .not_in_list => |il| blk: {
            const vals = try alloc.alloc(*ast.Expr, il.values.len);
            for (il.values, 0..) |v, i| vals[i] = try dupeExpr(alloc, v);
            break :blk .{ .not_in_list = .{ .expr = try dupeExpr(alloc, il.expr), .values = vals } };
        },
        // Unsupported in constraints (subqueries, aggregates, window functions, etc.)
        else => expr.*,
    };
    return copy;
}

/// Recursively free an Expr tree previously created by dupeExpr.
pub fn freeExpr(alloc: std.mem.Allocator, expr: *ast.Expr) void {
    switch (expr.*) {
        .lit_string => |s| alloc.free(s),
        .lit_bytes => |b| alloc.free(b),
        .column_ref => |r| {
            if (r.table) |t| alloc.free(t);
            alloc.free(r.column);
        },
        .binary => |b| { freeExpr(alloc, b.left); freeExpr(alloc, b.right); },
        .unary => |u| freeExpr(alloc, u.expr),
        .is_null => |e| freeExpr(alloc, e),
        .is_not_null => |e| freeExpr(alloc, e),
        .is_distinct => |d| { freeExpr(alloc, d.left); freeExpr(alloc, d.right); },
        .is_not_distinct => |d| { freeExpr(alloc, d.left); freeExpr(alloc, d.right); },
        .between => |b| { freeExpr(alloc, b.expr); freeExpr(alloc, b.low); freeExpr(alloc, b.high); },
        .in_list => |il| {
            freeExpr(alloc, il.expr);
            for (il.values) |v| freeExpr(alloc, v);
            alloc.free(il.values);
        },
        .not_in_list => |il| {
            freeExpr(alloc, il.expr);
            for (il.values) |v| freeExpr(alloc, v);
            alloc.free(il.values);
        },
        else => {},
    }
    alloc.destroy(expr);
}

pub const IndexKind = enum { ordered, hash, vector, json_path };

pub const IndexSchema = struct {
    id: IndexId,
    name: []const u8,
    kind: IndexKind,
    unique: bool,
    columns: []const ColumnId,
    // For vector indexes: dimension; for json_path: path strings
    extra: IndexExtra,
};

pub const IndexExtra = union(enum) {
    none,
    vector_dim: u32,
    json_paths: []const []const u8,
};

pub const ForeignKeySchema = struct {
    name: ?[]const u8,
    columns: []const ColumnId,
    ref_table_id: TableId,
    ref_columns: []const ColumnId,
};

pub const InboundForeignKey = struct {
    source_table_id: TableId,
    fk: *const ForeignKeySchema,
};

pub const TableSchema = struct {
    id: TableId,
    name: []const u8,
    columns: []const ColumnSchema,
    primary_key: []const ColumnId,
    indexes: []const IndexSchema,
    foreign_keys: []const ForeignKeySchema = &.{},

    pub fn columnByName(self: *const TableSchema, name: []const u8) ?*const ColumnSchema {
        for (self.columns) |*col| {
            if (std.ascii.eqlIgnoreCase(col.name, name)) return col;
        }
        return null;
    }

    pub fn columnById(self: *const TableSchema, id: ColumnId) ?*const ColumnSchema {
        for (self.columns) |*col| {
            if (col.id == id) return col;
        }
        return null;
    }
};

pub const SchemaError = error{
    TableAlreadyExists,
    TableNotFound,
    ColumnAlreadyExists,
    ColumnNotFound,
    IndexAlreadyExists,
    IndexNotFound,
    NoPrimaryKey,
    PrimaryKeyColumnNotFound,
    DuplicatePrimaryKeyColumn,
    InvalidForeignKey,
    ForeignKeyViolation,
    OutOfMemory,
};

pub const SchemaRegistry = struct {
    tables: std.StringHashMap(*TableSchema),
    tables_by_id: std.AutoHashMap(TableId, *TableSchema),
    next_table_id: TableId,
    next_index_id: IndexId,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SchemaRegistry {
        return .{
            .tables = std.StringHashMap(*TableSchema).init(alloc),
            .tables_by_id = std.AutoHashMap(TableId, *TableSchema).init(alloc),
            .next_table_id = 1,
            .next_index_id = 1,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            const tbl = entry.value_ptr.*;
            for (tbl.columns) |col| {
                self.alloc.free(col.name);
                if (col.default_value) |dv| if (dv == .string_val) self.alloc.free(dv.string_val);
                if (col.check_expr) |ce| freeExpr(self.alloc, ce);
            }
            self.alloc.free(tbl.columns);
            self.alloc.free(tbl.primary_key);
            for (tbl.indexes) |idx| {
                self.alloc.free(idx.name);
                self.alloc.free(idx.columns);
                switch (idx.extra) {
                    .json_paths => |paths| self.alloc.free(paths),
                    else => {},
                }
            }
            self.alloc.free(tbl.indexes);
            for (tbl.foreign_keys) |fk| {
                if (fk.name) |n| self.alloc.free(n);
                self.alloc.free(fk.columns);
                self.alloc.free(fk.ref_columns);
            }
            if (tbl.foreign_keys.len > 0) self.alloc.free(tbl.foreign_keys);
            self.alloc.free(tbl.name);
            self.alloc.destroy(tbl);
        }
        self.tables.deinit();
        self.tables_by_id.deinit();
    }

    pub fn getTable(self: *const SchemaRegistry, name: []const u8) ?*const TableSchema {
        return self.tables.get(name);
    }

    pub fn getTableById(self: *const SchemaRegistry, id: TableId) ?*const TableSchema {
        return self.tables_by_id.get(id);
    }

    /// Collect all FKs across all tables that reference the given table_id.
    pub fn getInboundForeignKeys(self: *const SchemaRegistry, table_id: TableId, alloc: std.mem.Allocator) ![]InboundForeignKey {
        var result: std.ArrayList(InboundForeignKey) = .empty;
        var it = self.tables_by_id.iterator();
        while (it.next()) |entry| {
            const tbl = entry.value_ptr.*;
            for (tbl.foreign_keys) |*fk| {
                if (fk.ref_table_id == table_id) {
                    try result.append(alloc, .{ .source_table_id = tbl.id, .fk = fk });
                }
            }
        }
        return result.toOwnedSlice(alloc);
    }

    /// Apply a CREATE TABLE statement to the schema.
    pub fn createTable(self: *SchemaRegistry, stmt: ast.CreateTableStmt) SchemaError!*const TableSchema {
        if (self.tables.contains(stmt.name)) return error.TableAlreadyExists;
        if (stmt.primary_key.columns.len == 0) return error.NoPrimaryKey;

        // Assign column IDs
        const cols = try self.alloc.alloc(ColumnSchema, stmt.columns.len);
        errdefer self.alloc.free(cols);
        var cols_named: usize = 0;
        errdefer for (cols[0..cols_named]) |c| self.alloc.free(c.name);
        for (stmt.columns, 0..) |col_def, i| {
            const default_val: ?ColumnDefault = if (col_def.default_value) |dv| blk: {
                break :blk switch (dv.*) {
                    .lit_int => |n| .{ .int_val = n },
                    .lit_float => |f| .{ .float_val = f },
                    .lit_bool => |b| .{ .bool_val = b },
                    .lit_null => .null_val,
                    .lit_string => |s| .{ .string_val = try self.alloc.dupe(u8, s) },
                    else => null, // non-literal defaults ignored at schema level
                };
            } else null;
            const check: ?*ast.Expr = if (col_def.check_expr) |ce|
                try dupeExpr(self.alloc, ce)
            else
                null;
            cols[i] = .{
                .id = @intCast(i),
                .name = try self.alloc.dupe(u8, col_def.name),
                .typ = col_def.typ,
                .nullable = col_def.nullable,
                .default_value = default_val,
                .unique = col_def.unique,
                .check_expr = check,
            };
            cols_named += 1;
        }

        // Map PK column names to IDs
        const pk_ids = try self.alloc.alloc(ColumnId, stmt.primary_key.columns.len);
        errdefer self.alloc.free(pk_ids);
        var seen = std.AutoHashMap(ColumnId, void).init(self.alloc);
        defer seen.deinit();
        for (stmt.primary_key.columns, 0..) |pk_name, i| {
            var found = false;
            for (cols) |col| {
                if (std.ascii.eqlIgnoreCase(col.name, pk_name)) {
                    if (seen.contains(col.id)) return error.DuplicatePrimaryKeyColumn;
                    try seen.put(col.id, {});
                    pk_ids[i] = col.id;
                    found = true;
                    break;
                }
            }
            if (!found) return error.PrimaryKeyColumnNotFound;
        }

        // Resolve foreign key constraints
        const fk_schemas = try self.alloc.alloc(ForeignKeySchema, stmt.foreign_keys.len);
        errdefer self.alloc.free(fk_schemas);
        var fks_resolved: usize = 0;
        errdefer for (fk_schemas[0..fks_resolved]) |fk| {
            if (fk.name) |n| self.alloc.free(n);
            self.alloc.free(fk.columns);
            self.alloc.free(fk.ref_columns);
        };
        for (stmt.foreign_keys, 0..) |fk_def, fi| {
            const ref_tbl = self.tables.get(fk_def.ref_table) orelse return error.InvalidForeignKey;
            if (fk_def.columns.len == 0 or fk_def.columns.len != fk_def.ref_columns.len)
                return error.InvalidForeignKey;

            const local_ids = try self.alloc.alloc(ColumnId, fk_def.columns.len);
            errdefer self.alloc.free(local_ids);
            for (fk_def.columns, 0..) |col_name, i| {
                var found = false;
                for (cols) |col| {
                    if (std.ascii.eqlIgnoreCase(col.name, col_name)) {
                        local_ids[i] = col.id;
                        found = true;
                        break;
                    }
                }
                if (!found) return error.InvalidForeignKey;
            }

            const ref_ids = try self.alloc.alloc(ColumnId, fk_def.ref_columns.len);
            errdefer self.alloc.free(ref_ids);
            for (fk_def.ref_columns, 0..) |col_name, i| {
                const col = ref_tbl.columnByName(col_name) orelse return error.InvalidForeignKey;
                ref_ids[i] = col.id;
            }

            const fk_name: ?[]const u8 = if (fk_def.name) |n| try self.alloc.dupe(u8, n) else null;
            fk_schemas[fi] = .{
                .name = fk_name,
                .columns = local_ids,
                .ref_table_id = ref_tbl.id,
                .ref_columns = ref_ids,
            };
            fks_resolved += 1;
        }

        const tbl_name = try self.alloc.dupe(u8, stmt.name);
        errdefer self.alloc.free(tbl_name);
        const tbl = try self.alloc.create(TableSchema);
        errdefer self.alloc.destroy(tbl);
        tbl.* = .{
            .id = self.next_table_id,
            .name = tbl_name,
            .columns = cols,
            .primary_key = pk_ids,
            .indexes = &.{},
            .foreign_keys = fk_schemas,
        };
        self.next_table_id += 1;

        try self.tables.put(tbl_name, tbl);
        try self.tables_by_id.put(tbl.id, tbl);
        return tbl;
    }

    /// Apply a CREATE INDEX statement.
    pub fn createIndex(self: *SchemaRegistry, stmt: ast.CreateIndexStmt) SchemaError!void {
        const tbl = self.tables.get(stmt.table) orelse return error.TableNotFound;

        // Check for duplicate index name
        for (tbl.indexes) |idx| {
            if (std.ascii.eqlIgnoreCase(idx.name, stmt.name)) return error.IndexAlreadyExists;
        }

        // Map column names to IDs
        const col_ids = try self.alloc.alloc(ColumnId, stmt.columns.len);
        errdefer self.alloc.free(col_ids);
        for (stmt.columns, 0..) |col_name, i| {
            const col = tbl.columnByName(col_name) orelse return error.ColumnNotFound;
            col_ids[i] = col.id;
        }

        const kind: IndexKind = switch (stmt.kind) {
            .ordered => .ordered,
            .hash => .hash,
            .vector => .vector,
            .json_path => .json_path,
        };
        const extra: IndexExtra = switch (stmt.kind) {
            .vector => |dim| .{ .vector_dim = dim },
            .json_path => |paths| .{ .json_paths = paths },
            else => .none,
        };

        const idx_name = try self.alloc.dupe(u8, stmt.name);
        errdefer self.alloc.free(idx_name);
        const new_idx = IndexSchema{
            .id = self.next_index_id,
            .name = idx_name,
            .kind = kind,
            .unique = stmt.unique,
            .columns = col_ids,
            .extra = extra,
        };
        self.next_index_id += 1;

        const new_indexes = try self.alloc.alloc(IndexSchema, tbl.indexes.len + 1);
        @memcpy(new_indexes[0..tbl.indexes.len], tbl.indexes);
        new_indexes[tbl.indexes.len] = new_idx;
        if (tbl.indexes.len > 0) self.alloc.free(tbl.indexes);
        tbl.indexes = new_indexes;
    }

    /// Apply ALTER TABLE ADD COLUMN.
    pub fn addColumn(self: *SchemaRegistry, table: []const u8, col_def: ast.ColumnDef) SchemaError!void {
        const tbl = self.tables.get(table) orelse return error.TableNotFound;
        for (tbl.columns) |col| {
            if (std.ascii.eqlIgnoreCase(col.name, col_def.name)) return error.ColumnAlreadyExists;
        }
        const new_id: ColumnId = @intCast(tbl.columns.len);
        const new_cols = try self.alloc.alloc(ColumnSchema, tbl.columns.len + 1);
        @memcpy(new_cols[0..tbl.columns.len], tbl.columns);
        new_cols[tbl.columns.len] = .{
            .id = new_id,
            .name = try self.alloc.dupe(u8, col_def.name),
            .typ = col_def.typ,
            .nullable = col_def.nullable,
        };
        if (tbl.columns.len > 0) self.alloc.free(tbl.columns);
        tbl.columns = new_cols;
    }

    /// Apply ALTER TABLE DROP COLUMN.
    pub fn dropColumn(self: *SchemaRegistry, table: []const u8, col_name: []const u8) SchemaError!void {
        const tbl = self.tables.get(table) orelse return error.TableNotFound;
        var idx: ?usize = null;
        for (tbl.columns, 0..) |col, i| {
            if (std.ascii.eqlIgnoreCase(col.name, col_name)) {
                idx = i;
                break;
            }
        }
        const drop_idx = idx orelse return error.ColumnNotFound;
        self.alloc.free(tbl.columns[drop_idx].name);
        const new_cols = try self.alloc.alloc(ColumnSchema, tbl.columns.len - 1);
        var j: usize = 0;
        for (tbl.columns, 0..) |col, i| {
            if (i != drop_idx) {
                new_cols[j] = col;
                j += 1;
            }
        }
        self.alloc.free(tbl.columns);
        tbl.columns = new_cols;
    }

    /// Drop a table from the schema. Callers must also unregister from storage.
    pub fn dropTable(self: *SchemaRegistry, name: []const u8) SchemaError!TableId {
        assert(name.len > 0);
        const tbl = self.tables.get(name) orelse return error.TableNotFound;
        const id = tbl.id;
        assert(id > 0);
        _ = self.tables.remove(name);
        _ = self.tables_by_id.remove(id);
        for (tbl.columns) |col| self.alloc.free(col.name);
        self.alloc.free(tbl.columns);
        self.alloc.free(tbl.primary_key);
        for (tbl.indexes) |idx| {
            self.alloc.free(idx.columns);
            switch (idx.extra) {
                .json_paths => |paths| self.alloc.free(paths),
                else => {},
            }
        }
        self.alloc.free(tbl.indexes);
        for (tbl.foreign_keys) |fk| {
            if (fk.name) |n| self.alloc.free(n);
            self.alloc.free(fk.columns);
            self.alloc.free(fk.ref_columns);
        }
        if (tbl.foreign_keys.len > 0) self.alloc.free(tbl.foreign_keys);
        self.alloc.free(tbl.name);
        self.alloc.destroy(tbl);
        return id;
    }
};

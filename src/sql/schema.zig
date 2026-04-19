/// Schema registry: tracks tables, columns, and indexes.
const std = @import("std");
const ast = @import("ast.zig");

pub const TableId = u32;
pub const IndexId = u32;
pub const ColumnId = u16;

pub const ColumnSchema = struct {
    id: ColumnId,
    name: []const u8,
    typ: ast.SqlType,
    nullable: ast.NullConstraint,
};

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

pub const TableSchema = struct {
    id: TableId,
    name: []const u8,
    columns: []const ColumnSchema,
    primary_key: []const ColumnId,
    indexes: []const IndexSchema,

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
            cols[i] = .{
                .id = @intCast(i),
                .name = try self.alloc.dupe(u8, col_def.name),
                .typ = col_def.typ,
                .nullable = col_def.nullable,
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

        const new_idx = IndexSchema{
            .id = self.next_index_id,
            .name = stmt.name,
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
};

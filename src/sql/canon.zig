/// Deterministic AST canonicalization → BLAKE3 QueryHash.
///
/// Canonical form is a compact tagged byte serialization of the AST.
/// The hash uniquely identifies the query's structure and type signature.
const std = @import("std");
const ast = @import("ast.zig");

pub const QueryHash = [32]u8;

pub const CanonWriter = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) CanonWriter {
        return .{ .buf = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *CanonWriter) void {
        self.buf.deinit(self.alloc);
    }

    pub fn hash(self: *const CanonWriter) QueryHash {
        var h: QueryHash = undefined;
        std.crypto.hash.Blake3.hash(self.buf.items, &h, .{});
        return h;
    }

    fn writeByte(self: *CanonWriter, b: u8) !void {
        try self.buf.append(self.alloc, b);
    }

    fn writeU16(self: *CanonWriter, v: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, v, .little);
        try self.buf.appendSlice(self.alloc, &bytes);
    }

    fn writeU32(self: *CanonWriter, v: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, v, .little);
        try self.buf.appendSlice(self.alloc, &bytes);
    }

    fn writeI64(self: *CanonWriter, v: i64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, v, .little);
        try self.buf.appendSlice(self.alloc, &bytes);
    }

    fn writeI128(self: *CanonWriter, v: i128) !void {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(i128, &bytes, v, .little);
        try self.buf.appendSlice(self.alloc, &bytes);
    }

    fn writeF64(self: *CanonWriter, v: f64) !void {
        const bits = @as(u64, @bitCast(v));
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, bits, .little);
        try self.buf.appendSlice(self.alloc, &bytes);
    }

    fn writeStr(self: *CanonWriter, s: []const u8) !void {
        try self.writeU32(@intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
    }

    // ─── Canonicalize a full parsed query ────────────────────────────────

    pub fn writeQuery(self: *CanonWriter, q: ast.ParsedQuery) !void {
        try self.writeU32(@intCast(q.stmts.len));
        for (q.stmts) |s| {
            try self.writeStmt(s);
        }
    }

    pub fn writeTransaction(self: *CanonWriter, txn: ast.TransactionBlock) !void {
        try self.writeByte(0x20);
        try self.writeU32(@intCast(txn.params.len));
        for (txn.params) |p| {
            try self.writeStr(p.name);
            try self.writeType(p.typ);
        }
        try self.writeU32(@intCast(txn.stmts.len));
        for (txn.stmts) |s| {
            try self.writeTxnStmt(s);
        }
    }

    fn writeStmt(self: *CanonWriter, s: ast.Stmt) !void {
        switch (s) {
            .select      => |q| { try self.writeByte(0x01); try self.writeSelect(q); },
            .insert      => |q| { try self.writeByte(0x02); try self.writeInsert(q); },
            .update      => |q| { try self.writeByte(0x03); try self.writeUpdate(q); },
            .delete      => |q| { try self.writeByte(0x04); try self.writeDelete(q); },
            .merge       => |q| { try self.writeByte(0x05); try self.writeMerge(q); },
            .create_table => |q| { try self.writeByte(0x10); try self.writeCreateTable(q); },
            .create_index => |q| { try self.writeByte(0x11); try self.writeCreateIndex(q); },
            .alter_table  => |q| { try self.writeByte(0x12); try self.writeAlterTable(q); },
            .transaction  => |q| { try self.writeByte(0x20); try self.writeTransaction(q); },
        }
    }

    fn writeTxnStmt(self: *CanonWriter, s: ast.TxnStmt) !void {
        switch (s) {
            .select => |q| { try self.writeByte(0x01); try self.writeSelect(q); },
            .insert => |q| { try self.writeByte(0x02); try self.writeInsert(q); },
            .update => |q| { try self.writeByte(0x03); try self.writeUpdate(q); },
            .delete => |q| { try self.writeByte(0x04); try self.writeDelete(q); },
            .merge  => |q| { try self.writeByte(0x05); try self.writeMerge(q); },
            .assert => |e| { try self.writeByte(0x06); try self.writeExpr(e);   },
        }
    }

    fn writeType(self: *CanonWriter, t: ast.SqlType) !void {
        switch (t) {
            .bool           => try self.writeByte(0x00),
            .int8           => |ov| { try self.writeByte(0x01); try self.writeByte(@intFromEnum(ov)); },
            .int16          => |ov| { try self.writeByte(0x02); try self.writeByte(@intFromEnum(ov)); },
            .int32          => |ov| { try self.writeByte(0x03); try self.writeByte(@intFromEnum(ov)); },
            .int64          => |ov| { try self.writeByte(0x04); try self.writeByte(@intFromEnum(ov)); },
            .uint8          => |ov| { try self.writeByte(0x05); try self.writeByte(@intFromEnum(ov)); },
            .uint16         => |ov| { try self.writeByte(0x06); try self.writeByte(@intFromEnum(ov)); },
            .uint32         => |ov| { try self.writeByte(0x07); try self.writeByte(@intFromEnum(ov)); },
            .uint64         => |ov| { try self.writeByte(0x08); try self.writeByte(@intFromEnum(ov)); },
            .float32        => try self.writeByte(0x09),
            .float64        => try self.writeByte(0x0A),
            .decimal        => |d| { try self.writeByte(0x0B); try self.writeByte(d.precision); try self.writeByte(d.scale); },
            .string         => try self.writeByte(0x0C),
            .bytes          => try self.writeByte(0x0D),
            .uuid           => try self.writeByte(0x0E),
            .timestamp      => try self.writeByte(0x0F),
            .interval_months => try self.writeByte(0x10),
            .interval_micros => try self.writeByte(0x11),
            .json           => try self.writeByte(0x12),
            .vector         => |dim| { try self.writeByte(0x13); try self.writeU32(dim); },
            .array          => |inner| { try self.writeByte(0x14); try self.writeType(inner.*); },
            .struct_type    => |fields| {
                try self.writeByte(0x15);
                try self.writeU32(@intCast(fields.len));
                for (fields) |f| {
                    try self.writeStr(f.name);
                    try self.writeType(f.typ);
                }
            },
            .null_type => try self.writeByte(0xFF),
        }
    }

    fn writeExpr(self: *CanonWriter, e: *ast.Expr) error{OutOfMemory}!void {
        switch (e.*) {
            .lit_int    => |v| { try self.writeByte(0x01); try self.writeI128(v); },
            .lit_float  => |v| { try self.writeByte(0x02); try self.writeF64(v); },
            .lit_string => |v| { try self.writeByte(0x03); try self.writeStr(v); },
            .lit_bytes  => |v| { try self.writeByte(0x04); try self.writeStr(v); },
            .lit_bool   => |v| { try self.writeByte(0x05); try self.writeByte(if (v) 1 else 0); },
            .lit_null   =>       try self.writeByte(0x06),
            .param      => |i| { try self.writeByte(0x07); try self.writeU32(i); },
            .nondet     => |k| { try self.writeByte(0x08); try self.writeByte(@intFromEnum(k)); },
            .column_ref => |r| {
                try self.writeByte(0x09);
                try self.writeByte(if (r.table != null) 1 else 0);
                if (r.table) |t| try self.writeStr(t);
                try self.writeStr(r.column);
            },
            .cast => |c| {
                try self.writeByte(0x0A);
                try self.writeExpr(c.expr);
                try self.writeType(c.to);
            },
            .binary => |b| {
                try self.writeByte(0x0B);
                try self.writeByte(@intFromEnum(b.op));
                try self.writeExpr(b.left);
                try self.writeExpr(b.right);
            },
            .unary => |u| {
                try self.writeByte(0x0C);
                try self.writeByte(@intFromEnum(u.op));
                try self.writeExpr(u.expr);
            },
            .is_null         => |inner| { try self.writeByte(0x0D); try self.writeExpr(inner); },
            .is_not_null     => |inner| { try self.writeByte(0x0E); try self.writeExpr(inner); },
            .is_distinct     => |pair| { try self.writeByte(0x0F); try self.writeExpr(pair.left); try self.writeExpr(pair.right); },
            .is_not_distinct => |pair| { try self.writeByte(0x10); try self.writeExpr(pair.left); try self.writeExpr(pair.right); },
            .between => |b| {
                try self.writeByte(0x11);
                try self.writeExpr(b.expr);
                try self.writeExpr(b.low);
                try self.writeExpr(b.high);
            },
            .like => |l| {
                try self.writeByte(0x12);
                try self.writeExpr(l.expr);
                try self.writeExpr(l.pattern);
            },
            .in_list => |il| {
                try self.writeByte(0x13);
                try self.writeExpr(il.expr);
                try self.writeU32(@intCast(il.values.len));
                for (il.values) |v| try self.writeExpr(v);
            },
            .not_in_list => |il| {
                try self.writeByte(0x14);
                try self.writeExpr(il.expr);
                try self.writeU32(@intCast(il.values.len));
                for (il.values) |v| try self.writeExpr(v);
            },
            .in_subquery     => |s| { try self.writeByte(0x15); try self.writeExpr(s.expr); try self.writeSelect(s.query.*); },
            .not_in_subquery => |s| { try self.writeByte(0x16); try self.writeExpr(s.expr); try self.writeSelect(s.query.*); },
            .exists     => |q| { try self.writeByte(0x17); try self.writeSelect(q.*); },
            .not_exists => |q| { try self.writeByte(0x18); try self.writeSelect(q.*); },
            .case_searched => |c| {
                try self.writeByte(0x19);
                try self.writeU32(@intCast(c.whens.len));
                for (c.whens) |w| { try self.writeExpr(w.cond); try self.writeExpr(w.result); }
                try self.writeByte(if (c.else_expr != null) 1 else 0);
                if (c.else_expr) |ee| try self.writeExpr(ee);
            },
            .case_simple => |c| {
                try self.writeByte(0x1A);
                try self.writeExpr(c.operand);
                try self.writeU32(@intCast(c.whens.len));
                for (c.whens) |w| { try self.writeExpr(w.cond); try self.writeExpr(w.result); }
                try self.writeByte(if (c.else_expr != null) 1 else 0);
                if (c.else_expr) |ee| try self.writeExpr(ee);
            },
            .fn_call => |f| {
                try self.writeByte(0x1B);
                try self.writeStr(f.name);
                try self.writeByte(if (f.distinct) 1 else 0);
                try self.writeByte(if (f.star) 1 else 0);
                try self.writeU32(@intCast(f.args.len));
                for (f.args) |a| try self.writeExpr(a);
            },
            .window_fn => |w| {
                try self.writeByte(0x1C);
                try self.writeStr(w.call.name);
                try self.writeU32(@intCast(w.call.args.len));
                for (w.call.args) |a| try self.writeExpr(a);
                // Canonicalize window spec
                try self.writeU32(@intCast(w.window.partition_by.len));
                for (w.window.partition_by) |p| try self.writeExpr(p);
                try self.writeU32(@intCast(w.window.order_by.len));
                for (w.window.order_by) |ob| {
                    try self.writeExpr(ob.expr);
                    try self.writeByte(if (ob.asc) 1 else 0);
                }
            },
            .subquery => |q| { try self.writeByte(0x1D); try self.writeSelect(q.*); },
            .typed    => |t| try self.writeExpr(t.inner),
        }
    }

    fn writeSelect(self: *CanonWriter, q: ast.SelectStmt) error{OutOfMemory}!void {
        try self.writeByte(if (q.distinct) 1 else 0);
        try self.writeU32(@intCast(q.items.len));
        for (q.items) |item| {
            switch (item) {
                .star => try self.writeByte(0x00),
                .expr => |ei| {
                    try self.writeByte(0x01);
                    try self.writeExpr(ei.expr);
                    try self.writeByte(if (ei.alias != null) 1 else 0);
                    if (ei.alias) |a| try self.writeStr(a);
                },
            }
        }
        try self.writeByte(if (q.from != null) 1 else 0);
        if (q.from) |f| try self.writeTableRef(f);
        try self.writeU32(@intCast(q.joins.len));
        for (q.joins) |j| try self.writeJoin(j);
        try self.writeByte(if (q.where != null) 1 else 0);
        if (q.where) |w| try self.writeExpr(w);
        try self.writeU32(@intCast(q.group_by.len));
        for (q.group_by) |g| try self.writeExpr(g);
        try self.writeByte(if (q.having != null) 1 else 0);
        if (q.having) |h| try self.writeExpr(h);
        try self.writeU32(@intCast(q.order_by.len));
        for (q.order_by) |ob| {
            try self.writeExpr(ob.expr);
            try self.writeByte(if (ob.asc) 1 else 0);
        }
        try self.writeByte(if (q.limit != null) 1 else 0);
        if (q.limit)  |l| try self.writeExpr(l);
        try self.writeByte(if (q.offset != null) 1 else 0);
        if (q.offset) |o| try self.writeExpr(o);
    }

    fn writeTableRef(self: *CanonWriter, tref: ast.TableRef) !void {
        switch (tref) {
            .named => |n| {
                try self.writeByte(0x01);
                try self.writeStr(n.name);
                try self.writeByte(if (n.alias != null) 1 else 0);
                if (n.alias) |a| try self.writeStr(a);
            },
            .subquery => |sq| {
                try self.writeByte(0x02);
                try self.writeSelect(sq.query.*);
                try self.writeStr(sq.alias);
            },
            .cte_ref => |c| {
                try self.writeByte(0x03);
                try self.writeStr(c.name);
            },
        }
    }

    fn writeJoin(self: *CanonWriter, j: ast.Join) !void {
        try self.writeByte(@intFromEnum(j.kind));
        try self.writeTableRef(j.table);
        if (j.condition) |cond| {
            try self.writeByte(1);
            switch (cond) {
                .on    => |e| { try self.writeByte(0); try self.writeExpr(e); },
                .using => |cols| {
                    try self.writeByte(1);
                    try self.writeU32(@intCast(cols.len));
                    for (cols) |c| try self.writeStr(c);
                },
            }
        } else {
            try self.writeByte(0);
        }
    }

    fn writeInsert(self: *CanonWriter, stmt: ast.InsertStmt) !void {
        try self.writeStr(stmt.table);
        try self.writeU32(@intCast(stmt.columns.len));
        for (stmt.columns) |c| try self.writeStr(c);
        switch (stmt.source) {
            .values => |rows| {
                try self.writeByte(0x01);
                try self.writeU32(@intCast(rows.len));
                for (rows) |row| {
                    try self.writeU32(@intCast(row.len));
                    for (row) |e| try self.writeExpr(e);
                }
            },
            .query => |q| { try self.writeByte(0x02); try self.writeSelect(q.*); },
        }
    }

    fn writeUpdate(self: *CanonWriter, stmt: ast.UpdateStmt) !void {
        try self.writeStr(stmt.table);
        try self.writeU32(@intCast(stmt.sets.len));
        for (stmt.sets) |a| {
            try self.writeStr(a.column);
            try self.writeExpr(a.value);
        }
        try self.writeByte(if (stmt.where != null) 1 else 0);
        if (stmt.where) |w| try self.writeExpr(w);
    }

    fn writeDelete(self: *CanonWriter, stmt: ast.DeleteStmt) !void {
        try self.writeStr(stmt.table);
        try self.writeByte(if (stmt.where != null) 1 else 0);
        if (stmt.where) |w| try self.writeExpr(w);
    }

    fn writeMerge(self: *CanonWriter, stmt: ast.MergeStmt) !void {
        try self.writeStr(stmt.target.name);
        try self.writeTableRef(stmt.source.ref);
        try self.writeExpr(stmt.on);
        try self.writeU32(@intCast(stmt.whens.len));
        for (stmt.whens) |w| {
            switch (w) {
                .matched => |m| {
                    try self.writeByte(0x01);
                    try self.writeByte(if (m.cond != null) 1 else 0);
                    if (m.cond) |c| try self.writeExpr(c);
                    switch (m.action) {
                        .update => |sets| {
                            try self.writeByte(0x01);
                            for (sets) |a| { try self.writeStr(a.column); try self.writeExpr(a.value); }
                        },
                        .delete => try self.writeByte(0x02),
                        .do_nothing => try self.writeByte(0x03),
                    }
                },
                .not_matched => |nm| {
                    try self.writeByte(0x02);
                    try self.writeByte(if (nm.cond != null) 1 else 0);
                    if (nm.cond) |c| try self.writeExpr(c);
                    for (nm.values) |v| try self.writeExpr(v);
                },
            }
        }
    }

    fn writeCreateTable(self: *CanonWriter, stmt: ast.CreateTableStmt) !void {
        try self.writeStr(stmt.name);
        try self.writeU32(@intCast(stmt.columns.len));
        for (stmt.columns) |col| {
            try self.writeStr(col.name);
            try self.writeType(col.typ);
            try self.writeByte(@intFromEnum(col.nullable));
        }
        try self.writeU32(@intCast(stmt.primary_key.columns.len));
        for (stmt.primary_key.columns) |c| try self.writeStr(c);
    }

    fn writeCreateIndex(self: *CanonWriter, stmt: ast.CreateIndexStmt) !void {
        try self.writeStr(stmt.name);
        try self.writeByte(if (stmt.unique) 1 else 0);
        try self.writeStr(stmt.table);
        try self.writeU32(@intCast(stmt.columns.len));
        for (stmt.columns) |c| try self.writeStr(c);
    }

    fn writeAlterTable(self: *CanonWriter, stmt: ast.AlterTableStmt) !void {
        try self.writeStr(stmt.table);
        switch (stmt.action) {
            .add_column  => |col| {
                try self.writeByte(0x01);
                try self.writeStr(col.name);
                try self.writeType(col.typ);
                try self.writeByte(@intFromEnum(col.nullable));
            },
            .drop_column => |name| { try self.writeByte(0x02); try self.writeStr(name); },
        }
    }
};

/// Compute a QueryHash for a ParsedQuery.
pub fn canonicalize(q: ast.ParsedQuery, alloc: std.mem.Allocator) !QueryHash {
    var w = CanonWriter.init(alloc);
    defer w.deinit();
    try w.writeQuery(q);
    return w.hash();
}

/// Compute a QueryHash for a TransactionBlock.
pub fn canonicalizeTransaction(txn: ast.TransactionBlock, alloc: std.mem.Allocator) !QueryHash {
    var w = CanonWriter.init(alloc);
    defer w.deinit();
    try w.writeTransaction(txn);
    return w.hash();
}

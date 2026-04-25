/// Recursive descent SQL parser for foldb's strict SQL dialect.
const std = @import("std");
const lex_mod = @import("lexer.zig");
const ast = @import("ast.zig");
const tok = @import("token.zig");

const assert = std.debug.assert;

/// Maximum items collected by any single parse loop. Guards against unbounded
/// loops on malformed input that never produces a clean break condition.
const MAX_PARSE_ITEMS: u32 = 4096;

pub const Lexer = lex_mod.Lexer;
pub const Token = tok.Token;
pub const TokenKind = tok.TokenKind;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    UnsupportedSyntax,
    AmbiguousColumnRef,
    MissingNullability, // column in CREATE TABLE lacks NULL/NOT NULL
    UnknownParam, // $name not found in TRANSACTION param list
    OutOfMemory,
} || lex_mod.LexError;

pub const Parser = struct {
    lexer: Lexer,
    arena: std.mem.Allocator,
    src: []const u8,
    err_msg: ?[]const u8 = null,
    err_pos: u32 = 0,
    // Set while parsing a TRANSACTION body so $name params can resolve to positional indices.
    txn_params: []const ast.TxnParam = &.{},

    pub fn init(src: []const u8, arena: std.mem.Allocator) Parser {
        return .{ .lexer = Lexer.init(src), .arena = arena, .src = src };
    }

    // ─── Peek / consume helpers ───────────────────────────────────────────

    fn peek(self: *Parser) ParseError!Token {
        return self.lexer.peek();
    }

    fn advance(self: *Parser) ParseError!Token {
        return self.lexer.next();
    }

    fn check(self: *Parser, kind: TokenKind) ParseError!bool {
        const t = try self.peek();
        return t.kind == kind;
    }

    fn eat(self: *Parser, kind: TokenKind) ParseError!bool {
        const t = try self.peek();
        if (t.kind == kind) {
            _ = try self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        const t = try self.advance();
        if (t.kind != kind) {
            self.err_pos = t.span.start;
            self.err_msg = "unexpected token";
            return error.UnexpectedToken;
        }
        return t;
    }

    fn expectIdent(self: *Parser) ParseError![]const u8 {
        const t = try self.advance();
        if (t.kind != .ident and !isKeywordUsableAsIdent(t.kind)) {
            self.err_pos = t.span.start;
            self.err_msg = "expected identifier";
            return error.UnexpectedToken;
        }
        return t.text(self.src);
    }

    fn peekKind(self: *Parser) ParseError!TokenKind {
        return (try self.peek()).kind;
    }

    fn eatIdent(self: *Parser, name: []const u8) ParseError!bool {
        const t = try self.peek();
        if ((t.kind == .ident or isKeywordUsableAsIdent(t.kind)) and
            std.ascii.eqlIgnoreCase(t.text(self.src), name))
        {
            _ = try self.advance();
            return true;
        }
        return false;
    }

    fn pos(self: *Parser) ParseError!u32 {
        return (try self.peek()).span.start;
    }

    // ─── Top level ───────────────────────────────────────────────────────

    pub fn parseQuery(self: *Parser) ParseError!ast.ParsedQuery {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (true) {
            assert(stmts.items.len < MAX_PARSE_ITEMS);
            _ = try self.eat(.sym_semicolon);
            const k = try self.peekKind();
            if (k == .eof) break;
            const s = try self.parseStmt();
            try stmts.append(self.arena, s);
            _ = try self.eat(.sym_semicolon);
        }
        return .{ .stmts = try stmts.toOwnedSlice(self.arena) };
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        const k = try self.peekKind();
        return switch (k) {
            .kw_select => .{ .select = try self.parseSelect() },
            .kw_insert => .{ .insert = try self.parseInsert() },
            .kw_update => .{ .update = try self.parseUpdate() },
            .kw_delete => .{ .delete = try self.parseDelete() },
            .kw_merge => .{ .merge = try self.parseMerge() },
            .kw_create => try self.parseCreate(),
            .kw_alter => .{ .alter_table = try self.parseAlter() },
            .kw_with => try self.parseWithStmt(),
            .kw_transaction => .{ .transaction = try self.parseTransaction() },
            else => {
                const t = try self.advance();
                // Reject ISOLATION LEVEL at parse time
                if (t.kind == .ident and std.ascii.eqlIgnoreCase(t.text(self.src), "isolation")) {
                    self.err_msg = "ISOLATION LEVEL is not supported; foldb enforces strict serializable always";
                    return error.UnsupportedSyntax;
                }
                self.err_pos = t.span.start;
                self.err_msg = "unexpected statement";
                return error.UnexpectedToken;
            },
        };
    }

    // ─── WITH ────────────────────────────────────────────────────────────

    fn parseCtes(self: *Parser) ParseError![]const ast.Cte {
        var ctes: std.ArrayList(ast.Cte) = .empty;
        _ = try self.expect(.kw_with);
        const recursive = try self.eat(.kw_recursive);
        while (true) {
            assert(ctes.items.len < MAX_PARSE_ITEMS);
            const name = try self.expectIdent();
            const columns = blk: {
                if (try self.eat(.sym_lparen)) {
                    var cols: std.ArrayList([]const u8) = .empty;
                    while (true) {
                        assert(cols.items.len < MAX_PARSE_ITEMS);
                        try cols.append(self.arena, try self.expectIdent());
                        if (!try self.eat(.sym_comma)) break;
                    }
                    _ = try self.expect(.sym_rparen);
                    break :blk try cols.toOwnedSlice(self.arena);
                }
                break :blk null;
            };
            _ = try self.expect(.kw_as);
            _ = try self.expect(.sym_lparen);
            const query = try self.arenaAlloc(ast.SelectStmt);
            query.* = try self.parseSelect();
            _ = try self.expect(.sym_rparen);
            try ctes.append(self.arena, .{
                .name = name,
                .recursive = recursive,
                .columns = columns,
                .query = query,
            });
            if (!try self.eat(.sym_comma)) break;
        }
        return ctes.toOwnedSlice(self.arena);
    }

    fn parseWithStmt(self: *Parser) ParseError!ast.Stmt {
        const ctes = try self.parseCtes();
        const k = try self.peekKind();
        switch (k) {
            .kw_select => {
                var s = try self.parseSelect();
                s.with = ctes;
                return .{ .select = s };
            },
            .kw_insert => {
                var s = try self.parseInsert();
                s.with = ctes;
                return .{ .insert = s };
            },
            .kw_update => {
                var s = try self.parseUpdate();
                s.with = ctes;
                return .{ .update = s };
            },
            .kw_delete => {
                var s = try self.parseDelete();
                s.with = ctes;
                return .{ .delete = s };
            },
            else => return error.UnexpectedToken,
        }
    }

    // ─── SELECT ──────────────────────────────────────────────────────────

    fn parseSelect(self: *Parser) ParseError!ast.SelectStmt {
        _ = try self.expect(.kw_select);
        const distinct = try self.eat(.kw_distinct);
        if (try self.eat(.kw_all)) {} // ALL is the default; consume it

        const items = try self.parseSelectItems();

        var from_ref: ?ast.TableRef = null;
        var joins: std.ArrayList(ast.Join) = .empty;
        if (try self.eat(.kw_from)) {
            from_ref = try self.parseTableRef();
            while (true) {
                assert(joins.items.len < MAX_PARSE_ITEMS);
                const jk = try self.peekKind();
                if (jk == .kw_join or jk == .kw_inner or jk == .kw_left or
                    jk == .kw_right or jk == .kw_full or jk == .kw_cross)
                {
                    try joins.append(self.arena, try self.parseJoin());
                } else break;
            }
        }

        const where_expr = if (try self.eat(.kw_where)) try self.parseExpr() else null;

        var group_by: []const *ast.Expr = &.{};
        if (try self.eat(.kw_group)) {
            _ = try self.expect(.kw_by);
            group_by = try self.parseExprList();
        }

        const having = if (try self.eat(.kw_having)) try self.parseExpr() else null;

        var windows: std.ArrayList(ast.NamedWindow) = .empty;
        if (try self.eat(.kw_window)) {
            while (true) {
                assert(windows.items.len < MAX_PARSE_ITEMS);
                const wname = try self.expectIdent();
                _ = try self.expect(.kw_as);
                _ = try self.expect(.sym_lparen);
                const spec = try self.parseWindowSpec();
                _ = try self.expect(.sym_rparen);
                try windows.append(self.arena, .{ .name = wname, .spec = spec });
                if (!try self.eat(.sym_comma)) break;
            }
        }

        var order_by: []const ast.OrderByItem = &.{};
        if (try self.eat(.kw_order)) {
            _ = try self.expect(.kw_by);
            order_by = try self.parseOrderByList();
        }

        const limit_expr = if (try self.eat(.kw_limit)) try self.parseExpr() else null;
        const offset_expr = if (try self.eat(.kw_offset)) try self.parseExpr() else null;

        return .{
            .with = &.{},
            .distinct = distinct,
            .items = items,
            .from = from_ref,
            .joins = try joins.toOwnedSlice(self.arena),
            .where = where_expr,
            .group_by = group_by,
            .having = having,
            .windows = try windows.toOwnedSlice(self.arena),
            .order_by = order_by,
            .limit = limit_expr,
            .offset = offset_expr,
        };
    }

    fn parseSelectItems(self: *Parser) ParseError![]const ast.SelectItem {
        var items: std.ArrayList(ast.SelectItem) = .empty;
        while (true) {
            assert(items.items.len < MAX_PARSE_ITEMS);
            const k = try self.peekKind();
            if (k == .op_star) {
                _ = try self.advance();
                try items.append(self.arena, .star);
            } else {
                const e = try self.parseExpr();
                const alias = if (try self.eat(.kw_as))
                    try self.expectIdent()
                else blk: {
                    // bare alias without AS
                    const pk = try self.peekKind();
                    if (pk == .ident) break :blk try self.expectIdent();
                    break :blk null;
                };
                try items.append(self.arena, .{ .expr = .{ .expr = e, .alias = alias } });
            }
            if (!try self.eat(.sym_comma)) break;
        }
        return items.toOwnedSlice(self.arena);
    }

    fn parseTableRef(self: *Parser) ParseError!ast.TableRef {
        const k = try self.peekKind();
        if (k == .sym_lparen) {
            _ = try self.advance();
            const q = try self.arenaAlloc(ast.SelectStmt);
            q.* = try self.parseSelect();
            _ = try self.expect(.sym_rparen);
            _ = try self.expect(.kw_as);
            const alias = try self.expectIdent();
            return .{ .subquery = .{ .query = q, .alias = alias } };
        }
        const name = try self.expectIdent();
        const alias = if (try self.eat(.kw_as))
            try self.expectIdent()
        else blk: {
            const pk = try self.peekKind();
            if (pk == .ident) break :blk try self.expectIdent();
            break :blk null;
        };
        return .{ .named = .{ .name = name, .alias = alias } };
    }

    fn parseJoin(self: *Parser) ParseError!ast.Join {
        const kind: ast.JoinKind = switch (try self.peekKind()) {
            .kw_cross => blk: {
                _ = try self.advance();
                _ = try self.expect(.kw_join);
                break :blk .cross;
            },
            .kw_inner => blk: {
                _ = try self.advance();
                _ = try self.expect(.kw_join);
                break :blk .inner;
            },
            .kw_left => blk: {
                _ = try self.advance();
                _ = try self.eat(.kw_outer);
                _ = try self.expect(.kw_join);
                break :blk .left;
            },
            .kw_right => blk: {
                _ = try self.advance();
                _ = try self.eat(.kw_outer);
                _ = try self.expect(.kw_join);
                break :blk .right;
            },
            .kw_full => blk: {
                _ = try self.advance();
                _ = try self.eat(.kw_outer);
                _ = try self.expect(.kw_join);
                break :blk .full;
            },
            .kw_join => blk: {
                _ = try self.advance();
                break :blk .inner;
            },
            else => return error.UnexpectedToken,
        };

        const tref = try self.parseTableRef();
        const condition: ?ast.JoinCondition = if (kind != .cross) blk: {
            if (try self.eat(.kw_on)) {
                break :blk .{ .on = try self.parseExpr() };
            } else if (try self.eat(.kw_using)) {
                _ = try self.expect(.sym_lparen);
                var cols: std.ArrayList([]const u8) = .empty;
                while (true) {
                    assert(cols.items.len < MAX_PARSE_ITEMS);
                    try cols.append(self.arena, try self.expectIdent());
                    if (!try self.eat(.sym_comma)) break;
                }
                _ = try self.expect(.sym_rparen);
                break :blk .{ .using = try cols.toOwnedSlice(self.arena) };
            } else {
                break :blk null;
            }
        } else null;

        return .{ .kind = kind, .table = tref, .condition = condition };
    }

    fn parseWindowSpec(self: *Parser) ParseError!ast.WindowSpec {
        var partition_by: []const *ast.Expr = &.{};
        if (try self.eat(.kw_partition)) {
            _ = try self.expect(.kw_by);
            partition_by = try self.parseExprList();
        }
        var order_by: []const ast.OrderByItem = &.{};
        if (try self.eat(.kw_order)) {
            _ = try self.expect(.kw_by);
            order_by = try self.parseOrderByList();
        }
        var frame: ?ast.WindowFrame = null;
        const fk = try self.peekKind();
        if (fk == .kw_rows or fk == .kw_range) {
            const mode: ast.WindowFrame.Mode = if (fk == .kw_rows) .rows else .range;
            _ = try self.advance();
            if (try self.eat(.kw_between)) {
                const s2 = try self.parseFrameBound();
                _ = try self.expect(.kw_and);
                const e2 = try self.parseFrameBound();
                frame = .{ .mode = mode, .start = s2, .end = e2 };
            } else {
                const start_bound = try self.parseFrameBound();
                frame = .{ .mode = mode, .start = start_bound, .end = .current_row };
            }
        }
        return .{ .partition_by = partition_by, .order_by = order_by, .frame = frame };
    }

    fn parseFrameBound(self: *Parser) ParseError!ast.WindowFrame.Bound {
        if (try self.eat(.kw_unbounded)) {
            if (try self.eat(.kw_preceding)) return .unbounded_preceding;
            if (try self.eat(.kw_following)) return .unbounded_following;
            return error.UnexpectedToken;
        }
        if (try self.eat(.kw_current)) {
            _ = try self.expect(.kw_row);
            return .current_row;
        }
        const e = try self.parseExpr();
        if (try self.eat(.kw_preceding)) return .{ .preceding = e };
        if (try self.eat(.kw_following)) return .{ .following = e };
        return error.UnexpectedToken;
    }

    fn parseOrderByList(self: *Parser) ParseError![]const ast.OrderByItem {
        var items: std.ArrayList(ast.OrderByItem) = .empty;
        while (true) {
            assert(items.items.len < MAX_PARSE_ITEMS);
            const e = try self.parseExpr();
            var asc = true;
            if (try self.eat(.kw_asc)) {
                asc = true;
            }
            if (try self.eat(.kw_desc)) {
                asc = false;
            }
            var nulls_first: ?bool = null;
            if (try self.eat(.kw_nulls)) {
                if (try self.eat(.kw_first)) {
                    nulls_first = true;
                } else if (try self.eat(.kw_last)) {
                    nulls_first = false;
                } else return error.UnexpectedToken;
            }
            try items.append(self.arena, .{ .expr = e, .asc = asc, .nulls_first = nulls_first });
            if (!try self.eat(.sym_comma)) break;
        }
        return items.toOwnedSlice(self.arena);
    }

    // ─── INSERT ──────────────────────────────────────────────────────────

    fn parseInsert(self: *Parser) ParseError!ast.InsertStmt {
        _ = try self.expect(.kw_insert);
        _ = try self.expect(.kw_into);
        const table = try self.expectIdent();

        var columns: std.ArrayList([]const u8) = .empty;
        if (try self.eat(.sym_lparen)) {
            while (true) {
                assert(columns.items.len < MAX_PARSE_ITEMS);
                try columns.append(self.arena, try self.expectIdent());
                if (!try self.eat(.sym_comma)) break;
            }
            _ = try self.expect(.sym_rparen);
        }

        const source: ast.InsertSource = blk: {
            if (try self.eat(.kw_values)) {
                var rows: std.ArrayList([]*ast.Expr) = .empty;
                while (true) {
                    assert(rows.items.len < MAX_PARSE_ITEMS);
                    _ = try self.expect(.sym_lparen);
                    const vals = try self.parseExprList();
                    _ = try self.expect(.sym_rparen);
                    try rows.append(self.arena, vals);
                    if (!try self.eat(.sym_comma)) break;
                }
                break :blk .{ .values = try rows.toOwnedSlice(self.arena) };
            } else {
                const q = try self.arenaAlloc(ast.SelectStmt);
                q.* = try self.parseSelect();
                break :blk .{ .query = q };
            }
        };

        var on_conflict: ?ast.OnConflict = null;
        const has_on_conflict: bool = if (try self.eat(.kw_on)) blk: {
            _ = try self.expect(.kw_conflict);
            break :blk true;
        } else try self.eat(.kw_conflict);
        if (has_on_conflict) {
            _ = try self.expect(.kw_do);
            if (try self.eat(.kw_nothing)) {
                on_conflict = .do_nothing;
            } else if (try self.eat(.kw_update)) {
                // ON CONFLICT (cols) DO UPDATE SET ...
                var target: std.ArrayList([]const u8) = .empty;
                if (try self.eat(.sym_lparen)) {
                    while (true) {
                        assert(target.items.len < MAX_PARSE_ITEMS);
                        try target.append(self.arena, try self.expectIdent());
                        if (!try self.eat(.sym_comma)) break;
                    }
                    _ = try self.expect(.sym_rparen);
                }
                _ = try self.expect(.kw_set);
                const sets = try self.parseAssignmentList();
                const w = if (try self.eat(.kw_where)) try self.parseExpr() else null;
                on_conflict = .{ .do_update = .{
                    .target = try target.toOwnedSlice(self.arena),
                    .sets = sets,
                    .where = w,
                } };
            } else return error.UnexpectedToken;
        }

        const returning = if (try self.eat(.kw_returning)) try self.parseSelectItems() else &.{};
        return .{
            .with = &.{},
            .table = table,
            .columns = try columns.toOwnedSlice(self.arena),
            .source = source,
            .on_conflict = on_conflict,
            .returning = returning,
        };
    }

    // ─── UPDATE ──────────────────────────────────────────────────────────

    fn parseUpdate(self: *Parser) ParseError!ast.UpdateStmt {
        _ = try self.expect(.kw_update);
        const table = try self.expectIdent();
        const alias = if (try self.eat(.kw_as)) try self.expectIdent() else null;
        _ = try self.expect(.kw_set);
        const sets = try self.parseAssignmentList();
        var from_ref: ?ast.TableRef = null;
        if (try self.eat(.kw_from)) {
            from_ref = try self.parseTableRef();
        }
        const where_expr = if (try self.eat(.kw_where)) try self.parseExpr() else null;
        const returning = if (try self.eat(.kw_returning)) try self.parseSelectItems() else &.{};
        return .{
            .with = &.{},
            .table = table,
            .alias = alias,
            .sets = sets,
            .from = from_ref,
            .where = where_expr,
            .returning = returning,
        };
    }

    fn parseAssignmentList(self: *Parser) ParseError![]const ast.Assignment {
        var list: std.ArrayList(ast.Assignment) = .empty;
        while (true) {
            assert(list.items.len < MAX_PARSE_ITEMS);
            const col = try self.expectIdent();
            _ = try self.expect(.op_eq);
            const val = try self.parseExpr();
            try list.append(self.arena, .{ .column = col, .value = val });
            if (!try self.eat(.sym_comma)) break;
        }
        return list.toOwnedSlice(self.arena);
    }

    // ─── DELETE ──────────────────────────────────────────────────────────

    fn parseDelete(self: *Parser) ParseError!ast.DeleteStmt {
        _ = try self.expect(.kw_delete);
        _ = try self.expect(.kw_from);
        const table = try self.expectIdent();
        const alias = if (try self.eat(.kw_as)) try self.expectIdent() else null;
        var using: std.ArrayList(ast.TableRef) = .empty;
        if (try self.eat(.kw_using)) {
            while (true) {
                assert(using.items.len < MAX_PARSE_ITEMS);
                try using.append(self.arena, try self.parseTableRef());
                if (!try self.eat(.sym_comma)) break;
            }
        }
        const where_expr = if (try self.eat(.kw_where)) try self.parseExpr() else null;
        const returning = if (try self.eat(.kw_returning)) try self.parseSelectItems() else &.{};
        return .{
            .with = &.{},
            .table = table,
            .alias = alias,
            .using = try using.toOwnedSlice(self.arena),
            .where = where_expr,
            .returning = returning,
        };
    }

    // ─── MERGE ───────────────────────────────────────────────────────────

    fn parseMerge(self: *Parser) ParseError!ast.MergeStmt {
        _ = try self.expect(.kw_merge);
        _ = try self.eat(.kw_into);
        const tgt_name = try self.expectIdent();
        const tgt_alias = if (try self.eat(.kw_as)) try self.expectIdent() else null;
        _ = try self.expect(.kw_using);
        const src = try self.parseTableRef();
        _ = try self.expect(.kw_on);
        const on_expr = try self.parseExpr();
        var whens: std.ArrayList(ast.MergeWhen) = .empty;
        while (try self.eat(.kw_when)) {
            if (try self.eat(.kw_matched)) {
                const cond = if (try self.eat(.kw_and)) try self.parseExpr() else null;
                _ = try self.expect(.kw_then);
                const action: ast.MergeAction = blk: {
                    if (try self.eat(.kw_update)) {
                        _ = try self.expect(.kw_set);
                        break :blk .{ .update = try self.parseAssignmentList() };
                    } else if (try self.eat(.kw_delete)) {
                        break :blk .delete;
                    } else if (try self.eat(.kw_do)) {
                        _ = try self.expect(.kw_nothing);
                        break :blk .do_nothing;
                    } else return error.UnexpectedToken;
                };
                try whens.append(self.arena, .{ .matched = .{ .cond = cond, .action = action } });
            } else if (try self.eat(.kw_not)) {
                _ = try self.expect(.kw_matched);
                const cond = if (try self.eat(.kw_and)) try self.parseExpr() else null;
                _ = try self.expect(.kw_then);
                _ = try self.expect(.kw_insert);
                var cols: std.ArrayList([]const u8) = .empty;
                if (try self.eat(.sym_lparen)) {
                    while (true) {
                        assert(cols.items.len < MAX_PARSE_ITEMS);
                        try cols.append(self.arena, try self.expectIdent());
                        if (!try self.eat(.sym_comma)) break;
                    }
                    _ = try self.expect(.sym_rparen);
                }
                _ = try self.expect(.kw_values);
                _ = try self.expect(.sym_lparen);
                const vals = try self.parseExprList();
                _ = try self.expect(.sym_rparen);
                try whens.append(self.arena, .{ .not_matched = .{
                    .cond = cond,
                    .columns = try cols.toOwnedSlice(self.arena),
                    .values = vals,
                } });
            } else return error.UnexpectedToken;
        }
        return .{
            .with = &.{},
            .target = .{ .name = tgt_name, .alias = tgt_alias },
            .source = .{ .ref = src },
            .on = on_expr,
            .whens = try whens.toOwnedSlice(self.arena),
        };
    }

    // ─── CREATE ──────────────────────────────────────────────────────────

    fn parseCreate(self: *Parser) ParseError!ast.Stmt {
        _ = try self.expect(.kw_create);
        const k = try self.peekKind();
        if (k == .kw_table) {
            return .{ .create_table = try self.parseCreateTable() };
        }
        // CREATE [UNIQUE] [ORDERED|HASH|VECTOR|JSON PATH] INDEX
        var unique = false;
        if (k == .kw_unique) {
            _ = try self.advance();
            unique = true;
        }
        return .{ .create_index = try self.parseCreateIndex(unique) };
    }

    fn parseCreateTable(self: *Parser) ParseError!ast.CreateTableStmt {
        _ = try self.expect(.kw_table);
        // Skip optional IF NOT EXISTS
        if (try self.eatIdent("if")) {
            _ = try self.expect(.kw_not);
            _ = try self.expect(.kw_exists);
        }
        const name = try self.expectIdent();
        _ = try self.expect(.sym_lparen);
        var columns: std.ArrayList(ast.ColumnDef) = .empty;
        var pk_cols: std.ArrayList([]const u8) = .empty;
        var fk_defs: std.ArrayList(ast.ForeignKeyConstraint) = .empty;
        while (true) {
            assert(columns.items.len + pk_cols.items.len + fk_defs.items.len < MAX_PARSE_ITEMS);
            const k = try self.peekKind();
            if (k == .kw_primary) {
                _ = try self.advance();
                _ = try self.expect(.kw_key);
                _ = try self.expect(.sym_lparen);
                while (true) {
                    assert(pk_cols.items.len < MAX_PARSE_ITEMS);
                    try pk_cols.append(self.arena, try self.expectIdent());
                    if (!try self.eat(.sym_comma)) break;
                }
                _ = try self.expect(.sym_rparen);
            } else if (try self.eatIdent("constraint")) {
                const fk_name = try self.expectIdent();
                try fk_defs.append(self.arena, try self.parseForeignKeyClause(fk_name));
            } else if (try self.eatIdent("foreign")) {
                try fk_defs.append(self.arena, try self.parseForeignKeyClause(null));
            } else {
                const col_span_start = (try self.peek()).span.start;
                const col_name = try self.expectIdent();
                const col_type = try self.parseType();
                var is_pk = false;
                const nullable: ast.NullConstraint = blk: {
                    // Allow column constraints in any order: NOT NULL, NULL, PRIMARY KEY
                    var got_null: ?ast.NullConstraint = null;
                    while (true) {
                        if (try self.eat(.kw_not)) {
                            _ = try self.expect(.lit_null);
                            got_null = .not_null;
                        } else if ((try self.peekKind()) == .lit_null) {
                            _ = try self.advance();
                            got_null = .nullable;
                        } else if ((try self.peekKind()) == .kw_primary) {
                            _ = try self.advance();
                            _ = try self.expect(.kw_key);
                            is_pk = true;
                            got_null = .not_null; // PRIMARY KEY implies NOT NULL
                        } else break; // exits the inner while(true) loop
                    }
                    if (got_null) |n| break :blk n;
                    break :blk .nullable; // default: nullable when no constraint given
                };
                if (is_pk) try pk_cols.append(self.arena, col_name);
                try columns.append(self.arena, .{
                    .name = col_name,
                    .typ = col_type,
                    .nullable = nullable,
                    .span = .{ .start = col_span_start, .end = self.lexer.pos },
                });
            }
            if (!try self.eat(.sym_comma)) break;
        }
        _ = try self.expect(.sym_rparen);
        return .{
            .name = name,
            .columns = try columns.toOwnedSlice(self.arena),
            .primary_key = .{ .columns = try pk_cols.toOwnedSlice(self.arena) },
            .foreign_keys = try fk_defs.toOwnedSlice(self.arena),
        };
    }

    fn parseForeignKeyClause(self: *Parser, fk_name: ?[]const u8) ParseError!ast.ForeignKeyConstraint {
        // Caller has already consumed CONSTRAINT name (if any); next is FOREIGN KEY
        _ = try self.eatIdent("foreign"); // no-op if called from bare FOREIGN branch (already consumed)
        _ = try self.expect(.kw_key);
        _ = try self.expect(.sym_lparen);
        var local_cols: std.ArrayList([]const u8) = .empty;
        while (true) {
            assert(local_cols.items.len < MAX_PARSE_ITEMS);
            try local_cols.append(self.arena, try self.expectIdent());
            if (!try self.eat(.sym_comma)) break;
        }
        _ = try self.expect(.sym_rparen);
        _ = try self.eatIdent("references");
        const ref_table = try self.expectIdent();
        var ref_cols: std.ArrayList([]const u8) = .empty;
        if (try self.eat(.sym_lparen)) {
            while (true) {
                assert(ref_cols.items.len < MAX_PARSE_ITEMS);
                try ref_cols.append(self.arena, try self.expectIdent());
                if (!try self.eat(.sym_comma)) break;
            }
            _ = try self.expect(.sym_rparen);
        }
        return .{
            .name = fk_name,
            .columns = try local_cols.toOwnedSlice(self.arena),
            .ref_table = ref_table,
            .ref_columns = try ref_cols.toOwnedSlice(self.arena),
        };
    }

    fn parseCreateIndex(self: *Parser, unique: bool) ParseError!ast.CreateIndexStmt {
        // Consume optional kind keyword
        const kind: ast.IndexKind = blk: {
            const k = try self.peekKind();
            if (k == .kw_ordered) {
                _ = try self.advance();
                break :blk .ordered;
            }
            if (k == .kw_hash) {
                _ = try self.advance();
                break :blk .hash;
            }
            if (k == .kw_vector) {
                _ = try self.advance();
                _ = try self.expect(.sym_lparen);
                const dim = try self.parseInt();
                _ = try self.expect(.sym_rparen);
                break :blk .{ .vector = @intCast(dim) };
            }
            if (k == .kw_json) {
                _ = try self.advance();
                _ = try self.expect(.kw_path);
                _ = try self.expect(.sym_lparen);
                var paths: std.ArrayList([]const u8) = .empty;
                while (true) {
                    assert(paths.items.len < MAX_PARSE_ITEMS);
                    try paths.append(self.arena, try self.expectIdent());
                    if (!try self.eat(.sym_comma)) break;
                }
                _ = try self.expect(.sym_rparen);
                break :blk .{ .json_path = try paths.toOwnedSlice(self.arena) };
            }
            break :blk .ordered; // default
        };
        _ = try self.expect(.kw_index);
        const name = try self.expectIdent();
        _ = try self.expect(.kw_on);
        const table = try self.expectIdent();
        _ = try self.expect(.sym_lparen);
        var cols: std.ArrayList([]const u8) = .empty;
        while (true) {
            assert(cols.items.len < MAX_PARSE_ITEMS);
            try cols.append(self.arena, try self.expectIdent());
            if (!try self.eat(.sym_comma)) break;
        }
        _ = try self.expect(.sym_rparen);
        return .{
            .name = name,
            .unique = unique,
            .kind = kind,
            .table = table,
            .columns = try cols.toOwnedSlice(self.arena),
        };
    }

    // ─── ALTER TABLE ─────────────────────────────────────────────────────

    fn parseAlter(self: *Parser) ParseError!ast.AlterTableStmt {
        _ = try self.expect(.kw_alter);
        _ = try self.expect(.kw_table);
        const table = try self.expectIdent();
        const action: ast.AlterAction = blk: {
            if (try self.eat(.kw_add)) {
                _ = try self.eat(.kw_column);
                const col_span_start = (try self.peek()).span.start;
                const col_name = try self.expectIdent();
                const col_type = try self.parseType();
                const nullable: ast.NullConstraint = blk2: {
                    if (try self.eat(.kw_not)) {
                        _ = try self.expect(.lit_null);
                        break :blk2 .not_null;
                    }
                    if ((try self.peekKind()) == .lit_null) {
                        _ = try self.advance();
                        break :blk2 .nullable;
                    }
                    break :blk2 .nullable; // default: nullable when no constraint given
                };
                break :blk .{ .add_column = .{
                    .name = col_name,
                    .typ = col_type,
                    .nullable = nullable,
                    .span = .{ .start = col_span_start, .end = col_span_start },
                } };
            } else if (try self.eat(.kw_drop)) {
                _ = try self.eat(.kw_column);
                break :blk .{ .drop_column = try self.expectIdent() };
            } else return error.UnexpectedToken;
        };
        return .{ .table = table, .action = action };
    }

    // ─── TRANSACTION BLOCK ───────────────────────────────────────────────

    fn parseTransaction(self: *Parser) ParseError!ast.TransactionBlock {
        _ = try self.expect(.kw_transaction);
        var params: std.ArrayList(ast.TxnParam) = .empty;
        if (try self.eat(.sym_lparen)) {
            while (true) {
                assert(params.items.len < MAX_PARSE_ITEMS);
                const pname = try self.expectIdent();
                const ptyp = try self.parseType();
                try params.append(self.arena, .{ .name = pname, .typ = ptyp });
                if (!try self.eat(.sym_comma)) break;
            }
            _ = try self.expect(.sym_rparen);
        }
        _ = try self.expect(.sym_lbrace);
        // Make param names visible to parsePrimaryExpr for $name resolution.
        self.txn_params = params.items;
        defer self.txn_params = &.{};
        var stmts: std.ArrayList(ast.TxnStmt) = .empty;
        while (!(try self.check(.sym_rbrace))) {
            const k = try self.peekKind();
            const s: ast.TxnStmt = switch (k) {
                .kw_select => .{ .select = try self.parseSelect() },
                .kw_insert => .{ .insert = try self.parseInsert() },
                .kw_update => .{ .update = try self.parseUpdate() },
                .kw_delete => .{ .delete = try self.parseDelete() },
                .kw_merge => .{ .merge = try self.parseMerge() },
                .kw_assert => blk: {
                    _ = try self.advance();
                    break :blk .{ .assert = try self.parseExpr() };
                },
                else => return error.UnexpectedToken,
            };
            try stmts.append(self.arena, s);
            _ = try self.eat(.sym_semicolon);
        }
        _ = try self.expect(.sym_rbrace);
        return .{
            .params = try params.toOwnedSlice(self.arena),
            .stmts = try stmts.toOwnedSlice(self.arena),
        };
    }

    // ─── Types ───────────────────────────────────────────────────────────

    fn parseType(self: *Parser) ParseError!ast.SqlType {
        const k = try self.peekKind();
        const overflow: ast.IntOverflow = blk: {
            const t = try self.advance();
            _ = t;
            if (try self.eat(.kw_wrapping)) break :blk .wrapping;
            break :blk .error_on_overflow;
        };
        return switch (k) {
            .kw_bool => .bool,
            .kw_int8 => .{ .int8 = overflow },
            .kw_int16 => .{ .int16 = overflow },
            .kw_int32 => .{ .int32 = overflow },
            .kw_int64 => .{ .int64 = overflow },
            .kw_uint8 => .{ .uint8 = overflow },
            .kw_uint16 => .{ .uint16 = overflow },
            .kw_uint32 => .{ .uint32 = overflow },
            .kw_uint64 => .{ .uint64 = overflow },
            .kw_float32 => .float32,
            .kw_float64 => .float64,
            .kw_decimal => blk: {
                _ = try self.expect(.sym_lparen);
                const p = try self.parseInt();
                _ = try self.expect(.sym_comma);
                const s = try self.parseInt();
                _ = try self.expect(.sym_rparen);
                break :blk .{ .decimal = .{ .precision = @intCast(p), .scale = @intCast(s) } };
            },
            .kw_string => .string,
            .kw_bytes => .bytes,
            .kw_uuid => .uuid,
            .kw_timestamp => .timestamp,
            .kw_interval => blk: {
                if (try self.eat(.kw_months)) break :blk .interval_months;
                if (try self.eat(.kw_micros)) break :blk .interval_micros;
                // Default: error — must specify MONTHS or MICROS
                self.err_msg = "INTERVAL requires MONTHS or MICROS qualifier";
                return error.UnsupportedSyntax;
            },
            .kw_json => .json,
            .kw_vector => blk: {
                _ = try self.expect(.sym_lparen);
                const dim = try self.parseInt();
                _ = try self.expect(.sym_rparen);
                break :blk .{ .vector = @intCast(dim) };
            },
            .kw_array => blk: {
                _ = try self.expect(.op_lt);
                const inner = try self.parseType();
                const inner_ptr = try self.arena.create(ast.SqlType);
                inner_ptr.* = inner;
                _ = try self.expect(.op_gt);
                break :blk .{ .array = inner_ptr };
            },
            .kw_struct => blk: {
                _ = try self.expect(.op_lt);
                var fields: std.ArrayList(ast.StructField) = .empty;
                while (true) {
                    const fname = try self.expectIdent();
                    const ftype = try self.parseType();
                    try fields.append(self.arena, .{ .name = fname, .typ = ftype });
                    if (!try self.eat(.sym_comma)) break;
                }
                _ = try self.expect(.op_gt);
                break :blk .{ .struct_type = try fields.toOwnedSlice(self.arena) };
            },
            else => {
                self.err_msg = "expected type name";
                return error.UnexpectedToken;
            },
        };
    }

    fn parseInt(self: *Parser) ParseError!i64 {
        const t = try self.expect(.lit_int);
        return std.fmt.parseInt(i64, t.text(self.src), 10) catch error.UnexpectedToken;
    }

    // ─── Expressions ─────────────────────────────────────────────────────

    fn parseExprList(self: *Parser) ParseError![]*ast.Expr {
        var list: std.ArrayList(*ast.Expr) = .empty;
        while (true) {
            assert(list.items.len < MAX_PARSE_ITEMS);
            try list.append(self.arena, try self.parseExpr());
            if (!try self.eat(.sym_comma)) break;
        }
        return list.toOwnedSlice(self.arena);
    }

    // Pratt-style precedence: or → and → not → comparison → is → additive → multiplicative → unary → primary
    fn parseExpr(self: *Parser) ParseError!*ast.Expr {
        return self.parseOrExpr();
    }

    fn parseOrExpr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseAndExpr();
        while (try self.eat(.kw_or)) {
            const right = try self.parseAndExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = .or_op, .left = left, .right = right } };
            left = e;
        }
        return left;
    }

    fn parseAndExpr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseNotExpr();
        while (try self.eat(.kw_and)) {
            const right = try self.parseNotExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = .and_op, .left = left, .right = right } };
            left = e;
        }
        return left;
    }

    fn parseNotExpr(self: *Parser) ParseError!*ast.Expr {
        if (try self.eat(.kw_not)) {
            const inner = try self.parseNotExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .unary = .{ .op = .not, .expr = inner } };
            return e;
        }
        return self.parseComparisonExpr();
    }

    fn parseComparisonExpr(self: *Parser) ParseError!*ast.Expr {
        const left = try self.parseIsExpr();
        const k = try self.peekKind();
        switch (k) {
            .op_eq, .op_neq, .op_lt, .op_gt, .op_lte, .op_gte => {
                _ = try self.advance();
                const op: ast.BinOp = switch (k) {
                    .op_eq => .eq,
                    .op_neq => .neq,
                    .op_lt => .lt,
                    .op_gt => .gt,
                    .op_lte => .lte,
                    .op_gte => .gte,
                    else => unreachable,
                };
                const right = try self.parseIsExpr();
                const e = try self.arenaAlloc(ast.Expr);
                e.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
                return e;
            },
            .kw_between => {
                _ = try self.advance();
                const low = try self.parseIsExpr();
                _ = try self.expect(.kw_and);
                const high = try self.parseIsExpr();
                const e = try self.arenaAlloc(ast.Expr);
                e.* = .{ .between = .{ .expr = left, .low = low, .high = high } };
                return e;
            },
            .kw_not => {
                // NOT BETWEEN, NOT IN, NOT LIKE
                const saved_pos = self.lexer.peeked;
                _ = try self.advance();
                const k2 = try self.peekKind();
                if (k2 == .kw_between) {
                    _ = try self.advance();
                    const low = try self.parseIsExpr();
                    _ = try self.expect(.kw_and);
                    const high = try self.parseIsExpr();
                    const inner = try self.arenaAlloc(ast.Expr);
                    inner.* = .{ .between = .{ .expr = left, .low = low, .high = high } };
                    const e = try self.arenaAlloc(ast.Expr);
                    e.* = .{ .unary = .{ .op = .not, .expr = inner } };
                    return e;
                } else if (k2 == .kw_in) {
                    _ = try self.advance();
                    return self.parseInExpr(left, true);
                } else if (k2 == .kw_like) {
                    _ = try self.advance();
                    const pattern = try self.parseIsExpr();
                    const inner = try self.arenaAlloc(ast.Expr);
                    inner.* = .{ .like = .{ .expr = left, .pattern = pattern } };
                    const e = try self.arenaAlloc(ast.Expr);
                    e.* = .{ .unary = .{ .op = .not, .expr = inner } };
                    return e;
                } else {
                    // put NOT back — wasn't ours
                    self.lexer.peeked = saved_pos;
                    return left;
                }
            },
            .kw_in => {
                _ = try self.advance();
                return self.parseInExpr(left, false);
            },
            .kw_like => {
                _ = try self.advance();
                const pattern = try self.parseIsExpr();
                const e = try self.arenaAlloc(ast.Expr);
                e.* = .{ .like = .{ .expr = left, .pattern = pattern } };
                return e;
            },
            else => return left,
        }
    }

    fn parseInExpr(self: *Parser, left: *ast.Expr, negated: bool) ParseError!*ast.Expr {
        _ = try self.expect(.sym_lparen);
        const k = try self.peekKind();
        if (k == .kw_select or k == .kw_with) {
            const q = try self.arenaAlloc(ast.SelectStmt);
            q.* = try self.parseSelect();
            _ = try self.expect(.sym_rparen);
            const e = try self.arenaAlloc(ast.Expr);
            e.* = if (negated)
                .{ .not_in_subquery = .{ .expr = left, .query = q } }
            else
                .{ .in_subquery = .{ .expr = left, .query = q } };
            return e;
        }
        const values = try self.parseExprList();
        _ = try self.expect(.sym_rparen);
        const e = try self.arenaAlloc(ast.Expr);
        e.* = if (negated)
            .{ .not_in_list = .{ .expr = left, .values = values } }
        else
            .{ .in_list = .{ .expr = left, .values = values } };
        return e;
    }

    fn parseIsExpr(self: *Parser) ParseError!*ast.Expr {
        const left = try self.parseBitOrExpr();
        if (try self.eat(.kw_is)) {
            const negated = try self.eat(.kw_not);
            if ((try self.peekKind()) == .lit_null) {
                _ = try self.advance();
                const e = try self.arenaAlloc(ast.Expr);
                e.* = if (negated) .{ .is_not_null = left } else .{ .is_null = left };
                return e;
            }
            if (try self.eat(.kw_distinct)) {
                _ = try self.expect(.kw_from);
                const right = try self.parseBitOrExpr();
                const e = try self.arenaAlloc(ast.Expr);
                e.* = if (negated)
                    .{ .is_not_distinct = .{ .left = left, .right = right } }
                else
                    .{ .is_distinct = .{ .left = left, .right = right } };
                return e;
            }
            return error.UnexpectedToken;
        }
        return left;
    }

    fn parseBitOrExpr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseBitXorExpr();
        while (try self.eat(.op_pipe)) {
            const right = try self.parseBitXorExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = .bit_or, .left = left, .right = right } };
            left = e;
        }
        return left;
    }

    fn parseBitXorExpr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseBitAndExpr();
        while (try self.eat(.op_hat)) {
            const right = try self.parseBitAndExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = .bit_xor, .left = left, .right = right } };
            left = e;
        }
        return left;
    }

    fn parseBitAndExpr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseShiftExpr();
        while (try self.eat(.op_amp)) {
            const right = try self.parseShiftExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = .bit_and, .left = left, .right = right } };
            left = e;
        }
        return left;
    }

    fn parseShiftExpr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseAdditiveExpr();
        var depth: u32 = 0;
        while (true) {
            assert(depth < MAX_PARSE_ITEMS);
            depth += 1;
            const k = try self.peekKind();
            const op: ast.BinOp = switch (k) {
                .op_lshift => .shl,
                .op_rshift => .shr,
                else => break,
            };
            _ = try self.advance();
            const right = try self.parseAdditiveExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
            left = e;
        }
        return left;
    }

    fn parseAdditiveExpr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseMultiplicativeExpr();
        var depth: u32 = 0;
        while (true) {
            assert(depth < MAX_PARSE_ITEMS);
            depth += 1;
            const k = try self.peekKind();
            const op: ast.BinOp = switch (k) {
                .op_plus => .add,
                .op_minus => .sub,
                .op_concat => .concat,
                .op_contains => .contains,
                .op_contained => .contained,
                else => break,
            };
            _ = try self.advance();
            const right = try self.parseMultiplicativeExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
            left = e;
        }
        return left;
    }

    fn parseMultiplicativeExpr(self: *Parser) ParseError!*ast.Expr {
        var left = try self.parseUnaryExpr();
        var depth: u32 = 0;
        while (true) {
            assert(depth < MAX_PARSE_ITEMS);
            depth += 1;
            const k = try self.peekKind();
            const op: ast.BinOp = switch (k) {
                .op_star => .mul,
                .op_slash => .div,
                .op_percent => .mod,
                else => break,
            };
            _ = try self.advance();
            const right = try self.parseUnaryExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
            left = e;
        }
        return left;
    }

    fn parseUnaryExpr(self: *Parser) ParseError!*ast.Expr {
        if (try self.eat(.op_minus)) {
            const inner = try self.parseUnaryExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .unary = .{ .op = .neg, .expr = inner } };
            return e;
        }
        if (try self.eat(.op_tilde)) {
            const inner = try self.parseUnaryExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .unary = .{ .op = .bit_not, .expr = inner } };
            return e;
        }
        return self.parseCastExpr();
    }

    fn parseCastExpr(self: *Parser) ParseError!*ast.Expr {
        var base = try self.parsePrimaryExpr();
        // Postfix :: cast operator
        while (try self.eat(.op_cast_op)) {
            const to = try self.parseType();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .cast = .{ .expr = base, .to = to } };
            base = e;
        }
        // Postfix -> and ->> (JSON operators)
        var json_depth: u32 = 0;
        while (true) {
            assert(json_depth < MAX_PARSE_ITEMS);
            json_depth += 1;
            const k = try self.peekKind();
            const op: ast.BinOp = switch (k) {
                .op_arrow => .arrow,
                .op_darrow => .darrow,
                else => break,
            };
            _ = try self.advance();
            const right = try self.parsePrimaryExpr();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .binary = .{ .op = op, .left = base, .right = right } };
            base = e;
        }
        return base;
    }

    fn parsePrimaryExpr(self: *Parser) ParseError!*ast.Expr {
        const t = try self.peek();
        const e = try self.arenaAlloc(ast.Expr);
        switch (t.kind) {
            .lit_int => {
                _ = try self.advance();
                const v = std.fmt.parseInt(i128, t.text(self.src), 10) catch return error.UnexpectedToken;
                e.* = .{ .lit_int = v };
            },
            .lit_float => {
                _ = try self.advance();
                const v = std.fmt.parseFloat(f64, t.text(self.src)) catch return error.UnexpectedToken;
                e.* = .{ .lit_float = v };
            },
            .lit_string => {
                _ = try self.advance();
                const raw = t.text(self.src);
                // strip outer quotes, unescape ''
                e.* = .{ .lit_string = try self.unescapeString(raw[1 .. raw.len - 1]) };
            },
            .lit_bytes => {
                _ = try self.advance();
                const raw = t.text(self.src);
                // strip x' and '
                e.* = .{ .lit_bytes = try self.unhexBytes(raw[2 .. raw.len - 1]) };
            },
            .lit_true => {
                _ = try self.advance();
                e.* = .{ .lit_bool = true };
            },
            .lit_false => {
                _ = try self.advance();
                e.* = .{ .lit_bool = false };
            },
            .lit_null => {
                _ = try self.advance();
                e.* = .lit_null;
            },
            .param => {
                _ = try self.advance();
                const num_str = t.text(self.src)[1..]; // skip '$'
                const num = std.fmt.parseInt(u32, num_str, 10) catch return error.UnexpectedToken;
                if (num == 0) return error.UnexpectedToken;
                e.* = .{ .param = num - 1 }; // convert to 0-based
            },
            .param_named => {
                _ = try self.advance();
                const name = t.text(self.src)[1..]; // skip '$'
                for (self.txn_params, 0..) |p, idx| {
                    if (std.mem.eql(u8, p.name, name)) {
                        e.* = .{ .param = @intCast(idx) };
                        break;
                    }
                } else return error.UnknownParam;
            },
            .kw_cast => {
                _ = try self.advance();
                _ = try self.expect(.sym_lparen);
                const inner = try self.parseExpr();
                _ = try self.expect(.kw_as);
                const to = try self.parseType();
                _ = try self.expect(.sym_rparen);
                e.* = .{ .cast = .{ .expr = inner, .to = to } };
            },
            .kw_case => {
                _ = try self.advance();
                return self.parseCaseExpr();
            },
            .kw_exists => {
                _ = try self.advance();
                _ = try self.expect(.sym_lparen);
                const q = try self.arenaAlloc(ast.SelectStmt);
                q.* = try self.parseSelect();
                _ = try self.expect(.sym_rparen);
                e.* = .{ .exists = q };
            },
            .sym_lparen => {
                _ = try self.advance();
                const k2 = try self.peekKind();
                if (k2 == .kw_select or k2 == .kw_with) {
                    const q = try self.arenaAlloc(ast.SelectStmt);
                    q.* = try self.parseSelect();
                    _ = try self.expect(.sym_rparen);
                    e.* = .{ .subquery = q };
                } else {
                    const inner = try self.parseExpr();
                    _ = try self.expect(.sym_rparen);
                    return inner;
                }
            },
            .ident => return self.parseIdentOrFnCall(),
            else => {
                // keywords usable as function names (e.g. built-ins)
                if (isBuiltinFn(t.kind)) return self.parseIdentOrFnCall();
                self.err_pos = t.span.start;
                self.err_msg = "unexpected token in expression";
                return error.UnexpectedToken;
            },
        }
        return e;
    }

    fn parseCaseExpr(self: *Parser) ParseError!*ast.Expr {
        // CASE [operand] WHEN ... THEN ... [ELSE ...] END
        const k = try self.peekKind();
        const operand: ?*ast.Expr = if (k != .kw_when) try self.parseExpr() else null;
        var whens: std.ArrayList(ast.CaseWhen) = .empty;
        while (try self.eat(.kw_when)) {
            const cond = try self.parseExpr();
            _ = try self.expect(.kw_then);
            const result = try self.parseExpr();
            try whens.append(self.arena, .{ .cond = cond, .result = result });
        }
        const else_expr = if (try self.eat(.kw_else)) try self.parseExpr() else null;
        _ = try self.expect(.kw_end);
        const e = try self.arenaAlloc(ast.Expr);
        if (operand) |op| {
            e.* = .{ .case_simple = .{
                .operand = op,
                .whens = try whens.toOwnedSlice(self.arena),
                .else_expr = else_expr,
            } };
        } else {
            e.* = .{ .case_searched = .{
                .whens = try whens.toOwnedSlice(self.arena),
                .else_expr = else_expr,
            } };
        }
        return e;
    }

    fn parseIdentOrFnCall(self: *Parser) ParseError!*ast.Expr {
        const t = try self.advance();
        const name = t.text(self.src);

        // Check for nondeterministic functions
        if (std.ascii.eqlIgnoreCase(name, "now")) {
            if (try self.eat(.sym_lparen)) {
                _ = try self.expect(.sym_rparen);
            }
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .nondet = .now };
            return e;
        }
        if (std.ascii.eqlIgnoreCase(name, "random")) {
            if (try self.eat(.sym_lparen)) {
                _ = try self.expect(.sym_rparen);
            }
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .nondet = .random };
            return e;
        }
        if (std.ascii.eqlIgnoreCase(name, "uuid") or std.ascii.eqlIgnoreCase(name, "uuid_generate_v7")) {
            if (try self.eat(.sym_lparen)) {
                _ = try self.expect(.sym_rparen);
            }
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .nondet = .uuid_v7 };
            return e;
        }

        // Qualified: table.column
        if ((try self.peekKind()) == .sym_dot) {
            _ = try self.advance();
            const col = try self.expectIdent();
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .column_ref = .{ .table = name, .column = col } };
            return e;
        }

        // Function call
        if (try self.eat(.sym_lparen)) {
            var distinct = false;
            var star = false;
            if ((try self.peekKind()) == .op_star) {
                _ = try self.advance();
                star = true;
            } else {
                if (try self.eat(.kw_distinct)) {
                    distinct = true;
                }
            }
            var args: std.ArrayList(*ast.Expr) = .empty;
            if (!star and (try self.peekKind()) != .sym_rparen) {
                while (true) {
                    assert(args.items.len < MAX_PARSE_ITEMS);
                    try args.append(self.arena, try self.parseExpr());
                    if (!try self.eat(.sym_comma)) break;
                }
            }
            _ = try self.expect(.sym_rparen);
            var fn_call = ast.FnCall{
                .name = name,
                .args = try args.toOwnedSlice(self.arena),
                .distinct = distinct,
                .star = star,
            };
            // Check for OVER clause → window function
            if (try self.eat(.kw_over)) {
                _ = try self.expect(.sym_lparen);
                const spec = try self.parseWindowSpec();
                _ = try self.expect(.sym_rparen);
                const e = try self.arenaAlloc(ast.Expr);
                e.* = .{ .window_fn = .{ .call = fn_call, .window = spec } };
                return e;
            }
            // Check for FILTER clause
            if (try self.eat(.kw_filter)) {
                _ = try self.expect(.sym_lparen);
                _ = try self.expect(.kw_where);
                fn_call.filter = try self.parseExpr();
                _ = try self.expect(.sym_rparen);
            }
            const e = try self.arenaAlloc(ast.Expr);
            e.* = .{ .fn_call = fn_call };
            return e;
        }

        // Bare column reference
        const e = try self.arenaAlloc(ast.Expr);
        e.* = .{ .column_ref = .{ .table = null, .column = name } };
        return e;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    fn arenaAlloc(self: *Parser, comptime T: type) ParseError!*T {
        return self.arena.create(T);
    }

    fn unescapeString(self: *Parser, raw: []const u8) ParseError![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\'' and i + 1 < raw.len and raw[i + 1] == '\'') {
                try out.append(self.arena, '\'');
                i += 2;
            } else {
                try out.append(self.arena, raw[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    fn unhexBytes(self: *Parser, hex: []const u8) ParseError![]const u8 {
        if (hex.len % 2 != 0) return error.UnexpectedToken;
        const out = try self.arena.alloc(u8, hex.len / 2);
        for (0..out.len) |i| {
            const hi = try hexDigit(hex[i * 2]);
            const lo = try hexDigit(hex[i * 2 + 1]);
            out[i] = (hi << 4) | lo;
        }
        return out;
    }
};

fn hexDigit(c: u8) ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.UnexpectedToken,
    };
}

fn isKeywordUsableAsIdent(k: TokenKind) bool {
    return switch (k) {
        // Non-reserved keywords usable as identifiers in unambiguous positions
        .kw_index, .kw_key, .kw_first, .kw_last, .kw_filter, .kw_row, .kw_rows, .kw_range, .kw_window, .kw_partition, .kw_over, .kw_nulls, .kw_recursive, .kw_path, .kw_hash, .kw_ordered, .kw_vector, .kw_months, .kw_micros, .kw_wrapping, .kw_current, .kw_following, .kw_preceding, .kw_unbounded, .kw_offset, .kw_nothing, .kw_do, .kw_conflict, .kw_returning => true,
        else => false,
    };
}

fn isBuiltinFn(k: TokenKind) bool {
    return switch (k) {
        // Type names usable as cast/constructor functions
        .kw_bool,
        .kw_int8,
        .kw_int16,
        .kw_int32,
        .kw_int64,
        .kw_uint8,
        .kw_uint16,
        .kw_uint32,
        .kw_uint64,
        .kw_float32,
        .kw_float64,
        .kw_decimal,
        .kw_string,
        .kw_bytes,
        .kw_uuid,
        .kw_timestamp,
        .kw_json,
        .kw_array,
        .kw_struct,
        // Aggregate keywords that appear as function names
        .kw_exists,
        => true,
        else => false,
    };
}

// Public API
pub fn parse(src: []const u8, arena: std.mem.Allocator) ParseError!ast.ParsedQuery {
    var p = Parser.init(src, arena);
    return p.parseQuery();
}

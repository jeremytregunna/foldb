const std = @import("std");

pub const TokenKind = enum {
    // Literals
    lit_int,
    lit_float,
    lit_string,
    lit_bytes,
    lit_true,
    lit_false,
    lit_null,

    // Identifier (bare or "double-quoted")
    ident,

    // Parameter: $1, $2, ...
    param,

    // DDL
    kw_create, kw_table, kw_index, kw_alter,
    kw_add, kw_drop, kw_column, kw_primary,
    kw_key, kw_unique, kw_ordered, kw_hash,
    kw_vector, kw_path,

    // DML
    kw_select, kw_from, kw_where, kw_insert,
    kw_into, kw_update, kw_delete, kw_merge,
    kw_using, kw_matched, kw_values, kw_set,
    kw_returning, kw_conflict, kw_do, kw_nothing,
    kw_when, kw_then,

    // Query structure
    kw_with, kw_as, kw_join, kw_inner,
    kw_left, kw_right, kw_full, kw_outer,
    kw_cross, kw_on, kw_group, kw_by,
    kw_having, kw_order, kw_asc, kw_desc,
    kw_limit, kw_offset, kw_distinct, kw_all,
    kw_exists, kw_in, kw_between, kw_like,
    kw_is, kw_not, kw_and, kw_or,
    kw_case, kw_else, kw_end, kw_cast,
    kw_window, kw_over, kw_partition, kw_rows,
    kw_range, kw_unbounded, kw_preceding, kw_following,
    kw_current, kw_row, kw_filter, kw_of,
    kw_nulls, kw_first, kw_last, kw_recursive,

    // Types
    kw_bool,
    kw_int8, kw_int16, kw_int32, kw_int64,
    kw_uint8, kw_uint16, kw_uint32, kw_uint64,
    kw_float32, kw_float64, kw_decimal,
    kw_string, kw_bytes, kw_uuid,
    kw_timestamp, kw_interval, kw_months, kw_micros,
    kw_json, kw_array, kw_struct, kw_wrapping,

    // Transaction block
    kw_transaction, kw_assert,

    // Operators
    op_eq,        // =
    op_neq,       // != or <>
    op_lt,        // <
    op_gt,        // >
    op_lte,       // <=
    op_gte,       // >=
    op_plus,      // +
    op_minus,     // -
    op_star,      // *
    op_slash,     // /
    op_percent,   // %
    op_concat,    // ||
    op_cast_op,   // ::
    op_arrow,     // ->
    op_darrow,    // ->>
    op_contains,  // @>
    op_contained, // <@
    op_pipe,      // |
    op_amp,       // &
    op_hat,       // ^
    op_tilde,     // ~
    op_lshift,    // <<
    op_rshift,    // >>
    op_at,        // @

    // Symbols
    sym_lparen, sym_rparen,
    sym_lbracket, sym_rbracket,
    sym_lbrace, sym_rbrace,
    sym_comma, sym_semicolon,
    sym_dot, sym_colon, sym_bang,

    eof,
    invalid,
};

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn slice(self: Span, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }
};

pub const Token = struct {
    kind: TokenKind,
    span: Span,

    pub fn text(self: Token, src: []const u8) []const u8 {
        return self.span.slice(src);
    }
};

fn eqci(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

const Keyword = struct { word: []const u8, kind: TokenKind };

const KEYWORDS = [_]Keyword{
    .{ .word = "add", .kind = .kw_add },
    .{ .word = "all", .kind = .kw_all },
    .{ .word = "alter", .kind = .kw_alter },
    .{ .word = "and", .kind = .kw_and },
    .{ .word = "array", .kind = .kw_array },
    .{ .word = "as", .kind = .kw_as },
    .{ .word = "asc", .kind = .kw_asc },
    .{ .word = "assert", .kind = .kw_assert },
    .{ .word = "between", .kind = .kw_between },
    .{ .word = "bool", .kind = .kw_bool },
    .{ .word = "by", .kind = .kw_by },
    .{ .word = "bytes", .kind = .kw_bytes },
    .{ .word = "case", .kind = .kw_case },
    .{ .word = "cast", .kind = .kw_cast },
    .{ .word = "column", .kind = .kw_column },
    .{ .word = "conflict", .kind = .kw_conflict },
    .{ .word = "create", .kind = .kw_create },
    .{ .word = "cross", .kind = .kw_cross },
    .{ .word = "current", .kind = .kw_current },
    .{ .word = "decimal", .kind = .kw_decimal },
    .{ .word = "delete", .kind = .kw_delete },
    .{ .word = "desc", .kind = .kw_desc },
    .{ .word = "distinct", .kind = .kw_distinct },
    .{ .word = "do", .kind = .kw_do },
    .{ .word = "drop", .kind = .kw_drop },
    .{ .word = "else", .kind = .kw_else },
    .{ .word = "end", .kind = .kw_end },
    .{ .word = "exists", .kind = .kw_exists },
    .{ .word = "false", .kind = .lit_false },
    .{ .word = "filter", .kind = .kw_filter },
    .{ .word = "first", .kind = .kw_first },
    .{ .word = "float32", .kind = .kw_float32 },
    .{ .word = "float64", .kind = .kw_float64 },
    .{ .word = "following", .kind = .kw_following },
    .{ .word = "from", .kind = .kw_from },
    .{ .word = "full", .kind = .kw_full },
    .{ .word = "group", .kind = .kw_group },
    .{ .word = "hash", .kind = .kw_hash },
    .{ .word = "having", .kind = .kw_having },
    .{ .word = "in", .kind = .kw_in },
    .{ .word = "index", .kind = .kw_index },
    .{ .word = "inner", .kind = .kw_inner },
    .{ .word = "insert", .kind = .kw_insert },
    .{ .word = "int16", .kind = .kw_int16 },
    .{ .word = "int32", .kind = .kw_int32 },
    .{ .word = "int64", .kind = .kw_int64 },
    .{ .word = "int8", .kind = .kw_int8 },
    .{ .word = "interval", .kind = .kw_interval },
    .{ .word = "into", .kind = .kw_into },
    .{ .word = "is", .kind = .kw_is },
    .{ .word = "join", .kind = .kw_join },
    .{ .word = "json", .kind = .kw_json },
    .{ .word = "key", .kind = .kw_key },
    .{ .word = "last", .kind = .kw_last },
    .{ .word = "left", .kind = .kw_left },
    .{ .word = "like", .kind = .kw_like },
    .{ .word = "limit", .kind = .kw_limit },
    .{ .word = "matched", .kind = .kw_matched },
    .{ .word = "merge", .kind = .kw_merge },
    .{ .word = "micros", .kind = .kw_micros },
    .{ .word = "months", .kind = .kw_months },
    .{ .word = "not", .kind = .kw_not },
    .{ .word = "nothing", .kind = .kw_nothing },
    .{ .word = "null", .kind = .lit_null },
    .{ .word = "nulls", .kind = .kw_nulls },
    .{ .word = "of", .kind = .kw_of },
    .{ .word = "offset", .kind = .kw_offset },
    .{ .word = "on", .kind = .kw_on },
    .{ .word = "or", .kind = .kw_or },
    .{ .word = "order", .kind = .kw_order },
    .{ .word = "ordered", .kind = .kw_ordered },
    .{ .word = "outer", .kind = .kw_outer },
    .{ .word = "over", .kind = .kw_over },
    .{ .word = "partition", .kind = .kw_partition },
    .{ .word = "path", .kind = .kw_path },
    .{ .word = "preceding", .kind = .kw_preceding },
    .{ .word = "primary", .kind = .kw_primary },
    .{ .word = "range", .kind = .kw_range },
    .{ .word = "recursive", .kind = .kw_recursive },
    .{ .word = "returning", .kind = .kw_returning },
    .{ .word = "right", .kind = .kw_right },
    .{ .word = "row", .kind = .kw_row },
    .{ .word = "rows", .kind = .kw_rows },
    .{ .word = "select", .kind = .kw_select },
    .{ .word = "set", .kind = .kw_set },
    .{ .word = "string", .kind = .kw_string },
    .{ .word = "struct", .kind = .kw_struct },
    .{ .word = "table", .kind = .kw_table },
    .{ .word = "then", .kind = .kw_then },
    .{ .word = "timestamp", .kind = .kw_timestamp },
    .{ .word = "transaction", .kind = .kw_transaction },
    .{ .word = "true", .kind = .lit_true },
    .{ .word = "uint16", .kind = .kw_uint16 },
    .{ .word = "uint32", .kind = .kw_uint32 },
    .{ .word = "uint64", .kind = .kw_uint64 },
    .{ .word = "uint8", .kind = .kw_uint8 },
    .{ .word = "unbounded", .kind = .kw_unbounded },
    .{ .word = "unique", .kind = .kw_unique },
    .{ .word = "update", .kind = .kw_update },
    .{ .word = "using", .kind = .kw_using },
    .{ .word = "uuid", .kind = .kw_uuid },
    .{ .word = "values", .kind = .kw_values },
    .{ .word = "vector", .kind = .kw_vector },
    .{ .word = "when", .kind = .kw_when },
    .{ .word = "where", .kind = .kw_where },
    .{ .word = "window", .kind = .kw_window },
    .{ .word = "with", .kind = .kw_with },
    .{ .word = "wrapping", .kind = .kw_wrapping },
};

pub fn lookupKeyword(s: []const u8) ?TokenKind {
    for (&KEYWORDS) |kw| {
        if (eqci(s, kw.word)) return kw.kind;
    }
    return null;
}

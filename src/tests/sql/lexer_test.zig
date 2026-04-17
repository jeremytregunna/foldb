const std = @import("std");
const sql = @import("sql.zig");
const lexer_mod = sql.lexer;
const token_mod = sql.token;

const TokenKind = token_mod.TokenKind;

fn tokenize(src: []const u8, alloc: std.mem.Allocator) ![]token_mod.Token {
    return lexer_mod.tokenizeAll(src, alloc);
}

test "lex keywords" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("SELECT FROM WHERE INSERT UPDATE DELETE", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.kw_select, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.kw_from, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.kw_where, tokens[2].kind);
    try std.testing.expectEqual(TokenKind.kw_insert, tokens[3].kind);
    try std.testing.expectEqual(TokenKind.kw_update, tokens[4].kind);
    try std.testing.expectEqual(TokenKind.kw_delete, tokens[5].kind);
    try std.testing.expectEqual(TokenKind.eof, tokens[6].kind);
}

test "lex identifiers" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("foo bar baz", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.ident, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.ident, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.ident, tokens[2].kind);
}

test "lex quoted identifier" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("\"my table\"", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.ident, tokens[0].kind);
}

test "lex string literal" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("'hello world'", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.lit_string, tokens[0].kind);
}

test "lex integer literal" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("42 -1 0", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.lit_int, tokens[0].kind);
}

test "lex float literal" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("3.14 1.0e10", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.lit_float, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.lit_float, tokens[1].kind);
}

test "lex param" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("$1 $2 $10", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.param, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.param, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.param, tokens[2].kind);
}

test "lex operators" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("= != <> <= >= || ::", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.op_eq, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.op_neq, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.op_neq, tokens[2].kind);
    try std.testing.expectEqual(TokenKind.op_lte, tokens[3].kind);
    try std.testing.expectEqual(TokenKind.op_gte, tokens[4].kind);
    try std.testing.expectEqual(TokenKind.op_concat, tokens[5].kind);
    try std.testing.expectEqual(TokenKind.op_cast_op, tokens[6].kind);
}

test "lex true false null" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("true false null TRUE FALSE NULL", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.lit_true, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.lit_false, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.lit_null, tokens[2].kind);
    try std.testing.expectEqual(TokenKind.lit_true, tokens[3].kind);
    try std.testing.expectEqual(TokenKind.lit_false, tokens[4].kind);
    try std.testing.expectEqual(TokenKind.lit_null, tokens[5].kind);
}

test "lex line comment" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("foo -- this is a comment\nbar", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.ident, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.ident, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.eof, tokens[2].kind);
}

test "lex block comment" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize("foo /* block comment */ bar", alloc);
    defer alloc.free(tokens);
    try std.testing.expectEqual(TokenKind.ident, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.ident, tokens[1].kind);
}

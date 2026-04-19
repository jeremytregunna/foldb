const std = @import("std");
const token = @import("token.zig");
pub const Token = token.Token;
pub const TokenKind = token.TokenKind;
pub const Span = token.Span;

pub const LexError = error{
    UnterminatedString,
    UnterminatedBlockComment,
    InvalidByteLiteral,
    InvalidParam,
    InvalidChar,
};

pub const Lexer = struct {
    src: []const u8,
    pos: u32,
    /// peek buffer: if non-null, next() returns this without advancing src
    peeked: ?Token = null,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src, .pos = 0 };
    }

    pub fn peek(self: *Lexer) LexError!Token {
        if (self.peeked == null) {
            self.peeked = try self.advance();
        }
        return self.peeked.?;
    }

    pub fn next(self: *Lexer) LexError!Token {
        if (self.peeked) |p| {
            self.peeked = null;
            return p;
        }
        return self.advance();
    }

    fn advance(self: *Lexer) LexError!Token {
        self.skipWhitespace();
        self.skipComments() catch |e| return e;
        self.skipWhitespace();

        if (self.pos >= self.src.len) {
            return self.tok(.eof, self.pos, self.pos);
        }

        const start = self.pos;
        const c = self.src[self.pos];

        if (c == '$') {
            self.pos += 1;
            const inner_start = self.pos;
            if (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                    self.pos += 1;
                }
                return self.tok(.param, start, self.pos);
            }
            while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) {
                self.pos += 1;
            }
            if (self.pos == inner_start) return error.InvalidParam;
            return self.tok(.param_named, start, self.pos);
        }

        if (c == '\'') return self.lexString(start);
        if ((c == 'x' or c == 'X') and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
            return self.lexBytes(start);
        }
        if (c == '"') return self.lexQuotedIdent(start);
        if (std.ascii.isAlphabetic(c) or c == '_') return self.lexIdent(start);
        if (std.ascii.isDigit(c)) return self.lexNumber(start);

        return self.lexOperatorOrSymbol(start);
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) {
            self.pos += 1;
        }
    }

    fn skipComments(self: *Lexer) LexError!void {
        while (self.pos + 1 < self.src.len) {
            if (self.src[self.pos] == '-' and self.src[self.pos + 1] == '-') {
                // single-line comment
                self.pos += 2;
                while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                    self.pos += 1;
                }
                self.skipWhitespace();
            } else if (self.src[self.pos] == '/' and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                var depth: u32 = 1;
                while (self.pos + 1 < self.src.len and depth > 0) {
                    if (self.src[self.pos] == '/' and self.src[self.pos + 1] == '*') {
                        depth += 1;
                        self.pos += 2;
                    } else if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        depth -= 1;
                        self.pos += 2;
                    } else {
                        self.pos += 1;
                    }
                }
                if (depth != 0) return error.UnterminatedBlockComment;
                self.skipWhitespace();
            } else {
                break;
            }
        }
    }

    fn lexString(self: *Lexer, start: u32) LexError!Token {
        self.pos += 1; // consume opening '
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '\'') {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '\'') {
                    // escaped ''
                    self.pos += 1;
                } else {
                    return self.tok(.lit_string, start, self.pos);
                }
            } else {
                self.pos += 1;
            }
        }
        return error.UnterminatedString;
    }

    fn lexBytes(self: *Lexer, start: u32) LexError!Token {
        self.pos += 2; // consume x'
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == '\'') {
                self.pos += 1;
                return self.tok(.lit_bytes, start, self.pos);
            }
            if (!std.ascii.isHex(ch)) return error.InvalidByteLiteral;
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    fn lexQuotedIdent(self: *Lexer, start: u32) LexError!Token {
        self.pos += 1; // consume "
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '"') {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '"') {
                    self.pos += 1; // escaped ""
                } else {
                    return self.tok(.ident, start, self.pos);
                }
            } else {
                self.pos += 1;
            }
        }
        return error.UnterminatedString;
    }

    fn lexIdent(self: *Lexer, start: u32) LexError!Token {
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }
        const word = self.src[start..self.pos];
        const kind = token.lookupKeyword(word) orelse .ident;
        return self.tok(kind, start, self.pos);
    }

    fn lexNumber(self: *Lexer, start: u32) LexError!Token {
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
            self.pos += 1;
        }
        var is_float = false;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            const next_pos = self.pos + 1;
            if (next_pos < self.src.len and std.ascii.isDigit(self.src[next_pos])) {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                    self.pos += 1;
                }
            }
        }
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) {
                self.pos += 1;
            }
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                self.pos += 1;
            }
        }
        return self.tok(if (is_float) .lit_float else .lit_int, start, self.pos);
    }

    fn lexOperatorOrSymbol(self: *Lexer, start: u32) LexError!Token {
        const c = self.src[self.pos];
        self.pos += 1;
        const has_next = self.pos < self.src.len;
        const next_c: u8 = if (has_next) self.src[self.pos] else 0;

        switch (c) {
            '(' => return self.tok(.sym_lparen, start, self.pos),
            ')' => return self.tok(.sym_rparen, start, self.pos),
            '[' => return self.tok(.sym_lbracket, start, self.pos),
            ']' => return self.tok(.sym_rbracket, start, self.pos),
            '{' => return self.tok(.sym_lbrace, start, self.pos),
            '}' => return self.tok(.sym_rbrace, start, self.pos),
            ',' => return self.tok(.sym_comma, start, self.pos),
            ';' => return self.tok(.sym_semicolon, start, self.pos),
            '.' => return self.tok(.sym_dot, start, self.pos),
            '%' => return self.tok(.op_percent, start, self.pos),
            '+' => return self.tok(.op_plus, start, self.pos),
            '*' => return self.tok(.op_star, start, self.pos),
            '/' => return self.tok(.op_slash, start, self.pos),
            '^' => return self.tok(.op_hat, start, self.pos),
            '~' => return self.tok(.op_tilde, start, self.pos),
            '&' => return self.tok(.op_amp, start, self.pos),
            '=' => return self.tok(.op_eq, start, self.pos),
            '!' => {
                if (has_next and next_c == '=') {
                    self.pos += 1;
                    return self.tok(.op_neq, start, self.pos);
                }
                return self.tok(.sym_bang, start, self.pos);
            },
            '<' => {
                if (has_next and next_c == '=') {
                    self.pos += 1;
                    return self.tok(.op_lte, start, self.pos);
                }
                if (has_next and next_c == '>') {
                    self.pos += 1;
                    return self.tok(.op_neq, start, self.pos);
                }
                if (has_next and next_c == '<') {
                    self.pos += 1;
                    return self.tok(.op_lshift, start, self.pos);
                }
                if (has_next and next_c == '@') {
                    self.pos += 1;
                    return self.tok(.op_contained, start, self.pos);
                }
                return self.tok(.op_lt, start, self.pos);
            },
            '>' => {
                if (has_next and next_c == '=') {
                    self.pos += 1;
                    return self.tok(.op_gte, start, self.pos);
                }
                if (has_next and next_c == '>') {
                    self.pos += 1;
                    return self.tok(.op_rshift, start, self.pos);
                }
                return self.tok(.op_gt, start, self.pos);
            },
            '-' => {
                if (has_next and next_c == '>') {
                    self.pos += 1;
                    if (self.pos < self.src.len and self.src[self.pos] == '>') {
                        self.pos += 1;
                        return self.tok(.op_darrow, start, self.pos);
                    }
                    return self.tok(.op_arrow, start, self.pos);
                }
                return self.tok(.op_minus, start, self.pos);
            },
            '|' => {
                if (has_next and next_c == '|') {
                    self.pos += 1;
                    return self.tok(.op_concat, start, self.pos);
                }
                return self.tok(.op_pipe, start, self.pos);
            },
            ':' => {
                if (has_next and next_c == ':') {
                    self.pos += 1;
                    return self.tok(.op_cast_op, start, self.pos);
                }
                return self.tok(.sym_colon, start, self.pos);
            },
            '@' => {
                if (has_next and next_c == '>') {
                    self.pos += 1;
                    return self.tok(.op_contains, start, self.pos);
                }
                return self.tok(.op_at, start, self.pos);
            },
            else => return self.tok(.invalid, start, self.pos),
        }
    }

    fn tok(self: *Lexer, kind: TokenKind, start: u32, end: u32) Token {
        _ = self;
        return .{ .kind = kind, .span = .{ .start = start, .end = end } };
    }
};

/// Tokenize the entire source into a slice. Caller owns the result.
pub fn tokenizeAll(src: []const u8, alloc: std.mem.Allocator) ![]Token {
    var list: std.ArrayList(Token) = .empty;
    var lex = Lexer.init(src);
    while (true) {
        const t = try lex.next();
        try list.append(alloc, t);
        if (t.kind == .eof) break;
    }
    return list.toOwnedSlice(alloc);
}

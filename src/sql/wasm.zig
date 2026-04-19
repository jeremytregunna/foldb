/// WASM module integration for foldb server-side logic.
///
/// Strategy for M5:
///   - Validate WASM module at registration time (no threads, no non-whitelisted imports,
///     no nondeterministic opcodes).
///   - Provide a pure-Zig evaluator for simple scalar functions (integer arithmetic,
///     string operations, basic control flow).
///   - Wasmtime FFI is scaffolded but not wired up — see TODO below.
///
/// §10.6: Constraints
///   - No SIMD floats with NaN-propagation variance.
///   - No threads (shared memory proposals).
///   - No host function calls except a whitelisted set for reading inputs/writing outputs.
const std = @import("std");

pub const WasmError = error{
    InvalidMagic,
    InvalidVersion,
    NonDeterministicFeature,
    ForbiddenImport,
    ForbiddenOpcode,
    ParseError,
    UnsupportedSection,
    FunctionNotFound,
    ExecutionTrap,
    TypeMismatch,
    OutOfMemory,
};

const WASM_MAGIC: [4]u8 = .{ 0x00, 0x61, 0x73, 0x6D };
const WASM_VERSION: [4]u8 = .{ 0x01, 0x00, 0x00, 0x00 };

/// Sections of a WASM binary (§5 of the WASM spec).
const Section = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    datacount = 12,
    _,
};

/// Opcodes forbidden for determinism.
const FORBIDDEN_OPCODES = [_]u8{
    0x00, // unreachable — allowed, but marks a trap
    // Thread-related opcodes (0xFE prefix):
    // We reject any 0xFE-prefixed instruction.
};

/// Allowed host import modules.
const ALLOWED_IMPORT_MODULES = [_][]const u8{
    "foldb", // foldb's own host API
};

/// Allowed foldb host functions (foldb module).
const ALLOWED_IMPORTS = [_][]const u8{
    "read_param", // read an input parameter
    "write_output", // write an output value
    "read_int",
    "read_float",
    "read_string",
    "write_int",
    "write_float",
    "write_string",
    "write_bool",
    "abort", // signal a constraint violation
};

/// Validated WASM module, ready for evaluation.
pub const WasmModule = struct {
    /// BLAKE3 of the original module bytes.
    hash: [32]u8,
    /// Parsed function signatures (name → type index).
    exports: []const Export,
    /// Raw code section bytes, for the evaluator.
    code_bytes: []const u8,
    /// Parsed type section.
    types: []const FuncType,
    /// Function code entries.
    functions: []const FuncCode,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *WasmModule) void {
        self.alloc.free(self.exports);
        self.alloc.free(self.types);
        for (self.functions) |f| self.alloc.free(f.locals);
        self.alloc.free(self.functions);
    }

    pub fn findExport(self: *const WasmModule, name: []const u8) ?u32 {
        for (self.exports) |exp| {
            if (std.mem.eql(u8, exp.name, name)) return exp.func_idx;
        }
        return null;
    }
};

pub const Export = struct { name: []const u8, func_idx: u32 };

pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

pub const LocalDecl = struct { count: u32, typ: ValType };

pub const FuncCode = struct {
    locals: []const LocalDecl,
    body: []const u8, // raw bytes of the function body
};

// ─── Validator ────────────────────────────────────────────────────────────────

// This is the domain boundary — raw WASM bytes from external sources (client upload,
// object store) are validated here: magic, version, import whitelist, and forbidden
// opcodes. Only a proven-valid WasmModule crosses past this point; the Evaluator
// and any core logic never receive unvalidated bytes.
pub fn validate(bytes: []const u8, alloc: std.mem.Allocator) WasmError!WasmModule {
    if (bytes.len < 8) return error.InvalidMagic;
    if (!std.mem.eql(u8, bytes[0..4], &WASM_MAGIC)) return error.InvalidMagic;
    if (!std.mem.eql(u8, bytes[4..8], &WASM_VERSION)) return error.InvalidVersion;

    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &hash, .{});

    var pos: usize = 8;
    var types: []const FuncType = &.{};
    var exports: []const Export = &.{};
    var functions: []const FuncCode = &.{};
    var code_bytes: []const u8 = &.{};

    while (pos < bytes.len) {
        if (pos >= bytes.len) break;
        const section_id = bytes[pos];
        pos += 1;
        const section_len, const len_bytes = readUleb128(bytes[pos..]) orelse return error.ParseError;
        pos += len_bytes;
        const section_data = bytes[pos .. pos + section_len];
        pos += section_len;

        const section = @as(Section, @enumFromInt(section_id));
        switch (section) {
            .type => types = try parseTypeSection(section_data, alloc),
            .import => try validateImportSection(section_data),
            .@"export" => exports = try parseExportSection(section_data, alloc),
            .code => {
                code_bytes = section_data;
                functions = try parseCodeSection(section_data, alloc);
                try validateCodeSection(section_data);
            },
            .custom => {
                // Custom sections may contain name information or debug info — allowed.
                // Reject "threads" feature section.
                if (section_data.len >= 7 and std.mem.eql(u8, section_data[0..7], "threads")) {
                    return error.NonDeterministicFeature;
                }
            },
            else => {}, // other sections allowed
        }
    }

    return .{
        .hash = hash,
        .exports = exports,
        .code_bytes = code_bytes,
        .types = types,
        .functions = functions,
        .alloc = alloc,
    };
}

fn validateImportSection(data: []const u8) WasmError!void {
    var pos: usize = 0;
    const count, const cb = readUleb128(data) orelse return error.ParseError;
    pos += cb;
    for (0..count) |_| {
        const mod_len, const mlb = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += mlb;
        const mod_name = data[pos .. pos + mod_len];
        pos += mod_len;

        const name_len, const nlb = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += nlb;
        const import_name = data[pos .. pos + name_len];
        pos += name_len;

        // Skip type byte + index
        pos += 1;
        _, const idx_bytes = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += idx_bytes;

        // Validate module name
        var allowed = false;
        for (ALLOWED_IMPORT_MODULES) |m| {
            if (std.mem.eql(u8, mod_name, m)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return error.ForbiddenImport;

        // Validate function name
        var fn_allowed = false;
        for (ALLOWED_IMPORTS) |fn_name| {
            if (std.mem.eql(u8, import_name, fn_name)) {
                fn_allowed = true;
                break;
            }
        }
        if (!fn_allowed) return error.ForbiddenImport;
    }
}

fn validateCodeSection(data: []const u8) WasmError!void {
    var pos: usize = 0;
    const count, const cb = readUleb128(data) orelse return error.ParseError;
    pos += cb;
    for (0..count) |_| {
        const body_size, const bsb = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += bsb;
        const body = data[pos .. pos + body_size];
        pos += body_size;
        try validateFunctionBody(body);
    }
}

fn validateFunctionBody(body: []const u8) WasmError!void {
    var pos: usize = 0;
    // Skip local declarations
    const local_count, const lc = readUleb128(body) orelse return error.ParseError;
    pos += lc;
    for (0..local_count) |_| {
        _, const nc = readUleb128(body[pos..]) orelse return error.ParseError;
        pos += nc;
        pos += 1; // value type byte
    }
    // Scan opcodes
    while (pos < body.len) {
        const opcode = body[pos];
        pos += 1;
        // Reject thread opcodes (0xFE prefix)
        if (opcode == 0xFE) return error.NonDeterministicFeature;
        // Reject SIMD opcodes (0xFD prefix) — they can have NaN-propagation variance
        if (opcode == 0xFD) return error.NonDeterministicFeature;
        pos += opcodeImmediateSize(opcode, body[pos..]) catch return error.ParseError;
    }
}

fn opcodeImmediateSize(opcode: u8, rest: []const u8) !usize {
    return switch (opcode) {
        0x00...0x0F => 0, // control flow without immediates
        0x02, 0x03, 0x04 => blk: { // block, loop, if (block type)
            if (rest.len == 0) return error.ParseError;
            // block type is either a valtype or -1 (0x40) for void, or a type index
            break :blk 1; // simplified
        },
        0x0C, 0x0D => blk: { // br, br_if
            _, const n = readUleb128(rest) orelse return error.ParseError;
            break :blk n;
        },
        0x0E => blk: { // br_table
            const count, const cb = readUleb128(rest) orelse return error.ParseError;
            var sz: usize = cb;
            for (0..count + 1) |_| {
                _, const n = readUleb128(rest[sz..]) orelse return error.ParseError;
                sz += n;
            }
            break :blk sz;
        },
        0x10 => blk: { // call
            _, const n = readUleb128(rest) orelse return error.ParseError;
            break :blk n;
        },
        0x11 => blk: { // call_indirect
            _, const n1 = readUleb128(rest) orelse return error.ParseError;
            _, const n2 = readUleb128(rest[n1..]) orelse return error.ParseError;
            break :blk n1 + n2;
        },
        0x20...0x24 => blk: { // local.get/set/tee, global.get/set
            _, const n = readUleb128(rest) orelse return error.ParseError;
            break :blk n;
        },
        0x28...0x3E => blk: { // memory load/store instructions (alignment + offset)
            _, const n1 = readUleb128(rest) orelse return error.ParseError;
            _, const n2 = readUleb128(rest[n1..]) orelse return error.ParseError;
            break :blk n1 + n2;
        },
        0x3F, 0x40 => 1, // memory.size, memory.grow
        0x41 => blk: { // i32.const
            _, const n = readSleb128(rest) orelse return error.ParseError;
            break :blk n;
        },
        0x42 => blk: { // i64.const
            _, const n = readSleb128(rest) orelse return error.ParseError;
            break :blk n;
        },
        0x43 => 4, // f32.const
        0x44 => 8, // f64.const
        else => 0,
    };
}

fn parseTypeSection(data: []const u8, alloc: std.mem.Allocator) WasmError![]const FuncType {
    var pos: usize = 0;
    const count, const cb = readUleb128(data) orelse return error.ParseError;
    pos += cb;
    const types = try alloc.alloc(FuncType, count);
    for (0..count) |i| {
        if (data[pos] != 0x60) return error.ParseError; // func type marker
        pos += 1;
        const param_count, const pc = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += pc;
        const params = try alloc.alloc(ValType, param_count);
        for (0..param_count) |j| {
            params[j] = @enumFromInt(data[pos]);
            pos += 1;
        }
        const result_count, const rc = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += rc;
        const results = try alloc.alloc(ValType, result_count);
        for (0..result_count) |j| {
            results[j] = @enumFromInt(data[pos]);
            pos += 1;
        }
        types[i] = .{ .params = params, .results = results };
    }
    return types;
}

fn parseExportSection(data: []const u8, alloc: std.mem.Allocator) WasmError![]const Export {
    var pos: usize = 0;
    const count, const cb = readUleb128(data) orelse return error.ParseError;
    pos += cb;
    const exports = try alloc.alloc(Export, count);
    for (0..count) |i| {
        const name_len, const nlb = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += nlb;
        const name = data[pos .. pos + name_len];
        pos += name_len;
        const kind = data[pos];
        pos += 1;
        const idx, const ib = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += ib;
        if (kind == 0x00) { // function export
            exports[i] = .{ .name = name, .func_idx = @intCast(idx) };
        }
    }
    return exports;
}

fn parseCodeSection(data: []const u8, alloc: std.mem.Allocator) WasmError![]const FuncCode {
    var pos: usize = 0;
    const count, const cb = readUleb128(data) orelse return error.ParseError;
    pos += cb;
    const functions = try alloc.alloc(FuncCode, count);
    for (0..count) |i| {
        const body_size, const bsb = readUleb128(data[pos..]) orelse return error.ParseError;
        pos += bsb;
        const body_start = pos;
        const body = data[pos .. pos + body_size];
        pos += body_size;

        var bpos: usize = 0;
        const local_count, const lc = readUleb128(body) orelse return error.ParseError;
        bpos += lc;
        const locals = try alloc.alloc(LocalDecl, local_count);
        for (0..local_count) |j| {
            const n, const nc = readUleb128(body[bpos..]) orelse return error.ParseError;
            bpos += nc;
            const typ: ValType = @enumFromInt(body[bpos]);
            bpos += 1;
            locals[j] = .{ .count = @intCast(n), .typ = typ };
        }
        _ = body_start;
        functions[i] = .{ .locals = locals, .body = body[bpos..] };
    }
    return functions;
}

// ─── Pure-Zig evaluator ──────────────────────────────────────────────────────

/// A simple stack-based evaluator for deterministic WASM scalar functions.
/// Supports: i32/i64 arithmetic, comparisons, local variables, basic control flow.
pub const Evaluator = struct {
    module: *const WasmModule,
    alloc: std.mem.Allocator,

    pub fn init(module: *const WasmModule, alloc: std.mem.Allocator) Evaluator {
        return .{ .module = module, .alloc = alloc };
    }

    pub const WasmVal = union(enum) {
        i32_val: i32,
        i64_val: i64,
        f32_val: f32,
        f64_val: f64,
    };

    /// Call an exported function by name with given arguments.
    pub fn call(self: *Evaluator, name: []const u8, args: []const WasmVal) WasmError![]const WasmVal {
        const func_idx = self.module.findExport(name) orelse return error.FunctionNotFound;
        if (func_idx >= self.module.functions.len) return error.FunctionNotFound;
        const func = self.module.functions[func_idx];
        return self.evalFunction(func, args);
    }

    fn evalFunction(self: *Evaluator, func: FuncCode, args: []const WasmVal) WasmError![]const WasmVal {
        // Initialize locals: args first, then zero-initialized declared locals
        var locals: std.ArrayList(WasmVal) = .empty;
        defer locals.deinit(self.alloc);
        for (args) |a| try locals.append(self.alloc, a);
        for (func.locals) |decl| {
            const zero: WasmVal = switch (decl.typ) {
                .i32 => .{ .i32_val = 0 },
                .i64 => .{ .i64_val = 0 },
                .f32 => .{ .f32_val = 0.0 },
                .f64 => .{ .f64_val = 0.0 },
            };
            for (0..decl.count) |_| try locals.append(self.alloc, zero);
        }

        var stack: std.ArrayList(WasmVal) = .empty;
        defer stack.deinit(self.alloc);

        var pc: usize = 0;
        const code = func.body;

        while (pc < code.len) {
            const op = code[pc];
            pc += 1;
            switch (op) {
                0x00 => return error.ExecutionTrap, // unreachable
                0x01 => {}, // nop
                0x0F => break, // return
                0x1A => {
                    _ = stack.pop();
                }, // drop
                0x1B => { // select
                    const cond = stack.pop();
                    const b = stack.pop();
                    const a = stack.pop();
                    try stack.append(self.alloc, if (valToBool(cond)) a else b);
                },

                // local.get
                0x20 => {
                    const idx, const n = readUleb128(code[pc..]) orelse return error.ParseError;
                    pc += n;
                    try stack.append(self.alloc, locals.items[idx]);
                },
                // local.set
                0x21 => {
                    const idx, const n = readUleb128(code[pc..]) orelse return error.ParseError;
                    pc += n;
                    locals.items[idx] = stack.pop();
                },
                // local.tee
                0x22 => {
                    const idx, const n = readUleb128(code[pc..]) orelse return error.ParseError;
                    pc += n;
                    locals.items[idx] = stack.items[stack.items.len - 1];
                },

                // i32.const
                0x41 => {
                    const v, const n = readSleb128(code[pc..]) orelse return error.ParseError;
                    pc += n;
                    try stack.append(self.alloc, .{ .i32_val = @intCast(v) });
                },
                // i64.const
                0x42 => {
                    const v, const n = readSleb128(code[pc..]) orelse return error.ParseError;
                    pc += n;
                    try stack.append(self.alloc, .{ .i64_val = v });
                },
                // f32.const
                0x43 => {
                    const bits = std.mem.readInt(u32, code[pc..][0..4], .little);
                    pc += 4;
                    try stack.append(self.alloc, .{ .f32_val = @bitCast(bits) });
                },
                // f64.const
                0x44 => {
                    const bits = std.mem.readInt(u64, code[pc..][0..8], .little);
                    pc += 8;
                    try stack.append(self.alloc, .{ .f64_val = @bitCast(bits) });
                },

                // i32 arithmetic
                0x6A => try binaryI32(&stack, self.alloc, i32Add),
                0x6B => try binaryI32(&stack, self.alloc, i32Sub),
                0x6C => try binaryI32(&stack, self.alloc, i32Mul),
                0x6D => { // i32.div_s
                    const b = popI32(&stack) orelse return error.ExecutionTrap;
                    const a = popI32(&stack) orelse return error.ExecutionTrap;
                    if (b == 0) return error.ExecutionTrap;
                    try stack.append(self.alloc, .{ .i32_val = @divTrunc(a, b) });
                },
                0x6E => { // i32.div_u
                    const b = popU32(&stack) orelse return error.ExecutionTrap;
                    const a = popU32(&stack) orelse return error.ExecutionTrap;
                    if (b == 0) return error.ExecutionTrap;
                    try stack.append(self.alloc, .{ .i32_val = @bitCast(a / b) });
                },
                0x71 => try binaryI32(&stack, self.alloc, i32And),
                0x72 => try binaryI32(&stack, self.alloc, i32Or),
                0x73 => try binaryI32(&stack, self.alloc, i32Xor),

                // i32 comparisons → bool (i32)
                0x46 => try cmpI32(&stack, self.alloc, .eq),
                0x47 => try cmpI32(&stack, self.alloc, .ne),
                0x48 => try cmpI32(&stack, self.alloc, .lt_s),
                0x49 => try cmpI32(&stack, self.alloc, .lt_u),
                0x4A => try cmpI32(&stack, self.alloc, .gt_s),
                0x4B => try cmpI32(&stack, self.alloc, .gt_u),
                0x4C => try cmpI32(&stack, self.alloc, .le_s),
                0x4D => try cmpI32(&stack, self.alloc, .le_u),
                0x4E => try cmpI32(&stack, self.alloc, .ge_s),
                0x4F => try cmpI32(&stack, self.alloc, .ge_u),

                // i64 arithmetic
                0x7C => try binaryI64(&stack, self.alloc, i64Add),
                0x7D => try binaryI64(&stack, self.alloc, i64Sub),
                0x7E => try binaryI64(&stack, self.alloc, i64Mul),

                // i64 comparisons
                0x51 => try cmpI64(&stack, self.alloc, .eq),
                0x52 => try cmpI64(&stack, self.alloc, .ne),
                0x53 => try cmpI64(&stack, self.alloc, .lt_s),
                0x57 => try cmpI64(&stack, self.alloc, .le_s),
                0x58 => try cmpI64(&stack, self.alloc, .ge_s),

                // conversions
                0xA7 => { // i32.wrap_i64
                    const v = popI64(&stack) orelse return error.ExecutionTrap;
                    try stack.append(self.alloc, .{ .i32_val = @truncate(v) });
                },
                0xAC => { // i64.extend_i32_s
                    const v = popI32(&stack) orelse return error.ExecutionTrap;
                    try stack.append(self.alloc, .{ .i64_val = v });
                },

                0x0B => {}, // end of block/function
                else => return error.ForbiddenOpcode,
            }
        }

        return stack.toOwnedSlice(self.alloc);
    }
};

// ─── Arithmetic helpers ───────────────────────────────────────────────────────

const CmpOp = enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u };

fn valToBool(v: Evaluator.WasmVal) bool {
    return switch (v) {
        .i32_val => |n| n != 0,
        .i64_val => |n| n != 0,
        else => false,
    };
}

fn popI32(stack: *std.ArrayList(Evaluator.WasmVal)) ?i32 {
    const v = stack.pop();
    return if (v == .i32_val) v.i32_val else null;
}

fn popU32(stack: *std.ArrayList(Evaluator.WasmVal)) ?u32 {
    const v = stack.pop();
    return if (v == .i32_val) @bitCast(v.i32_val) else null;
}

fn popI64(stack: *std.ArrayList(Evaluator.WasmVal)) ?i64 {
    const v = stack.pop();
    return if (v == .i64_val) v.i64_val else null;
}

fn binaryI32(stack: *std.ArrayList(Evaluator.WasmVal), alloc: std.mem.Allocator, f: fn (i32, i32) i32) !void {
    const b = popI32(stack) orelse return error.ExecutionTrap;
    const a = popI32(stack) orelse return error.ExecutionTrap;
    try stack.append(alloc, .{ .i32_val = f(a, b) });
}

fn binaryI64(stack: *std.ArrayList(Evaluator.WasmVal), alloc: std.mem.Allocator, f: fn (i64, i64) i64) !void {
    const b = popI64(stack) orelse return error.ExecutionTrap;
    const a = popI64(stack) orelse return error.ExecutionTrap;
    try stack.append(alloc, .{ .i64_val = f(a, b) });
}

fn cmpI32(stack: *std.ArrayList(Evaluator.WasmVal), alloc: std.mem.Allocator, op: CmpOp) !void {
    const b = popI32(stack) orelse return error.ExecutionTrap;
    const a = popI32(stack) orelse return error.ExecutionTrap;
    const result: bool = switch (op) {
        .eq => a == b,
        .ne => a != b,
        .lt_s => a < b,
        .lt_u => @as(u32, @bitCast(a)) < @as(u32, @bitCast(b)),
        .gt_s => a > b,
        .gt_u => @as(u32, @bitCast(a)) > @as(u32, @bitCast(b)),
        .le_s => a <= b,
        .le_u => @as(u32, @bitCast(a)) <= @as(u32, @bitCast(b)),
        .ge_s => a >= b,
        .ge_u => @as(u32, @bitCast(a)) >= @as(u32, @bitCast(b)),
    };
    try stack.append(alloc, .{ .i32_val = if (result) 1 else 0 });
}

fn cmpI64(stack: *std.ArrayList(Evaluator.WasmVal), alloc: std.mem.Allocator, op: CmpOp) !void {
    const b = popI64(stack) orelse return error.ExecutionTrap;
    const a = popI64(stack) orelse return error.ExecutionTrap;
    const result: bool = switch (op) {
        .eq => a == b,
        .ne => a != b,
        .lt_s => a < b,
        .le_s => a <= b,
        .ge_s => a >= b,
        else => false,
    };
    try stack.append(alloc, .{ .i32_val = if (result) 1 else 0 });
}

fn i32Add(a: i32, b: i32) i32 {
    return a +% b;
}
fn i32Sub(a: i32, b: i32) i32 {
    return a -% b;
}
fn i32Mul(a: i32, b: i32) i32 {
    return a *% b;
}
fn i32And(a: i32, b: i32) i32 {
    return a & b;
}
fn i32Or(a: i32, b: i32) i32 {
    return a | b;
}
fn i32Xor(a: i32, b: i32) i32 {
    return a ^ b;
}
fn i64Add(a: i64, b: i64) i64 {
    return a +% b;
}
fn i64Sub(a: i64, b: i64) i64 {
    return a -% b;
}
fn i64Mul(a: i64, b: i64) i64 {
    return a *% b;
}

// ─── LEB128 helpers ───────────────────────────────────────────────────────────

/// Returns (value, bytes_consumed) or null on truncation.
pub fn readUleb128(data: []const u8) ?struct { usize, usize } {
    var result: usize = 0;
    var shift: usize = 0;
    for (data, 0..) |byte, i| {
        result |= (@as(usize, byte & 0x7F) << @intCast(shift));
        shift += 7;
        if (byte & 0x80 == 0) return .{ result, i + 1 };
        if (shift >= 64) return null;
    }
    return null;
}

pub fn readSleb128(data: []const u8) ?struct { i64, usize } {
    var result: i64 = 0;
    var shift: usize = 0;
    for (data, 0..) |byte, i| {
        result |= (@as(i64, byte & 0x7F) << @intCast(shift));
        shift += 7;
        if (byte & 0x80 == 0) {
            if (shift < 64 and (byte & 0x40) != 0) {
                result |= -(@as(i64, 1) << @intCast(shift));
            }
            return .{ result, i + 1 };
        }
    }
    return null;
}

// ─── Wasmtime FFI scaffold (NOT wired up for M5) ──────────────────────────────
//
// TODO (M6+): wire this up via translate-c in build.zig:
//
//   const translate_c = b.addTranslateC(.{
//       .root_source_file = b.path("src/sql/wasmtime.h"),
//       .target = target,
//       .optimize = optimize,
//   });
//   translate_c.linkSystemLibrary("wasmtime", .{});
//
// For now, all WASM execution uses the pure-Zig evaluator above.

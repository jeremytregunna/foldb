/// SQL AST types. All nodes are arena-allocated; call arena.deinit() to free.
const token_mod = @import("token.zig");
const storage_mod = @import("storage.zig");
pub const Span = token_mod.Span;

pub const Decimal = storage_mod.Decimal;

// ─── Type expressions ────────────────────────────────────────────────────────

pub const IntOverflow = enum { error_on_overflow, wrapping };

pub const SqlType = union(enum) {
    bool,
    int8: IntOverflow,
    int16: IntOverflow,
    int32: IntOverflow,
    int64: IntOverflow,
    uint8: IntOverflow,
    uint16: IntOverflow,
    uint32: IntOverflow,
    uint64: IntOverflow,
    decimal: struct { precision: u8, scale: u8 },
    string,
    bytes,
    uuid,
    timestamp,
    interval_months,
    interval_micros,
    json,
    vector: u32, // dimension
    array: *const SqlType,
    struct_type: []const StructField,
    // Internal-only: type of NULL literal before resolution
    null_type,

    pub fn isNumeric(self: SqlType) bool {
        return switch (self) {
            .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64, .decimal => true,
            else => false,
        };
    }

    pub fn isInteger(self: SqlType) bool {
        return switch (self) {
            .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => true,
            else => false,
        };
    }

    pub fn eql(self: SqlType, other: SqlType) bool {
        return switch (self) {
            .bool => other == .bool,
            .int8 => other == .int8,
            .int16 => other == .int16,
            .int32 => other == .int32,
            .int64 => other == .int64,
            .uint8 => other == .uint8,
            .uint16 => other == .uint16,
            .uint32 => other == .uint32,
            .uint64 => other == .uint64,
            .string => other == .string,
            .bytes => other == .bytes,
            .uuid => other == .uuid,
            .timestamp => other == .timestamp,
            .interval_months => other == .interval_months,
            .interval_micros => other == .interval_micros,
            .json => other == .json,
            .null_type => other == .null_type,
            .decimal => |a| switch (other) {
                .decimal => |b| a.precision == b.precision and a.scale == b.scale,
                else => false,
            },
            .vector => |a| switch (other) {
                .vector => |b| a == b,
                else => false,
            },
            .array => |a| switch (other) {
                .array => |b| a.eql(b.*),
                else => false,
            },
            .struct_type => false,
        };
    }
};

pub const StructField = struct {
    name: []const u8,
    typ: SqlType,
};

// ─── Expressions ─────────────────────────────────────────────────────────────

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    and_op,
    or_op,
    concat, // ||
    contains, // @>
    contained, // <@
    arrow, // ->  (JSON field access, returns JSON)
    darrow, // ->> (JSON field access, returns text)
    bit_and, // &
    bit_or, // |
    bit_xor, // ^
    shl, // <<
    shr, // >>
};

pub const UnaryOp = enum { neg, not, bit_not };

pub const NondetKind = enum { now, random, uuid_v7 };

pub const WindowFrame = struct {
    pub const Bound = union(enum) {
        unbounded_preceding,
        preceding: *Expr,
        current_row,
        following: *Expr,
        unbounded_following,
    };
    pub const Mode = enum { rows, range };
    mode: Mode,
    start: Bound,
    end: Bound,
};

pub const WindowSpec = struct {
    partition_by: []const *Expr,
    order_by: []const OrderByItem,
    frame: ?WindowFrame,
};

pub const OrderByItem = struct {
    expr: *Expr,
    asc: bool,
    nulls_first: ?bool,
};

pub const CaseWhen = struct {
    cond: *Expr,
    result: *Expr,
};

pub const Expr = union(enum) {
    lit_int: i128,
    lit_float: Decimal,
    lit_string: []const u8,
    lit_bytes: []const u8,
    lit_bool: bool,
    lit_null,

    column_ref: ColumnRef,
    param: u32, // $1 → 0, $2 → 1 (0-based index)
    nondet: NondetKind, // NOW(), RANDOM(), UUID() — resolved by gateway

    cast: struct { expr: *Expr, to: SqlType },

    binary: struct { op: BinOp, left: *Expr, right: *Expr },
    unary: struct { op: UnaryOp, expr: *Expr },

    is_null: *Expr,
    is_not_null: *Expr,
    is_distinct: struct { left: *Expr, right: *Expr },
    is_not_distinct: struct { left: *Expr, right: *Expr },

    between: struct { expr: *Expr, low: *Expr, high: *Expr },
    like: struct { expr: *Expr, pattern: *Expr },

    in_list: struct { expr: *Expr, values: []*Expr },
    not_in_list: struct { expr: *Expr, values: []*Expr },
    in_subquery: struct { expr: *Expr, query: *SelectStmt },
    not_in_subquery: struct { expr: *Expr, query: *SelectStmt },
    exists: *SelectStmt,
    not_exists: *SelectStmt,

    case_searched: struct { whens: []CaseWhen, else_expr: ?*Expr },
    case_simple: struct { operand: *Expr, whens: []CaseWhen, else_expr: ?*Expr },

    fn_call: FnCall,
    window_fn: struct { call: FnCall, window: WindowSpec },

    subquery: *SelectStmt,

    // Assigned by type-checker, not parser
    typed: struct { inner: *Expr, typ: SqlType },
};

pub const ColumnRef = struct {
    table: ?[]const u8,
    column: []const u8,
};

pub const FnCall = struct {
    name: []const u8,
    args: []*Expr,
    distinct: bool,
    star: bool, // COUNT(*)
    filter: ?*Expr = null,
};

// ─── SELECT ──────────────────────────────────────────────────────────────────

pub const SelectItem = union(enum) {
    star, // * — rejected in registered queries
    expr: struct { expr: *Expr, alias: ?[]const u8 },
};

pub const JoinKind = enum { inner, left, right, full, cross };

pub const JoinCondition = union(enum) {
    on: *Expr,
    using: []const []const u8,
};

pub const Join = struct {
    kind: JoinKind,
    table: TableRef,
    condition: ?JoinCondition,
};

pub const TableRef = union(enum) {
    named: struct { name: []const u8, alias: ?[]const u8 },
    subquery: struct { query: *SelectStmt, alias: []const u8 },
    cte_ref: struct { name: []const u8, alias: ?[]const u8 },
};

pub const SelectStmt = struct {
    with: []const Cte,
    distinct: bool,
    items: []const SelectItem,
    from: ?TableRef,
    joins: []const Join,
    where: ?*Expr,
    group_by: []const *Expr,
    having: ?*Expr,
    windows: []const NamedWindow,
    order_by: []const OrderByItem,
    limit: ?*Expr,
    offset: ?*Expr,
};

pub const NamedWindow = struct {
    name: []const u8,
    spec: WindowSpec,
};

pub const Cte = struct {
    name: []const u8,
    recursive: bool,
    columns: ?[]const []const u8,
    query: *SelectStmt,
};

// ─── DML ─────────────────────────────────────────────────────────────────────

pub const OnConflict = union(enum) {
    do_nothing,
    do_update: struct {
        target: []const []const u8, // conflict columns
        sets: []const Assignment,
        where: ?*Expr,
    },
};

pub const InsertStmt = struct {
    with: []const Cte,
    table: []const u8,
    columns: []const []const u8,
    source: InsertSource,
    on_conflict: ?OnConflict,
    returning: []const SelectItem,
};

pub const InsertSource = union(enum) {
    values: []const []*Expr, // VALUES (a, b), (c, d)
    query: *SelectStmt,
};

pub const Assignment = struct {
    column: []const u8,
    value: *Expr,
};

pub const UpdateStmt = struct {
    with: []const Cte,
    table: []const u8,
    alias: ?[]const u8,
    sets: []const Assignment,
    from: ?TableRef,
    where: ?*Expr,
    returning: []const SelectItem,
};

pub const DeleteStmt = struct {
    with: []const Cte,
    table: []const u8,
    alias: ?[]const u8,
    using: []const TableRef,
    where: ?*Expr,
    returning: []const SelectItem,
};

pub const MergeWhen = union(enum) {
    matched: struct {
        cond: ?*Expr,
        action: MergeAction,
    },
    not_matched: struct {
        cond: ?*Expr,
        columns: []const []const u8,
        values: []*Expr,
    },
};

pub const MergeAction = union(enum) {
    update: []const Assignment,
    delete,
    do_nothing,
};

pub const MergeStmt = struct {
    with: []const Cte,
    target: struct { name: []const u8, alias: ?[]const u8 },
    source: struct { ref: TableRef },
    on: *Expr,
    whens: []const MergeWhen,
};

// ─── DDL ─────────────────────────────────────────────────────────────────────

pub const NullConstraint = enum { not_null, nullable };

pub const ColumnDef = struct {
    name: []const u8,
    typ: SqlType,
    nullable: NullConstraint,
    /// DEFAULT <literal>. Only literal Expr variants are valid here.
    default_value: ?*Expr = null,
    /// Column-level UNIQUE constraint.
    unique: bool = false,
    /// CHECK (expr). Expression must be deterministic (no nondet variants).
    check_expr: ?*Expr = null,
    span: Span,
};

pub const PrimaryKey = struct {
    columns: []const []const u8,
};

pub const ForeignKeyConstraint = struct {
    name: ?[]const u8,
    columns: []const []const u8,
    ref_table: []const u8,
    ref_columns: []const []const u8,
};

pub const CreateTableStmt = struct {
    name: []const u8,
    columns: []const ColumnDef,
    primary_key: PrimaryKey,
    foreign_keys: []const ForeignKeyConstraint = &.{},
};

pub const IndexKind = union(enum) {
    ordered,
    hash,
    vector: u32, // dimension (must match column type)
    json_path: []const []const u8, // declared paths
};

pub const CreateIndexStmt = struct {
    name: []const u8,
    unique: bool,
    kind: IndexKind,
    table: []const u8,
    columns: []const []const u8,
};

pub const AlterAction = union(enum) {
    add_column: ColumnDef,
    drop_column: []const u8,
};

pub const AlterTableStmt = struct {
    table: []const u8,
    action: AlterAction,
};

pub const DropTableStmt = struct {
    name: []const u8,
    if_exists: bool,
};

// ─── Transaction block ───────────────────────────────────────────────────────

pub const TxnParam = struct {
    name: []const u8,
    typ: SqlType,
};

pub const TxnStmt = union(enum) {
    select: SelectStmt,
    insert: InsertStmt,
    update: UpdateStmt,
    delete: DeleteStmt,
    merge: MergeStmt,
    assert: *Expr,
};

pub const TransactionBlock = struct {
    params: []const TxnParam,
    stmts: []const TxnStmt,
};

// ─── Top-level ───────────────────────────────────────────────────────────────

pub const DescribeTableStmt = struct {
    name: []const u8,
};

pub const Stmt = union(enum) {
    select: SelectStmt,
    insert: InsertStmt,
    update: UpdateStmt,
    delete: DeleteStmt,
    merge: MergeStmt,
    create_table: CreateTableStmt,
    create_index: CreateIndexStmt,
    alter_table: AlterTableStmt,
    drop_table: DropTableStmt,
    describe_table: DescribeTableStmt,
    transaction: TransactionBlock,
};

/// Top-level parse result: one or more statements.
pub const ParsedQuery = struct {
    stmts: []const Stmt,
};

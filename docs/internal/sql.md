# SQL Layer

The SQL layer transforms SQL text into a validated, canonicalized execution plan and a stable query hash. It is a compile-time pipeline — queries are registered and validated once; execution receives only pre-validated plans.

## Role

Parses, type-checks, plans, and canonicalizes SQL queries. Produces a `QueryHash` (BLAKE3) that serves as a stable identifier for the query across registrations and nodes. Execution dispatches by hash, not by SQL text.

## Pipeline

```
SQL text → Lexer → Parser → Type Checker → Planner → Canonicalization → QueryHash
```

Each stage is deterministic and validated by the next. A failure at any stage returns an error — nothing partial reaches the executor.

## Guarantees

- **Idempotent registration**: Registering identical SQL twice returns the same hash without re-processing.
- **Hash stability**: The `QueryHash` is invariant to formatting, whitespace, and alias names — only structure and type signature matter.
- **Type safety at plan time**: All expressions are type-annotated before execution. No type errors occur at eval time.
- **Deterministic evaluation**: `evalExpr` is a pure function over row data, resolved parameters, and nondeterminism tokens. Same inputs, same output.

## Type Checking Rules (§10.2)

The type checker enforces these invariants before planning:

- No `SELECT *` — all columns must be explicit.
- No implicit type coercions.
- Nullable columns in `WHERE`/`ON` predicates require explicit `IS NULL` guards.
- Join column references must be qualified.
- Functions with side effects are banned from `WHERE`/`HAVING`.

These rules eliminate entire classes of runtime errors.

## Canonicalization

Produces a stable BLAKE3 hash over the query's structure and type signature. Queries that are semantically equivalent (same structure, same types) produce the same hash regardless of formatting. This enables query caching and deduplication across registrations.

## Nondeterminism

Functions like `NOW()`, `RANDOM()`, and `UUID_V7()` are not evaluated during planning or execution — they are resolved by the gateway before the intent reaches the executor. The SQL layer records only their count (`nondet_idx`) so the executor can substitute pre-resolved values at apply time.

## Expression Evaluation Boundary

**In**: `PlanExpr` + `EvalCtx` (row data as `?ColumnValue`, resolved parameters, nondeterminism tokens).

**Out**: A runtime `Value` — one of: null, bool, int64, uint64, f64, string, bytes, opaque.

Column references are resolved to positions (not names) at plan time. No late name resolution occurs during evaluation.

## Caller Responsibilities

- Provide valid UTF-8 SQL text to `SqlRegistry.register()`.
- Supply parameters at execution time as binary-encoded `ColumnValue` values matching the types extracted during type checking.
- Do not pass nondeterministic function results as parameters — these are resolved by the gateway.

## Error Conditions

| Stage | Error | Meaning |
|---|---|---|
| Lexer/Parser | `LexError`, `ParseError` | Malformed SQL syntax |
| Type checker | `TypeCheckError` | Invalid references, coercions, or §10.2 violations |
| Planner | `PlanError` | Unsupported operations or unfeasible plans |
| Execution | `ConstraintViolation` | Foreign key or assertion failure during apply |
| Execution | `bad_params` | CRC mismatch on deserialized parameters |
| Execution | `missing_query` | No handler registered for the given hash |

## Transaction Blocks and ASSERT

SQL supports a transaction block syntax: `TRANSACTION (params) { stmt; stmt; ASSERT expr; }`. An `ASSERT` expression is evaluated as part of the transaction; if it fails, the transaction produces a deterministic abort at `seq` with no mutations applied.

## WASM Modules

When transaction logic exceeds what SQL can express, a WASM module referenced by hash can be called from within a transaction body. Modules are loaded and validated at registration time. The WASM runtime enforces determinism by disabling all nondeterministic opcodes (no NaN-propagating SIMD floats, no threads) and restricting host function calls to a whitelist for reading inputs and writing outputs.

## What the SQL Layer Does Not Do

- Does not perform query optimization — the planner uses greedy heuristics only.
- Does not enforce transaction isolation — that is the sequencer's and executor's responsibility.
- Does not auto-reject stale queries when schema changes — schema version is tracked for DDL safety but existing registrations are not invalidated automatically.
- Does not inline CTEs or push down all predicates.
- Does not enforce primary key uniqueness or foreign key semantics — those are enforced by storage.

## Source Files

- `src/sql/sql.zig` — module exports
- `src/sql/lexer.zig` — tokenization
- `src/sql/token.zig` — token definitions
- `src/sql/parser.zig` — AST construction from token stream
- `src/sql/ast.zig` — AST node types
- `src/sql/type_checker.zig` — type annotation and §10.2 rule enforcement
- `src/sql/type_conv.zig` — type coercion rules
- `src/sql/plan.zig` — logical plan construction and expression lowering
- `src/sql/canon.zig` — canonicalization and BLAKE3 QueryHash generation
- `src/sql/registry.zig` — query registration and hash-keyed lookup
- `src/sql/schema.zig` — table and column schema types
- `src/sql/eval_expr.zig` — runtime expression evaluation (PlanExpr → Value)
- `src/sql/executor_bridge.zig` — wires SQL plans into the executor as query handlers
- `src/sql/params_codec.zig` — parameter binary encoding and decoding
- `src/sql/key_encode.zig` — row key encoding for storage
- `src/sql/agg_accum.zig` — aggregate function accumulators
- `src/sql/agg_helpers.zig` — aggregate helper utilities
- `src/sql/window_exec.zig` — window function execution
- `src/sql/wasm.zig` — WASM-targeted SQL entry points

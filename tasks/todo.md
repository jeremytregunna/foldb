# M5 — SQL Front-end

## Objective
Parser, type checker, query registration, planner, canonicalization.
End state: register a SQL query → get a QueryHash → bind params → execute via executor.

## File layout (`src/sql/`)

| File | Purpose |
|------|---------|
| `sql.zig` | Public re-exports |
| `token.zig` | Token enum + span |
| `lexer.zig` | Tokenizer |
| `ast.zig` | Full AST node types |
| `parser.zig` | Recursive descent parser |
| `types.zig` | SQL type system (§10.3) |
| `schema.zig` | Schema registry (tables, columns, indexes) |
| `type_checker.zig` | Strict type checking (§10.2 rules) |
| `planner.zig` | Deterministic query planner |
| `canon.zig` | AST → canonical bytes → BLAKE3 hash |
| `registry.zig` | SQL → QueryHash → ExecutionPlan |
| `executor_bridge.zig` | ExecutionPlan → QueryHandler (executor integration) |
| `wasm.zig` | WASM module validation + pure-Zig evaluator |

## Tasks

### Phase 1 — Core types
- [ ] `token.zig`: all keywords, operators, literals
- [ ] `types.zig`: all 17 SQL types from §10.3
- [ ] `ast.zig`: Stmt, Expr, TypeExpr, DDL, DML, TransactionBlock

### Phase 2 — Lexer + Parser
- [ ] `lexer.zig`: tokenize full dialect
- [ ] `parser.zig`: recursive descent
  - [ ] DDL: CREATE TABLE, CREATE INDEX, ALTER TABLE
  - [ ] DML: SELECT, INSERT, UPDATE, DELETE, MERGE
  - [ ] WITH (CTEs), window functions, GROUP BY, HAVING, subqueries
  - [ ] TRANSACTION block with ASSERT
  - [ ] Reject: SELECT *, triggers, stored procs, ISOLATION LEVEL (parse errors)

### Phase 3 — Schema
- [ ] `schema.zig`: TableDef, ColumnDef, IndexDef
- [ ] DDL transaction effects (add/drop table, add/drop column, add index)
- [ ] Schema version tracking per registered query

### Phase 4 — Type checker
- [ ] `type_checker.zig`: walk AST against schema
- [ ] Reject implicit coercions (cast must be explicit `::type`)
- [ ] Reject nullable-by-default columns (each column must declare NULL or NOT NULL)
- [ ] Reject `=` on nullable column without IS NULL guard
- [ ] Reject unqualified refs in joins
- [ ] Reject side-effecting functions in WHERE/ON/HAVING
- [ ] Reject SELECT * in registered queries

### Phase 5 — Canonicalization
- [ ] `canon.zig`: deterministic byte serialization of AST
- [ ] BLAKE3 hash → `[32]u8` QueryHash

### Phase 6 — Planner
- [ ] `planner.zig`: typed AST → ExecutionPlan
- [ ] Index selection from schema
- [ ] All sorts have deterministic, seeded order
- [ ] No non-whitelisted calls in plan

### Phase 7 — WASM
- [ ] `wasm.zig`: validate module at registration (no threads, no non-whitelisted host calls, no nondeterministic SIMD)
- [ ] Pure-Zig evaluator for simple scalar functions
- [ ] Wasmtime FFI: stub with clear TODO

### Phase 8 — Executor bridge + integration
- [ ] `executor_bridge.zig`: ExecutionPlan → QueryHandler closure
- [ ] Reads from Storage at seq-1; produces []Mutation
- [ ] Hook into existing executor.registry

### Phase 9 — Tests
- [ ] `tests/sql/lexer_test.zig`
- [ ] `tests/sql/parser_test.zig` (happy path + rejection cases)
- [ ] `tests/sql/type_checker_test.zig`
- [ ] `tests/sql/registry_test.zig` (register → hash → execute round-trip)
- [ ] `tests/sql/integration_test.zig` (CREATE TABLE → INSERT → SELECT end-to-end)

## Zig 0.16.0 notes
- Thread `io: std.Io` through any file/network/time/rng operations
- Use `std.Io.Dir` / `std.Io.File` (not `std.fs.*`)
- Use `@Int`, `@Struct`, `@Enum` etc. (not `@Type(...)`)
- No `std.Thread.Pool` — use `std.Io.async` / `std.Io.Group`

## Invariants to preserve
- Query hash uniquely determines AST + type signature forever (§9.5)
- No nondeterminism inside execution code path
- DDL is a transaction (schema changes go through the log)

## Review
<!-- filled in after implementation -->

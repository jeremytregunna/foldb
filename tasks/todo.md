# SQL Completeness

## Priority 1 — High-value gaps

- [x] **Subqueries** — scalar subqueries in SELECT list, EXISTS/NOT EXISTS in WHERE, IN/NOT IN subquery form
- [x] **SELECT DISTINCT** — deduplication in executor
- [x] **RETURNING clause** — INSERT/UPDATE/DELETE/MERGE
- [x] **ON CONFLICT DO UPDATE / DO NOTHING**

## Priority 2 — Join completeness

- [x] **FULL OUTER JOIN**
- [x] **CROSS JOIN**
- [x] **JOIN … USING clause** — fully implemented; USING cols expanded to equality conditions in planner

## Priority 3 — DML completeness

- [x] **UPDATE … FROM**
- [x] **DELETE … USING**

## Priority 4 — Aggregate completeness

- [x] **ARRAY_AGG**
- [x] **STRING_AGG**
- [x] **Aggregate FILTER clause** — `agg(x) FILTER (WHERE cond)`

## Priority 5 — Window function completeness

- [x] **LAG / LEAD**
- [x] **FIRST_VALUE / LAST_VALUE / NTH_VALUE**
- [x] **Window frame specification** (ROWS/RANGE BETWEEN) — fully implemented; ROWS offsets and RANGE peer-group semantics with correct SQL standard defaults

## Priority 6 — Operator completeness

- [x] **Bitwise operators** (`&`, `|`, `^`, `~`, `<<`, `>>`)
- [x] **JSON operators** (`@>`, `<@`, `->`, `->>`)

## Priority 7 — DDL execution

- [x] **ALTER TABLE**
- [x] **CREATE INDEX**

## Notes

- Non-deterministic functions (NOW, RANDOM, UUID_V7) intentionally excluded
- Correlated subqueries are a stretch goal; scalar/exists subqueries come first
- SELECT * expansion is intentionally blocked in registered queries (stay that way)
- WASM UDF infrastructure exists but is not in scope here
- All SQL completeness items done. Remaining stretch: USING column deduplication in SELECT *, offset RANGE bounds (requires type-specific order key arithmetic)

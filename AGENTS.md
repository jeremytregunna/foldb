# Foldb Team Conventions

## Commit Messages

### Conventional Commits Required
- **Format**: `<type>: <description>`
- **Types**: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`, `build`
- **Imperative mood**: "add" not "added"
- **Subject under 72 chars**, body wrapped at 72
- **Closes #123** in footer for issue references

**EXAMPLES**:
```
feat: add query builder for folded data
fix: resolve memory leak in arena allocator
refactor: simplify fold operation logic
```

## Project Structure

```
foldb/
├── build.zig          # Build config (Zig 0.16.0+)
├── src/
│   ├── lib.zig        # Core library - public API
│   └── main.zig       # CLI entry point
├── tests/             # Integration tests
├── docs/              # Documentation
└── AGENTS.md          # This file
```

## Development Workflow

1. **Branch from master** - Use `feature/<desc>`, `bugfix/<desc>`, `hotfix/<desc>`
2. **Atomic commits** - One logical change per commit
3. **Tests pass** - `zig build test` before pushing
4. **Update docs** - README, inline comments for public API
5. **PR with squash merge** - Clean history on master

## Code Style

### Naming
- **Modules**: `snake_case` (`folded_data.zig`)
- **Types**: `PascalCase` (`FoldedRecord`)
- **Functions/vars**: `snake_case` (`fold_data()`, `record_count`)
- **Constants**: `SCREAMING_SNAKE_CASE` (`MAX_RECORDS`)
- **Enums**: `PascalCase` (`RecordType`)

### Formatting
- **4-space indent**
- **120 char max line length**
- **Trailing commas** in multi-line lists/structs
- **One blank line** between function definitions

### Error Handling
- **Prefer explicit handling**: `const result = try operation()`
- **Error unions** for fallible ops: `fn fetchData() !Data`
- **Catch only when acceptable**: Handle with `catch |err|`

### Memory
- **Use ArenaAllocator** for scoped allocations
- **Always defer cleanup**: `defer arena.deinit()`

### Documentation
- **Document all public API** with `///` comments
- **Parameters, returns, errors** clearly stated

## Compliance Check

**BEFORE SUBMITTING WORK, VERIFY**:

- [ ] All code compiles without warnings
- [ ] `zig build test` passes
- [ ] Commit messages follow conventional commits
- [ ] Public API documented
- [ ] Error handling explicit and appropriate
- [ ] Code follows style guidelines above
- [ ] Branch name follows convention
- [ ] No secrets or credentials committed

**IF YOU CONSIDER AN EXCEPTION TO ANY RULE: STOP and get explicit permission from the user first.**

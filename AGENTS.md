# Team Conventions & Guidelines

This document outlines the conventions, guidelines, and best practices for the Foldb project.

## 📝 Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages.

### Format

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation changes |
| `style` | Code style changes (formatting, etc.) |
| `refactor` | Code refactoring (no feature/bug changes) |
| `perf` | Performance improvements |
| `test` | Adding or modifying tests |
| `chore` | Maintenance, dependencies, build changes |
| `ci` | CI/CD configuration changes |
| `build` | Build system or external dependency changes |

### Examples

```
feat(db): add query builder for folded data
fix(lib): resolve memory leak in arena allocator
docs: update README with build instructions
refactor(core): simplify fold operation logic
test(lib): add unit tests for example function
chore(deps): update zig to 0.16.0
```

### Commit Message Guidelines

- Use imperative mood in the description ("add" not "added")
- Keep the subject line under 72 characters
- Wrap the body at 72 characters
- Use the body to explain what/why, not how (that's in the code)
- Reference issues in the footer: `Closes #123`

## 🏗️ Project Structure

```
foldb/
├── build.zig          # Build configuration (Zig 0.16.0+)
├── src/
│   ├── lib.zig        # Core library - public API
│   ├── main.zig       # Application entry point
│   └── [modules]/      # Additional modules as project grows
├── tests/             # Integration tests (if needed)
├── docs/              # Documentation
├── .gitignore         # Git ignore rules
├── AGENTS.md          # This file - team conventions
├── README.md          # Project overview
└── LICENSE            # License file
```

### Source File Organization

- `lib.zig` - Core library code, public API
- `main.zig` - CLI/application entry point
- Additional modules should be added to `src/` with clear naming

## 🔄 Development Workflow

### Branch Naming

```
feature/<description>    # New features
bugfix/<description>     # Bug fixes
hotfix/<description>     # Urgent production fixes
docs/<description>       # Documentation changes
refactor/<description>   # Refactoring work
test/<description>       # Test additions
```

### Pull Request Process

1. Create a feature branch from `master`
2. Make changes with atomic commits
3. Ensure all tests pass: `zig build test`
4. Update documentation if needed
5. Create PR with descriptive title and body
6. Request review from team members
7. Address feedback and iterate
8. Squash commits if necessary before merging
9. Merge to `master` with squash merge

### Code Review Guidelines

- Review for correctness, clarity, and maintainability
- Check that tests are included for new functionality
- Ensure code follows project style guidelines
- Look for potential performance issues
- Verify error handling is appropriate

## 🎨 Code Style

### Zig Conventions

#### Naming Conventions

| Element | Style | Example |
|---------|-------|---------|
| Modules | snake_case | `folded_data.zig` |
| Types | PascalCase | `FoldedRecord` |
| Functions | snake_case | `fold_data()` |
| Variables | snake_case | `record_count` |
| Constants | SCREAMING_SNAKE_CASE | `MAX_RECORDS` |
| Enums | PascalCase | `RecordType` |
| Test functions | snake_case | `test_fold_operation()` |

#### Formatting

- Indent with 4 spaces
- Maximum line length: 120 characters
- Use trailing commas in multi-line lists/structs
- One blank line between function definitions
- Consistent spacing around operators

#### Error Handling

```zig
// Prefer explicit error handling
const result = try someOperation();

// Use error unions for fallible operations
fn fetchData() !Data {
    return data;
}

// Use catch when failure is acceptable
const value = riskyOperation() catch |err| {
    std.debug.print("Handled: {s}\n", .@errorName(err));
    return defaultValue;
};
```

#### Memory Management

```zig
// Use ArenaAllocator for scoped allocations
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const scoped_alloc = arena.allocator();

// Always defer cleanup
var resource = try createResource(allocator);
defer resource.deinit();
```

### Documentation

```zig
/// Brief description of the function
///
/// Longer description with more details.
///
/// # Parameters
///
/// * `allocator` - Memory allocator to use
/// * `data` - Input data to process
///
/// # Returns
///
/// Processed data, or an error if processing fails.
///
/// # Errors
///
/// * `error.OutOfMemory` - If allocation fails
/// * `error.InvalidInput` - If data is invalid
pub fn processData(allocator: Allocator, data: []const u8) !ProcessedData {
    // Implementation
}
```

### Testing

```zig
// Unit tests should be in the same file as the code
test "process data handles empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    
    const result = try processData(arena.allocator(), &.{});
    try std.testing.expectEqual(expected, result);
}
```

## 📋 Code Quality

### Requirements

- All code must compile without warnings
- All tests must pass: `zig build test`
- Code must follow the style guidelines above
- Public API must be documented
- Error handling must be explicit and appropriate

### Before Committing

```bash
# Build the project
zig build

# Run tests
zig build test

# Check for issues (if tools are available)
# zig fmt --check src/
```

## 📦 Dependencies

- **Zig**: 0.16.0 or later
- Minimize external dependencies
- Document all dependencies in README.md

## 🔒 Security

- Never commit secrets or credentials
- Use environment variables for sensitive configuration
- Review third-party dependencies for security issues
- Keep Zig and dependencies up to date

## 📚 Documentation

- Keep README.md up to date
- Document all public API functions
- Add inline comments for complex logic
- Update AGENTS.md when conventions change

## 🐛 Bug Reports

When reporting bugs, include:

1. Steps to reproduce
2. Expected behavior
3. Actual behavior
4. Zig version
5. Operating system
6. Relevant error messages or stack traces

## 🚀 Releasing

1. Ensure all tests pass
2. Update CHANGELOG.md if applicable
3. Update version in `src/lib.zig`
4. Create tagged release: `git tag -a v0.2.0 -m "Release v0.2.0"`
5. Push tags: `git push origin --tags`

---

*Last updated: 2026-04-17*

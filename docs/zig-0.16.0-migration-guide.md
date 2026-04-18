# Zig 0.16.0 Migration Guide for LLMs

> **Purpose**: This document is a reference for directing an LLM to update Zig code from version 0.15.x to 0.16.0. It summarizes all breaking changes, renames, and migration patterns from the official 0.16.0 release notes (https://ziglang.org/download/0.16.0/release-notes.html).
>
> **When writing or modifying Zig code targeting 0.16.0, follow the rules below. When upgrading existing code, apply the transformation patterns shown with ⬇️ arrows.**

---

## 1. The Headline Change: I/O as an Interface

**Most impactful change in the release.** All I/O — file system, networking, process management, time, randomness, sync primitives — now requires an `Io` instance to be passed explicitly.

### Core rules for 0.16.0 code

- Functions that do I/O take an `io: std.Io` parameter.
- `std.fs.*` is gone; use `std.Io.Dir` and `std.Io.File` instead.
- `std.net.*` is gone; use `std.Io.net` instead.
- `std.time.*` is largely gone; use `std.Io.Timestamp` and `std.Io.Duration`.
- Sync primitives live under `std.Io.*`, not `std.Thread.*`.
- `main` should generally accept `std.process.Init` (see "Juicy Main" below), which provides a pre-built `io`.

### Obtaining an `Io` instance when you don't have one

```zig
var threaded: Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

This is a workaround — prefer threading `Io` through your API like you would an `Allocator`.

### Available implementations

- `Io.Threaded` — feature-complete, well-tested, supports cancelation. Default choice.
- `Io.Evented` — work-in-progress, experimental, stackful coroutines.
- `Io.Uring` — proof-of-concept (io_uring).
- `Io.Kqueue` — proof-of-concept.
- `Io.Dispatch` — Grand Central Dispatch (macOS).
- `Io.failing` — simulates a system with no I/O.

### Testing

Use `std.testing.io` in tests, analogous to `std.testing.allocator`.

### Concurrency primitives

- `io.async(fn, .{args})` → creates a `Future(T)`. Infallible. May execute synchronously.
- `io.concurrent(fn, .{args})` → creates a `Future(T)`. Must run concurrently. Can fail with `error.ConcurrencyUnavailable`.
- `Future(T)` has `.await(io)` and `.cancel(io)` methods (both idempotent).
- `Io.Group` — manages many tasks with shared lifetime. O(1) overhead per task. Methods: `.async`, `.await`, `.cancel`.
- `Io.Queue(T)` — thread-safe MPMC queue with runtime-configurable buffer.
- `Io.Select` — high-level task-completion selection.
- `Io.Batch` — low-level operation-layer concurrency.

### Standard task-spawning pattern (handles cancelation + resource cleanup)

```zig
var foo_future = io.async(foo, .{args});
defer if (foo_future.cancel(io)) |resource| resource.deinit() else |_| {}

const foo_result = try foo_future.await(io);
```

If the function returns no resource: `defer _ = foo_future.cancel(io) catch {};`
If the function returns `void`: `defer foo_future.cancel(io) catch {};`

### Cancelation

- Spelled with **one `l`**: `Canceled`, `Canceling`, `error.Canceled`. (The release notes are emphatic about this.)
- Most I/O error sets now include `error.Canceled`.
- Three ways to handle `error.Canceled` (in order of preference):
  1. Propagate it.
  2. `io.recancel()` and don't propagate.
  3. Make it unreachable via `io.swapCancelProtection()`.
- Add manual cancel points with `io.checkCancel()` (rarely needed; useful in long CPU-bound work).

### Sync primitive renames (USE NEW NAMES IN 0.16.0)

| Old (0.15.x) | New (0.16.0) |
|---|---|
| `std.Thread.ResetEvent` | `std.Io.Event` |
| `std.Thread.WaitGroup` | `std.Io.Group` |
| `std.Thread.Futex` | `std.Io.Futex` |
| `std.Thread.Mutex` | `std.Io.Mutex` |
| `std.Thread.Condition` | `std.Io.Condition` |
| `std.Thread.Semaphore` | `std.Io.Semaphore` |
| `std.Thread.RwLock` | `std.Io.RwLock` |
| `std.once` | **REMOVED** — hand-roll the logic |
| `std.Thread.Mutex.Recursive` | **REMOVED** |
| `std.Thread.Pool` | **REMOVED** — use `std.Io.async` / `std.Io.Group` |

### Time renames

| Old | New |
|---|---|
| `std.time.Instant` | `std.Io.Timestamp` |
| `std.time.Timer` | `std.Io.Timestamp` |
| `std.time.timestamp` | `std.Io.Timestamp.now` |

New: `Clock.resolution` can be called to query clock resolution. `error.Unexpected` and `error.ClockUnsupported` removed from timeout/clock error sets.

### Entropy / RNG

```zig
// OLD
std.crypto.random.bytes(&buffer);
// NEW
io.random(&buffer);
```

```zig
// OLD
const rng = std.crypto.random;
// NEW
const rng_impl: std.Random.IoSource = .{ .io = io };
const rng = rng_impl.interface();
```

```zig
// OLD
posix.getrandom(&buffer);
// NEW
io.random(&buffer);
```

- `io.random` — may use stored RNG state.
- `io.randomSecure` — always syscalls; returns `error.EntropyUnavailable` on failure.
- `std.Options.crypto_always_getrandom` and `std.Options.crypto_fork_safety` are gone (replaced by `random` vs `randomSecure`).

---

## 2. "Juicy Main" — New `main` Signature

`main` may now take a `std.process.Init` parameter, which provides pre-initialized `arena`, `gpa`, `io`, `environ_map`, `preopens`, and `minimal` (which contains `args` and `environ`).

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // ...
}
```

`main` can alternatively accept `std.process.Init.Minimal` (only raw `args` and `environ`), or take no parameter at all (but then you can't access CLI args or env vars).

### Environment variables and CLI args are **no longer global**

- `std.os.environ` is gone (it had a major footgun — impossible to populate without libc).
- Accessing env vars now goes through `init.environ_map` or `init.minimal.environ`.
- Accessing CLI args now goes through `init.minimal.args` (use `.iterate()` or `.toSlice(allocator)`).
- Functions that need env vars should take a `*const process.Environ.Map` parameter.

---

## 3. Language Changes

### 3.1 `@Type` removed — use individual type-creating builtins

`@Type` is **gone**. Use one of 8 new builtins.

| Old | New |
|---|---|
| `@Type(.enum_literal)` | `@EnumLiteral()` |
| `@Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } })` | `@Int(.unsigned, 10)` |
| `std.meta.Int(.unsigned, 10)` (deprecated helper) | `@Int(.unsigned, 10)` |
| `std.meta.Tuple(&.{u32, [2]f64})` (deprecated) | `@Tuple(&.{u32, [2]f64})` |

#### `@Pointer`

```zig
@Pointer(.one, .{ .@"const" = true }, u32, null)
@Pointer(.many, .{ .@"align" = 1 }, u64, 0)
```

Signature: `@Pointer(size, attrs, Element, sentinel)`.

#### `@Fn`

```zig
@Fn(
    &.{ f64, *const anyopaque },                         // param types
    &.{ .{}, .{ .@"noalias" = true } },                  // param attrs
    u32,                                                 // return type
    .{ .@"callconv" = .c, .varargs = true },             // fn attrs
)
```

Use `&@splat(.{})` for default param attrs everywhere.

#### `@Struct`

```zig
@Struct(
    .@"extern",            // layout
    null,                  // backing int (or null)
    &.{ "foo", "bar" },    // field names
    &.{ [2]f64, u32 },     // field types
    &.{                    // field attrs
        .{ .@"align" = 1 },
        .{ .@"comptime" = true, .default_value_ptr = &@as(u32, 123) },
    },
)
```

#### `@Union`

```zig
@Union(.auto, MyEnum, &.{ "foo", "bar" }, &.{ i64, f64 }, &@splat(.{}))
```

#### `@Enum`

```zig
@Enum(u32, .exhaustive, &.{ "foo", "bar" }, &.{ 0, 1 })
```

#### No `@Float`, `@Array`, `@Opaque`, `@Optional`, `@ErrorUnion`, `@ErrorSet`

- Float: use `std.meta.Float(bits)` or write `f32`/`f64` etc. directly.
- Array: use `[len]Elem` or `[len:sentinel]Elem` syntax.
- Opaque: write `opaque {}`.
- Optional: write `?T`.
- Error union: write `E!T`.
- Error set: **reifying error sets is no longer possible**. Declare explicitly with `error{ ... }`.

#### Tuples can no longer be reified with `comptime` fields.

### 3.2 `@cImport` deprecated — move to build system

`@cImport` still works but is deprecated. Migrate to `translate-c` in `build.zig`.

Before (in `c.zig`):

```zig
pub const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("GLFW/glfw3.h");
});
```

After — create a `c.h`:

```c
#include <stdio.h>
#include <GLFW/glfw3.h>
```

And in `build.zig`:

```zig
const translate_c = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});
translate_c.linkSystemLibrary("glfw", .{});

const exe = b.addExecutable(.{
    .name = "prog",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
        },
    }),
});
```

In source: `const c = @import("c");`

### 3.3 `switch` improvements

- `packed struct` and `packed union` are now valid switch prong items (compared by backing integer).
- Decl literals and result-type-requiring expressions (e.g. `@enumFromInt`) work as prong items.
- Union tag captures work for all prongs, not only `inline` ones.
- Prongs with errors not in the switched set are allowed if they do `=> comptime unreachable`.
- **Switch prong captures may no longer all be discarded.**
- Switching on `void` no longer requires an `else` prong unconditionally.

### 3.4 Packed unions can now use equality comparisons directly

No need to wrap in a packed struct anymore.

### 3.5 Small integer → float coercion is implicit when safe

If every value of the integer type fits in the float's significand, no `@floatFromInt` needed.

```zig
// OLD
var foo_int: u24 = 123;
var foo_float: f32 = @floatFromInt(foo_int);
// NEW
var foo_float: f32 = foo_int;   // u24 fits in f32 significand → implicit
// Still required for u25+ into f32
var bar_int: u25 = 123;
var bar_float: f32 = @floatFromInt(bar_int);
```

### 3.6 Runtime indexing of vectors is forbidden

```zig
// OLD
for (0..vector_len) |i| { _ = vector[i]; }

// NEW — coerce to array first
const vt = @typeInfo(@TypeOf(vector)).vector;
const array: [vt.len]vt.child = vector;
for (&array) |elem| { _ = elem; }
```

### 3.7 Vector/Array in-memory coercion removed

If you were `@ptrCast`ing between arrays and vectors, use direct coercion. If coercing `anyerror![4]i32` to `anyerror!@Vector(4, i32)`, unwrap the error first.

### 3.8 Returning `&local` from a function is now a compile error

```zig
// COMPILE ERROR in 0.16.0
fn foo() *i32 {
    var x: i32 = 1234;
    return &x;
}
```

Write `return undefined` if you actually want that semantics.

### 3.9 Unary float builtins forward result types

`@sqrt`, `@sin`, `@cos`, `@tan`, `@exp`, `@exp2`, `@log`, `@log2`, `@log10`, `@floor`, `@ceil`, `@trunc`, `@round` now propagate result type through:

```zig
const x: f64 = @sqrt(@floatFromInt(N)); // now works
```

### 3.10 `@floor`/`@ceil`/`@round`/`@trunc` can convert float → int

```zig
const actual: u8 = @round(value_f32);   // works directly
```

**`@intFromFloat` is deprecated** — use `@trunc` instead.

### 3.11 `packed union`: all fields must have the same `@bitSizeOf` as the backing int

```zig
// OLD (error in 0.16)
const U = packed union { x: u8, y: u16 };

// NEW
const U = packed union(u16) {
    x: packed struct(u16) { data: u8, padding: u8 = 0 },
    y: u16,
};
```

### 3.12 Pointers forbidden in `packed struct` / `packed union`

Use `usize` + `@ptrFromInt` / `@intFromPtr` instead.

### 3.13 `packed union` may now declare explicit backing int

`packed union(u16) { ... }` is now legal. Sometimes required (see next item).

### 3.14 Extern types must have explicit backing/tag integer

Implicit backing ints on `enum`, `packed struct`, `packed union` are **no longer valid in extern contexts** (e.g. `export var`).

```zig
// OLD → error
const Enum = enum { a, b, c, d };
export var x: Enum = .a;

// NEW
const Enum = enum(u8) { a, b, c, d };
export var x: Enum = .a;
```

### 3.15 Lazy field analysis

Struct/union/enum/opaque fields are only analyzed when size or a field type is actually needed. You can use a type as a namespace, or hold a `*T`, without forcing `T` resolution.

### 3.16 Pointers to comptime-only types are runtime types

`*comptime_int` and `[]comptime_int` are runtime types (can exist at runtime, just can't be dereferenced there). Same as `*const fn () void`. Useful: you can pass `[]const std.builtin.Type.StructField` to runtime code and load `.name` from it at runtime.

### 3.17 `*u8` and `*align(1) u8` are distinct types

They coerce to each other (in-memory coercion) — for practical purposes they're interchangeable, analogous to `u32` vs `c_uint`.

### 3.18 Zero-bit tuple fields are no longer implicitly `comptime`

Reverts an unintentional 0.14 rule. The value is still comptime-known but `is_comptime` now reports `false`. Only breaks code that depended on `is_comptime` from `@typeInfo` or on equivalence between tuple types with/without explicit `comptime` fields.

---

## 4. Standard Library Migration Cheat Sheet

### 4.1 Error set renames

| Old | New |
|---|---|
| `error.RenameAcrossMountPoints` | `error.CrossDevice` |
| `error.NotSameFileSystem` | `error.CrossDevice` |
| `error.SharingViolation` | `error.FileBusy` |
| `error.EnvironmentVariableNotFound` | `error.EnvironmentVariableMissing` |

- `std.Io.Dir.rename` now returns `error.DirNotEmpty` instead of `error.PathAlreadyExists` in that scenario.

### 4.2 `fmt` renames

| Old | New |
|---|---|
| `fmt.Formatter` | `fmt.Alt` |
| `fmt.format` | `std.Io.Writer.print` |
| `fmt.FormatOptions` | `fmt.Options` |
| `fmt.bufPrintZ` | `fmt.bufPrintSentinel` |

### 4.3 Removed with no replacement (or with major redesign)

- `SegmentedList`
- `meta.declList`
- `Io.GenericWriter`, `Io.AnyWriter`, `Io.null_writer`, `Io.CountingReader`
- `Io.GenericReader`, `Io.AnyReader` → use `Io.Reader` (one unified type)
- `FixedBufferStream` → use `Io.Reader.fixed(data)` / `Io.Writer.fixed(buffer)`
- `Thread.Mutex.Recursive`
- `Thread.Pool`
- `std.once`
- `std.builtin.subsystem`
- `std.fs.getAppDataDir` (applications should write this themselves; alt: `known-folders`)
- `DynLib` on Windows (use `LoadLibraryExW` + `GetProcAddress` directly)
- `ArrayHashMap`, `AutoArrayHashMap`, `StringArrayHashMap` (managed versions)

### 4.4 `std.io` → `std.Io`

All references to `std.io` (lowercase) should be updated. Examples:

```zig
// OLD
var fbs = std.io.fixedBufferStream(data);
const reader = fbs.reader();

// NEW
var reader: std.Io.Reader = .fixed(data);
```

```zig
// OLD
var fbs = std.io.fixedBufferStream(buffer);
const writer = fbs.writer();

// NEW
var writer: std.Io.Writer = .fixed(buffer);
```

LEB128:
- `std.leb.readUleb128` → `std.Io.Reader.takeLeb128`
- `std.leb.readIleb128` → `std.Io.Reader.takeLeb128`

### 4.5 Filesystem migrations (`std.fs.*` → `std.Io.Dir` / `std.Io.File`)

**General rule: add an `io` parameter.** `file.close()` → `file.close(io)`.

Top-level:

| Old | New |
|---|---|
| `fs.copyFileAbsolute` | `std.Io.Dir.copyFileAbsolute` |
| `fs.makeDirAbsolute` | `std.Io.Dir.createDirAbsolute` |
| `fs.deleteDirAbsolute` | `std.Io.Dir.deleteDirAbsolute` |
| `fs.openDirAbsolute` | `std.Io.Dir.openDirAbsolute` |
| `fs.openFileAbsolute` | `std.Io.Dir.openFileAbsolute` |
| `fs.accessAbsolute` | `std.Io.Dir.accessAbsolute` |
| `fs.createFileAbsolute` | `std.Io.Dir.createFileAbsolute` |
| `fs.deleteFileAbsolute` | `std.Io.Dir.deleteFileAbsolute` |
| `fs.renameAbsolute` | `std.Io.Dir.renameAbsolute` |
| `fs.readLinkAbsolute` | `std.Io.Dir.readLinkAbsolute` |
| `fs.symLinkAbsolute` | `std.Io.Dir.symLinkAbsolute` |
| `fs.has_executable_bit` | `std.Io.File.Permissions.has_executable_bit` |
| `fs.realpath` | `std.Io.Dir.realPathFileAbsolute` |
| `fs.rename` | `std.Io.Dir.rename` (now takes two `Dir` args + `io`) |
| `fs.cwd` | `std.Io.Dir.cwd` |
| `fs.defaultWasiCwd` | `std.os.defaultWasiCwd` |
| `fs.realpathAlloc` | `std.Io.Dir.realPathFileAbsoluteAlloc` |
| `fs.openSelfExe` | `std.process.openExecutable` |
| `fs.selfExePath` | `std.process.executablePath` |
| `fs.selfExePathAlloc` | `std.process.executablePathAlloc` |
| `fs.selfExeDirPath` | `std.process.executableDirPath` |
| `fs.selfExeDirPathAlloc` | `std.process.executableDirPathAlloc` |
| `fs.Dir` | `std.Io.Dir` |
| `fs.File` | `std.Io.File` |
| `fs.Dir.setAsCwd` | `std.process.setCurrentDir` |
| `fs.Dir.realpath` | `std.Io.Dir.realPathFile` |
| `fs.Dir.realpathAlloc` | `std.Io.Dir.realPathFileAlloc` |

Dir methods:

| Old | New |
|---|---|
| `Dir.makeDir` | `Dir.createDir` |
| `Dir.makePath` | `Dir.createDirPath` |
| `Dir.makeOpenDir` | `Dir.createDirPathOpen` |
| `Dir.atomicSymLink` | `Dir.symLinkAtomic` |
| `Dir.chmod` | `Dir.setPermissions` |
| `Dir.chown` | `Dir.setOwner` |

File methods:

| Old | New |
|---|---|
| `File.Mode` / `File.PermissionsWindows` / `File.PermissionsUnix` | `std.Io.File.Permissions` |
| `File.default_mode` | `Permissions.default_file` |
| `File.getOrEnableAnsiEscapeSupport` | `File.enableAnsiEscapeCodes` |
| `File.setEndPos` | `File.setLength` |
| `File.getEndPos` | `File.length` |
| `File.seekTo` / `seekBy` / `seekFromEnd` | `File.Reader.seekTo` / `Reader.seekBy` / `Writer.seekTo` |
| `File.getPos` | `File.Reader.logicalPos`, `Io.Writer.logicalPos` |
| `File.mode` | `File.stat().permissions.toMode` |
| `File.chmod` | `File.setPermissions` |
| `File.chown` | `File.setOwner` |
| `File.updateTimes` | `File.setTimestamps`, `File.setTimestampsNow` |
| `File.read` / `readv` | `File.readStreaming` |
| `File.pread` / `preadv` | `File.readPositional` |
| `File.preadAll` | `File.readPositionalAll` |
| `File.write` / `writev` | `File.writeStreaming` |
| `File.pwrite` / `pwritev` | `File.writePositional` |
| `File.writeAll` | `File.writeStreamingAll` |
| `File.pwriteAll` | `File.writePositionalAll` |
| `File.copyRange` / `copyRangeAll` | `File.writer` |

Deprecated (still present but moved):
- `fs.path` → `std.Io.Dir.path`
- `fs.max_path_bytes` → `std.Io.Dir.max_path_bytes`
- `fs.max_name_bytes` → `std.Io.Dir.max_name_bytes`

Removed with no replacement — all the `*Z` (null-terminated) and `*W` (wide) variants of `realpath`, `openDir`, `deleteFile`, etc. Also `deleteTreeAbsolute`, `adaptToNewApi`/`adaptFromNewApi`, `isCygwinPty`.

New additions:
- `Io.Dir.hardLink`, `Io.Dir.Reader`, `Io.Dir.setFilePermissions`, `Io.Dir.setFileOwner`
- `Io.File.NLink`
- `Io.Dir.renamePreserve` (rename without replacing destination)

### 4.6 File reading patterns

```zig
// OLD
const contents = try std.fs.cwd().readFileAlloc(allocator, file_name, 1234);

// NEW — note reordered args and new limit type; error is StreamTooLong, not FileTooBig
const contents = try std.Io.Dir.cwd().readFileAlloc(io, file_name, allocator, .limited(1234));
```

```zig
// OLD
const contents = try file.readToEndAlloc(allocator, 1234);

// NEW
var file_reader = file.reader(&.{});
const contents = try file_reader.interface.allocRemaining(allocator, .limited(1234));
```

### 4.7 `File.Stat.atime` is optional

Filesystems often refuse or fail to report atime. It's now `?i128`.

```zig
// OLD
stat.atime
// NEW
stat.atime orelse return error.FileAccessTimeUnavailable
```

`setTimestamps` now takes independent options per field:

```zig
// OLD
try file.setTimestamps(io, src.atime, src.mtime);
// NEW
try file.setTimestamps(io, .{
    .access_timestamp = .init(src.atime),
    .modify_timestamp = .init(src.mtime),
});
```

### 4.8 Atomic / temporary files — new API

```zig
// OLD
var buffer: [1024]u8 = undefined;
var atomic_file = try dest_dir.atomicFile(io, dest_path, .{
    .permissions = actual_permissions,
    .write_buffer = &buffer,
});
defer atomic_file.deinit();
// ... use atomic_file.file_writer ...
try atomic_file.flush();
try atomic_file.renameIntoPlace();

// NEW
var atomic_file = try dest_dir.createFileAtomic(io, dest_path, .{
    .permissions = actual_permissions,
    .make_path = true,
    .replace = true,
});
defer atomic_file.deinit(io);

var buffer: [1024]u8 = undefined;
var file_writer = atomic_file.file.writer(io, &buffer);
// ... use file_writer ...
try file_writer.flush();
try atomic_file.replace(io); // or .link(io) if .replace = false
```

### 4.9 Selectively walking directories

`Dir.walk` doesn't support skipping directories. Use `Dir.walkSelectively` when you need filtering, so skipped directories don't cause needless open/close syscalls.

```zig
var walker = try dir.walkSelectively(gpa);
defer walker.deinit();
while (try walker.next(io)) |entry| {
    if (failsFilter(entry)) continue;
    if (entry.kind == .directory) {
        try walker.enter(io, entry);
    }
    // ...
}
```

`Walker.Entry` has a new `depth` function. `Walker` and `SelectiveWalker` have `leave` functions for bailing out mid-iteration.

### 4.10 `fs.path` — Windows paths, pure `relative`

- API changes: `windowsParsePath` / `diskDesignator` / `diskDesignatorWindows` → `parsePath`, `parsePathWindows`, `parsePathPosix`. New `getWin32PathType`. `componentIterator` / `ComponentIterator.init` can no longer fail.
- `relative`, `relativeWindows`, `relativePosix` are now pure — require CWD and (optional) environment map as arguments instead of calling the OS internally.

```zig
// OLD
const rel = try std.fs.path.relative(gpa, from, to);

// NEW
const cwd_path = try std.process.currentPathAlloc(io, gpa);
defer gpa.free(cwd_path);
const rel = try std.fs.path.relative(gpa, cwd_path, environ_map, from, to);
```

### 4.11 Current directory API

| Old | New |
|---|---|
| `std.process.getCwd(buffer)` | `std.process.currentPath(io, buffer)` |
| `std.process.getCwdAlloc(allocator)` | `std.process.currentPathAlloc(io, allocator)` |

### 4.12 "Preopens"

| Old | New |
|---|---|
| `std.fs.wasi.Preopens` / `.preopensAlloc(arena)` | `std.process.Preopens` / `.init(arena)` |

Or get it from `std.process.Init.preopens` via "Juicy Main". On non-WASI, data is `void` — zero cost.

### 4.13 Process API

```zig
// OLD — child process
var child = std.process.Child.init(argv, gpa);
child.stdin_behavior = .Pipe;
child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;
try child.spawn(io);

// NEW
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe,
    .stdout = .pipe,
    .stderr = .pipe,
});
```

```zig
// OLD
const result = std.process.Child.run(allocator, io, .{...});
// NEW
const result = std.process.run(allocator, io, .{...});
```

```zig
// OLD
const err = std.process.execv(arena, argv);
// NEW
const err = std.process.replace(io, .{ .argv = argv });
```

### 4.14 Memory locking / protection moved to `std.process`

```zig
// OLD
std.posix.PROT.READ | std.posix.PROT.WRITE
// NEW (type-safe)
.{ .READ = true, .WRITE = true }
```

```zig
// OLD
try std.posix.mlock();
try std.posix.mlock2(slice, std.posix.MLOCK_ONFAULT);
try std.posix.mlockall(slice, std.posix.MCL_CURRENT | std.posix.MCL_FUTURE);

// NEW
try std.process.lockMemory(slice, .{});
try std.process.lockMemory(slice, .{ .on_fault = true });
try std.process.lockMemoryAll(.{ .current = true, .future = true });
```

### 4.15 `std.posix` / `std.os.windows`

Most medium-level functions are removed. Go higher (`std.Io`) or lower (`std.posix.system` directly for syscalls).

### 4.16 Collection migration to "Unmanaged" style

The redundant `FooUnmanaged` suffix is being dropped. The allocator field is being removed from managed variants.

| Old | New |
|---|---|
| `AutoArrayHashMapUnmanaged` | `array_hash_map.Auto` |
| `StringArrayHashMapUnmanaged` | `array_hash_map.String` |
| `ArrayHashMapUnmanaged` | `array_hash_map.Custom` |
| `ArrayHashMap` / `AutoArrayHashMap` / `StringArrayHashMap` | **REMOVED** |

Also new: `heap.MemoryPoolUnmanaged`, `heap.MemoryPoolAlignedUnmanaged`, `heap.MemoryPoolExtraUnmanaged`.

### 4.17 `PriorityQueue` / `PriorityDequeue`

No more `Allocator` field; `add` → `push`, `remove` → `pop`; init with `.empty`.

| Old | New |
|---|---|
| `init` | `.empty` (or `initContext` for `PriorityQueue`) |
| `add` | `push` |
| `addSlice` | `pushSlice` |
| `addUnchecked` | `pushUnchecked` |
| `remove` / `removeOrNull` | `pop` |
| `removeMin` / `removeMinOrNull` | `popMin` (dequeue) |
| `removeMax` / `removeMaxOrNull` | `popMax` (dequeue) |
| `removeIndex` | `popIndex` |

```zig
const MinHeap = std.PriorityQueue(u32, void, lessThan);
var queue: MinHeap = .empty;
```

### 4.18 Heap changes

- **`heap.ArenaAllocator` is now thread-safe and lock-free.** No behavior change for single-threaded users. Can now be used as the backing allocator for an `Io` instance.
- **`heap.ThreadSafeAllocator` removed** — it was an anti-pattern; lock-free allocators are better.

### 4.19 `mem` rename: "index of" → "find"

New cut functions: `cut`, `cutPrefix`, `cutSuffix`, `cutScalar`, `cutLast`, `cutLastScalar`.

Naming concepts in `std.mem`: `find` (return index of substring), `pos` (starting index), `last` (search from end), `linear` (simple for-loop), `scalar` (single element).

### 4.20 `math.sign`

Now returns the smallest integer type that fits possible values.

### 4.21 `BitSet` / `EnumSet`

`initEmpty` / `initFull` replaced with decl literals (`.empty` / `.full`).

### 4.22 `std.crypto` additions

- **AES-SIV** and **AES-GCM-SIV** (nonce-reuse resistant).
- **Ascon-AEAD**, **Ascon-Hash**, **Ascon-CHash** (NIST SP 800-232 lightweight crypto).

### 4.23 `Io.Writer.Allocating` gets `alignment` field

`alignment: std.mem.Alignment` — runtime-known. Use the `*Raw` variants of the Allocator API.

### 4.24 `compress`

lzma, lzma2, xz all migrated to `Io.Reader` / `Io.Writer`. Deflate now has a complete compressor (plus `Raw` and `Huffman` writers). Decompression uses reader `peek` for simpler bit reading.

### 4.25 Misc

- `tar.extract` now sanitizes path traversal.
- Automatic fetching of root certificates on Windows is now triggered.
- Debug info reworked — `std.debug.StackIterator` is no longer `pub`.
  - New functions: `std.debug.writeStackTrace`, `dumpStackTrace`, `captureCurrentStackTrace`, `writeCurrentStackTrace`, `dumpCurrentStackTrace`.
  - Renames: `captureStackTrace` → `captureCurrentStackTrace`; `dumpStackTraceFromBase` → `dumpCurrentStackTrace`; `walkStackWindows` → `captureCurrentStackTrace`; `writeStackTraceWindows` → `writeCurrentStackTrace`.
- `ucontext_t` and related signal/setjmp machinery removed — roll your own `mcontext_t` for your target if needed.

---

## 5. Build System Changes

### 5.1 `--fork=<path>` flag

Temporarily override a package with a local fork. Matches by `name`+`fingerprint` in `build.zig.zon` (ignores version). Resolves before fetch.

```
zig build --fork=/home/me/dev/dvui
```

### 5.2 Packages fetched into project-local `zig-pkg/`

Instead of `$GLOBAL_ZIG_CACHE/p/$HASH`. The global cache still gets a compressed tarball. Recommendation: don't commit `zig-pkg/` to source control.

**`build.zig.zon` now requires a `fingerprint` field, and `name` must be an enum literal (not a string).** Legacy hash format is no longer supported.

`ZIG_BTRFS_WORKAROUND` env var is ignored — kernel bug long-since fixed.

### 5.3 Unit test timeouts

```
zig build test --test-timeout 500ms
```

Terminates and restarts any test block exceeding the wall-clock deadline. Helpful for catching hangs.

### 5.4 `--error-style` flag

Replaces `--prominent-compile-errors`. Values: `verbose` (default), `minimal`, `verbose_clear`, `minimal_clear` (the `_clear` variants clear the terminal on `--watch` rebuilds). Env var: `ZIG_BUILD_ERROR_STYLE`.

Old equivalent: `--prominent-compile-errors` ≈ `--error-style minimal`.

### 5.5 `--multiline-errors` flag

Options: `indent` (new default), `newline`, `none`. Env var: `ZIG_BUILD_MULTILINE_ERRORS`.

### 5.6 Temporary Files API

**`RemoveDir` step is gone.** **`Build.makeTempPath` is gone.** Use the updated `WriteFile` step instead:

- `b.addTempFiles` → WriteFile step in "tmp mode" (outside `o`, no caching, auto-cleanup on completion).
- `b.addMutateFiles` → WriteFile step in "mutate mode" (operations against a scratch dir).
- `b.tmpPath` → shortcut: `addTempFiles` + `WriteFile.getDirectory`.

### 5.7 Misc

- `std.Build.Step.ConfigHeader` handles leading whitespace in cmake-style configs.

---

## 6. Compiler & Toolchain Notes (Non-Breaking, Good to Know)

### 6.1 C translation

Backed by **arocc + translate-c** (no more libclang). Compiled lazily on first `@cImport`. Behavior should be identical; if it's not, it's a bug — report it.

### 6.2 LLVM backend

- Experimental incremental compilation.
- Error set types now lowered as enums → error names visible at runtime.
- Better debug info for unions with zero-bit payloads; types have proper names.

### 6.3 Incremental compilation

Much better in 0.16.0 but **still disabled by default**. Enable with:

```
zig build -fincremental --watch
```

Combines well with `--error-style verbose_clear` or `minimal_clear`.

### 6.4 New ELF linker

- Enabled with `-fnew-linker` (CLI) or `exe.use_new_linker = true` (build.zig).
- Default when `-fincremental` + ELF target.
- Much faster incremental link; tradeoff is that executables produced this way currently lack DWARF info.

### 6.5 x86 backend

Still the default for Debug. Passes more behavior tests than LLVM backend. Faster compilation, better debug info, worse machine code.

### 6.6 aarch64 backend

Still a WIP; currently crashes on behavior tests.

### 6.7 WebAssembly backend

Passes 92% (1813/1970) of behavior tests vs LLVM.

### 6.8 For-loop safety checks

Slices: ~30% less codegen overhead.

### 6.9 `std.Progress` on Windows

Now reports info from child processes. Max node length bumped 40 → 120.

### 6.10 Windows networking

All networking implemented via direct AFD access — **no dependency on ws2_32.dll**. Proper cancelation + batch support.

### 6.11 Completed migration to NtDll

Only a handful of `crypt32` and one `kernel32` (`CreateProcessW`) extern functions remain on Windows.

### 6.12 `std.zig.Subsystem`

`std.Target.SubSystem` moved to `std.zig.Subsystem`. Deprecated alias remains, deprecated field names retained to not break `exe.subsystem = .Windows`.

**`std.builtin.subsystem` removed entirely** — subsystem is a link-time concept; determining at compile time was flaky and incorrect.

### 6.13 Toolchain bumps

- LLVM 21 (loop vectorization disabled to work around a regression).
- musl 1.2.5, glibc 2.43, Linux 6.19 headers, macOS 26.4 headers, FreeBSD 15.0 libc.
- OpenBSD: supports dynamically-linked libc when cross-compiling.

### 6.14 Dropped OS support

Solaris, AIX, z/OS removed (proprietary-OS sourcing issues). illumos (open-source) still supported.

### 6.15 New target support

- `aarch64-maccatalyst`, `x86_64-maccatalyst` cross-compilation.
- `loongarch32-linux` (syscalls only, no libc yet).
- Basic support: Alpha, KVX, MicroBlaze, OpenRISC, PA-RISC, SuperH (need Zig's C backend + GCC, or external LLVM/Clang fork).
- Big-endian ARM emits BE8 on ARMv6+ (was legacy BE32).

### 6.16 OS minimum versions

| OS | Min |
|---|---|
| DragonFly BSD | 6.0 |
| FreeBSD | 14.0 |
| Linux | 5.10 |
| NetBSD | 10.1 |
| OpenBSD | 7.8 |
| macOS | 13.0 |
| Windows | 10 |

---

## 7. Quick Checklist When Upgrading Zig Source Code

1. **Thread `io` through the call graph.** Almost any function that touches files, network, time, sync, or randomness now wants `io: std.Io`.
2. **Change `main` signature** to accept `std.process.Init` (or `.Minimal`) if you need args/env/etc.
3. **Replace `std.fs.*` with `std.Io.Dir` / `std.Io.File`** per the table in §4.5.
4. **Replace `std.net.*` with `std.Io.net`.**
5. **Replace `std.Thread.{Mutex,Condition,Semaphore,RwLock,Futex,ResetEvent,WaitGroup}` with `std.Io.*`** equivalents. Remove `std.Thread.Pool`, `std.once`.
6. **Replace `std.io.*` with `std.Io.*`**; `FixedBufferStream` → `Io.Reader.fixed` / `Io.Writer.fixed`; `GenericReader`/`AnyReader` → `Io.Reader`.
7. **Replace `@Type(...)` with `@Int`, `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple`, `@EnumLiteral`** as appropriate. You cannot reify error sets — declare them with `error{ ... }`.
8. **Add explicit backing integers** to any `enum`, `packed struct`, or `packed union` used in extern contexts.
9. **Remove pointers from `packed struct` / `packed union`** — use `usize` + `@ptrFromInt` / `@intFromPtr`.
10. **Check packed unions for equal-sized fields** — pad fields so they all match the backing int.
11. **Stop returning `&local`** from functions.
12. **Prefer `@trunc` over `@intFromFloat`**; drop unnecessary `@floatFromInt` for small-int-to-float conversions.
13. **Replace `@ptrCast` between arrays and vectors** with direct coercion; stop runtime-indexing vectors.
14. **Update `readFileAlloc` / `readToEndAlloc`** to new signatures; expect `StreamTooLong` instead of `FileTooBig`.
15. **Update `atomicFile` usage** to `createFileAtomic`.
16. **Update process spawning / execution** APIs (`std.process.spawn`, `std.process.run`, `std.process.replace`).
17. **Update env var / CLI arg access** to go through `init.environ_map` / `init.minimal.args`.
18. **Update `std.process.getCwd`** → `std.process.currentPath(io, ...)`.
19. **Update error names**: `RenameAcrossMountPoints`/`NotSameFileSystem` → `CrossDevice`; `SharingViolation` → `FileBusy`; `EnvironmentVariableNotFound` → `EnvironmentVariableMissing`.
20. **Update `fmt.*`**: `Formatter` → `Alt`, `format` → `Io.Writer.print`, `FormatOptions` → `Options`, `bufPrintZ` → `bufPrintSentinel`.
21. **Update containers**: `ArrayHashMapUnmanaged` → `array_hash_map.Custom` etc.; `PriorityQueue`/`PriorityDequeue` `add`/`remove` → `push`/`pop`; initialize with `.empty`.
22. **Update `build.zig.zon`**: ensure `fingerprint` is present; `name` must be an enum literal.
23. **Remove uses of `RemoveDir` step and `Build.makeTempPath`**; migrate to `addTempFiles` / `addMutateFiles`.
24. **If using `--prominent-compile-errors`**: replace with `--error-style minimal`.
25. **Remove uses of `std.builtin.subsystem`**; the field no longer exists.

---

*Source: https://ziglang.org/download/0.16.0/release-notes.html — 8 months of work, 244 contributors, 1183 commits.*

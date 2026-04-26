# Fold Executor Refactor

Bring the implementation in line with the spec (§7 Fold Executor, §9 Gateway) by
extracting the fold state out of the Gateway into a proper FoldExecutor component
that runs on its own OS thread.

## Problem

The fold state (`sql_exec`, `schema`, `registry`) lives inside `Gateway`. The
Gateway drives the fold by calling `applyNewEntries()` from three places:

- `conn.zig loop()` — before every request dispatch
- `submitAndDrain()` — after `awaitCommit`, to advance the executor to `result.seq`
- `applyEntriesLoop` coroutine in `server.zig` — background 5ms heartbeat

`applyNewEntries` reads from partition log files using blocking syscalls (`lseek` +
`read` per entry). Because it runs on the I/O fiber thread, it stalls every other
connection fiber while it holds the OS thread.

This is also architecturally wrong: the spec (§7) says the Fold Executor is a
separate component with its own thread per data partition. The Gateway should wait
for executor output, not drive it.

## What changes

### New: `src/executor/fold_executor.zig`

Owns the fold state. Runs one OS thread that reads from the partition log
continuously and applies entries.

```
FoldExecutor {
    sql_exec:    SqlExecutor       // fold state (moved from Gateway)
    schema:      SchemaRegistry    // moved from Gateway
    registry:    SqlRegistry       // moved from Gateway
    log:         *Log              // partition log to read from
    from_seq:    Seq               // next seq to consume
    shutdown:    atomic bool
    thread:      ?std.Thread
}
```

Thread loop:

```
while !shutdown:
    entries = log.read(from_seq, batch=64)
    if entries empty:
        log.waitForEntries(from_seq)   // blocks on condvar until sequencer appends
        continue
    for each entry:
        switch kind:
            schema_change => applySchema(entry)
            txn_intent    => sql_exec.run(entry)
            else          => sql_exec.advanceSeq(entry.seq)
        from_seq = entry.seq + 1
```

Public API (called by Gateway from I/O fiber):

```zig
pub fn current_seq(self: *const FoldExecutor) Seq
pub fn wait_for(self: *const FoldExecutor, target: Seq, io: ?std.Io) !void
pub fn querySelect(...) !ResultSet      // delegates to sql_exec
pub fn readAt(...) !ResultSet           // delegates to sql_exec
pub fn waitFor(self, seq: Seq) ExecResult  // for write result fetch
```

`wait_for` uses `io.sleep(100µs)` when `io` is non-null (I/O fiber path) so other
fibers run while waiting. Falls back to `sched_yield` in tests.

### Modified: `src/log/manager.zig`

Add a condvar so the FoldExecutor thread sleeps efficiently instead of spinning:

```zig
// Added to Log:
mutex: std.Thread.Mutex = .{}
cond:  std.Thread.Condition = .{}

// Called by sequencer after every append_entry_at:
pub fn notifyAppend(self: *Log) void

// Called by FoldExecutor when log is empty:
pub fn waitForEntries(self: *Log, from_seq: Seq) void
```

### Modified: `src/gateway/gateway.zig`

- Remove `sql_exec`, `schema`, `registry` fields — they move to FoldExecutor
- Add `fold_executor: *FoldExecutor` field
- Remove `applyNewEntries()` and `readMergedEntries()`
- Replace the apply loop in `submitAndDrain`:

```zig
// Before:
while (self.sql_exec.current_seq() < result.seq) {
    try self.applyNewEntries();
}
const exec_result = self.sql_exec.waitFor(result.seq);

// After:
try self.fold_executor.wait_for(result.seq, self.io);
const exec_result = self.fold_executor.waitFor(result.seq);
```

- `querySelect`, `readAt` delegate to `self.fold_executor`
- `register`, `applyDdl` schema state comes from `self.fold_executor.schema` /
  `self.fold_executor.registry`

### Modified: `src/sequencer/sequencer.zig`

After each `partition_log.append_entry_at(le)` in `flushOutputs`, call:

```zig
partition_log.notifyAppend();
```

So the FoldExecutor thread wakes immediately when new entries arrive.

### Modified: `src/net/server.zig`

- Remove `applyEntriesLoop` function and its `group.async` call — FoldExecutor
  thread replaces it
- Start FoldExecutor thread(s) before the accept loop, stop them on shutdown

### Modified: `src/net/conn.zig`

- Remove `self.gw.applyNewEntries() catch {}` from `loop()` — the FoldExecutor
  runs continuously, reads are always current

### Modified: `src/main.zig`

Wire FoldExecutor into the startup sequence: create it, start its thread, pass it
to Gateway init.

## What disappears

| Removed | Replacement |
|---------|-------------|
| `Gateway.applyNewEntries()` | FoldExecutor thread |
| `Gateway.readMergedEntries()` | FoldExecutor thread |
| `applyEntriesLoop` in server.zig | FoldExecutor thread |
| `gw.applyNewEntries()` in conn.zig `loop()` | Not needed — executor is always running |
| `gw.applyNewEntries()` in submitAndDrain | `fold_executor.wait_for(seq, io)` |
| `sql_exec`, `schema`, `registry` in Gateway | Moved to FoldExecutor |

## Side effect: blocking disk reads leave the I/O thread

`log.read()` uses blocking `lseek` + `read` syscalls. After this refactor those
calls happen on the FoldExecutor OS thread, never on the I/O fiber thread. The
fiber starvation problem is resolved without any O_DIRECT or io_uring work.

When we do add O_DIRECT + async reads later, the work targets the FoldExecutor
thread, which is the correct architectural boundary.

## Scope

Single Raft group is kept as-is — per-partition Raft is not in scope (not in the
current spec milestone). The FoldExecutor initially handles all data partitions in
one thread; the structure is set up to support one thread per partition later.

## Files

| File | Status |
|------|--------|
| `src/executor/fold_executor.zig` | New |
| `src/log/manager.zig` | Add condvar wake |
| `src/gateway/gateway.zig` | Remove fold state; add FoldExecutor ref |
| `src/sequencer/sequencer.zig` | Add notifyAppend() call |
| `src/net/server.zig` | Remove applyEntriesLoop; start FoldExecutor |
| `src/net/conn.zig` | Remove applyNewEntries from loop() |
| `src/main.zig` | Wire FoldExecutor into startup |

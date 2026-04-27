/// FoldExecutor: applies committed log entries on a dedicated OS thread.
/// Owns schema, registry, and sql_exec. Runs one thread per instance that
/// reads from partition logs and applies entries in sequence order.
const std = @import("std");
const sql_mod = @import("sql.zig");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");
const cdc_mod = @import("cdc.zig");
const executor_bridge = @import("executor_bridge.zig");
const executor_mod = @import("executor.zig");
const exchange_bus_mod = @import("exchange_bus.zig");
const declare_reads_mod = @import("declare_reads.zig");

const assert = std.debug.assert;
const Seq = log_mod.Seq;
const LogEntry = log_mod.LogEntry;
const ExchangeBus = exchange_bus_mod.ExchangeBus;
const ExchangeMsg = exchange_bus_mod.ExchangeMsg;
const ForeignRead = exchange_bus_mod.ForeignRead;
const FetchedRow = exchange_bus_mod.FetchedRow;
const ForeignRowEntry = sql_mod.executor_bridge.ForeignRowEntry;

pub const ExecResult = executor_bridge.ExecResult;
pub const ResolvedValue = executor_bridge.ResolvedValue;

pub const FoldExecutor = struct {
    /// Cluster-wide schema: all databases. DDL is applied to the database named by
    /// each log entry's db_id (Step 2). Until Step 2, all DDL goes to default_database_id.
    cluster: sql_mod.ClusterSchema,
    registry: sql_mod.SqlRegistry,
    sql_exec: sql_mod.SqlExecutor,
    /// Arena for storage-layer column slice allocations during DDL. Owned.
    storage_schema_arena: std.heap.ArenaAllocator,
    /// This partition's own Storage — used for writes, DDL, and exchange fetch. Borrowed.
    storage: *storage_mod.Storage,
    /// All-partitions view used only for the direct querySelect/readAt read paths.
    /// These paths are non-transactional and bypass the exchange protocol. Borrowed.
    read_storage: *storage_mod.PartitionedStorage,
    /// Merged log stream across all log partitions. Borrowed from Gateway.
    log_mux: *log_mod.LogMux,
    /// Which partition this executor services.
    partition_id: u32,
    /// Total data partition count (1 = single-partition mode, no exchange).
    part_count: u32,
    /// Peer-to-peer exchange bus. Null in single-partition mode.
    bus: ?*ExchangeBus,
    /// CPU to pin this executor's thread to.
    cpu_id: u32,
    /// When true, runMultiPartition uses direct read_storage reads instead of the
    /// live SPSC bus. Set during replayFromLog() so recovering nodes re-derive
    /// cross-partition foreign rows from local storage without needing live peers.
    replay_mode: bool = false,
    shutdown: std.atomic.Value(bool),
    thread: ?std.Thread,
    alloc: std.mem.Allocator,

    pub fn init(
        storage: *storage_mod.Storage,
        read_storage: *storage_mod.PartitionedStorage,
        cdc: *cdc_mod.CdcManager,
        log_mux: *log_mod.LogMux,
        partition_id: u32,
        part_count: u32,
        bus: ?*ExchangeBus,
        cpu_id: u32,
        alloc: std.mem.Allocator,
    ) !*FoldExecutor {
        const fe = try alloc.create(FoldExecutor);
        errdefer alloc.destroy(fe);
        fe.alloc = alloc;
        fe.storage_schema_arena = std.heap.ArenaAllocator.init(alloc);
        fe.storage = storage;
        fe.read_storage = read_storage;
        fe.log_mux = log_mux;
        fe.partition_id = partition_id;
        fe.part_count = part_count;
        fe.bus = bus;
        fe.cpu_id = cpu_id;
        fe.shutdown = .init(false);
        fe.thread = null;
        fe.cluster = try sql_mod.ClusterSchema.init(alloc);
        errdefer fe.cluster.deinit();
        const default_schema = fe.cluster.getDb(sql_mod.default_database_id).?;
        fe.registry = sql_mod.SqlRegistry.init(alloc, default_schema);
        fe.sql_exec = sql_mod.SqlExecutor.init(storage, &fe.registry, default_schema, alloc);
        fe.sql_exec.initCdc(cdc);
        fe.sql_exec.filter_partition = partition_id;
        fe.sql_exec.part_count = part_count;
        return fe;
    }

    /// Returns the schema for the default database. Until Step 2 (log envelope),
    /// all DDL operates on the default database.
    fn defaultDb(self: *FoldExecutor) *sql_mod.SchemaRegistry {
        return self.cluster.getDb(sql_mod.default_database_id).?;
    }

    fn defaultDbConst(self: *const FoldExecutor) *sql_mod.SchemaRegistry {
        return self.cluster.databases.get(sql_mod.default_database_id).?;
    }

    pub fn deinit(self: *FoldExecutor) void {
        self.registry.deinit();
        self.cluster.deinit();
        self.storage_schema_arena.deinit();
        self.alloc.destroy(self);
    }

    pub fn start(self: *FoldExecutor) !void {
        assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadLoop, .{self});
    }

    pub fn stop(self: *FoldExecutor) void {
        self.shutdown.store(true, .release);
        self.log_mux.notifyAppend();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn threadLoop(self: *FoldExecutor) void {
        pinToCpu(self.cpu_id);
        const batch = 64;
        while (!self.shutdown.load(.acquire)) {
            const from = self.sql_exec.current_seq() + 1;
            const entries = self.log_mux.read(from, batch, self.alloc) catch continue;
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) {
                if (self.shutdown.load(.acquire)) break;
                self.log_mux.waitForEntries(from);
                continue;
            }
            for (entries) |e| {
                self.applyEntry(e);
            }
        }
    }

    fn pinToCpu(cpu_id: u32) void {
        var cpu_set = std.mem.zeroes(std.os.linux.cpu_set_t);
        const elem = cpu_id / @bitSizeOf(usize);
        if (elem < cpu_set.len) {
            cpu_set[elem] |= @as(usize, 1) << @intCast(cpu_id % @bitSizeOf(usize));
        }
        std.os.linux.sched_setaffinity(0, &cpu_set) catch |err| {
            std.log.warn("FoldExecutor[{d}]: CPU pin to {d} failed: {}", .{ cpu_id, cpu_id, err });
        };
    }

    fn applyEntry(self: *FoldExecutor, entry: LogEntry) void {
        switch (entry.header.kind) {
            .schema_change => {
                if (isSqlDdl(entry.payload)) {
                    self.replayDdl(entry.payload) catch |err| {
                        std.log.warn("FoldExecutor: DDL replay err={}", .{err});
                    };
                } else {
                    _ = self.registry.register(entry.payload) catch |err| std.log.warn("registry register: {}", .{err});
                }
                self.sql_exec.advanceSeq(entry.header.seq);
            },
            .txn_intent => {
                if (self.bus != null) {
                    self.runMultiPartition(entry) catch |err| {
                        std.log.warn("FoldExecutor[{d}]: multi-partition seq={d} err={}", .{ self.partition_id, entry.header.seq, err });
                        self.sql_exec.advanceSeq(entry.header.seq);
                    };
                } else {
                    _ = self.sql_exec.run(entry) catch |err| {
                        std.log.warn("FoldExecutor: run seq={d} err={}", .{ entry.header.seq, err });
                        self.sql_exec.advanceSeq(entry.header.seq);
                    };
                }
            },
            // Route all non-txn entries through sql_exec.run so snapshot_marker
            // entries trigger notify_snapshot on the log.
            else => _ = self.sql_exec.run(entry) catch |err| {
                std.log.warn("FoldExecutor: run seq={d} err={}", .{ entry.header.seq, err });
                self.sql_exec.advanceSeq(entry.header.seq);
            },
        }
    }

    // ---- Multi-partition rendezvous (spec §7.3) ----

    /// Peer-to-peer value exchange for cross-partition txns.
    /// Declare foreign reads → send requests via SPSC bus → serve-and-wait →
    /// run SQL plan with pre-fetched foreign rows → apply own mutations.
    fn runMultiPartition(self: *FoldExecutor, entry: LogEntry) !void {
        const bus = self.bus orelse {
            // No bus wired — fall back to direct execution (single-partition mode).
            _ = try self.sql_exec.run(entry);
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Decode intent to get read_set_hint.
        var validated = executor_mod.validate_txn_entry(entry, alloc) catch {
            _ = try self.sql_exec.run(entry);
            return;
        };
        defer validated.decoded.deinit();
        const decoded = validated.decoded;
        const seq = validated.seq;

        // Determine if this is truly a multi-partition transaction.
        // Both conditions must hold: the transaction spans multiple partitions (any_foreign),
        // AND my partition is one of them (my_in_hint).  If only one partition is in the
        // hints, every executor runs directly — the ones without data produce no mutations.
        var any_foreign = false;
        var my_in_hint = false;
        for (decoded.read_set_hint) |pid| {
            if (pid == self.partition_id) my_in_hint = true else any_foreign = true;
        }
        for (decoded.write_set_hint) |pid| {
            if (pid == self.partition_id) my_in_hint = true else any_foreign = true;
        }
        const is_multi = my_in_hint and any_foreign;
        if (!is_multi) {
            _ = try self.sql_exec.run(entry);
            return;
        }

        // Look up the plan to call declareReads.
        const rq = self.sql_exec.registry.lookup(decoded.query_hash.*) orelse {
            _ = try self.sql_exec.run(entry);
            return;
        };

        // Phase A: declare which foreign rows we need.
        var foreign_reads: std.ArrayList(ForeignRead) = .empty;
        defer {
            for (foreign_reads.items) |fr| if (fr.key.len > 0) alloc.free(fr.key);
            foreign_reads.deinit(alloc);
        }
        try declare_reads_mod.declareReads(
            rq.plan,
            self.partition_id,
            decoded.read_set_hint,
            alloc,
            &foreign_reads,
        );

        // Collect the set of target partitions we need responses from.
        var targets: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer targets.deinit(alloc);
        for (decoded.read_set_hint) |pid| {
            if (pid != self.partition_id) try targets.put(alloc, pid, {});
        }
        for (decoded.write_set_hint) |pid| {
            if (pid != self.partition_id) try targets.put(alloc, pid, {});
        }

        // Phase B: acquire foreign rows.
        // During live execution: peer-to-peer SPSC serve-and-wait.
        // During replay: direct reads from read_storage (all partitions visible locally).
        var accumulated: std.ArrayList(ForeignRowEntry) = .empty;
        defer accumulated.deinit(alloc);

        if (self.replay_mode) {
            try self.fetchForeignRowsDirect(foreign_reads.items, seq, &accumulated, alloc);
        } else {
            try self.serveAndWait(bus, seq, &targets, foreign_reads.items, &accumulated, alloc);
        }

        // Phase C: execute with foreign rows populated.
        self.sql_exec.pending_foreign_rows = accumulated.items;
        defer self.sql_exec.pending_foreign_rows = &.{};
        _ = try self.sql_exec.run(entry);
    }

    /// Live execution Phase B: send requests to peers, serve their requests, accumulate responses.
    fn serveAndWait(
        self: *FoldExecutor,
        bus: *ExchangeBus,
        seq: Seq,
        targets: *std.AutoHashMapUnmanaged(u32, void),
        foreign_reads: []const ForeignRead,
        accumulated: *std.ArrayList(ForeignRowEntry),
        alloc: std.mem.Allocator,
    ) !void {
        // Send ExchangeRequests to each target partition.
        var target_it = targets.keyIterator();
        while (target_it.next()) |pid| {
            var reads_for_target: std.ArrayList(ForeignRead) = .empty;
            defer reads_for_target.deinit(alloc);
            for (foreign_reads) |fr| try reads_for_target.append(alloc, fr);
            const req = ExchangeMsg{ .request = .{
                .seq = seq,
                .from = self.partition_id,
                .to = pid.*,
                .reads = reads_for_target.items,
            } };
            while (!bus.push(self.partition_id, pid.*, req)) std.Thread.yield() catch {};
        }

        var responses_received: u32 = 0;
        const responses_needed: u32 = targets.count();

        while (responses_received < responses_needed) {
            for (0..self.part_count) |peer_idx| {
                const peer: u32 = @intCast(peer_idx);
                if (peer == self.partition_id) continue;
                while (bus.pop(peer, self.partition_id)) |msg| {
                    switch (msg) {
                        .request => |req| {
                            if (req.seq != seq) break;
                            const fetched = try self.fetchForRequest(req, seq, alloc);
                            const resp = ExchangeMsg{ .response = .{
                                .seq = seq,
                                .from = self.partition_id,
                                .to = peer,
                                .rows = fetched,
                            } };
                            while (!bus.push(self.partition_id, peer, resp)) std.Thread.yield() catch {};
                        },
                        .response => |resp| {
                            if (resp.seq != seq) break;
                            for (resp.rows) |fetched| {
                                try accumulated.append(alloc, .{
                                    .from_partition = fetched.from_partition,
                                    .table_id = fetched.table_id,
                                    .key = fetched.key,
                                    .row = fetched.row,
                                });
                            }
                            if (targets.contains(resp.from)) {
                                responses_received += 1;
                                _ = targets.remove(resp.from);
                            }
                        },
                    }
                }
            }
            if (responses_received < responses_needed) std.Thread.yield() catch {};
        }
    }

    /// Replay Phase B: derive foreign rows directly from read_storage (all partitions visible).
    /// Produces the same ForeignRowEntry slice that serveAndWait would have produced,
    /// without requiring live peers or the SPSC bus (spec §7.3 replay path).
    fn fetchForeignRowsDirect(
        self: *FoldExecutor,
        foreign_reads: []const ForeignRead,
        seq: Seq,
        accumulated: *std.ArrayList(ForeignRowEntry),
        alloc: std.mem.Allocator,
    ) !void {
        const read_seq: Seq = if (seq > 0) seq - 1 else 0;
        for (foreign_reads) |fr| {
            if (fr.key.len == 0) {
                // Sentinel: full scan across all partitions for this table.
                var iter = self.read_storage.scan(fr.table_id, storage_mod.KeyRange.all(), read_seq, alloc) catch continue;
                defer iter.deinit();
                while (iter.next() catch break) |row| {
                    const key_copy = alloc.dupe(u8, row.key) catch continue;
                    const vals_copy = alloc.dupe(storage_mod.ColumnValue, row.values) catch {
                        alloc.free(key_copy);
                        continue;
                    };
                    try accumulated.append(alloc, .{
                        .from_partition = 0, // single-node: partition identity not needed
                        .table_id = fr.table_id,
                        .key = key_copy,
                        .row = .{ .key = key_copy, .seq = row.seq, .values = vals_copy, .is_tombstone = row.is_tombstone },
                    });
                }
            } else {
                const row_opt = self.read_storage.get(fr.table_id, fr.key, read_seq) catch null;
                var cloned_row: ?storage_mod.Row = null;
                if (row_opt) |row| {
                    var r = row;
                    defer r.deinit(alloc);
                    const key_copy = try alloc.dupe(u8, r.key);
                    const vals_copy = try alloc.dupe(storage_mod.ColumnValue, r.values);
                    cloned_row = .{ .key = key_copy, .seq = r.seq, .values = vals_copy, .is_tombstone = r.is_tombstone };
                }
                try accumulated.append(alloc, .{
                    .from_partition = 0,
                    .table_id = fr.table_id,
                    .key = fr.key,
                    .row = cloned_row,
                });
            }
        }
    }

    /// Fetch the rows requested by `req` from this executor's own storage at seq-1.
    fn fetchForRequest(
        self: *FoldExecutor,
        req: exchange_bus_mod.ExchangeRequest,
        seq: Seq,
        alloc: std.mem.Allocator,
    ) ![]FetchedRow {
        const read_seq: Seq = if (seq > 0) seq - 1 else 0;
        var fetched: std.ArrayList(FetchedRow) = .empty;
        errdefer fetched.deinit(alloc);

        for (req.reads) |fr| {
            if (fr.key.len == 0) {
                // Sentinel: full scan of this table from own partition.
                var iter = self.storage.scan(fr.table_id, storage_mod.KeyRange.all(), read_seq, alloc) catch continue;
                defer iter.deinit();
                while (iter.next() catch break) |row| {
                    const key_copy = alloc.dupe(u8, row.key) catch continue;
                    const vals_copy = alloc.dupe(storage_mod.ColumnValue, row.values) catch {
                        alloc.free(key_copy);
                        continue;
                    };
                    try fetched.append(alloc, .{
                        .from_partition = self.partition_id,
                        .table_id = fr.table_id,
                        .key = key_copy,
                        .row = .{ .key = key_copy, .seq = row.seq, .values = vals_copy, .is_tombstone = row.is_tombstone },
                    });
                }
            } else {
                // Point lookup.
                const row_opt = self.storage.get(fr.table_id, fr.key, read_seq) catch null;
                var cloned_row: ?storage_mod.Row = null;
                if (row_opt) |row| {
                    var r = row;
                    defer r.deinit(alloc);
                    const key_copy = try alloc.dupe(u8, r.key);
                    const vals_copy = try alloc.dupe(storage_mod.ColumnValue, r.values);
                    cloned_row = .{ .key = key_copy, .seq = r.seq, .values = vals_copy, .is_tombstone = r.is_tombstone };
                }
                try fetched.append(alloc, .{
                    .from_partition = self.partition_id,
                    .table_id = fr.table_id,
                    .key = fr.key,
                    .row = cloned_row,
                });
            }
        }
        return fetched.toOwnedSlice(alloc);
    }

    // ---- Schema / DDL ----

    /// Validate DDL against the current schema without mutating any state.
    /// Called by Gateway before Raft submission so the client gets early error feedback.
    /// Does not check SchemaBreakingChange — that is enforced at replay time.
    pub fn validateDdl(self: *FoldExecutor, sql: []const u8) !void {
        assert(sql.len > 0);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var parser = sql_mod.parser.Parser.init(sql, arena.allocator());
        const parsed = try parser.parseQuery();
        if (parsed.stmts.len == 0) return;
        const stmt = parsed.stmts[0];
        switch (stmt) {
            .create_table => |ct| {
                if (self.defaultDb().getTable(ct.name) != null) return error.TableAlreadyExists;
            },
            .drop_table => |dt| {
                if (!dt.if_exists and self.defaultDb().getTable(dt.name) == null) return error.TableNotFound;
            },
            .create_index => |ci| {
                const tbl = self.defaultDb().getTable(ci.table) orelse return error.TableNotFound;
                for (tbl.indexes) |idx| {
                    if (std.ascii.eqlIgnoreCase(idx.name, ci.name)) return error.IndexAlreadyExists;
                }
            },
            .alter_table => |at| {
                const tbl = self.defaultDb().getTable(at.table) orelse return error.TableNotFound;
                switch (at.action) {
                    .add_column => |col| {
                        if (tbl.columnByName(col.name) != null) return error.ColumnAlreadyExists;
                    },
                    .drop_column => |col_name| {
                        if (tbl.columnByName(col_name) == null) return error.ColumnNotFound;
                    },
                }
            },
            .create_database, .drop_database => {}, // validated at execution time (Step 6)
            else => return error.TypeCheckError,
        }
    }

    fn replayDdl(self: *FoldExecutor, sql: []const u8) !void {
        // Suppress "already exists / not found" errors: at-least-once replay on crash-restart
        // can re-deliver an entry whose effects are already in the schema.
        self.applyDdlToSchema(sql) catch |e| switch (e) {
            error.TableAlreadyExists,
            error.IndexAlreadyExists,
            error.ColumnAlreadyExists,
            error.ColumnNotFound,
            error.TableNotFound,
            => {},
            else => return e,
        };
    }

    fn applyDdlToSchema(self: *FoldExecutor, sql: []const u8) !void {
        assert(sql.len > 0);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        var parser = sql_mod.parser.Parser.init(sql, arena.allocator());
        const parsed = try parser.parseQuery();

        if (parsed.stmts.len == 0) return;
        const stmt = parsed.stmts[0];

        // drop_transaction doesn't modify the schema; handle it before applyDdl.
        if (stmt == .drop_transaction) {
            var hash: sql_mod.QueryHash = undefined;
            _ = std.fmt.hexToBytes(&hash, stmt.drop_transaction.hash_hex) catch return;
            self.registry.unregister(hash);
            return;
        }

        const drop_table_id: ?storage_mod.TableId = if (stmt == .drop_table) blk: {
            const dt = stmt.drop_table;
            const tbl = self.defaultDb().getTable(dt.name) orelse {
                if (dt.if_exists) return;
                break :blk null;
            };
            break :blk tbl.id;
        } else null;

        try self.registry.applyDdl(stmt);

        // Each executor owns its own Storage and registers tables/indexes independently.
        switch (stmt) {
            .create_table => |ct| {
                const tbl = self.defaultDb().getTable(ct.name) orelse return error.TableNotFound;
                try self.storage.registerTable(
                    try sqlTableToStorage(tbl, self.storage_schema_arena.allocator()),
                );
            },
            .drop_table => {
                if (drop_table_id) |id| self.storage.unregisterTable(id);
            },
            .create_index => |ci| {
                const tbl = self.defaultDb().getTable(ci.table) orelse return error.TableNotFound;
                if (tbl.indexes.len == 0) return;
                const idx = tbl.indexes[tbl.indexes.len - 1];
                const spec: storage_mod.IndexSpec = switch (idx.kind) {
                    .vector => .{ .vector = switch (idx.extra) {
                        .vector_dim => |d| d,
                        else => 0,
                    } },
                    .json_path => .{ .json_path = switch (idx.extra) {
                        .json_paths => |p| p,
                        else => &.{},
                    } },
                    else => return,
                };
                const column_idx: u32 = if (idx.columns.len > 0) idx.columns[0] else 0;
                try self.storage.registerIndex(.{
                    .id = idx.id,
                    .table_id = tbl.id,
                    .column_idx = column_idx,
                    .spec = spec,
                });
            },
            else => {},
        }
    }

    // ---- Query Registration ----

    /// Validate a SQL string against the current schema without registering it.
    /// Returns the canonical hash on success. Does not mutate any state.
    /// Called by Gateway before Raft submission for early client-visible error feedback.
    pub fn validateQuery(self: *FoldExecutor, sql: []const u8) !sql_mod.QueryHash {
        return self.registry.validateQuery(sql);
    }

    /// Compute the canonical hash of a SQL string without registering it.
    /// Pure computation — safe to call from any thread concurrently.
    pub fn computeQueryHash(self: *const FoldExecutor, sql: []const u8) !sql_mod.QueryHash {
        return sql_mod.computeQueryHash(sql, self.alloc);
    }

    pub fn schemaVersion(self: *const FoldExecutor) u64 {
        return self.registry.schema_seq;
    }

    // ---- Seq tracking ----

    pub fn current_seq(self: *const FoldExecutor) Seq {
        return self.sql_exec.current_seq();
    }

    /// Wait until FoldExecutor has processed target seq.
    /// Suspends the fiber with io.sleep(100µs) so other fibers can run.
    pub fn wait_for(self: *FoldExecutor, target: Seq, io: ?std.Io) !void {
        while (self.sql_exec.current_seq() < target) {
            if (io) |the_io| {
                try the_io.sleep(.{ .nanoseconds = 100_000 }, .awake);
            } else {
                _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = 100 }, null);
            }
        }
    }

    /// Return the ExecResult for seq. Caller must have called wait_for(seq) first.
    pub fn waitFor(self: *FoldExecutor, seq: Seq) ExecResult {
        return self.sql_exec.waitFor(seq);
    }

    pub fn lastExecDetail(self: *const FoldExecutor) []const u8 {
        return self.sql_exec.lastDetail();
    }

    // ---- Query execution ----

    /// Look up a registered query. Returns null if not found.
    /// The returned pointer is stable — RegisteredQuery is heap-allocated and never moved.
    pub fn lookupQuery(self: *const FoldExecutor, hash: sql_mod.QueryHash) ?*const sql_mod.RegisteredQuery {
        return self.registry.lookup(hash);
    }

    pub fn isSelectQuery(self: *const FoldExecutor, hash: sql_mod.QueryHash) bool {
        const rq = self.registry.lookup(hash) orelse return false;
        for (rq.plan.stmts) |stmt| {
            switch (stmt) {
                .select, .describe_table, .describe_transaction, .show_transactions, .show_databases => {},
                else => return false,
            }
        }
        return true;
    }

    pub fn querySelect(
        self: *FoldExecutor,
        hash: sql_mod.QueryHash,
        params: []const storage_mod.ColumnValue,
        nondet: []const ResolvedValue,
        alloc: std.mem.Allocator,
    ) !sql_mod.ResultSet {
        // RegisteredQuery is heap-allocated and never freed (no unregister operation).
        // The acquire/release on committed_seq provides happens-before with FoldExecutor's
        // writes; after wait_for() returns the registry state for this query is stable.
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        if (rq.plan.stmts.len > 0 and rq.plan.stmts[0] == .describe_table) {
            return self.buildDescribeResult(rq.plan.stmts[0].describe_table, alloc);
        }
        if (rq.plan.stmts.len > 0 and rq.plan.stmts[0] == .describe_transaction) {
            return self.buildDescribeTransactionResult(rq.plan.stmts[0].describe_transaction, alloc);
        }
        if (rq.plan.stmts.len > 0 and rq.plan.stmts[0] == .show_transactions) {
            return self.buildShowTransactionsResult(alloc);
        }
        if (rq.plan.stmts.len > 0 and rq.plan.stmts[0] == .show_databases) {
            return self.buildShowDatabasesResult(alloc);
        }

        const decoded_params = try decodeParams(params, rq.param_types, alloc);
        defer alloc.free(decoded_params);

        // Use a temporary executor backed by the all-partitions PartitionedStorage so
        // non-transactional reads (querySelect/readAt) see data from every partition.
        var read_exec = sql_mod.SqlExecutor.initAll(self.read_storage, &self.registry, self.defaultDb(), alloc);
        var rows = try read_exec.querySelect(
            rq.plan,
            decoded_params,
            nondet,
            self.sql_exec.current_seq() + 1,
            alloc,
        );
        const rows_slice = try rows.toOwnedSlice(alloc);
        // Column names were pre-computed at registration time — no schema access needed.
        const columns_slice = try dupeStringSlice(rq.output_column_names, alloc);

        return sql_mod.ResultSet{
            .columns = columns_slice,
            .rows = rows_slice,
            .alloc = alloc,
        };
    }

    pub fn readAt(
        self: *FoldExecutor,
        hash: sql_mod.QueryHash,
        params: []const storage_mod.ColumnValue,
        seq: Seq,
        alloc: std.mem.Allocator,
    ) !sql_mod.ResultSet {
        const rq = self.registry.lookup(hash) orelse return error.QueryNotFound;

        const decoded_params = try decodeParams(params, rq.param_types, alloc);
        defer alloc.free(decoded_params);

        var read_exec = sql_mod.SqlExecutor.initAll(self.read_storage, &self.registry, self.defaultDb(), alloc);
        var rows = try read_exec.querySelect(rq.plan, decoded_params, &.{}, seq + 1, alloc);
        const rows_slice = try rows.toOwnedSlice(alloc);
        const columns_slice = try dupeStringSlice(rq.output_column_names, alloc);

        return sql_mod.ResultSet{
            .columns = columns_slice,
            .rows = rows_slice,
            .alloc = alloc,
        };
    }

    // ---- Schema queries ----

    pub fn resolveTableName(self: *const FoldExecutor, name: []const u8) ?u32 {
        const tbl = self.defaultDbConst().getTable(name) orelse return null;
        return tbl.id;
    }

    pub fn tableIdExists(self: *const FoldExecutor, id: u32) bool {
        return self.defaultDbConst().getTableById(id) != null;
    }

    // ---- Startup replay ----

    /// Replay all committed log entries synchronously. Called by Gateway.init() before start().
    pub fn replayFromLog(self: *FoldExecutor) !void {
        // Use direct storage reads for cross-partition foreign rows during replay:
        // the live SPSC bus is not active, but read_storage (all partitions) can
        // re-derive the same values the exchange would have provided (spec §7.3).
        self.replay_mode = true;
        defer self.replay_mode = false;

        const batch = 256;

        // Pass 1: schema — DDL and query registration only.
        var from_seq: Seq = 1;
        while (true) {
            const entries = try self.log_mux.read(from_seq, batch, self.alloc);
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |e| {
                if (e.header.kind == .schema_change) {
                    if (isSqlDdl(e.payload)) {
                        try self.replayDdl(e.payload);
                    } else {
                        _ = try self.registry.register(e.payload);
                    }
                }
                from_seq = e.header.seq + 1;
            }
            if (entries.len < batch) break;
        }

        // Pass 2: DML — apply txn_intent entries to rebuild storage state.
        from_seq = 1;
        while (true) {
            const entries = try self.log_mux.read(from_seq, batch, self.alloc);
            defer {
                for (entries) |*e| e.deinit(self.alloc);
                self.alloc.free(entries);
            }
            if (entries.len == 0) break;
            for (entries) |e| {
                // Route through applyEntry so multi-partition txns use fetchForeignRowsDirect
                // (replay_mode=true) instead of the live SPSC bus.
                self.applyEntry(e);
                from_seq = e.header.seq + 1;
            }
            if (entries.len < batch) break;
        }
    }

    // ---- Private helpers ----

    fn buildDescribeResult(self: *FoldExecutor, table_name: []const u8, alloc: std.mem.Allocator) !sql_mod.ResultSet {
        assert(table_name.len > 0);
        const tbl = self.defaultDb().getTable(table_name) orelse return error.TableNotFound;
        assert(tbl.columns.len <= std.math.maxInt(u32));

        const col_names = [_][]const u8{ "column", "type", "nullable", "primary_key" };
        const columns = try alloc.alloc([]const u8, col_names.len);
        errdefer alloc.free(columns);
        for (col_names, 0..) |n, i| columns[i] = try alloc.dupe(u8, n);

        const rows = try alloc.alloc([]const ?storage_mod.ColumnValue, tbl.columns.len);
        errdefer alloc.free(rows);
        var built: usize = 0;
        errdefer for (rows[0..built]) |r| {
            for (r) |v| if (v) |cv| cv.freeIfOwned(alloc);
            alloc.free(r);
        };

        for (tbl.columns, 0..) |col, i| {
            var is_pk = false;
            for (tbl.primary_key) |pk_id| {
                if (pk_id == col.id) {
                    is_pk = true;
                    break;
                }
            }
            const type_str = try sqlTypeStr(col.typ, alloc);
            const row = try alloc.alloc(?storage_mod.ColumnValue, 4);
            row[0] = .{ .string = try alloc.dupe(u8, col.name) };
            row[1] = .{ .string = type_str };
            row[2] = .{ .string = try alloc.dupe(u8, if (col.nullable == .nullable) "YES" else "NO") };
            row[3] = .{ .string = try alloc.dupe(u8, if (is_pk) "YES" else "NO") };
            rows[i] = row;
            built += 1;
        }
        return sql_mod.ResultSet{ .columns = columns, .rows = rows, .alloc = alloc };
    }

    fn buildShowDatabasesResult(self: *FoldExecutor, alloc: std.mem.Allocator) !sql_mod.ResultSet {
        const columns = try alloc.alloc([]const u8, 2);
        columns[0] = try alloc.dupe(u8, "id");
        columns[1] = try alloc.dupe(u8, "name");

        var rows_list: std.ArrayList([]const ?storage_mod.ColumnValue) = .empty;
        errdefer {
            for (rows_list.items) |r| {
                for (r) |v| if (v) |cv| cv.freeIfOwned(alloc);
                alloc.free(r);
            }
            rows_list.deinit(alloc);
        }

        var it = self.cluster.db_names.iterator();
        while (it.next()) |entry| {
            const db_id = entry.value_ptr.*;
            const row = try alloc.alloc(?storage_mod.ColumnValue, 2);
            row[0] = .{ .int64 = @intCast(db_id) };
            row[1] = .{ .string = try alloc.dupe(u8, entry.key_ptr.*) };
            try rows_list.append(alloc, row);
        }

        return sql_mod.ResultSet{
            .columns = columns,
            .rows = try rows_list.toOwnedSlice(alloc),
            .alloc = alloc,
        };
    }

    fn buildDescribeTransactionResult(self: *FoldExecutor, hash_hex: []const u8, alloc: std.mem.Allocator) !sql_mod.ResultSet {
        var hash: sql_mod.QueryHash = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch return error.TableNotFound;
        const rq = self.registry.lookup(hash) orelse return error.TableNotFound;

        const columns = try alloc.alloc([]const u8, 2);
        columns[0] = try alloc.dupe(u8, "hash");
        columns[1] = try alloc.dupe(u8, "sql");

        const rows = try alloc.alloc([]const ?storage_mod.ColumnValue, 1);
        const row = try alloc.alloc(?storage_mod.ColumnValue, 2);
        row[0] = .{ .string = try alloc.dupe(u8, hash_hex) };
        row[1] = .{ .string = try alloc.dupe(u8, rq.sql_text) };
        rows[0] = row;

        return sql_mod.ResultSet{ .columns = columns, .rows = rows, .alloc = alloc };
    }

    fn buildShowTransactionsResult(self: *FoldExecutor, alloc: std.mem.Allocator) !sql_mod.ResultSet {
        const columns = try alloc.alloc([]const u8, 2);
        columns[0] = try alloc.dupe(u8, "hash");
        columns[1] = try alloc.dupe(u8, "sql");

        var rows_list: std.ArrayList([]const ?storage_mod.ColumnValue) = .empty;
        errdefer {
            for (rows_list.items) |r| {
                for (r) |v| if (v) |cv| cv.freeIfOwned(alloc);
                alloc.free(r);
            }
            rows_list.deinit(alloc);
        }

        var it = self.registry.queries.iterator();
        while (it.next()) |entry| {
            const rq = entry.value_ptr.*;
            var hex_buf: [64]u8 = undefined;
            for (rq.hash, 0..) |b, i| _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{b}) catch {};
            const row = try alloc.alloc(?storage_mod.ColumnValue, 2);
            row[0] = .{ .string = try alloc.dupe(u8, &hex_buf) };
            row[1] = .{ .string = try alloc.dupe(u8, rq.sql_text) };
            try rows_list.append(alloc, row);
        }

        return sql_mod.ResultSet{
            .columns = columns,
            .rows = try rows_list.toOwnedSlice(alloc),
            .alloc = alloc,
        };
    }
};

fn dupeStringSlice(src: []const []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    const dst = try alloc.alloc([]const u8, src.len);
    for (src, 0..) |s, i| dst[i] = try alloc.dupe(u8, s);
    return dst;
}

fn isSqlDdl(sql: []const u8) bool {
    const s = std.mem.trimStart(u8, sql, " \t\r\n");
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t' and s[end] != '(') : (end += 1) {}
    if (end == 0) return false;
    var buf: [6]u8 = undefined;
    const len = @min(end, buf.len);
    for (s[0..len], 0..) |c, i| buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    const tok = buf[0..len];
    return std.mem.eql(u8, tok, "create") or std.mem.eql(u8, tok, "drop") or std.mem.eql(u8, tok, "alter");
}

fn decodeParams(
    params: []const storage_mod.ColumnValue,
    param_types: []const sql_mod.ast.SqlType,
    alloc: std.mem.Allocator,
) ![]const storage_mod.ColumnValue {
    if (param_types.len > 0 and params.len != param_types.len) return error.ParamDecodeError;
    return try alloc.dupe(storage_mod.ColumnValue, params);
}

fn sqlTableToStorage(
    tbl: *const sql_mod.schema.TableSchema,
    alloc: std.mem.Allocator,
) !storage_mod.TableSchema {
    const cols = try alloc.alloc(storage_mod.ColumnSchema, tbl.columns.len);
    for (tbl.columns, cols) |src, *dst| {
        dst.* = .{
            .col_type = sqlTypeToColumnType(src.typ),
            .nullable = src.nullable == .nullable,
        };
    }
    return .{
        .table_id = tbl.id,
        .columns = cols,
    };
}

fn sqlTypeToColumnType(t: sql_mod.ast.SqlType) storage_mod.ColumnType {
    return switch (t) {
        .bool => .bool_t,
        .int8 => .int8,
        .int16 => .int16,
        .int32 => .int32,
        .int64 => .int64,
        .uint8 => .uint8,
        .uint16 => .uint16,
        .uint32 => .uint32,
        .uint64 => .uint64,
        .string => .string,
        .bytes => .bytes,
        .uuid => .bytes,
        .timestamp => .int64,
        .interval_months, .interval_micros => .int64,
        .decimal => .decimal,
        .json, .vector, .array, .struct_type => .bytes,
        .null_type => .bytes,
    };
}

fn sqlTypeStr(t: sql_mod.ast.SqlType, alloc: std.mem.Allocator) ![]u8 {
    return switch (t) {
        .bool => alloc.dupe(u8, "bool"),
        .int8 => alloc.dupe(u8, "int8"),
        .int16 => alloc.dupe(u8, "int16"),
        .int32 => alloc.dupe(u8, "int32"),
        .int64 => alloc.dupe(u8, "int64"),
        .uint8 => alloc.dupe(u8, "uint8"),
        .uint16 => alloc.dupe(u8, "uint16"),
        .uint32 => alloc.dupe(u8, "uint32"),
        .uint64 => alloc.dupe(u8, "uint64"),
        .decimal => |d| std.fmt.allocPrint(alloc, "decimal({d},{d})", .{ d.precision, d.scale }),
        .string => alloc.dupe(u8, "string"),
        .bytes => alloc.dupe(u8, "bytes"),
        .uuid => alloc.dupe(u8, "uuid"),
        .timestamp => alloc.dupe(u8, "timestamp"),
        .interval_months => alloc.dupe(u8, "interval_months"),
        .interval_micros => alloc.dupe(u8, "interval_micros"),
        .json => alloc.dupe(u8, "json"),
        .vector => |dim| std.fmt.allocPrint(alloc, "vector({d})", .{dim}),
        .array => alloc.dupe(u8, "array"),
        .struct_type => alloc.dupe(u8, "struct"),
        .null_type => alloc.dupe(u8, "null"),
    };
}

/// SqlCrossPartitionHandler: planning document and skeleton for bridging the SQL
/// executor into the PartitionSet 4-phase cross-partition protocol.
///
/// ## Current state (as of this writing)
///
/// The SQL execution stack (Gateway → FoldExecutor → SqlExecutor) uses a shared
/// PartitionedStorage with filter_partition per executor. On each committed log entry:
///
///   1. Every FoldExecutor calls SqlExecutor.run(entry) — all N executors replay the
///      full SQL plan against a shared PartitionedStorage.
///   2. Each SqlExecutor filters its own mutations by partition ID after the plan runs
///      (see filter_partition in executor_bridge.zig:355).
///   3. Each partition independently applies its own filtered mutations to storage.
///
/// This is correct for in-process multi-partition deployments where all partitions
/// share memory. It is NOT sufficient for multi-node deployments where partition data
/// lives on separate machines: each node would need to run the full SQL plan but only
/// has access to its own storage partition, making foreign row reads impossible.
///
/// ## The PartitionSet 4-phase protocol (spec §7.3)
///
/// PartitionSet (src/executor/partition_set.zig) implements the correct protocol
/// for cross-partition atomicity:
///
///   Phase A (declareReads): Each partition announces which foreign rows it needs at
///     seq-1. This lets the coordinator know exactly what data to fetch before any
///     partition starts executing — no round-trips during execution.
///
///   Phase B (fetch): The PartitionSet coordinator fetches each declared row from its
///     source partition's storage at seq-1. All fetches complete before Phase C begins.
///
///   Phase C (execute): Each partition runs its local slice of the transaction using
///     its own storage PLUS the pre-fetched foreign rows. No cross-partition storage
///     access occurs during execution — only the pre-fetched foreign_rows slice.
///
///   Phase D (apply): All partitions' mutations are applied atomically (all-or-nothing).
///     No partition applies until ALL Phase C executes succeed.
///
/// The handler interface is CrossPartitionQueryHandler in src/executor/registry.zig:
///
///   declareReads(ctx, local_partition, out) — populate `out` with ForeignReadRequests
///   execute(ctx, local_partition, storage, foreign_rows, mutations) — produce mutations
///
/// ## What SqlCrossPartitionHandler would need to do
///
/// To bridge the SQL executor into this protocol, we need a handler that wraps a
/// SQL query hash and drives it through the 4-phase interface. The key challenges:
///
/// ### Phase A — declareReads
///
/// The SQL planner's reconnaissance scan (src/gateway/recon.zig) determines which
/// partition IDs a plan will read and write — but it does so at the gateway level
/// during TxnIntent construction, not per-partition at execution time.
///
/// For the 4-phase protocol, each partition's declareReads must declare only the
/// foreign rows IT needs from OTHER partitions. The reconnaissance scan doesn't
/// currently produce this granularity: it produces a set of partition IDs, not
/// (partition_id, table_id, key) triples.
///
/// To implement declareReads correctly, one of:
///
///   Option A1 — Static key extraction: For queries with known PK lookups (e.g.,
///     "UPDATE accounts SET balance = balance - $1 WHERE id = $2"), the planner
///     could statically extract the PK key expression and, given the param bindings,
///     determine exactly which (partition, table, key) a given partition-local execution
///     needs from a remote partition. This is feasible for simple point-lookup plans
///     but requires the planner to emit per-partition read declarations.
///
///   Option A2 — Reconnaissance per partition: Run the reconnaissance scan
///     (reconnaissanceScan in recon.zig) with the local partition ID as a filter, so
///     it only returns foreign (partition, table, key) pairs that this partition needs.
///     Currently reconnaissanceScan doesn't distinguish "foreign" from "local" reads.
///     It would need to be extended to produce ForeignReadRequest items.
///
///   Option A3 — Conservative over-declaration: Always declare ALL rows of ALL tables
///     touched by the plan as foreign reads, then filter in Phase C. This is always
///     correct but generates O(table_rows) network traffic per transaction on multi-node.
///     Acceptable for small tables, impractical for large ones.
///
/// The fundamental gap: the SQL planner currently has no concept of "which keys does
/// partition P need from partition Q". Adding this requires either:
///   - A new plan IR node that carries per-partition read declarations, or
///   - A separate "split plan" compilation pass that, given a local partition ID,
///     emits ForeignReadRequests for all cross-partition key accesses in the plan.
///
/// ### Phase B — fetch
///
/// Already implemented in PartitionSet.run_cross_partition_fetch. No changes needed
/// here — this phase is handled entirely by the coordinator.
///
/// ### Phase C — execute
///
/// The SqlExecutor.executePlan currently runs the full plan and filters mutations
/// by partition at the end (filter_partition). For the 4-phase protocol, Phase C must:
///
///   1. Run only this partition's "slice" of the plan — the mutations that belong to
///      this partition_id. The filter_partition mechanism already achieves this.
///   2. Supply foreign rows as a pre-fetched read set, NOT via live storage lookups.
///      Currently, SqlExecutor reads all data directly from PartitionedStorage. For
///      multi-node, foreign partition data must come from the pre-fetched foreign_rows
///      slice instead.
///
/// This requires a new entry point on SqlExecutor (or a wrapper): something like
///   executePlanSlice(plan, params, nondet, read_seq, write_seq, foreign_rows, partition_id)
/// where storage lookups for foreign keys are intercepted and redirected to foreign_rows.
///
/// Implementing this interception requires threading the foreign_rows through the
/// EvalCtx (executor_bridge.zig) so that scan/pk_lookup nodes check foreign_rows
/// before hitting storage. This is a significant change to the SQL execution core.
///
/// ### Phase D — apply
///
/// Already implemented in PartitionSet.run_cross_partition_apply. No changes needed
/// here — this phase is handled entirely by the coordinator.
///
/// ## What remains for true multi-node operation
///
/// Beyond the handler interface, operating across nodes requires:
///
///   1. Network transport: Phase B fetch currently calls
///      self.executors[source_index].storage.get(...) — a direct memory call. For
///      remote partitions, this must be replaced by an RPC (e.g., gRPC or a custom
///      binary protocol) that asks the remote node to read the row at seq-1.
///
///   2. Partition routing: The coordinator needs to know which node owns which
///      partition ID. A routing table (partition_id → node address) must be maintained,
///      probably in the Gateway or a separate topology service.
///
///   3. Two-phase commit or Paxos over the apply step: Phase D currently commits
///      all partitions in-process (no failure between partitions is possible). Across
///      nodes, Phase D needs a distributed commit protocol so that a node crash between
///      apply steps is detected and rolled back on recovery.
///
///   4. SQL plan split API: SqlExecutor needs a way to execute only the mutations for
///      one partition given a pre-fetched foreign row set. This is the largest single
///      change required in the SQL execution core.
///
/// ## Skeleton implementation
///
/// Below is a skeleton of what SqlCrossPartitionHandler would look like once the above
/// infrastructure is in place. Fields and functions are commented with what they need.
///
/// NOTE: This is NOT a working implementation — it is a design sketch. The functions
/// return error.NotImplemented so the file compiles but does not regress test coverage.
/// Real implementation would replace the stubs with the mechanisms described above.

const std = @import("std");
const executor_mod = @import("executor.zig");

const QueryContext = executor_mod.QueryContext;
const ForeignReadRequest = executor_mod.ForeignReadRequest;
const ForeignRow = executor_mod.ForeignRow;
const Storage = executor_mod.Storage;
const Mutation = executor_mod.Mutation;
const PartitionId = executor_mod.PartitionId;

/// Adapter that wraps a SQL query plan for use as a CrossPartitionQueryHandler.
///
/// When a cross-partition transaction arrives through the PartitionSet, instead of
/// each FoldExecutor independently filtering mutations, the SqlCrossPartitionHandler
/// drives the 4-phase protocol: declare which foreign rows are needed (Phase A),
/// receive them pre-fetched (Phase B, handled by PartitionSet), execute the SQL plan
/// slice for one partition given the foreign row set (Phase C), and return the
/// partition-local mutations for atomic application (Phase D, handled by PartitionSet).
///
/// ## Current limitation
///
/// The SQL planner does not yet emit per-partition read declarations, and SqlExecutor
/// does not yet have a "execute with foreign rows" entry point. Until both are added,
/// this handler cannot be fully implemented. See the module-level comment for the
/// full design gap analysis.
pub const SqlCrossPartitionHandler = struct {
    /// The SQL query hash registered in SqlRegistry. Used to look up the compiled plan.
    /// FUTURE: replace with a direct pointer to a compiled ExecutionPlan to avoid the
    /// registry lookup on every declareReads/execute call.
    query_hash: [32]u8,

    /// Number of storage partitions. Needed to hash keys to partition IDs.
    partition_count: u32,

    /// Build the CrossPartitionQueryHandler function-pointer pair for registration
    /// with PartitionSet.register_cross_all.
    ///
    /// Usage (once implemented):
    ///   const h = SqlCrossPartitionHandler{ .query_hash = hash, .partition_count = n };
    ///   try partition_set.register_cross_all(hash, h.asHandler());
    pub fn asHandler(self: *const SqlCrossPartitionHandler) executor_mod.CrossPartitionQueryHandler {
        _ = self;
        return .{
            .declareReads = declareReadsStub,
            .execute = executeStub,
        };
    }

    /// Phase A stub: declare which foreign rows this partition needs at seq-1.
    ///
    /// FUTURE implementation outline:
    ///   1. Look up the compiled ExecutionPlan for query_hash.
    ///   2. Walk the plan's DML nodes to find all PK key accesses.
    ///   3. For each key expression that can be statically evaluated with ctx.params:
    ///        a. Encode the key using sql/key_encode.
    ///        b. Hash it to a partition ID via Wyhash(key) % partition_count.
    ///        c. If that partition ID != local_partition, emit a ForeignReadRequest.
    ///   4. For key expressions that cannot be statically evaluated (e.g., subquery
    ///      results), fall back to Option A3: declare all rows of the target table
    ///      as foreign reads (conservative over-declaration).
    ///
    ///   The reconnaissance scan in recon.zig already walks the plan and hashes keys
    ///   to partition IDs — it needs to be extended to emit ForeignReadRequests for
    ///   cross-partition accesses rather than just collecting partition ID sets.
    fn declareReadsStub(
        ctx: QueryContext,
        local_partition: PartitionId,
        out: *std.ArrayList(ForeignReadRequest),
    ) anyerror!void {
        _ = ctx;
        _ = local_partition;
        _ = out;
        return error.NotImplemented;
    }

    /// Phase C stub: execute this partition's slice of the SQL plan.
    ///
    /// FUTURE implementation outline:
    ///   1. Look up the compiled ExecutionPlan for query_hash.
    ///   2. Decode ctx.params using the registered param_types.
    ///   3. Call a new SqlExecutor entry point — something like:
    ///        sql_exec.executePlanSlice(plan, params, nondet, read_seq, local_partition,
    ///                                  foreign_rows, mutations)
    ///      where:
    ///        - read_seq = ctx.seq - 1 (MVCC snapshot before this txn)
    ///        - local_partition filters which mutations to retain (same as filter_partition)
    ///        - foreign_rows is threaded into EvalCtx so pk_lookup/scan nodes check it
    ///          before hitting storage for keys that hash to remote partitions
    ///   4. Return mutations (only those belonging to local_partition).
    ///
    ///   The key implementation work: extend EvalCtx in executor_bridge.zig with a
    ///   foreign_rows field, and teach executeGet/executeScan to check foreign_rows
    ///   first when the key maps to a remote partition.
    fn executeStub(
        ctx: QueryContext,
        local_partition: PartitionId,
        storage: *Storage,
        foreign: []const ForeignRow,
        mutations: *std.ArrayList(Mutation),
    ) anyerror!void {
        _ = ctx;
        _ = local_partition;
        _ = storage;
        _ = foreign;
        _ = mutations;
        return error.NotImplemented;
    }
};

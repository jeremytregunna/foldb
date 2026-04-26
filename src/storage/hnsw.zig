/// HNSW (Hierarchical Navigable Small World) in-memory vector index.
/// Spec §11.1: M=16, ef_construction=200, ef_search=64, cosine distance default.
/// Deletes are soft-tombstoned; graph is rebuilt from base table on recovery.
const std = @import("std");
const types = @import("types.zig");

const Seq = types.Seq;
const TableId = types.TableId;

pub const Match = struct {
    pk: []const u8,
    distance: f32,
};

const Candidate = struct {
    id: u32,
    dist: f32,
};

const Node = struct {
    pk: []const u8,
    vec: []f32,
    seq: Seq,
    deleted: bool,
    // neighbors[l] = neighbor node IDs at layer l. Layer 0 = base layer.
    layers: []std.ArrayListUnmanaged(u32),

    fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        alloc.free(self.pk);
        alloc.free(self.vec);
        for (self.layers) |*l| l.deinit(alloc);
        alloc.free(self.layers);
    }
};

pub const HnswIndex = struct {
    dim: u32,
    M: u32,
    ef_construction: u32,
    nodes: std.ArrayListUnmanaged(Node),
    entry_point: ?u32,
    max_level: u32,
    table_id: TableId,
    column_idx: u32,
    alloc: std.mem.Allocator,

    pub fn init(dim: u32, table_id: TableId, column_idx: u32, alloc: std.mem.Allocator) HnswIndex {
        return .{
            .dim = dim,
            .M = 16,
            .ef_construction = 200,
            .nodes = .empty,
            .entry_point = null,
            .max_level = 0,
            .table_id = table_id,
            .column_idx = column_idx,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *HnswIndex) void {
        for (self.nodes.items) |*node| node.deinit(self.alloc);
        self.nodes.deinit(self.alloc);
    }

    /// Insert a vector associated with primary key pk at the given seq.
    /// Caller must ensure vec.len == self.dim (validated at the storage boundary).
    pub fn insert(self: *HnswIndex, vec: []const f32, pk: []const u8, seq: Seq) !void {
        std.debug.assert(vec.len == self.dim);

        const node_id: u32 = @intCast(self.nodes.items.len);
        const ml: f64 = 1.0 / @log(@as(f64, @floatFromInt(self.M)));
        const level = selectLevel(pk, ml);

        const pk_copy = try self.alloc.dupe(u8, pk);
        errdefer self.alloc.free(pk_copy);
        const vec_copy = try self.alloc.dupe(f32, vec);
        errdefer self.alloc.free(vec_copy);
        const layers = try self.alloc.alloc(std.ArrayListUnmanaged(u32), level + 1);
        errdefer self.alloc.free(layers);
        for (layers) |*l| l.* = .empty;

        try self.nodes.append(self.alloc, Node{
            .pk = pk_copy,
            .vec = vec_copy,
            .seq = seq,
            .deleted = false,
            .layers = layers,
        });

        if (self.entry_point == null) {
            self.entry_point = node_id;
            self.max_level = level;
            return;
        }

        var curr_ep = self.entry_point.?;
        const curr_max = self.max_level;

        // Greedy descent from curr_max down to level+1
        if (curr_max > level) {
            var l: u32 = curr_max;
            while (l > level) : (l -= 1) {
                curr_ep = self.greedySearch(vec, curr_ep, l);
            }
        }

        // Beam search and connect from min(level, curr_max) down to 0
        const connect_from = @min(level, curr_max);
        var l: u32 = connect_from + 1;
        while (l > 0) {
            l -= 1;
            const M_eff: u32 = if (l == 0) self.M * 2 else self.M;
            const candidates = try self.beamSearch(vec, curr_ep, self.ef_construction, l);
            defer self.alloc.free(candidates);

            const num = @min(M_eff, @as(u32, @intCast(candidates.len)));
            for (candidates[0..num]) |c| {
                // Only add layers if the existing node participates at this level
                if (l < self.nodes.items[c.id].layers.len) {
                    try self.nodes.items[node_id].layers[l].append(self.alloc, c.id);
                    try self.nodes.items[c.id].layers[l].append(self.alloc, node_id);
                    try self.pruneNeighbors(c.id, l, M_eff);
                }
            }
            if (candidates.len > 0) curr_ep = candidates[0].id;
        }

        if (level > curr_max) {
            self.entry_point = node_id;
            self.max_level = level;
        }
    }

    /// Mark a node deleted by pk. Returns true if found.
    pub fn markDeleted(self: *HnswIndex, pk: []const u8) bool {
        for (self.nodes.items) |*node| {
            if (std.mem.eql(u8, node.pk, pk)) {
                node.deleted = true;
                return true;
            }
        }
        return false;
    }

    /// Rebuild the graph, removing tombstoned nodes and remapping neighbor indices.
    pub fn pruneDeleted(self: *HnswIndex) !void {
        var has_deleted = false;
        for (self.nodes.items) |node| {
            if (node.deleted) {
                has_deleted = true;
                break;
            }
        }
        if (!has_deleted) return;

        const old_to_new = try self.alloc.alloc(u32, self.nodes.items.len);
        defer self.alloc.free(old_to_new);
        const DELETED: u32 = std.math.maxInt(u32);
        var next_id: u32 = 0;
        for (self.nodes.items, 0..) |node, i| {
            old_to_new[i] = if (node.deleted) DELETED else blk: {
                const id = next_id;
                next_id += 1;
                break :blk id;
            };
        }

        var new_nodes: std.ArrayListUnmanaged(Node) = .empty;
        errdefer {
            for (new_nodes.items) |*n| n.deinit(self.alloc);
            new_nodes.deinit(self.alloc);
        }

        for (self.nodes.items) |*node| {
            if (node.deleted) {
                node.deinit(self.alloc);
                continue;
            }
            for (node.layers) |*layer| {
                var out: usize = 0;
                for (layer.items) |nb| {
                    const new_nb = old_to_new[nb];
                    if (new_nb != DELETED) {
                        layer.items[out] = new_nb;
                        out += 1;
                    }
                }
                layer.shrinkRetainingCapacity(out);
            }
            try new_nodes.append(self.alloc, node.*);
        }

        self.nodes.deinit(self.alloc);
        self.nodes = new_nodes;

        if (self.entry_point) |ep| {
            const new_ep = if (ep < old_to_new.len) old_to_new[ep] else DELETED;
            self.entry_point = if (new_ep == DELETED)
                (if (self.nodes.items.len > 0) @as(u32, 0) else null)
            else
                new_ep;
        }
    }

    /// ANN search: return up to k nearest non-deleted nodes visible at at_seq.
    pub fn search(self: *HnswIndex, query: []const f32, k: u32, ef: u32, at_seq: Seq, alloc: std.mem.Allocator) ![]Match {
        if (self.nodes.items.len == 0) return alloc.alloc(Match, 0);

        var curr_ep = self.entry_point.?;
        const curr_max = self.max_level;

        // Greedy descent from top level to level 1
        if (curr_max > 0) {
            var l: u32 = curr_max;
            while (l > 0) : (l -= 1) {
                curr_ep = self.greedySearch(query, curr_ep, l);
            }
        }

        // Beam search at level 0
        const ef_use = @max(k, ef);
        const candidates = try self.beamSearch(query, curr_ep, ef_use, 0);
        defer self.alloc.free(candidates);

        // Collect up to k non-deleted results
        var results: std.ArrayListUnmanaged(Match) = .empty;
        errdefer {
            for (results.items) |m| alloc.free(m.pk);
            results.deinit(alloc);
        }

        for (candidates) |c| {
            if (results.items.len >= k) break;
            const node = &self.nodes.items[c.id];
            if (node.deleted) continue;
            if (node.seq > at_seq) continue;
            try results.append(alloc, Match{
                .pk = try alloc.dupe(u8, node.pk),
                .distance = c.dist,
            });
        }

        return results.toOwnedSlice(alloc);
    }

    /// Greedy 1-nearest search at a given layer (used for descent).
    fn greedySearch(self: *HnswIndex, query: []const f32, entry: u32, level: u32) u32 {
        var best = entry;
        var best_dist = cosineDistance(query, self.nodes.items[entry].vec);
        var changed = true;

        while (changed) {
            changed = false;
            if (level >= self.nodes.items[best].layers.len) break;
            for (self.nodes.items[best].layers[level].items) |nid| {
                const d = cosineDistance(query, self.nodes.items[nid].vec);
                if (d < best_dist) {
                    best_dist = d;
                    best = nid;
                    changed = true;
                }
            }
        }
        return best;
    }

    /// Beam search returning candidates sorted ASC by distance.
    fn beamSearch(self: *HnswIndex, query: []const f32, entry: u32, ef: u32, level: u32) ![]Candidate {
        var visited = std.AutoHashMap(u32, void).init(self.alloc);
        defer visited.deinit();

        // Sorted ASC by dist: front=closest (candidates to explore)
        var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
        defer candidates.deinit(self.alloc);

        // Sorted ASC by dist: front=closest, back=worst (result set, bounded to ef)
        var result: std.ArrayListUnmanaged(Candidate) = .empty;
        defer result.deinit(self.alloc);

        const entry_dist = cosineDistance(query, self.nodes.items[entry].vec);
        try visited.put(entry, {});
        try insertSorted(&candidates, .{ .id = entry, .dist = entry_dist }, self.alloc);
        try insertSorted(&result, .{ .id = entry, .dist = entry_dist }, self.alloc);

        while (candidates.items.len > 0) {
            const c = candidates.orderedRemove(0);
            const worst_dist: f32 = if (result.items.len > 0)
                result.items[result.items.len - 1].dist
            else
                std.math.floatMax(f32);

            if (c.dist > worst_dist and result.items.len >= ef) break;

            if (level >= self.nodes.items[c.id].layers.len) continue;
            for (self.nodes.items[c.id].layers[level].items) |nid| {
                if (visited.contains(nid)) continue;
                try visited.put(nid, {});

                const n_dist = cosineDistance(query, self.nodes.items[nid].vec);
                const cur_worst = if (result.items.len > 0)
                    result.items[result.items.len - 1].dist
                else
                    std.math.floatMax(f32);

                if (n_dist < cur_worst or result.items.len < ef) {
                    try insertSorted(&candidates, .{ .id = nid, .dist = n_dist }, self.alloc);
                    try insertSorted(&result, .{ .id = nid, .dist = n_dist }, self.alloc);
                    if (result.items.len > ef) {
                        _ = result.pop();
                    }
                }
            }
        }

        return result.toOwnedSlice(self.alloc);
    }

    /// Prune node's neighbor list at level to at most M neighbors (keep closest).
    fn pruneNeighbors(self: *HnswIndex, node_id: u32, level: u32, M: u32) !void {
        if (level >= self.nodes.items[node_id].layers.len) return;
        const neighbors = &self.nodes.items[node_id].layers[level];
        if (neighbors.items.len <= M) return;

        const center = self.nodes.items[node_id].vec;
        var sorted = try self.alloc.alloc(Candidate, neighbors.items.len);
        defer self.alloc.free(sorted);

        for (neighbors.items, 0..) |nid, i| {
            sorted[i] = .{ .id = nid, .dist = cosineDistance(center, self.nodes.items[nid].vec) };
        }
        std.sort.block(Candidate, sorted, {}, candidateLessThan);

        neighbors.shrinkRetainingCapacity(0);
        for (sorted[0..@min(M, sorted.len)]) |c| {
            try neighbors.append(self.alloc, c.id);
        }
    }
};

/// Deterministic level assignment using FNV-1a hash of pk.
fn selectLevel(pk: []const u8, ml: f64) u32 {
    var h: u64 = 14695981039346656037;
    for (pk) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    const uniform: f64 = @as(f64, @floatFromInt(h & 0xFFFFFF)) / 16777216.0;
    if (uniform <= 0.0) return 0;
    const level_f: f64 = -@log(uniform + 1e-10) * ml;
    const capped: u32 = 16;
    return @min(@as(u32, @intFromFloat(@floor(level_f))), capped);
}

fn cosineDistance(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0;
    var norm_a: f32 = 0;
    var norm_b: f32 = 0;
    for (a, b) |ai, bi| {
        dot += ai * bi;
        norm_a += ai * ai;
        norm_b += bi * bi;
    }
    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (denom < 1e-10) return 1.0;
    const sim = dot / denom;
    // Clamp to [0, 2] (cosine distance = 1 - similarity, range [0, 2])
    return 1.0 - @max(-1.0, @min(1.0, sim));
}

/// Insert into a sorted-ASC candidates list using binary search.
fn insertSorted(list: *std.ArrayListUnmanaged(Candidate), item: Candidate, alloc: std.mem.Allocator) !void {
    var lo: usize = 0;
    var hi: usize = list.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (list.items[mid].dist < item.dist) lo = mid + 1 else hi = mid;
    }
    try list.insert(alloc, lo, item);
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    return a.dist < b.dist;
}

pub const HnswError = error{OutOfMemory};

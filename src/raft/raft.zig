/// Foldb Raft module — single-partition replicated log.
const types = @import("types.zig");
const rpc_mod = @import("rpc.zig");
const node_mod = @import("node.zig");
const transport_mod = @import("transport.zig");
const cluster_mod = @import("cluster.zig");
const persistent_mod = @import("persistent_state.zig");
const watermark_mod = @import("watermark.zig");

pub const Term = types.Term;
pub const RaftRole = types.RaftRole;

pub const NodeId = rpc_mod.NodeId;
pub const AppendEntriesArgs = rpc_mod.AppendEntriesArgs;
pub const AppendEntriesResult = rpc_mod.AppendEntriesResult;
pub const RequestVoteArgs = rpc_mod.RequestVoteArgs;
pub const RequestVoteResult = rpc_mod.RequestVoteResult;
pub const Message = rpc_mod.Message;
pub const MessageKind = rpc_mod.MessageKind;

pub const RaftNode = node_mod.RaftNode;
pub const Output = node_mod.Output;
pub const Config = node_mod.Config;
pub const ConfigChangeOp = node_mod.ConfigChangeOp;
pub const ConfigChange = node_mod.ConfigChange;

pub const InProcessBus = transport_mod.InProcessBus;
pub const TcpTransport = transport_mod.TcpTransport;
pub const Envelope = transport_mod.Envelope;

pub const SimCluster = cluster_mod.SimCluster;
pub const DynSimCluster = cluster_mod.DynSimCluster;
pub const ClusterError = cluster_mod.ClusterError;
pub const NetworkSim = cluster_mod.NetworkSim;
pub const NetworkConfig = cluster_mod.NetworkConfig;

pub const PersistentState = persistent_mod.PersistentState;
pub const loadPersistentState = persistent_mod.load;
pub const savePersistentState = persistent_mod.save;

pub const Watermark = watermark_mod.Watermark;
pub const loadWatermark = watermark_mod.load;
pub const saveWatermark = watermark_mod.save;

// Serialization helpers (re-exported for tests and TCP transport)
pub const encodeMessage = rpc_mod.encodeMessage;
pub const decodeMessage = rpc_mod.decodeMessage;
pub const serializeRequestVoteArgs = rpc_mod.serializeRequestVoteArgs;
pub const deserializeRequestVoteArgs = rpc_mod.deserializeRequestVoteArgs;
pub const serializeRequestVoteResult = rpc_mod.serializeRequestVoteResult;
pub const deserializeRequestVoteResult = rpc_mod.deserializeRequestVoteResult;
pub const serializeAppendEntriesResult = rpc_mod.serializeAppendEntriesResult;
pub const deserializeAppendEntriesResult = rpc_mod.deserializeAppendEntriesResult;
pub const serializeAppendEntriesHeader = rpc_mod.serializeAppendEntriesHeader;
pub const deserializeAppendEntriesHeader = rpc_mod.deserializeAppendEntriesHeader;

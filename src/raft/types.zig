/// Core Raft types.
pub const Term = u64;

pub const RaftRole = enum {
    follower,
    candidate,
    leader,
};

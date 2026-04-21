# FoldDB — Work Tracker

Spec: `foldb-spec.md` | Plan: `PLAN.md`

## Current Focus

**Next up:** Prompt 12 — HNSW ANN queries wired into SQL executor

---

## Milestone Status

| # | Milestone | Spec | Status |
|---|-----------|------|--------|
| M1 | Log (single node) | §5 | ✅ Done |
| M2 | Log (replicated) | §5.4 | 🟡 Raft SM + TcpTransport done; 3-node cluster tested; no dynamic reconfig |
| M3 | Storage | §6 | ✅ Done |
| M4 | Fold Executor | §7 | ✅ Done |
| M5 | SQL front-end | §10 | ✅ Done (CTEs skip type-check) |
| M6 | Gateway | §9 | ✅ Done |
| M7 | Sequencer + multi-partition log | §8 | 🟡 Multi-node Raft works; dynamic reconfig not implemented |
| M8 | Multi-partition execution | §7.3 | 🟡 Dataflow exists; not network-tested |
| M9 | Tiered storage | §6.7, §13 | ✅ Done (S3 wired; snapshot scheduling + log truncation implemented) |
| M10 | CDC | §12 | ✅ Done (manager + before-images; delivery hardened) |
| M11 | Specialty indexes | §11 | 🟡 HNSW + JSON done; ANN queries not wired |
| M12 | Operations | §13 | 🔴 No config, no auth, no reconfig API |

---

## Prompt Checklist

- [x] **Prompt 1** — Config struct + JSON parser (`src/config/config.zig`)
- [x] **Prompt 2** — Wire Config into Gateway and `main.zig`
- [x] **Prompt 3** — Sequencer: peer addresses + ms-based tick config
- [x] **Prompt 4** — Raft TcpTransport: send side
- [x] **Prompt 5** — Raft TcpTransport: receive side
- [x] **Prompt 5b** — TcpTransport DST: fault injection seed sweep
- [x] **Prompt 6** — Sequencer: wire TcpTransport + tick loop + 3-node test
- [ ] **Prompt 7** — Auth enforcement
- [x] **Prompt 8** — Wire S3ObjectStore into Gateway
- [x] **Prompt 9** — Snapshot scheduling + snapshot_marker log entry
- [x] **Prompt 10** — Log truncation after durable snapshot
- [x] **Prompt 11** — CDC subscription hardening (next/ack/gap-free)
- [ ] **Prompt 12** — HNSW ANN queries wired into SQL executor
- [ ] **Prompt 13** — Full DST suite (10k seeds, kill-9, snapshot round-trip)
- [ ] **Prompt 14** — Reconfiguration API (add/remove node)

---

## Deferred (Post-v1 / [OPEN] in spec)

- WASM module execution (§10.6)
- TLS (§16, marked [OPEN])
- Full-text search (§11.3, marked [OPEN])
- Resharding (§13.3, marked [OPEN])
- CTE type-checking (parse/plan works; type-check skipped)
- PAX per-column codecs (block layout exists; dictionary/RLE/FoR not applied)

---

## Known Issues

- `src/net/conn.zig`: auth accepts all credentials unconditionally → fixed in Prompt 7
- `src/sequencer/sequencer.zig`: 0 peers, Output.send dropped → fixed in Prompts 3–6
- `src/main.zig`: only `--storage-dir` and `--port`; all else hardcoded → fixed in Prompts 1–2
- `src/sql/type_checker.zig:592`: CTE type-check skipped → deferred

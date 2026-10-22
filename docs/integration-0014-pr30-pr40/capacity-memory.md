# Capacity and memory budget

The candidate is **POOL5218304 / PARALLEL4 / CONTEXT1048576 / KV_SHARD1 / ROUND_ROWS16**, not8 streams. `scripts/port.sh`'s automatic pool only guarantees **one** whole window per owner; it does not multiply by PARALLEL. The explicit pool is required. The pinned kit only accepts16 decode rows;32/48 are not supported recipe settings even though the geometry formula can be evaluated for them.

`lanes.zig` reserves `alignForward(prompt_tokens + max_new_tokens + round_rows + 2, 2048)`. For input+allowed-output1048576 this is1050624. `shard.plan` cuts the pool into equal owner parts, refuses non4096-aligned pools and a part too small for one full window. An extent cannot cross an owner boundary.

| Pool | Per owner | Two full-window extents/owner | Remaining/owner |
|---:|---:|---|---:|
|1048576|524288|Startup refused: PartTooSmall|—|
|4194304|2097152|No: short4096/owner|—|
|4202496|2101248|Exact fresh-layout minimum|0|
|5218304|2609152|Yes in an unfragmented layout|507904|

The target's total spare1015808 positions is placement/cache/fragmentation headroom. It does **not** guarantee admission under arbitrary fragmentation, pending restores, holds, shared-prefix pins or transfers. Each owner must actually show two live streams **simultaneously decoding**; four HTTP completions after queueing do not prove this.

The actual pure `parts.Planner` tests in `tests/integration-pr30-pr40/capacity_tests.zig` exercise all rows above. Opportunistic twins are allowed only when complete free extents fit in every other part; `planTwins` simply returns if they do not, never requiring a second permanent full-window budget. Nonpinned twins can be revoked; `planDecode` releases them before first decode. `growth_rows=32768` is a soft kept-state slack, not an irrevocable reservation per live stream. Carry/move choices also require destination headroom of2048*(destination live+1) in the relevant path. Restores/holds, fanout and fragmentation remain explicit runtime cases.

## What memory does and does not scale

`shard.zig` and `prompt.Caches.initParts` give a first-order **pool-plane** budget for this checkpoint (ratios2,2,2,1; compressed row codes+scales, replicated index planes):

- Replicated:890 bytes/global token/rank.
- TP2 sharded:530 bytes/global token/rank (360 owner-compressed +170 replicated index). Pool5218304:2765701120 bytes, about2.576GiB/rank.
- Stable0014's1048576 replicated pool:933232640 bytes, about0.869GiB/rank. The target's plane-only increase is about1.707GiB/rank, **not** a total resident-memory prediction.
- Sharded compressed planes also have fixed pad/trash rows; raw compressor stores scale with streams (`slots *64*head_dim*4` for both raw_kv and raw_score per compressed layer). Window rings, stream state, draft/round workspaces, index buffers, fetch/union buffers and graph capture are additional. `Round.init` has pool-dependent key/score/tile buffers; `Chunk.useShard` adds a65536-row fetch buffer and position-index arrays. These are not included in890/530.
- RoPE rows remain `window + round_rows +1`, not the entire5.218M pool. Weights/Engram/vision weights are unchanged; CPU request JSON/messages/templates/token IDs, image payloads and pending jobs remain dynamic.
- When spill is later enabled, default staging is128MiB **per rank**, additional to GPU/CPU caches; current first-phase overlay keeps spill off. On disk,64GiB cap/rank plus50GiB free-space floor is the documented later-phase starting point, subject to actual local disk checks. No disk availability was checked on the serving nodes in this preparation.
- CUDA parked-page budgeting changes what the arena considers available; it does not disable official host protection or make nominal memory free. Prepare gate3GiB queues concurrent preparations, first prepare always proceeds; it is not a hard memory cap. Memguard remains2.5GiB sustained4s / hard1GiB, unchanged.

Tonight must measure actual post-load reserve, CUDA/arena growth, graph capture, per-rank RSS/PSS/anonymous/file memory, swap, prefill reservations and natural idle reclamation before escalating. There is no offline proof that the full configuration fits the physical machines through all four long requests.

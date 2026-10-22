# 0014 + PR30/PR40: isolated candidate, not deployed

This branch starts at `14d87694fe62982889e634363bccc704f94f13b6`, the public source counterpart of the deployed **0012+0014** repair. It includes no local0013 toolmerge/namespace experiment. Upstream patch numbers0013/0014 in PR30 refer to spill/cache features, not those local patch numbers.

Frozen upstream recipe base: `370daf0cc38f348516a98ebab38f6053858eab1f`.
PR30 head: `e7dd2e32bfd7d77be305731007ed76a8b43186f5`.
PR40 head: `bd3f7fc9da1086b232c99977e5ba276e9ed1b4f7`.
Engine: `629c524a0ea57512a5342abb498d1b7c25353343`; input tools `59402086381a42c74d53053443224eec2790b4c5`; kernel kit `abe07c7d509a0199cc7fec15263be2aa52ac652f`; Zig0.17.0. These are pins, not floating branch tips.

## Mapping and conflict decisions

| Source | Active integration | Decision |
|---|---|---|
| PR30 base/main prerequisites0008 pool/window,0010 RDMA idle, pin/round checks | Preserved from requested PR base | Required by exported feature stack; systemd template is files only, never installed/enabled |
| PR30 patches0011–0022 | Original feature patches, strict filename order | CUDA parked-page budget, spill v2/cache tier, shard/fetch/placement, wire/pair failure, picture spill/ring |
| PR30 patch0023 vs PR40 standalone0011 | **0023 only** | All added/removed code lines identical; headers and preimage/context differ. Applying both is a duplicate, not an extra fix |
| Local0011 HfText reclaiming scratch | `0100-local-0014-preservation.patch`, hf_text.zig | Retains caller-owned output/error copies and temporary converted-message/context lifetime. PR40 moves core tokenizer/template scratch to page allocations but does not replace this wrapper |
| Local0012 immutable list-prefix concatenation | Same0100, eval.zig | Accumulator and alias/growth rules ported verbatim; preserves output semantics and prevents quadratic immutable-list copying |
| Local0014 per-image scratch | Same0100, vision.zig | One image's decode/resize allocations released; aligned payload and BadImage text copied to caller owner before scratch deinit |
| Local diagnostic-only0007–0010a | Exact originals in `baseline-patches/` | Were disabled in deployed runtime. Retained for provenance, not applied to the rewritten upstream engine; avoids stale instrumentation conflicts |
| Local0013 and upstream PR28/9/41/43/44 | Not added | Outside this integration |

Git's recipe merge was clean; **that did not mean the engine patch glob was valid**. The old local filenames overlapped the new sequence and depended on diagnostic hunks. They were moved out of the active glob, then the three functional local fixes were rebased after the upstream stack. Original eight local patches are retained byte-for-byte. Baseline series manifests here describe the old series only.

## Target

The explicit candidate overlay is `tests/integration-pr30-pr40/candidate.env.example`:
`POOL=5218304`, `PARALLEL=4`, `CONTEXT=1048576`, `KV_SHARD=1`, `ROUND_ROWS=16`.
No running service, default image, security, network, API/authentication or generation setting is changed by checking out this branch. Spill and automatic pair restarts start **off for evidence-preserving A/B**; their code is present and later validation is separate.

See [capacity and memory](capacity-memory.md), [test results](offline-results.md), and [build, tonight A/B and rollback](tonight-plan.md). CPU/static results are not GPU validation or production stability.

## Follow-up checkpoint

The active series now has22 patches: upstream20, local0014 preservation0100 and test-only planner probe0101. See [failure-followup.md](failure-followup.md) for optimized-mode/test portability corrections, exact weight lock and mandatory Linux/ARM64 gates. This remains an undeployed candidate.

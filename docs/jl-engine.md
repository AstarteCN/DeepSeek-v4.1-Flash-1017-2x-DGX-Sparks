# ENGINE=jl: Jay Leaton's CUDA DeepSeek-V4.1 Zig engine

`ENGINE=jl ./start.sh` serves the same checkpoint (`Mia-AiLab/DeepSeek-V4.1-Flash-1017-EAQ-v1-2.9-bpw`, optionally with
`ABLIT=1`) with a second engine: the CUDA DeepSeek-V4.1 port of
**[Jay Leaton (jayleaton)](https://github.com/jayleaton)**, from his recipe
[jayleaton/deepseek-v41-tensorfold-spark](https://github.com/jayleaton/deepseek-v41-tensorfold-spark) (`engine/zig`, a
TensorFold 1.0.2 source export; Apache-2.0, his `dsv41` family files MIT, Copyright (c) 2026 Jay Leaton). The default
engine (BertholomusAI's fork, `ENGINE=zig`) is unchanged and stays the default; `ENGINE=jl` is a second path in the same
scripts, so you can A/B the two on one pair of Sparks and go back with `ENGINE=zig ./start.sh restart`.

Credits: [`../CREDITS.md`](../CREDITS.md). His own documentation of the engine (every setting, the decode roofline, what
was tried) is in his repository: `docs/ZIG-SERVE.md`, `docs/DECODE.md`, `docs/ZIG-RESULTS.md`.

## Why a second engine

Both engines are Zig, on TensorFold's CUDA lane core, but they are two implementations of the DeepSeek-V4.1 family with
different environment variables (`TF_DS_*` against `TF_DSV41_*`), different kernels and different inputs. The decode and
prefill work of his repository lives in his engine's source, so none of it can be switched on in BertholomusAI's engine
by a setting. His decode notes (`docs/DECODE.md`, windows G13 to G17) list what moved his 1-row window from 35.0 to ~21.8 ms:
the router as a CUDA GEMV, the mHC boundary as one launch, CSA2's decode attention core and indexer top-k in CUDA, dense
EXL3 over a 16-byte-coalesced repack, the round plan through a RoCE host mailbox, the CSA2 indexer and compressor on
priority streams, the L2 prefetch paced beside the exchanges, and slot-agnostic row graphs for multi-stream rounds. Prefill:
4K prompt pieces, a fused dense EXL3 GEMM with a tuning table, replay (CED) with bounded decoder replay, several slots'
pieces in one run, and split KV with a larger pool. His published speeds are on his own 2.8 bpw pack with
expert pruning on; **they are not this recipe's numbers** (see below).

## What is the same, and what is not

Same: the checkpoint and its pinned revision, the Engram source shards (`ENGRAM_ID`), `model/chat_template.jinja` and the served
folder, the worker's NFS volume, the link and RoCE-rail discovery (`scripts/nodes.sh`), the API key, the memory guards,
`./stop.sh` and the container name. `ENGINE=jl` reads the folder `served_in_container` names (the checkpoint linked), the
`ABLIT=1` overlay applies as before (it is a file-level overlay of the EXL3 shards), and the image routing bias comes from the
checkpoint's own 43 `gate.bias_vl` tensors (`TF_DSV41_BIAS_VL` names the served folder; `scripts/jl-prepare.sh` checks they are
there).

Different, and why:

| | `ENGINE=zig` | `ENGINE=jl` |
| --- | --- | --- |
| Engine | BertholomusAI `deepseek-v41-zig` @ `3ff3b2a` + `zig/patches` | his `engine/zig` @ `JL_REF` (`jl/Dockerfile` fetches it) |
| Image | `zig/Dockerfile` on NVIDIA's PyTorch container | `jl/Dockerfile`: CUDA 13.0.1 devel/runtime, cuBLAS 13.6.0.2, as his; an `-assets` image on the PyTorch container |
| Weights | a weight file per rank (`tf-dsv41-rank-cache`) | the engine writes *prepared layer images* on its first start (~95 GB a node, local disk) |
| Engram | the base model's shards, whole, on the worker's disk (rank 0: NFS or `HEAD_ENGRAM_DIR`) | packed per rank (`engram-l{1,14}-r{rank}of2.bin`, ~94 GiB a node, **local disk on both**) by his `scripts/pack_engram.py` |
| Kernels | the kit's captured Triton binaries | Triton programs compiled ahead of time from the reference tree (the *AOT set*), for exactly the shapes this environment launches |
| Settings | `TF_DS_*`, the `CONTEXT` / `PARALLEL` / `ROUND_ROWS` / `GRAPHS` ... settings | `TF_DSV41_*` (`scripts/jl-env.sh`); `GRAPHS`, `SIDE`, `PREFETCH`, `ENGRAM_AIO`, `REPLAY_FLOOR` and `ROUND_ROWS` are ignored |
| RoCE | `TF_RDMA_DEVICES`, `TF_RDMA_GID_INDEX` | `TF_TP_ROCE_HCA` (the devices `scripts/nodes.sh` found; the engine detects the GID index itself) |
| Rank commands | `tensorfold-native serve` / `tf-dsv41-lanes` | `tensorfold-dsv41 serve` / `tf-dsv41-m1 follow` |

## Use it

```bash
ENGINE=jl ./start.sh restart        # the first time: scripts/jl-prepare.sh, then the start
# or put ENGINE=jl in scripts/local.sh or .env
ENGINE=jl DRY_RUN=1 ./start.sh      # both ranks' docker commands, nothing started
ENGINE=jl ./scripts/jl-prepare.sh   # prepare alone (no server is stopped)
```

`scripts/jl-prepare.sh` does, safe to re-run (each step skips what is done):

1. preflight, including the **free disk on both Sparks**: ~96 GiB for Engram's shards and ~100 GiB for the engine's prepared
   weight images a node, plus 15 GiB (`SKIP_DISK_CHECK=1` skips it; `JL_ROOT` and `WORKER_JL_ROOT` move the folders);
2. builds `jl/Dockerfile` (~15 minutes of Zig and nvcc on a Spark) and copies the engine image to the worker;
3. downloads the checkpoint and Engram's source shards as `scripts/prepare.sh` does, makes the served folder and the worker's
   NFS volume;
4. packs Engram's per-rank shards on each node's disk and checks them against the source (`pack_engram.py --check`: header, size and
   sampled rows);
5. makes the assets on the head: `sigs.json`, `rope.bin` (window + 2,048 rows), `engram-host.bin`, and the AOT set (`tf-dsv41-m1
   aot-needs` lists the Triton programs the environment launches, ~11 minutes; `triton_fill.py compile` builds the missing ones on
   CPU, Triton 3.7.1 and ptxas 13.3.73, the first time ~1 hour), checks the set again, and copies the assets to the worker.

The engine's first start then writes the prepared weight images (~95 GB a node) and times its draft windows once
(`TF_DSV41_CALIB=zig`, stored under the state folder); `WAIT_TIMEOUT` is 5400 s for this engine. **Change the window, the slots,
`JL_PF_4K`, `JL_KV_SPLIT`, `JL_EXPERT_TOPP` or a `TF_DSV41_*` value that shapes a Triton program and `start.sh` runs the prepare step
again** (`scripts/jl-env.sh`'s `jl_env_aot_hash` is part of the prepared marker); only the missing programs are compiled.

## Settings

`scripts/config.sh` (layered as the others): `JL_REPO` / `JL_REF` (his repository and the commit built), `JL_PY_REPO` /
`JL_PY_REF` (TensorFold 0.6.0, the Python reference his generators read), `JL_ROOT` / `WORKER_JL_ROOT` (the per-node folders),
`JL_POOL_TOKENS` (2,100,000: the paged KV pool the slots share, split over the two ranks; bigger pools took his flash17 pack under the
engine's 4 GiB memory floor during 4K prefills; this checkpoint is about as large, so it starts there too), `JL_KV_SPLIT` (1),
`JL_PF_4K` (1; the pieces fall back to 2K segments, same bits, when either rank cannot keep 3.5 GiB free),
`JL_EXPERT_TOPP` (empty = exact), `JL_SESSION_DISK_GIB` (32; his profile has 128). `CONTEXT`, `PARALLEL` (the slots), `THINKING`,
`REASONING_EFFORT`, `TEMPERATURE`, `TOP_P`, `TOP_K`, `MAX_TOKENS`, `RDMA`, `HOST`, `PORT`, `SERVED_NAME` and `API_KEY` work as before. `DRAFTS=0`
is refused (his profile was measured, and the AOT set built, with drafts). Any `TF_DSV41_*` or `GLM53_TF_*` variable you export goes
to both ranks and replaces the profile's value of the same name; his `docs/ZIG-SERVE.md` describes each.

Two choices that differ from his published profile, on purpose:

- **Exact by default.** His profile prunes decode's routed experts (`TF_DSV41_EXPERT_TOPP=0.85`). His own measurement calls it lossy (top-1
  0.9944 against the unpruned engine). Here it is off unless `JL_EXPERT_TOPP=0.85`. Speeds in his README include it.
- **NCCL cuMem off** on both ranks (`NCCL_CUMEM_ENABLE=0`, `NCCL_CUMEM_HOST_ENABLE=0`): on a GB10 NCCL's cuMem allocations exhausted the
  driver's pool at boot (`NV_ERR_NO_MEMORY`) and failed later starts. This is BobClawblaw's fix to his `scripts/serve.sh`; set
  `NCCL_CUMEM_ENABLE=1` to turn it back on.

His README also suggests a 2100-2200 MHz GPU clock cap (`nvidia-smi -lgc 300,2100`) for temperature control; the existing note
that both GPUs must share one ceiling applies to this engine too.

## This checkpoint on his engine

His engine was built for his own packs. Mia's EAQ pack differed in two ways, and one setting had to change on this head:

- **Storage.** His engine loads a router bias only as F32 and DSpark's confidence head only as F32 or BF16. The EAQ pack keeps the three
  DSpark blocks' `ffn.gate.bias` and `mtp.2.confidence_head.proj.weight` as F16, so the first boots stopped with `UnexpectedTensor`.
  `scripts/jl-fixup-pack.py` (run by `jl-prepare.sh`) writes copies of the two shards that hold them (38 and 39 of 39) with those four
  tensors widened to F32, an exact conversion, beside the checkpoint (`<HF_CACHE>/tensorfold-dsv41/<rev>/jl-shards`) and links them into the
  served folder. Every other tensor is copied byte for byte (checked on a sample); the checkpoint itself is not touched.
- **KV pool.** His 2,100,000-token pool did not pass the engine's own boot check on this head: with the machine's other software holding
  memory, the worst serving point left 2.42 GiB against the 4 GiB floor, and the engine reported that 504,163 tokens is the most that fits.
  On the pair this was measured on, `scripts/local.sh` sets `JL_POOL_TOKENS=500000`. The pool is shared by the slots, so one request can fill about 500K positions, not the
  524,288-token window. More free memory on the head allows a bigger pool (the boot log says how much).

## Measured here

Booted on the pair on 2026-10-19 (`ENGINE=jl ./start.sh`; the first start built the prepared weight images, 7 minutes; later starts ~3
minutes). `tools/smoke.py`: all checks pass (reply shape, stop strings, streaming usage, a tool call and its result, greedy determinism,
thinking on and off); `17 * 23` gives `391`. `tools/bench.py` (random-word prompts, thinking off, temperature 0, 2 repetitions):

| | ENGINE=jl | ENGINE=zig (README, Status, same tool and prompt style, earlier day) |
| --- | ---: | ---: |
| decode, 1 stream, tok/s | 45 (drafts accepted 0.46) | 55-61 |
| decode, 2 / 4 streams together | 68 / 93 | n/a / 113-117 |
| prefill, 8K / 32K prompt, tok/s | 2,007 / 1,957 | ~1,960 / ~2,000 |

**It is not faster here.** Decode is 15-25 % lower with random-word prompts, which the drafter cannot predict; prefill is about equal. This is
not a matched A/B (different days, the pool is 500K here, nothing else was changed), and real prompts draft better than random words, so
repeat both engines back to back on your own traffic before drawing a conclusion. His published speeds are on his packs with expert pruning on.

## Not verified

- Exactness against the other engine (`tools/exact.py` on both) and quality: not run.
- Vision (an image request), the 4-slot behaviour under long prompts and long-run stability: not run. The boot log warns that long prompts
  fall back to 2,048-row segments on the head (`prefill workspace ... leaves 2.18 GiB, under the 4.0 GiB hard floor`) and that the memory
  floor, 4.44 GiB, is under the 5 GiB target; both follow from the head's other software.
- His `pack_engram.py` ran here for the first time against a full checkpoint (in his history it had not): the shards pass its `--check`
  (header, size, 256 sampled rows) and the engine booted from them.
- Rollback: `ENGINE=zig ./start.sh restart`. The other engine's Engram copy on the worker was deleted on 2026-10-19; `scripts/prepare.sh`
  makes it again (~203 GB over NFS).

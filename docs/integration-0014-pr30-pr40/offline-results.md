# Offline results and remaining gates (Windows host)

No Spark connection or operation, inference, model load, production build, restart or configuration change occurred. These results are candidate preparation, not production acceptance.

| Group | Result | Meaning / limit |
|---|---|---|
|Frozen source|PR30 e7dd2e32… / PR40 bd3f7fc9…|Exact full SHAs in README; the two prepare-memory diffs have identical added/removed lines |
|Clean replay|22/22 active patches applied strictly (follow-up)|Includes upstream20 plus local0100 and test-only0101; no standalone duplicate0011 |
|Tokenizer|11/11 native CPU tests pass|Includes depth-first vs original breadth-first IDs, CJK/added tokens/invalid UTF-8 and owner-arena capacity. For262214 text bytes measured scratch3071134B vs29432292B; not a full-model performance result |
|Shard|22/22 pass|Addressing, bounds, owner/fetch/row packing and plane copy models |
|Pool|3/3 pass|Pool/window/RoPE sizing and invalid inputs |
|Planner Debug|3/3 pass|Unmutated suite, every documented mutant killed, public declarations compile |
|Full-window capacity|8/8 pass|Five new integration cases plus three imported shard cases.4M nominal only two full extents; exact lower bound and requested5.218M admit four,2+2 by owner, twins on/off |
|Prepare gate|13/13 pass|Includes five gate-specific cases plus imported JSON/log cases: first admission, concurrent queue, cancellation, reservation release, absent meminfo and disabled settings |
|Template host adapter|All six selected filters pass|14 immutable-list semantic cases + five render/arena/thinking/tools/error cases (31 Zig test invocations including repeated module-import tests). Only POSIX strftimeNow is refused in a disposable copy; selected tests never invoke it. Not unmodified Linux golden parity |
|Image CPU adapter|Payload/error/lifetime checks pass|Two synthetic PNG payloads/tokens byte-identical, two lanes×two images release to0 live bytes, invalid/oversized images preserve error text, failures at allocations1/3/7 unwind to0. Only Windows clock glue differs from the real function adapter. Not a model/GPU or JPEG/Pillow result |
|Server ARM64|Semantic compilation check passes|`zig test -target aarch64-linux-gnu -fno-emit-bin` with real server/seam/tokenizer/template modules; no execution or full CUDA link |
|Shell syntax|15/15 files pass individually|Git Bash syntax only, no server launch |
|Port-script suite|Follow-up134/134;4 mandatory-Linux skips|Original4 failures depend on Linux /proc or real POSIX symlinks: live parked pages, weight-file symlink refusal, pairwatch symlink-log rotation and spill ownership symlink guard. Do not treat these as security passes; rerun on Linux |
|Python unit discovery|Not passing on Windows|Scripts17 and tools12 test groups include errors/failures due Linux utilities/POSIX paths and Windows selecting WSL bash. Initial sandbox temp failures were separate. Full Linux runs pending; no success claim |
|Synthetic serving-tool selftest|Follow-up93/93 expectations pass|Original64/71 failures are diagnosed and test portability fixed; native-Linux runbook remains mandatory. See failure-followup.md for exact causes, not generic decoding attribution |

## Explicit discrepancies / not run

- Unmodified template tests cannot compile on Windows: upstream `localtime_r` takes std.c.time_t, which is void on this target while gettimeofday supplies c_long. Production source was not modified for this; use full Linux tests.
- The original optimized `counted_at_plan` fault probe is corrected by test-only0101; Debug, ReleaseSafe and ReleaseFast now pass3/3. Non-test release probes preserve counters0 at plan /1 at apply. Binary identity and whole-engine memory safety are not claimed. Native Linux/ARM64 all-mode repetition remains required; details in failure-followup.md.
- The first synthetic image failure probe used allocation1000, which did not trigger. It is explicitly not a passed OOM test; corrected bounded probes1/3/7 all triggered and unwound correctly.
- WSL distribution listing returned E_ACCESSDENIED. It was not retried or used. CPU work continued with existing Windows Zig/Git Bash, not on the Sparks.
- Eight frozen golden files have Windows-invalid names. Original Git blob IDs and SHA256 hashes are retained in the materialization receipt; never silently rename them and claim full319-case golden coverage.
- Full Linux template/server/golden tests, native ARM64 all-mode mutation confirmation, Linux filesystem/security tests, disk quota/ownership behavior, JPEG/Pillow failure/cancellation, NVCC/full ARM64 image link, CUDA kernels/graphs, RDMA/NFS behavior, model-output/token parity, four near1M decoders and spill/failure recovery all remain runtime gates.

Private raw test outputs and source/copy checks are archived separately. This public report contains no local process logs, host paths, private requests, machine addresses or credentials. Reproduction commands and budgets are in tonight-plan.md; no successful static test implies deployment readiness by itself.

Follow-up evidence and precise original failure attribution: [failure-followup.md](failure-followup.md), [failure-results.json](failure-results.json). These supersede the initial failure summary without erasing its history.

# Candidate build, bounded A/B and rollback — not executed

Prerequisite: the operator confirms the production tasks have ended and approves the idle test window. **Nothing in this preparation polls, builds on, stops or starts the Sparks.** Do not invoke start.sh, prepare.sh, systemd, port ownership helpers or GPU validation tools now.

## Reproduce source and build

1. In an isolated checkout of this integration branch, use an existing engine repository containing629c524:
   `python tests/integration-pr30-pr40/prepare_source.py --engine-repo <existing-engine-repo> --out <new-source-directory>`.
   This makes no network request and strictly applies all21 active patches. It produces SOURCE_SHA256SUMS and an apply receipt. On Windows eight invalid golden filenames are recorded by original blob ID; a complete Linux materialization is required before full golden parity.
2. CPU tests (Zig0.17.0, serial commands, limit compilation to two cores on a busy workstation): `zig test -lc zig/src/core/tokenizer/tokenizer.zig`; `zig test -lc zig/src/core/template/template.zig`; `zig test -lc zig/src/server/prepare_gate.zig`; `zig test -lc zig/src/families/dsv41/{parts,shard,pool}.zig` (expand into three commands). Copy capacity_tests.zig beside parts/shard and test it. Use Debug for the mutation suite; the separate ReleaseSafe mutation discrepancy is documented. On Linux also run `zig/tests/server/zig_test.sh`, full golden parity, `scripts/port_test.sh`, Python unit discovery and tools/selftest.py. No real API is needed: selftest uses synthetic local fake servers.
3. On Windows host, `windows_template_tests.py --source <materialized> --zig <zig.exe> --out <new-dir>` offers selected real template/list/arena tests with only the unrelated POSIX clock function refused in a disposable copy. It is **not** unmodified Linux golden parity. Do not ship the compatibility adapter as production engine code.
4. Full CUDA/ARM64 image build is pending. Use this branch's existing `scripts/prepare.sh` build argument/kit mechanism only after reviewing its side effects and the idle window. For a build-only step, create a context containing only `zig/Dockerfile` and active `zig/patches`, and pass TF_REPO/TF_REF/INPUTS_REF/ZIG_VERSION/ZIG_SHA256/BASE_IMAGE/SM121/PATCHES_HASH from the pinned `scripts/config.sh`. Build to a **new candidate image tag**; never retag stable0014, never transfer credentials/private local.sh or weights into build context. Verify image labels and compiled binary hashes before starting. Full compile/NVCC/linking has not run during preparation.

## Before switching

Save both original container identities/digests, exact private launcher/config checksums, mount/network/auth/generation settings, guard states and logs. Reuse original API/tunnel/security settings. The old source counterpart is14d87694fe62982889e634363bccc704f94f13b6, current stable0012+0014, with shared1048576 pool/two streams; record live state afresh rather than trusting yesterday's record. Keep the old images, stopped containers, launcher and binaries.

Use the explicit `candidate.env.example` overlay, a separate candidate recipe directory/image/container identity, same weights/kit/network and official guard. `PAIR_RESTART=0` preserves first failure evidence; engine peer-death exit handling remains enabled. Do not install the supplied systemd unit or run ownership/chown helpers automatically. Only one model pair may occupy memory at a time.

## Batches (one attempt each; inspect a failure before proposing a repeat)

| Phase | Scope / budget | Pass | Stop / evidence |
|---|---|---|---|
|0014 baseline|At most6 short text/tool/image/cancel requests;10min|Collect deterministic text/token baseline, completed request returns idle, current memory baseline|Any failure: preserve both ranks and stop escalation; no extra pressure|
|Candidate load/smoke|Exact5.218M/4/1M/shard configuration;6 short requests;10min after healthy load|Actual config/guards/image verified, outputs match baseline where deterministic, two then four short requests observed|Wrong config, OOM/guard/API failure: stop batch, save evidence|
|Long text + images|At most6 requests;20min;32K→128K→256K with2/4 synthetic images; one cancelled request|Byte/token/error semantics, request memory release, no monotonic idle baseline growth, gate wait/cancel releases reservation|Timeout, leak evidence, guard or broken peer: collect before cleanup, do not retry blindly|
|Four distinct long histories|At most3 batches,4 requests/batch;20min/batch:~512K,~768K, then prompt1040384+allowed output8192 per lane (total1048576)|Both parts each live2, all4 simultaneously decode; verify actual prompt/cache/output lengths and common time interval|Queueing alone is not four-way pass. If no overlap before budget, report coverage gap and design a new bounded step, do not silently extend|
|Same-prefix fanout/continuation|One prepared long prefix followed by4 branches;≤8 requests/20min|Prefix aliases stable, correct resume,2+2 owner distribution, no misplaced/stale generations; idle release recorded|Wrong output/token digest, cache corruption, planner mismatch or OOM => stop|
|Spill/cache restore|After explicit disk review:64GiB/rank cap,50GiB free floor,128MiB staging/rank;≤8 requests/20min|Quota/lineage/owner salt, images preserved, reload and cancellation release holds, mismatch fails closed|Disk floor/quota error, private cache access concern, corrupt lineage or lingering holds => stop|
|Fault boundary|Only idle candidate, explicit operator action; one peer-death case + one restored-cache case,≤15min|Both ranks exit/refuse as designed; no hung peer; evidence saved; controlled restore|No automatic crash/restart loop. Do not kill unknown or stable processes; timeout/hang => capture then controlled stop|

Lengths must be measured with the candidate's actual tokenizer/template, including images/tools; the table is a target, not observed coverage. A4MiB body is not necessarily1M tokens. Long histories plus allowed output must not exceed1048576. The full-window reservation is1050624 positions per lane.

Use lightweight5s memory/GPU/request sampling, RSS/PSS at15–30s, persist both rank logs and memguard/queue/planner/gate events. Align UTC request IDs, owner/live/decoding state, prompt/cache/output counts. Observe5min natural idle after long phases without clearing cache or restarting. An official guard/OOM/unresponsive system/broken API ends the batch; preserve scene first, cancel only own requests, then stop a known hung candidate peer under existing safe procedure. Do not impose an extra5GiB threshold or lower official protection. Swap/PSI are recorded and interpreted, not hidden.

## Rollback

1. Cancel own candidate requests; preserve both rank logs/exit/guard/swap/placement state. Disable/disarm only the **candidate** pairwatch if later enabled; do not let it respawn during rollback.
2. Stop the exact candidate pair using its dedicated recipe/identity. Wait for both ranks to exit and memory recover; never load stable alongside a live candidate.
3. Restore exact saved0014 image IDs, binary/launcher/config checksums and original shared1048576/two-stream parameters; remove only the candidate overlay from that invocation. Restore original API/auth/network/generation settings byte-for-byte. Do not use the older0014→0012 rollback as this operation's rollback.
4. Start original0014 only in the confirmed idle window, verify identity/health/guards and one short text/image request, leave it running if healthy. Keep candidate evidence and spill cache isolated; do not delete old logs or overwrite stable images/configs.

This document is an execution plan, not an automatic deployment script or a claim that any GPU batch has passed.

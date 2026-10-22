# Follow-up: optimized mutation probe and host test failures

These changes affect test fixtures and the candidate profile. Production remains0014. No model request, service restart, GPU build or deployment was performed for this follow-up. The separate GLM storage audit is not part of this public source change.

## Planner: ReleaseSafe / ReleaseFast

The original `counted_at_plan` mutation writes counters through `@constCast(self)` inside `Planner.planAdmit(self: *const Planner)`. Its named killer can see a reused read-only observation in optimized tests: direct/volatile probes see the increment, but the named killer misses it while other checks fail. Debug kills the mutant. This is a defect in where the fault is injected; it is not evidence that normal release planning increments counters.

`Planner.mut` is guarded by `builtin.is_test`. In ordinary executables it is always false. Before and after the fix, independent non-test ReleaseSafe and ReleaseFast probes both report `is_test=false`, counters0 after planning and1 after application. The test-only0101 patch moves the exact injection to mutable `Fx.plan` after the real planner returns. No production planner algorithm or release error path is changed. The unmutated suite, every mutant killed by its named check, and public-declaration compilation now pass3/3 in each of Debug, ReleaseSafe and ReleaseFast.

This does not establish whole-engine memory safety or identical binaries: stripped Windows probe binaries differ, including optimized code sections. Their semantic probes agree; binary identity is explicitly not claimed. The exact compiler transformation is not proved. Repeat all three modes on native Linux/ARM64 before deployment; any unmutated failure, surviving mutant or unexpected release counters blocks the candidate.

## Port134/138

The four failures were: live parked-page accounting from native `/proc/meminfo` and `/proc/zoneinfo`; weight-file symlink refusal; pairwatch log-rotation symlink refusal; and spill-ownership canonical/symlink checks. MSYS `/proc` is not the required Linux data, and emulated `ln -s` is not a real POSIX symlink. These are not security passes.

The harness now detects capabilities, reports4 explicit mandatory-Linux skips, and passes134/134 executed checks. Its two pre-existing Linux golden-probe skips remain visible. `PORT_TEST_REQUIRE_LINUX=1 bash scripts/port_test.sh` fails closed with exit2 on this host before testing. On native Linux it must run with real symlinks and both proc files and finish without these skips; ownership/log/weight protections must not be waived.

## Mock64/71

The original seven unmet expectations were test-host defects, not seven engine failures:

| Original label/group | Verified cause | Change / evidence |
|---|---|---|
|counters; spill candidate|Fake server startup called unavailable Windows `os.statvfs`|Use `shutil.disk_usage(...).free`, which uses available filesystem bytes on Linux as well; portable unit verifies it|
|KV labels|Colon-containing log names became NTFS streams or invalid paths|Bounded safe stem plus hash; collision/unsafe-name unit passes|
|pair kill / spill resolve|POSIX quoting, unquoted interpreter paths and `true`/`cat`/`test` were passed to Windows command shell|Shell-specific quoting and portable synthetic Python commands; actual validators unchanged|
|failure diagnostics|CP936 child stderr was decoded as UTF-8 or hidden behind another exception|Explicit UTF-8 child Python and diagnostic replacement decoding|
|runbook|Native shell/filesystem/systemd fixture assumptions; PATH selected unavailable WSL Bash|Explicit native-Linux prerequisite; not executed or marked passed here|

The first portability rerun reached90/93. The remaining spill prekill used POSIX `true`; its missing state caused the strict postkill failure. The pair fixture restarted after1s, which could fit inside one Windows TCP observation, hiding the outage. The fixture now waits, bounded30s, for the real validator to log its down observation before restarting; if no observation appears, it does not restart and the test fails. No real validator timeout or failure criterion was relaxed.

Final mock run:93 expectations,0 unmet in194.375s; portable units2/2. Native-Linux runbook is still skipped, and `tools/selftest.py --require-linux` exits2 here. Full Linux Python discovery and runbook remain mandatory. The earlier report's generic attribution to log decoding is superseded by the concrete causes above.

## Checkpoint lock

The old recipe source default was `6d54be4fca338d79b17c3b03cc9a423bb3ac6718`; frozen upstream main370daf0 defaults to `45ee5d0fd106c94a3d77f721e09cbb2f50e5a16b`. Neither is the actual saved0014 deployment checkpoint. The recorded stable model revision is **878f5689915bcb44d985125e9a8cd4b78874e546**, Engram **1bae0e1088993b9b82de08f59de5be5a34e42170**. These are public weight revisions; no private paths or data are included here.

`candidate.env.example` now requires explicit VERIFIED_STABLE_MODEL_REVISION / VERIFIED_STABLE_ENGRAM_REVISION, rejects missing/different values, sets both exact refs and retains HF_HUB_OFFLINE=1. Four synthetic profile cases pass: missing rejected; recorded pair accepted; new upstream model rejected; different Engram rejected. Before tonight's switch, verify live0014 mount/file revisions and hashes, apply the overlay after private configuration without a later override, inspect effective MODEL_REVISION/ENGRAM_REVISION and actual mounted checkpoint/rank cache, and prohibit downloads. If live values differ, stop and reconcile rather than editing the lock automatically.

## Required gates before production switch

1. Fresh native Linux/ARM64 source replay of all22 patches and full hash check. Confirm local0011/0012/0014 files remain exact; local0013 tool-merge is absent. Use pinned Zig0.17.0. Run `parts.zig` tests in Debug, ReleaseSafe and ReleaseFast; all three cases must pass in every mode. Repeat non-test release counter probes if any source/compiler difference exists.
2. Unmodified template/server tests and full golden parity, including eight filenames not materializable on Windows; tokenizer, shard, pool, capacity, prepare-gate, PNG/JPEG/Pillow ownership/error/cancel checks. No compatibility adapter enters the image.
3. `PORT_TEST_REQUIRE_LINUX=1 bash scripts/port_test.sh`, both Python unit-discovery suites, and `python tools/selftest.py --require-linux --keep`; no unmet expectations or mandatory-platform skips. Test the actual symlink/ownership/log refusal behavior.
4. Exact ARM64/CUDA image build/link, source labels, kit and binary hashes, checkpoint lock, original network/mount/auth/guard parity and rollback review. Static pass is not permission to switch or evidence of GPU stability.
5. In a separately confirmed idle window, follow tonight-plan.md: bounded0014 baseline then candidate5,218,304 shared pool,4 lanes,1,048,576 window, shard1. Observe2 live sessions per owner and four simultaneous decoders, then fanout/restore/cancel/failure boundaries under unchanged official guard. Do not equate queue completion with four-way decode.

Public reproducible artifacts: `tests/integration-pr30-pr40/prepare_source.py`, `verify_weight_profile.py`, `capacity_tests.zig`; `zig/patches/0101-planner-mutation-probe.patch`; `tools/test_selftest_portability.py`; this directory's `failure-results.json`, `provenance.json` and `engine-SOURCE_SHA256SUMS`. Private detailed probe sources/logs and original results remain in the separate backup, not the public fork.

# Integrating the bounded-validated list-prefix fix

Promotion status: integrated as the selected default after bounded validation.

The coordinated deployment completed successfully and retained 0012. A subsequent
default-entry check was a no-op on the same service generation, with both ranks
healthy and idle, a shared 1M token pool, two admitted lanes, diagnostic logging
off, and the original memory guard unchanged. A further 21.110-second smoke run
passed three completed requests and one planned cancellation, including an
observed two-lane overlap. These checks confirm this integration, not unbounded
workload stability.

This integration branch contains the accepted HfText scratch-lifetime fix (0011)
and the immutable list-prefix optimization (0012). It carries the same source and
tested artifacts as the experimental branch; promotion does not introduce another
compiler run or another behavior change. Later optimizations belong on a separate
experimental branch until their own validation is complete.

## Source and build inputs

The recipe base remains `31eea4608f8bb292a92e2f7a1db400e928620c78`, with serving
TensorFold at `629c524a0ea57512a5342abb498d1b7c25353343`. The earlier
[`hf-scratch-series.json`](../zig/patches/hf-scratch-series.json) preserves the
eleven-patch 0011 baseline. The new
[`list-prefix-series.json`](../zig/patches/list-prefix-series.json) records the
complete twelve-patch order, hashes, and resulting changed-source hashes.

`zig/Dockerfile` applies `zig/patches/*.patch` in filename order. Including
`0012-list-concat-prefix.patch` in that directory therefore includes the fix in a
subsequent recipe build; no manual post-build source edit is required. The added
patch SHA-256 is
`7af10b50e456cef53f4b0b75e600e4eb50de7d4dd672caf99fa16a677a7703e6`.
It changes only `zig/src/core/template/eval.zig`, whose final SHA-256 is
`2f25efef0e4bd95a08f285739528e1d9e29a1cbad0e73b5ce80de718573e9355`.

The selected artifact set reuses the already tested native executable and the
unchanged worker executable. No rebuild is needed to deploy that exact set:

| Executable | Observed SHA-256 |
| --- | --- |
| `tensorfold-native` | `c4eb359824af3b594000f9889713a000d4a34aea20a7ab2ab58efe8a77902b98` |
| `tf-dsv41-lanes` | `4358a917d68b06d1b9c3f850c115c83a17c726acf6aacf8f385e322d05f695b2` |

These hashes identify the validated artifacts; they are not a promise that an
arbitrary build environment will reproduce identical binaries. This repository
does not redistribute binaries, weights, deployment settings, or private records.
For a separate source rebuild, retain the pinned SDK, dependencies, full patch
order and [isolated build procedure](hf-scratch-build.md), then validate the new
artifacts separately. The worker is from the serving pin, not `INPUTS_REF`.

Both `TF_DS_MEMORY_DIAG` and `TF_DS_GRAPH_DIAG` remain off by default. The 0011 and
0012 behavior fixes apply independently of those logging switches. The complete
diagnostic patch chain must be kept together; its earlier 0008 patch alone does
not have the final opt-in gate.

## Validation scope and rollback

The [CPU tests](../tests/list-prefix-concat/README.md) passed 26 semantic/allocator
tests per variant and 18 exact HfText output comparisons. The
[bounded serving regression](../tests/list-prefix-concat/runtime-results.md)
covered long inputs, cached concurrent output, and cancellation. The repeated
4096-message case reduced sampled extra head-process RSS by about 91.936%; this
is not a full-model or GPU-memory reduction claim.

An integration/default selection does not expand that evidence. Full use of the
shared 1M token pool, long-duration steady state, and two fully cold simultaneous
long prefills remain unvalidated. The tool-heavy slice-and-replace path and
alternating list accumulators still have quadratic work. No general guarantee
for arbitrary message counts or HTTP concurrency follows from these checks.

Keep the accepted 0011 artifact set for rollback, retain the memory guard and its
thresholds, and use a coordinated pair lifecycle. Deployment-specific commands
and credentials are intentionally outside this public source backup.

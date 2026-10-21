# Immutable list prefix candidate (0012)

Experimental branch `experiment/list-prefix-concat`, based on stable fork commit
`3368a0f5423b0fb28f51fde7461522dba5e43d21`. A
[bounded GPU-serving regression](runtime-results.md) has completed; broader
capacity and long-running validation remain outstanding.
The stable `fix/hf-scratch-arena` branch is unchanged.

The DeepSeek chat template grows `ns.msgs = ns.msgs + [message]`. Copying the whole
list for every append retains a quadratic number of Value cells in a render arena.
This patch makes an uninterrupted append chain amortized linear while preserving
immutable list behavior. It builds on accepted per-call HfText scratch reclamation
(0011); the two changes address different sources of temporary memory.

Only the latest full backing slice may be extended. Old aliases keep their original
length and contents. A branch from a shorter prefix or a different list gets a fresh
buffer. Growth retains the old buffer until the render arena is destroyed. Every
concatenation still constructs a new List object, including concatenation with an
empty list, preserving `sameas`. No mutable list operation is introduced. The
accumulator is render-local and handles lists and tuples under the existing type
checks. The threshold is 128 Value cells.

The patch changes only `zig/src/core/template/eval.zig`. This is the tested statistics
variant and retains the existing diagnostic counters. Apply to the recipe at engine
commit `629c524a0ea57512a5342abb498d1b7c25353343`, after its existing recipe and
statistics patches and 0011. The expected eval.zig SHA256 before applying is
`3470e155a5ca9d89f8ba317da7c6a28a2d49090d43d0056110ae63d6d1e41a9d`;
after applying it is
`2f25efef0e4bd95a08f285739528e1d9e29a1cbad0e73b5ce80de718573e9355`.

```sh
# Run from an isolated TensorFold source tree; RECIPE_DIR is this fork checkout.
git apply --check "$RECIPE_DIR/zig/patches/0012-list-concat-prefix.patch"
git apply "$RECIPE_DIR/zig/patches/0012-list-concat-prefix.patch"
cp "$RECIPE_DIR/tests/list-prefix-concat/list_concat_tests.zig" zig/src/core/template/list_concat_tests.zig
zig test zig/src/core/template/list_concat_tests.zig -lc -O ReleaseSafe
```

Use the pinned Zig 0.17.0 toolchain. Tests include the existing template feature
probes, 14 synthetic Jinja reference cases, and successful/error render allocator
failure sweeps: 26 tests pass on both baseline and candidate. They cover old aliases,
same backing pointer with different lengths, self-concat without growth, nested RHS,
iteration while appending, empty-list identity, shallow namespaces, tuple/type errors,
Unicode and macros. Standalone tests are not included in the serving binary.

The actual HfText renderer and tokenizer, with the pinned public checkpoint metadata,
passed all 18 offline pairs with byte-identical render output and token IDs. Coverage
includes tools/thinking/Chinese, invalid inputs, caller-copy OOM and cancellation
consumer lifetime. This does not test actual network/SSE cancellation or GPU execution.
For this A/B, baseline includes every patch through **0011**; candidate contains the
identical series plus **0012**. Do not omit 0011 from either variant. Both include
identical diagnostics. Reuse the [HfText scratch harness](../hf-scratch/README.md)
and its 15 default synthetic fixtures. Add
the three `fixtures/tool_rounds_*.json` files and their `manifest-additions.json`
entries to that harness fixture manifest. No HfText runner change is required. Run
the same baseline/candidate CLI with both binaries built from the same pinned source
and public model metadata, selecting these 18 default cases. The existing runner
requires an isolated no-GPU, network-none container with at most 3 GiB RAM, no
swap, and a 600-second batch bound. Keep its 2-CPU outer limit and ReleaseSafe. The original optional
8192-message case was not run in this batch.

Sampled extra RSS above the loaded-tokenizer baseline (MiB):

| Synthetic history | 0011 | 0011 + 0012 |
| --- | ---: | ---: |
| 128 alternating messages | 13.52 | 12.86 |
| 1024 alternating messages | 22.24 | 15.04 |
| 4096 alternating messages | 275.83 | 20.53 |
| 128 assistant/two-tool rounds | 5.55 | 6.39 |
| 512 assistant/two-tool rounds | 51.97 | 50.97 |
| 1024 assistant/two-tool rounds | 171.50 | 168.65 |

These are synthetic offline lower-bound samples at 5 ms intervals, not production
capacity guarantees. The 4096-message case drops about 92.56% in this measurement.
The tool-heavy cases expose a remaining quadratic path: `ns.msgs[:-1] + [...]` copies
the previous history, and `parts + [part]` can alternate accumulator chains. Thus
this patch does not make every template workload linear. Small-case differences may
reflect sampling and allocation choices; no consistent benefit is claimed for those
cases, and these timings are not a throughput claim. Request-owned backing
was released in every case; the worker experiment had no cgroup OOM or swap activity.

Independent static review found no blocking issue in the frozen patch. Review does
not replace runtime regression. `list_concat_values` remains a logical output-size
counter; it must not be interpreted as physical cells copied after this patch.

The candidate remains experimental after its bounded serving regression. The
accepted 0011 deployment was restored and remains the stable default. Keep it for rollback;
no model weights, deployment settings, network/security settings or memory protection
thresholds are part of this patch.

Source attribution and the upstream repository license remain applicable. No upstream
PR or issue is submitted by this export.

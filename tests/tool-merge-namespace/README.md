# Private tool-merge turns (0013, experimental)

Branch `experiment/toolmerge-namespace` is based on the accepted 0012 integration
commit `872f38dd63fa505e575f8407d8f869d2cf7d5910` on `fix/list-prefix-concat`.
It is not the selected default. This experiment keeps the
[0012 native source and artifact inputs](../../docs/list-prefix-integration.md).

This candidate changes only `model/chat_template.jinja`. It builds on the accepted
0011 scratch reclamation and 0012 immutable-list prefix optimization. No engine,
weight, network, protection threshold, or deployment setting changes are included.
The native binary remains unchanged. The upstream recipe, TensorFold, and model
retain their licenses and attribution.

The merge pass previously rebuilt `msgs[:-1] + [replacement]` for each additional
tool result. The candidate creates private user-turn namespaces and updates their
`parts` attribute. The lists remain immutable. Only template-created namespaces
are changed; incoming message dictionaries are never mutated. Later passes read
only `role` and `parts`, and do not serialize, compare, or expose the private turn
objects. Tool ordering, reasoning, and generation suffix behavior are unchanged.

The source template SHA-256 is
`2ad469968493ff62065c26f49a6b12e5f6968ef51f6321bc5a7361c21c3cc477`;
the candidate is
`0faf4f4050879f3c91ef0e63368cce8264fe627457fbe82dd3a98d9381122e10`.
The included `0013-private-tool-merge-turns.patch` targets the recipe's model
template, **not** the TensorFold source patch directory. Do not put it under
`zig/patches`. This experimental branch supplies the candidate template directly.
Use a separate model view to test it; keep the original model template and weights.

The template patch SHA-256 is
`ef31d03b34f51e46c0057aee6befd5356904dcc0aa449421c8dc324771216cb4`.
For a clean recipe checkout at the 0012 integration commit above, apply the patch
from a separate checkout of this experiment as follows. The experiment branch
itself already contains the candidate template; do not apply it twice.

```sh
git apply --check "$EXPERIMENT_CHECKOUT/tests/tool-merge-namespace/0013-private-tool-merge-turns.patch"
git apply "$EXPERIMENT_CHECKOUT/tests/tool-merge-namespace/0013-private-tool-merge-turns.patch"
```

These commands modify the recipe template only. They neither deploy a service nor
alter a model snapshot. The file hashes above identify the required before and
after contents. From this recipe's root, `sha256sum -c
tests/tool-merge-namespace/SHA256SUMS` verifies the published test/source inputs.

## Reproduce the CPU comparison

Use an isolated TensorFold checkout at
`629c524a0ea57512a5342abb498d1b7c25353343`, with this recipe's native patches through
0012. The expected `eval.zig` hash is
`2f25efef0e4bd95a08f285739528e1d9e29a1cbad0e73b5ce80de718573e9355`, and the HfText
hash is `c3d5a1c288ea56546ff23a3d2d6bdc7604f06f7bfbe4423720ae234f50c887bf`.
Use the pinned Zig 0.17.0 toolchain and already-cached dependencies. No download,
package installation, GPU device, or live service is needed by these tests.

Copy `tool_merge_tests.zig`, both `*-chat-template.jinja` files,
`merge-fixture.json`, and `invalid-merge-fixture.json` to
`zig/src/core/template/` in that isolated checkout. Then run:

```sh
zig test zig/src/core/template/tool_merge_tests.zig -lc -O ReleaseSafe
```

All 12 tests passed, including two new full-template success/error allocation
failure sweeps. These exercise every GPA backing allocation failure index and
cleanup, not every suballocation within a backing arena.

Build the CPU harness using the [existing harness instructions](../hf-scratch/README.md),
but substitute this directory's `hf_scratch_harness.zig`. Its only harness extension
allows a sequence of requests on one loaded HfText instance. Reuse the existing
`build-harness.zig` and `harness_template_module.zig`. Both A/B sides use this same
binary; only the metadata's template file changes.

Run `python3 prepare_fixtures.py` in a fresh checkout to assemble 38 synthetic
fixtures from the existing tests plus this directory's additions. Prepare two
separate metadata directories containing the verified public tokenizer/config
files. The baseline uses `baseline-chat-template.jinja`; the candidate uses
`candidate-chat-template.jinja`. The two hash manifests pin every metadata file.
Do not modify an original model snapshot or follow a symlink when replacing the
template in an isolated metadata copy.

Inside an externally bounded no-GPU, network-none Linux container, run:

```sh
python3 run_hf_ab.py \
  --baseline-bin /binaries/hf-scratch-harness \
  --candidate-bin /binaries/hf-scratch-harness \
  --metadata /baseline-metadata --candidate-metadata /candidate-metadata \
  --fixtures /fixtures --output /results/run --execute \
  --timeout 30 --total-seconds 570
```

Keep the outer limit at 2 CPUs, 3 GiB memory and 3 GiB total memory plus swap
(no swap); use no GPU devices or Docker socket. The runner checks its memory,
swap, device, and network boundaries, stops on the first failure, and never retries.
The CPU build used the same limit, `ReleaseSafe`, and a 10-minute outer budget.

## Observations and limits

All 38 primary HfText pairs matched rendered bytes, token IDs, errors, and cleanup.
They cover tool-first histories, reversed and repeated tool IDs, mixed roles,
thinking, Chinese, object/list/null content, invalid input, allocation failure,
and a normal/error/normal/normal sequence on one HfText instance. An additional
560 seeded Python/Jinja reference pairs matched. These are synthetic tests, not
private conversation reproductions.
The local reference check is `python3 reference_parity.py`, after fixture
preparation, using an already available Jinja2 3.1.6 environment.

Sampled extra process RSS above loaded-tokenizer baseline, MiB:

| Assistant/two-tool rounds | Original template | Candidate |
| --- | ---: | ---: |
| 128 | 6.94 | 3.62 |
| 512 | 52.37 | 30.34 |
| 1024 (3072 messages) | 170.79 | 53.04 |
| 2048 (6144 messages, separate pair) | 645.45 | 120.93 |

The 1024-round sample decreases by about 69%. The doubling trend is consistent
with eliminating the repeated outer-list slice for this specific two-tool shape.
It does not establish that every template history is linear. With long `parts`
lists, the single list-prefix accumulator can switch between lists; subsequent
outer appends may copy again. For example, 128 groups of 129 results measured
333.07 -> 173.01 MiB, and 32 groups of 512 measured 166.01 -> 141.17 MiB.

Sampling at 5 ms gives a lower bound on the true transient peak, not exact
allocation accounting. One-byte text growth and allocator bucket boundaries can
change the observed peak. There were no cgroup OOM or swap events. Request-owned
backing was released in all tests. Mock cancellation covers output lifetime after
render/encode, not interruption inside a render or real HTTP/SSE cancellation.

`generate_gpu_shapes.py` creates three fully synthetic shapes for a separate
bounded serving comparison: 3072 tool-history messages plus one final user
request, thinking disabled, with 89228 / 281600 / 332800 tokens. The tools and
history remain fixed; only final-user reference padding differs. All three final
shapes have exact offline original/candidate text and token parity. Their six
calibration/scaling pairs bring the total to 44; two intermediate long-length
pairs are included in that total. The generator never sends requests. The output
instruction asks for a long answer, but actual output length and concurrent
progress must be observed; a token cap alone proves neither.

At these longer padding lengths, tokenizer-related memory can dominate: final
281600-token extra RSS was 174.98 -> 165.70 MiB; 332800 tokens was
216.28 -> 212.35 MiB. This is a focused template allocation optimization, not a
claim that total memory always falls by 69%, that the original incident is fully
attributed, or that shared 1M / two-lane long-running stability is proven.

`offline-results.json` and `synthetic-shape-results.json` contain sanitized
aggregates and hashes. The [bounded GPU-serving A/B](runtime-results.md) is now
complete and the 0012 default was restored. Its results are mixed: compact memory
improves, while some long, concurrent, and cancellation peaks increase. Do not
generalize the compact reduction. `gpu-results.json` preserves the de-identified
aggregate. Nothing here changes the stable default or requests an upstream PR.

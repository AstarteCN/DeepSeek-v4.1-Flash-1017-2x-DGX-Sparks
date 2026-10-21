# HfText scratch lifetime regression

This CPU-only harness calls the real TensorFold `HfText` renderer and tokenizer.
It uses public model metadata and generated synthetic messages. It does not load
weights, initialize a GPU, contact a service, or reproduce a private conversation.
The code is covered by this repository's Apache-2.0 license; the underlying
TensorFold and model projects retain their own licenses and attribution.

## Fix and integration

`zig/patches/0011-hf-reclaiming-scratch.patch` gives each render and encode call an
independent page-backed scratch arena. Only the final text, token IDs, or dynamic
error description is copied into the caller's allocator. The scratch arena is
destroyed before returning. Previously, nested temporary allocations were backed
by the request arena; copying the result could leave those temporary blocks live
until the whole request was released.

The recipe's existing `zig/Dockerfile` applies every patch in filename order, so
the fix is included in a subsequent recipe build. There is no new runtime switch
for the fix. This commit does not change deployment settings or publish an image.
Keep an existing working image until validating a separately tagged build.

Tested source pins:

* Recipe: `31eea4608f8bb292a92e2f7a1db400e928620c78`.
* Serving engine: `bertholomus/TensorFold` at
  `629c524a0ea57512a5342abb498d1b7c25353343`.
* Compiler: Zig 0.17.0, Linux aarch64; harness uses `ReleaseSafe`.
* Behavior patch SHA-256:
  `ba8f28643cdf24083704137cbc2b5e2a216840985870762b048584f60b802097`.
* `hf_text.zig` before/after SHA-256:
  `f33ae4bec55cb268d254994cd26875a02dbc1b2ac274ede27cd2a8e20b515728` /
  `c3d5a1c288ea56546ff23a3d2d6bdc7604f06f7bfbe4423720ae234f50c887bf`.

## Prepare the offline comparison

Use two fresh checkouts at the serving pin. Apply this recipe's patches in sorted
order to each checkout, **excluding only** `0011-hf-reclaiming-scratch.patch`
from the baseline. Keep all other patches identical. Check each patch with
`git apply --check` before applying it. Do not use a live deployment source tree.

Copy these files into **both** source trees:

| This directory | Destination relative to the source root |
| --- | --- |
| `hf_scratch_harness.zig` | `zig/src/server/hf_scratch_harness.zig` |
| `harness_template_module.zig` | `zig/src/core/template/harness_template_module.zig` |
| `build-harness.zig` | `build-harness.zig` |

In each isolated source tree, with the pinned SDK and required packages already
cached, compile without network access or GPU devices:

```sh
/opt/zig/zig build --build-file build-harness.zig --prefix ./harness-out -j1
```

Use an external container limit of 3 GiB RAM, 3 GiB total RAM+swap (zero allowed
swap), 2 CPUs, and a 20-minute build timeout. No model weights are needed. Missing
SDK/packages are a prerequisite failure, not permission to fetch an unpinned SDK.

Generate the fixtures with `python3 make_fixtures.py`. The generator produces
16 cases; the 8192-message case is excluded by default. Generated fixtures and
test outputs are ignored by Git.

The metadata comes from the public model repository
[Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw](https://huggingface.co/Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw).
The tested revision is `878f5689915bcb44d985125e9a8cd4b78874e546`.
Only `tokenizer.json`, `tokenizer_config.json`, `config.json`, and
`chat_template.jinja` are needed. `metadata_expected.json` pins their exact
SHA-256 values, independently of a mutable repository branch. The runner rejects
different bytes. Obtain the files separately under the model's terms; no metadata
or weights are redistributed here. Do not silently replace the hash list when
claiming to reproduce the measurements below.

## Run

Use a pre-existing local Linux image with Python 3 and the two CPU binaries.
The following mount variables are caller-selected absolute paths: `HARNESS_DIR`
(this directory with generated fixtures), `BINARIES_DIR` (containing `baseline`
and `candidate` executables), `METADATA_DIR`, and an empty `RESULTS_DIR`.

```sh
docker run --rm --network none --memory 3g --memory-swap 3g --cpus 2 \
  --mount "type=bind,src=$HARNESS_DIR,dst=/harness,readonly" \
  --mount "type=bind,src=$BINARIES_DIR,dst=/binaries,readonly" \
  --mount "type=bind,src=$METADATA_DIR,dst=/metadata,readonly" \
  --mount "type=bind,src=$RESULTS_DIR,dst=/results" \
  --entrypoint python3 "$LOCAL_CPU_IMAGE" /harness/run_hf_ab.py \
  --baseline-bin /binaries/baseline --candidate-bin /binaries/candidate \
  --metadata /metadata --output /results/run --execute
```

Do not add GPU devices or a Docker socket. The runner verifies cgroup-v2 RAM and
swap limits, no NVIDIA device nodes, and only the loopback interface. It does not
create the container or enforce the CPU limit itself. It stops at the first
failure, with a 30-second per-process and 600-second batch bound; it does not
increase budgets or retry. Omit `--execute` to inspect the plan. `--case` can be
repeated to select a smaller batch.

Both binaries also support `--hex-self-test`. Decode each emitted `DATA` hex
record and verify the exact `i % 251` byte pattern for lengths 2048, 2049, 4096,
and 4097. The published harness includes the explicit `usize` chunk length that
fixed a harness-only overflow in an earlier test, without weakening ReleaseSafe.

## Observed results and limits

All 12 small cases matched rendered bytes, token IDs, and error `DATA` records
exactly. They cover Unicode/Chinese, thinking, tools, explicit prefix/suffix IDs,
invalid options/roles, caller-allocation failure, and mocked cancellation/drain
ownership. Cancellation here is a mock consumer that reads outputs after cancel
and before join; it is not a live HTTP cancellation test. OOM cases deny the
caller allocator and do not exhaust every independent scratch allocation path.

The three memory cases also matched exactly. Inputs have the same synthetic word
count split across different message counts. The figures are sampled process RSS
in bytes, not CUDA allocation or token-pool capacity:

| Messages | Baseline request peak | Fixed request peak | Baseline/fixed request samples |
| --- | ---: | ---: | ---: |
| 128 | 129634304 | 108978176 | 5 / 5 |
| 1024 | 202674176 | 116977664 | 9 / 8 |
| 4096 | 755261440 | 387743744 | 34 / 35 |

At 4096 messages, loaded-baseline RSS was 97361920 / 97366016 bytes, and
post-cleanup RSS was 97439744 / 97443840 bytes (a 77824-byte residual in both
variants). Each loaded-baseline and cleanup phase had 19 samples per variant.
The request peak fell by about 48.7%. Measurements used fresh processes, nominal
5 ms sampling, and 100 ms handshake holds around baseline and cleanup phases.
Sampled peaks are lower bounds on instantaneous peaks. Matched optional diagnostic
patches were present in both measured source trees; they were not the A/B variable.

`complete` in the runner means bounded execution and exact output comparison.
`owner_live=0` counts the caller backing allocator, not the independent scratch;
the RSS phases provide separate evidence of cleanup. Inspect both before drawing
a memory conclusion. Raw machine logs are deliberately not included.

This fixes temporary-allocation lifetime. A single render can still have quadratic
message-list work, HTTP preparation is not bounded by the engine's lane count,
and the request queue has no fixed cap in the pinned source. These tests do not
establish stability for arbitrary message counts, HTTP concurrency, or all 1M
context workloads.

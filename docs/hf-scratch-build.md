# Reproducing the scratch-lifetime build

This document describes the 0011 baseline. The integrated 0012 extension and its
full patch order are recorded in [list-prefix integration](list-prefix-integration.md).

This fork preserves the MiaAI recipe and attribution. Its additional behavior
change is `0011-hf-reclaiming-scratch.patch`; the preceding diagnostic additions
are optional logging and counters. No published engine image is supplied here.

The complete source recipe is recorded in
[`hf-scratch-series.json`](../zig/patches/hf-scratch-series.json): serving, input
tool and kernel-kit pins, ordered patch hashes, and hashes of every source file
changed by the series. It contains source paths only, with no deployment identity
or machine records. Start from recipe `31eea4608f8bb292a92e2f7a1db400e928620c78`
and TensorFold `629c524a0ea57512a5342abb498d1b7c25353343`.

## Complete patch order

The existing `zig/Dockerfile` automatically applies `zig/patches/*.patch` in
filename order. Keep the original five recipe patches, then apply:

1. `0007-graph-allocation-diagnostics.patch`
2. `0008-host-template-diagnostics.patch`
3. `0009-memory-arena-diagnostics.patch`
4. `0010-http-connection-memory-diagnostics.patch`
5. `0010a-memory-diag-env-shadow-fix.patch`
6. `0011-hf-reclaiming-scratch.patch`

The `0010a` file is the unchanged diagnostic compiler-name correction, renamed
to make its order unambiguous before the independent HfText behavior patch.
It resolves a Zig capture-variable shadowing error; do not omit it. The patch
bytes, including older comments mentioning a CPU diagnostic build, are retained
to preserve the exact reviewed inputs. The diagnostics also work in the native
serving build.

The **complete** diagnostic series defaults to off. `0008` in isolation is not
default-off: its later gating is supplied by `0009`. Use the series together.

| Control | Default | Scope |
| --- | --- | --- |
| `TF_DS_MEMORY_DIAG=1` | off | template dimensions and concatenation counts; HTTP connection capacities and phases; GPU arena and graph counters |
| `TF_DS_GRAPH_DIAG=1` | off | graph capture diagnostics only; retained as a narrower switch |
| HfText scratch reclamation | on | behavior fix; independent of either diagnostic switch |

Diagnostics report counts and lengths, not request text, headers, token arrays,
or environment contents. Connection identifiers are local counters. HTTP arena
capacity is reserved capacity, not a live-byte measurement. Device arena used and
reserved counters describe that arena; they are not total process RSS or all
CUDA allocations. Graph snapshots use `cuMemGetInfo` without adding a device
synchronization, but enabled logging still has overhead. Disable both diagnostic
switches for normal operation unless collecting a bounded measurement.

## Isolated build

Use a fresh source checkout, not a running deployment tree. Verify its HEAD is the
serving pin. Check patch SHA-256 against the manifest, then run `git apply --check`
and `git apply` for each patch in the listed order. On Windows, disable Git
autocrlf conversion while applying patches; the manifest hashes are canonical LF
bytes. Hash each resulting changed file and compare it with
`patched_source_sha256` before building.

The upstream recipe's Dockerfile still documents the complete dependency/image
build. For a bounded offline rebuild, use an already available aarch64 build
image containing the pinned Zig SDK, cached Zig packages, CUDA compiler and
libraries. No GPU is required. Stage only the isolated source and a fresh output
directory. For example, with caller-selected absolute `SOURCE_DIR`, `OUTPUT_DIR`
and a pre-existing `LOCAL_BUILD_IMAGE`:

```sh
docker run --rm --network none --memory 3g --memory-swap 3g --cpus 2 \
  -e NVIDIA_VISIBLE_DEVICES=void \
  --mount "type=bind,src=$SOURCE_DIR,dst=/src" \
  --mount "type=bind,src=$OUTPUT_DIR,dst=/out" \
  --entrypoint timeout "$LOCAL_BUILD_IMAGE" 1200 sh -ec '
    cd /src
    /opt/zig/zig build -Dnvcc=/usr/local/cuda/bin/nvcc -Dsm=121 \
      -Doptimize=ReleaseFast --prefix /out -j1 install native
  '
```

The container must have no GPU devices, model mounts, network, or Docker socket.
Do not increase resource limits automatically after failure. The command is an
example for a prepared build environment; it does not fetch dependencies or
guarantee that an arbitrary image has the required cache.

Both the native server and `tf-dsv41-lanes` come from this serving tree. The
separate `INPUTS_REF` checkout supplies preparation tools only; it is not the
worker's serving source. The HfText fix changes native text preparation, while
the complete diagnostic build also covers the worker. Package outputs in a new
image tag and record binary hashes before any service replacement. Never replace
an existing deployment tag simply to run this build.

Run the [CPU regression harness](../tests/hf-scratch/README.md) first. In the A/B,
all diagnostic patches must be identical and only the HfText patch omitted from
the baseline. Runtime rollout, pair lifecycle protection, and rollback are
deployment-specific and deliberately are not automated by this public backup.
This source series does not claim an unbounded HTTP queue or quadratic template
work has been fixed.

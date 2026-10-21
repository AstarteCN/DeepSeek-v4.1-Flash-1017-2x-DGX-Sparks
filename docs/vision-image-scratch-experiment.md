# Experimental per-image scratch lifetime candidate (0014)

This branch builds on accepted 0012. It does not include 0013 and is not the production default.

The image prepare hook previously used its caller allocator for decoding, scaling,
patchification and the final payload. When the caller is a request arena, freeing
non-top temporary allocations does not release them. History containing images can
therefore retain temporary CPU buffers until request/connection arena reset.

The candidate runs the unchanged preparation body in a per-image page-backed arena,
copies the final 16-byte-aligned payload to the caller allocator, then releases the
temporary arena. BadImage diagnostic strings are also copied to caller ownership
before temporary storage is destroyed. OOM during either copy propagates normally.
The extra final-payload copy may increase a single-image instantaneous peak; this
targets accumulation across many images, not a claim of universally lower allocation.

Linux ARM64 CPU-only synthetic measurements (main process, 20ms sampling):

| Synthetic input | Baseline peak PSS MiB | Candidate peak PSS MiB |
|---|---:|---:|
| 4 x 1920x1080, one lane | 235.7 | 67.9 |
| 8 x 1920x1080, one lane | 466.1 | 118.1 |
| 8 x 1920x1080 per lane, two CPU lanes | 930.5 | 210.0 |
| 7 x 854x480, one lane | 86.2 | 21.0 |

31 bounded cases passed, including byte equality of the full prepared payload and
token counts for 58 generated PNGs plus a generated JPEG via the real Pillow helper,
post-scratch payload rereads, invalid/oversized image error-message lifetime, and
backing allocation-failure injection for the pure PNG path. Main-process Swap was
zero in these samples. CPU lanes are not model inference concurrency. Pillow-child
memory is not included in main-process PSS. Some completed measurements were reused
after harness-only log-order/transport corrections; no repeated failed load loop.

An existing baseline limitation remains: one injected allocation failure with an
eagerly started Pillow helper completed the Zig allocation cleanup/summary but did
not exit within 30s. That case is not accepted as a pass; PNG OOM testing was then
isolated with Pillow disabled. Pillow protocol recovery under OOM is unverified.
This branch does not repair that separate path.

The full native service executable compiled on ARM64. A later bounded real HTTP comparison is documented in
[HTTP results](vision-image-scratch-http-results.md). Temporary instances were restored
and stopped; the production default remains unchanged.
These results do not establish 1M/2-lane stability or account for all observed host
memory growth. Original user images, requests, logs and machine details are excluded.

Apply patches through 0012 and this 0014 to the pinned TensorFold source. Run
`python tests/vision-image-scratch/prepare.py --source /path/to/patched/TensorFold --out /path/to/input`.
Compile the emitted `vision_ab.zig` with Zig 0.17.0 on Linux ARM64 using
`zig build-exe vision_ab.zig -O ReleaseSafe -lc -femit-bin=/work/vision_ab`.
Use a CPU-only, network-disabled container with two CPUs, 3GiB memory/swap limit,
input mounted read-only at /input and writable /work; run /input/run_cases.py.
Each case has a 30s deadline; allocation backing is limited to 2GiB and the batch
to 180s. Generated fixtures contain only solid colors and geometric lines.

The test adapter extracts the actual candidate wrapper, original preparation body
and decoder from the patched source. Only the scratch page allocator is wrapped
for accounting/failure injection; the decoder and picture/Pillow implementations
are the pinned sources. Retain the repository LICENSE/NOTICE and upstream attribution.

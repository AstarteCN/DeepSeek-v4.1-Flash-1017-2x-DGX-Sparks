# Bounded HTTP comparison: 0012 versus 0012 + 0014

The experimental per-image scratch change passed this bounded real HTTP comparison;
it is not the production default and has not established full 1M-context stability.
Both versions retained a shared 1,048,576-token pool, two configured lanes, identical
weights and safety settings, and the existing 2.5 GiB / 4-second soft memory guard
and 1 GiB hard floor. Versions ran sequentially; no two models were loaded together.

Each version received eight synthetic-image requests: 1/4/8 images, two overlapping
8-image requests, repeated 8 images, invalid input, and an early SSE disconnect.
Six normal generations returned HTTP200; invalid input returned400. All six normal
temperature-zero generated texts matched. Both disconnects produced server-side
client-left with zero generated tokens, then queues returned idle. This covers
early cancellation, not every mid-decode/slow-client cancellation case.

Observed largest input was 7,765 tokens with max 16 generated tokens. Peak active HTTP
connections was 2 and peak waiting was 1. This demonstrates HTTP overlap, not proof of
sustained engine parallel-two saturation or full-window operation. No private images,
project inputs, conversations or logs are included in this report.

Main rank0 process PSS, GiB (one-second smaps sampling):

|Metric|0012|0012+0014|
|---|---:|---:|
|Initial idle PSS|2.550|2.551|
|Sampled peak PSS|3.931|3.172|
|Post-request idle PSS|3.003|3.000|
|Minimum MemAvailable|6.215|6.780|

The sampled peak reduction was0.759 GiB, primarily anonymous RSS.
Shorter transients may be missed. Rank1 peak PSS was
2.697 versus2.699 GiB.
Both versions retained a similar post-startup idle increase: about0.45 GiB on rank0
and0.38 GiB on rank1. The patch reduces request-lifetime image scratch accumulation;
it does not eliminate that shared retained component or establish its allocation site.

No OOM or memory-guard kill occurred during either request window. Candidate system
swap-in/out deltas were zero on both nodes; baseline rank0 swapped out7 pages
(28 KiB), rank1 zero. These are system counters, not proof of per-process ownership.
Minimum rank1 MemAvailable was8.943 versus
8.543 GiB; global availability is affected
by reclaimable caches and need not track main-process PSS between sequential runs.

The request batches took56.31 and57.03 seconds including deliberate sleeps and
observation. This single small sample is not a throughput benchmark or evidence of
no performance cost. The eight-image cold request was 10.56 versus11.34 seconds.

The original0012 instances were restored and verified, then stopped as planned.
Candidate instances also stopped; default scripts and patch list were unchanged.
The baseline Pillow forced-OOM helper-exit limitation remains unresolved, as recorded
in the CPU experiment. HTTP tests did not inject OOM or repeat the video task.
The previously observed long-task memory growth is not fully attributed by this test.

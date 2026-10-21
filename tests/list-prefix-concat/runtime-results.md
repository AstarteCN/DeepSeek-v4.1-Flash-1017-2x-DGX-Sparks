# Bounded GPU-serving regression

The 0012 candidate completed a bounded run of eight inference requests and three
tokenization requests in approximately 455 seconds. The accepted 0011 deployment
was restored afterward. This remains an experiment; the stable fork branch is
unchanged. No raw requests, machine logs, or deployment identifiers are included.

## Host preparation memory

For a repeated 4096-message synthetic history with 30734 input tokens, sampled
extra head-process RSS above the pre-request baseline was:

| Measurement (MiB) | 0011 | 0011 + 0012 |
| --- | ---: | ---: |
| Repeat request peak above baseline | 278.875000 | 22.488281 |
| Post-request residual above baseline | 0.328125 | 0.335938 |

The repeat peak fell by approximately 91.936%. This is host-process RSS, not a
measurement of GPU allocation, total model memory, or maximum serving capacity.
The first-request residual was 186.625 / 187.117188 MiB, respectively. This similar
first-use retention is tracked separately from the repeat comparison and is not
assigned to template savings or a leak. Graph warmup may contribute, but this
measurement alone does not establish its allocation breakdown. Sampled peaks can
miss shorter transient allocations.

## Long-input and concurrency checks

| Input tokens | Single request: output / cached tokens | Single elapsed (s) | Two-lane request: output / cached tokens | Two-lane elapsed (s) |
| ---: | ---: | ---: | ---: | ---: |
| 281661 | 8 / 28672 | 130.594 | 1024 / 280576 | 21.063 |
| 332862 | 8 / 28672 | 160.031 | 1024 / 331776 | 21.031 |

The two-lane requests had an 18.297-second overlap between their nonempty SSE
output intervals, and 11 fresh status samples reported `running=2, waiting=0`.
This supports overlapping admitted work and output, not continuous simultaneous
GPU activity throughout all 18.297 seconds. The cached-token counts are part of
the result: this was not a two-lane fully cold long-prefill benchmark, and elapsed
times are not a throughput improvement claim.

A planned cancellation observed 17 delta events, establishing a lower bound of
16 generated tokens, and returned to idle in 0.235 seconds. No new OOM events or
swap-out increments were observed during the bounded run. The recipe's memory
guard and its thresholds were unchanged.

## Remaining coverage

The configured shared pool remains 1M tokens with two admitted lanes. Full-pool
capacity, long-running steady state, and two simultaneous fully cold long
prefills have not been validated. Tool-heavy `ns.msgs[:-1]` copying and alternating
accumulator chains still retain a quadratic path. These results add a bounded
serving regression to the [offline CPU evidence](README.md); they do not promote
0012 to a stable default or establish safety for arbitrary HTTP concurrency.

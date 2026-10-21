# Bounded 0012 / 0013 serving comparison

Both versions passed seven inference requests (six completed and one planned
cancellation) plus three tokenization requests. The baseline batch took 382.703
seconds and the candidate batch 370.203 seconds. The accepted 0012 default was
restored and its normal entry point verified afterward. **0013 remains
experimental and is not the selected default.** This is a single bounded run,
not a statistical latency or throughput benchmark.

Both sides used the same native binary and identical HTTP payload bytes. Only
the chat template changed. Each shape contains 3073 synthetic messages: 1024
assistant/two-tool rounds and one final-user instruction, with thinking disabled.
Only final-user padding differs across the three shapes. Tokenization checks
matched at 89228, 281600, and 332800 tokens, with matching token-ID hashes.
The [machine-readable aggregate](gpu-results.json) includes the hashes, counts,
timings, and measurement definitions; it contains no raw requests or machine logs.

## Memory results are mixed across shapes

The table reports sampled head-process RSS increase over each phase's own
pre-request median, in MiB. It is not GPU allocation or total model capacity.

| Shape and phase | 0012 | 0013 |
| --- | ---: | ---: |
| Compact tokenize | 174.227 | 42.418 |
| Compact warm repeat | 173.629 | 43.367 |
| Long A tokenize | 169.918 | 153.934 |
| Long A single inference | 161.996 | 168.777 |
| Long B tokenize | 203.055 | 220.773 |
| Long B single inference | 220.168 | 219.684 |
| Two-lane group, shared process peak | 321.586 | 337.887 |
| Planned cancellation | 221.773 | 232.359 |

Compact tokenize and warm-repeat increases fell by about 75.7% and 75.0%,
respectively. **That reduction does not generalize to the long shapes:** Long B
tokenization, the concurrent group, and cancellation had higher sampled peaks.
Long A inference also rose slightly, while Long B inference was nearly unchanged.
These observations do not isolate every allocation source or establish a uniform
memory improvement.

First inference is deliberately excluded from that comparison: the baseline
service had prior graph warmup, whereas the candidate was newly started. Its
176.035 / 218.988 MiB peaks and 33.707 / 209.313 MiB post-request increases are
therefore not controlled estimates of template benefit or evidence of a leak.
For the compact warm repeat, post-request residuals were -0.027 / 0.035 MiB.
For the concurrent group they were 67.836 / 70.344 MiB; observed idle does not
mean every reusable allocation has been freed.

RSS was sampled at 50 Hz; node observations were sampled at 1 Hz. Clock alignment
had approximately 0.15-0.16 seconds of uncertainty, which was included when
selecting peak windows. Sampled peaks can miss shorter transients. Do not compare
these values directly to the separate offline 5 ms sampling results.

## Serving, overlap, and cancellation

Long single requests produced eight output tokens each and reused 88064 input
tokens. Long A elapsed time was 108.765 / 110.312 seconds (0012 / 0013); Long B
was 147.016 / 146.813 seconds. For concurrent requests, each side produced 512
tokens per request, reusing 280576 / 331776 tokens for A / B. Candidate elapsed
times were 24.516 / 25.937 seconds, versus 34.532 / 36.547 for the baseline.
These are observations from one run with cached prefixes, not proof of a general
speedup or two fully cold long-prefill performance.

The candidate's nonempty SSE output intervals overlapped for 21.640 seconds,
with 11 fresh `running=2, waiting=0` samples and 10 consecutive sampled intervals
in which both outputs advanced. Baseline figures were 31.422 seconds, 10 samples,
and nine intervals. This demonstrates admitted overlap and output progress;
it does not prove simultaneous GPU kernels throughout the output interval.

Both planned cancellations observed 17 nonempty deltas, supporting a lower bound
of 16 generated tokens; final usage was unavailable. The release-check timer was
0.172 seconds for both. Measuring from the cancellation event to the first idle
observation instead gives 0.172 / 0.188 seconds. The aggregate explicitly names
both time origins.

No new OOM events, swap-out increments, or increase in swap used were observed
on either rank in either batch. The existing memory guard and thresholds were
unchanged. This does not establish protection against arbitrary future loads.

## Uncovered cases

The concurrent prompts total 614400 input tokens and share a history. Their total
being below 1M is not a general capacity guarantee or proof of independent cache
allocations. Full shared-pool occupancy, long-running steady state, arbitrary
HTTP concurrency, and two fully cold simultaneous long prefills remain untested.
Long `parts` lists can still displace the single prefix accumulator and leave
superlinear outer-list copying. The original incident is not fully attributed by
these measurements. Keep the accepted 0012 default while evaluating 0013 further.

# zig/patches

Patches to BertholomusAI's TensorFold fork at `TF_REF` (`scripts/config.sh`), applied in filename order by `zig/Dockerfile`
(`git apply` in the checkout's root). The image tag changes with them.

| Patch | Switch (both ranks) | Default | What it does |
| --- | --- | --- | --- |
| `0001-c7-indexer-split.patch` | `TF_DS_IDX_SPLIT=1` | off | splits the prefill indexer's row blocks between the two ranks (idea: drowzeys, GLM-5.3-Flash recipe) |
| `0002-c3-engram-lanes.patch` | `TF_DS_ENGRAM_LANES=2` | off | a second AIO ring for a prompt chunk's Engram reads |
| `0004-call-gate.patch` | none (always on) | **on** | enforces `tool_choice` `"required"` and a named function: the answer opens with the first token of the template's tool-call markup (for this model, the `<` before `｜DSML｜`) and finishes an offered tool name; requests without `tool_choice` are unchanged (taken from the spark1/spark2 deployment's copy of this recipe; tested: required and named choices return tool calls, auto/none/absent unchanged) |

With every switch unset, and for requests without a `tool_choice`, the engine behaves like the pinned one (`tools/exact.py` compares token hashes; bit-identity verified for 0001 and 0002 on the earlier pin; 0004 is checked by the same replay; the image of the current pin was not run on a pair). Remove a patch from
this folder to leave it out of the image; never run `scripts/prepare.sh` to rebuild with a partial cache.

`0003-c1-cache-placement.patch` (`TF_DS_CACHE_PLACEMENT=1`: a resumed prompt moves its kept rows to a free extent instead of over another
conversation's) is gone: the pin moved to `629c524`, whose `lanes.zig` does this itself (`placeSoft` leaves each kept extent room to grow, a
conversation that shares a prefix copies the shared rows to a free extent, `9f82099`/`629c524`), and the patch no longer applies to it. A
`TF_DS_CACHE_PLACEMENT` in your `scripts/local.sh` is ignored now.

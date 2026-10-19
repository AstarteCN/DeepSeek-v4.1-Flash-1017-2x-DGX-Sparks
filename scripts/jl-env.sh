# ENGINE=jl: the engine settings both ranks of Jay Leaton's CUDA DeepSeek-V4.1 Zig engine are started with.
# Sourced by start.sh and scripts/jl-prepare.sh after scripts/config.sh. The names, values and their order are the serving
# profile of https://github.com/jayleaton/deepseek-v41-tensorfold-spark (config/prod-zig-flash17.env.example at JL_REF,
# Jay Leaton, Apache-2.0; every knob is described in that repository's docs/ZIG-SERVE.md, "Serving settings"), with this
# recipe's settings (scripts/config.sh) filling in the values that are the user's: the window, the streams, the pool, the
# thinking default, the paths inside the containers. Two differences from his profile are deliberate:
#   - TF_DSV41_EXPERT_TOPP (decode routed-expert pruning, 0.85 in his profile) is off unless JL_EXPERT_TOPP is set: his own
#     measurements call it lossy (top-1 0.9944 against the unpruned engine), and this recipe's tools/exact.py checks that
#     what is served is exact;
#   - the NVMe session tier is JL_SESSION_DISK_GIB (32), not his 128 GiB.
# The AOT set (Triton programs, scripts/jl-prepare.sh) is enumerated from this environment: change a value that appears
# in jl_env_aot_hash's list and ./start.sh runs the prepare step again.

# Where the per-node folders are inside the containers
JL_ASSETS_IN=/assets JL_ENGRAM_IN=/engram JL_PREPARED_IN=/prepared JL_STATE_IN=/state JL_CACHE_IN=/cache JL_SESSIONS_IN=/sessions

# jl_env_build: JL_ENV=(KEY=VALUE ...), the profile, with any TF_DSV41_* or GLM53_TF_* variable you exported replacing its
# line (or added after the profile, when the profile has none).
jl_env_build() {
  local model; model=$(served_in_container)
  local -a e=(
    # --- decode
    TF_DSV41_R1=1
    TF_DSV41_DRAFTS=1
    TF_DSV41_OWN_PREFILL=1
    TF_DSV41_GRAPHS=1
    TF_DSV41_SAMPLING=1
    TF_DSV41_SLOTS="$PARALLEL"
    TF_DSV41_SLOT_DRAFTS=1
    TF_DSV41_CONTEXT="$CONTEXT"
    TF_DSV41_ASSETS="$JL_ASSETS_IN"
    # --- the paged KV pool shared by the slots (split KV: compressed KV rows sharded over the ranks)
    TF_DSV41_POOL_TOKENS="$JL_POOL_TOKENS"
    TF_DSV41_FORMS_INPLACE=1
    TF_DSV41_INDEX_KV=fp8
    TF_DSV41_ENGRAM_DIR="$JL_ENGRAM_IN"
    TF_DSV41_PREPARED="$JL_PREPARED_IN"
    TF_DSV41_PREPARED_WRITE=1
    TF_DSV41_PLAN_TIMEOUT=1800
    TF_DSV41_SESSIONS=1
    TF_DSV41_SESSION_RAM_MIB=256
    TF_DSV41_SESSION_DISK="$JL_SESSIONS_IN"
    TF_DSV41_SESSION_DISK_GIB="$JL_SESSION_DISK_GIB"
    TF_DSV41_SESSION_DISK_MIN=1024
    TF_DSV41_FLOOR_GIB=5
    TF_DSV41_FLOOR_HARD_GIB=4
    TF_DSV41_REQUEST_LOG="$JL_STATE_IN/requests.jsonl"
    TF_DSV41_DISCONNECT=1
    TF_DSV41_DRAIN_S=20
    TF_DSV41_SSE_KEEPALIVE_S=15
    TF_DSV41_THINKING="$THINKING"
    TF_DSV41_SCHEMA_PROMPT=1
    # --- images: DeepSeek's vision tower on rank 0, with the pack's own 43 learned image routing biases
    TF_DSV41_IMAGES=native
    TF_DSV41_BIAS_VL="$model"
    # --- transport and decode levers
    GLM53_TF_ROCE_MAX_KB=1024
    TF_DSV41_INDEX_BUDGET_MIB=64
    TF_DSV41_PREFETCH_AHEAD=1
    TF_DSV41_SPEC_DRAFT=1
    TF_DSV41_DRAFT_GRAPHS=1
    TF_DSV41_ROWS_CAP=64
    TF_DSV41_GRAMMAR=1
    TF_DSV41_TOOL_GRAMMAR=0
    TF_DSV41_PF_DENSE=fused
    TF_DSV41_PF_DENSE_TABLE="$JL_CACHE_IN/pfdense-table.json"
    TF_DSV41_PLAN_LINK=rdma
    TF_DSV41_PLAN_PIN=auto
    TF_DSV41_L2PF=1
    TF_DSV41_L2PF_MB=12
    TF_DSV41_L2PF_PACE_GBPS=150
    TF_DSV41_DEPTH_JOINT=0
    TF_DSV41_ENGRAM_GATE=1
    TF_DSV41_BRANCHES=1
    TF_DSV41_BRANCHES_PRIO=side
    TF_DSV41_MHC_DEFER=1
    GLM53_TF_ROCE_FAST=1
    TF_DSV41_GREEDY_GPU=1
    TF_DSV41_PREFILL=replay
    TF_DSV41_GM_V2=1
    # --- the measured serving set (his profile's "final serving set")
    TF_DSV41_PREFILL_PIECES=1
    TF_DSV41_SESSION_SLOTS=1
    TF_DSV41_TAIL_JOIN=1
    TF_DSV41_DRAFT_TIMED=1
    TF_DSV41_CODE_ACCEPT=0
    TF_DSV41_ROUTER_GROUP_ROT=1
    TF_DSV41_MHC_PFDEC=17
    TF_DSV41_DRAFT_BATCH_PROJ=1
    TF_DSV41_DRAFT_CHAIN=1
    TF_DSV41_DRAFT_OVERLAP=1
    TF_DSV41_ROUND_GRAPH=1
    TF_DSV41_KV_NORM_STORE=1
    TF_DSV41_LOOKUP_PLAN=1
    TF_DSV41_JOIN_DRAFTS=1
    TF_DSV41_PIECE_RUNS=1
    TF_DSV41_REPLAY_RUNS=1
    TF_DSV41_ENGRAM_AIO=1
    TF_DSV41_DRAFT_CAPTURE=1
    TF_DSV41_MHC_DEFER_AT=exchange
    TF_DSV41_LIN2=1
    TF_DSV41_GRAPH_FLOOR=hold
    TF_DSV41_PF_WS_SHARE=1
    TF_DSV41_INDEX_BOUND=1
    TF_DSV41_LOOKUP=1
    TF_DSV41_ENGRAM_PREFETCH=1
    # draft pricing from this engine's own boot measurement, stored per shape and read by later boots
    TF_DSV41_CALIB=zig
    TF_DSV41_CALIB_DIR="$JL_STATE_IN/calib-zig"
  )
  if [[ "$JL_KV_SPLIT" == 1 ]]; then e+=(TF_DSV41_KV_SPLIT=1 TF_DSV41_KV_SPLIT_COMPACT=1); fi
  if [[ "$JL_PF_4K" == 1 ]]; then
    # 4K prefill pieces (they fall back to 2K segments, same bits, when either rank cannot keep PF_WS_FLOOR_GIB free)
    e+=(TF_DSV41_PF_4K=1 TF_DSV41_PF_4K_MEMORY_OK=1 TF_DSV41_PREFILL_CHUNK=4096 TF_DSV41_PREFILL_ROWS=4096 TF_DSV41_PF_WS_FLOOR_GIB=3.5)
  else
    e+=(TF_DSV41_PF_4K=0 TF_DSV41_PREFILL_CHUNK=2048 TF_DSV41_PREFILL_ROWS=2048)
  fi
  [[ -z "$JL_EXPERT_TOPP" ]] || e+=("TF_DSV41_EXPERT_TOPP=$JL_EXPERT_TOPP")
  [[ -z "$REASONING_EFFORT" ]] || e+=("TF_DSV41_DEFAULT_EFFORT=$REASONING_EFFORT")
  [[ "$RDMA" == 1 ]] && e+=(TF_COMM_BACKEND=roce) || e+=(TF_COMM_BACKEND=nccl)
  # what the user exported wins, name by name
  local -A over=(); local n kv i
  while IFS= read -r n; do
    [[ "$n" =~ ^(TF_DSV41|GLM53_TF)_[A-Z0-9_]+$ ]] || continue
    over[$n]=${!n}
  done < <(compgen -e | LC_ALL=C sort)
  JL_ENV=()
  for kv in "${e[@]}"; do
    n=${kv%%=*}
    if [[ -n "${over[$n]+x}" ]]; then JL_ENV+=("$n=${over[$n]}"); unset "over[$n]"; else JL_ENV+=("$kv"); fi
  done
  for n in "${!over[@]}"; do JL_ENV+=("$n=${over[$n]}"); done
}

# jl_env_aot_hash: changes with every value the AOT set depends on, which for safety is the whole environment minus
# the folders and the values that cannot change a program's shape
jl_env_aot_hash() {
  printf '%s\n' "${JL_ENV[@]}" | LC_ALL=C sort |
    grep -vE '^(TF_DSV41_(ASSETS|ENGRAM_DIR|PREPARED|PREPARED_WRITE|SESSION_[A-Z_]+|REQUEST_LOG|CALIB_DIR|PF_DENSE_TABLE|THINKING|DEFAULT_EFFORT|DRAIN_S|SSE_KEEPALIVE_S|PLAN_TIMEOUT|FLOOR_GIB|FLOOR_HARD_GIB|DISCONNECT|SCHEMA_PROMPT|BIAS_VL)|TF_COMM_BACKEND)=' |
    sha256sum | cut -c1-16
}
# jl_env_args: the same environment as docker -e arguments (JL_ARGS)
jl_env_args() { JL_ARGS=(); local kv; for kv in "${JL_ENV[@]}"; do JL_ARGS+=(-e "$kv"); done; }

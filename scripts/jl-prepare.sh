#!/usr/bin/env bash
# ENGINE=jl: prepare two Sparks to serve Mia EAQ v1 2.9 bpw (optionally ABLIT=1) with Jay Leaton's CUDA DeepSeek-V4.1 Zig
# engine (https://github.com/jayleaton/deepseek-v41-tensorfold-spark, docs/jl-engine.md). ./start.sh runs this by itself when
# ENGINE=jl and something is not ready; run it alone to prepare while a server is up. Safe to re-run: every step skips work
# that is already done.
#   1. preflight: docker and the GPU on both Sparks, key-based ssh, the link between them, free disk on both
#   2. the images on this Spark (jl/Dockerfile at JL_REF: the engine, and the assets image on the NVIDIA PyTorch container),
#      then the engine image on the worker (docker save | docker load: only what it lacks is stored)
#   3. the checkpoint into HF_CACHE (~196 GiB, resumable) and Engram's two source shards (~203 GB), as prepare.sh does; the
#      served folder (the checkpoint linked, with the recipe's chat template); a read-only NFS volume of HF_CACHE on the worker
#   4. Engram's per-rank shards (engram-l{1,14}-r{rank}of2.bin, ~94 GiB a node) packed from the source shards on each node's
#      own disk (scripts/pack_engram.py of his repository), and checked against the source
#   5. the per-rank assets on this Spark: sigs.json, rope.bin, engram-host.bin and the AOT set (the Triton programs every
#      launch of this environment can need: `tf-dsv41-m1 aot-needs` lists them, `triton_fill.py compile` builds the missing
#      ones; the first time ~1 hour of CPU), then copied to the worker; the dense-prefill tuning table on both
# The engine writes its prepared weight images (~95 GB a node) on its first start. Pass --rebuild to rebuild the images from
# scratch. --skip-engram leaves out step 4 (and the disk it needs): everything else is made, but the setup is not marked
# ready, so ./start.sh still prepares Engram's shards before it starts. VERIFY_SHA=1 also checks Engram's source shards against
# the sha256 the model card lists. JL_COMPILE_CPUS=N limits the Triton compile's CPUs (docker --cpus).
# Taken from his repository's docs/ZIG-SERVE.md, scripts/run-zig.sh, docker/zig/Dockerfile and scripts/pack_engram.py (Jay
# Leaton, Apache-2.0): the steps, the commands and the files they make; the node discovery, NFS volume and checkpoint
# handling are this recipe's (scripts/prepare.sh).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
export ENGINE=jl
source ./scripts/config.sh
source ./scripts/nodes.sh

REBUILD=0; SKIP_ENGRAM=0
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --skip-engram) SKIP_ENGRAM=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
ablit_notice
[[ "$DRAFTS" == 1 ]] || die "ENGINE=jl serves with drafts (DRAFTS=1): its profile was measured and its AOT set built that way"
ASSETS_IMAGE="$IMAGE-assets"
UIDGID="$(id -u):$(id -g)"
# a container's view of HF_CACHE (the snapshot's files are links into ../../blobs)
in_hf() { docker run --rm --network none --user "$UIDGID" -e HOME=/tmp -v "$HF_CACHE:/hf" "$@"; }
gib() { echo $(( $1 / 1024 ** 3 )); }

# ---------------------------------------------------------------- 1. preflight
mkdir -p "$STATE_DIR" "$HF_CACHE/hub"
exec 9>"$STATE_DIR/prepare.lock"
flock -n 9 || die "another prepare.sh is already running; wait for it or stop it: pgrep -af prepare.sh"
if [[ "$ABLIT" == 1 ]]; then
  command -v hf >/dev/null || die "install the Hugging Face CLI: pip install -U huggingface_hub"
  log "Downloading the matching Mia 2.9 bpw overlay from $ABLIT_ID @ ${ABLIT_REVISION:0:8}"
  hf download "$ABLIT_ID" --revision "$ABLIT_REVISION" --cache-dir "$HF_CACHE/hub" \
    --include apply_mia29_wo_b_graft.py --include "$ABLIT_SIDECAR" --include EXL3_MIA29_ABLIT_META.json --include README.md >/dev/null || \
    die "cannot download the gated overlay: use your HF read token (HF_TOKEN or hf auth login) and obtain access at https://huggingface.co/$ABLIT_ID"
fi
log "Preflight checks on both Sparks"
command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is your user in the docker group?)"
nvidia-smi -L >/dev/null 2>&1 || warn "nvidia-smi failed on this node: is the NVIDIA driver working?"
check_workers
need_worker 1
worker 1 'docker info >/dev/null 2>&1' || die "$(worker_host 1) cannot talk to its docker daemon (docker group?)"
worker 1 'nvidia-smi -L >/dev/null 2>&1' || warn "nvidia-smi failed on $(worker_host 1)"
detect_links
log "Link: this node $HEAD_ADDR ($HEAD_DEV, RoCE $HEAD_HCAS) <-> $(worker_host 1) $WORKER_ADDR ($WORKER_DEV, RoCE $WORKER_HCAS); NFS from $(nfs_server 1)"

H_ENGRAM=$(jl_engram_dir "$JL_ROOT");  W_ENGRAM=$(jl_engram_dir "$WORKER_JL_ROOT")
H_ASSETS=$(jl_assets_dir "$JL_ROOT");  W_ASSETS=$(jl_assets_dir "$WORKER_JL_ROOT")
H_PREP=$(jl_prepared_dir "$JL_ROOT");  W_PREP=$(jl_prepared_dir "$WORKER_JL_ROOT")
H_STATE=$(jl_state_dir "$JL_ROOT");    W_STATE=$(jl_state_dir "$WORKER_JL_ROOT")
H_CACHE=$(jl_cache_dir "$JL_ROOT");    W_CACHE=$(jl_cache_dir "$WORKER_JL_ROOT")
mkdir -p "$H_ENGRAM" "$H_ASSETS" "$H_PREP" "$H_STATE/sessions" "$H_CACHE"
worker 1 "mkdir -p $W_ENGRAM $W_ASSETS $W_PREP $W_STATE/sessions $W_CACHE"

# Disk: what each node still has to write (Engram's shards, the engine's prepared weight images on its first start, the
# assets), against what it has free; the numbers are his docs/INSTALL.md's (~94 GiB, ~95 GB) with a margin.
engram_done() { # <dir>: both of a node's shards are there at their final size (~47 GiB each)
  local f n=0; for f in "$1"/engram-l*-r*of2.bin; do [[ -f $f ]] && (( $(stat -L -c %s "$f") > 40 * 1024 ** 3 )) && n=$((n + 1)); done; (( n == 2 ))
}
prepared_done() { (( $(du -sb "$1" 2>/dev/null | cut -f1) > 80 * 1024 ** 3 )); }   # the engine's prepared weight images: ~95 GB a node, many files
if [[ "${SKIP_DISK_CHECK:-0}" != 1 ]]; then
  need_h=15; (( SKIP_ENGRAM )) || engram_done "$H_ENGRAM" || need_h=$((need_h + 96)); prepared_done "$H_PREP" || need_h=$((need_h + 100))
  free_h=$(gib "$(df -B1 --output=avail "$JL_ROOT" 2>/dev/null | tail -1 || echo 0)")
  (( free_h >= need_h )) || die "$JL_ROOT has $free_h GiB free here; ENGINE=jl still has to write ~$need_h GiB on this Spark (Engram's shards ~96, the engine's prepared weight images ~100 on its first start, assets). Free the disk or point JL_ROOT at a bigger one; SKIP_DISK_CHECK=1 skips this check"
  need_w=15
  (( SKIP_ENGRAM )) || worker 1 "ls $W_ENGRAM/engram-l*-r*of2.bin 2>/dev/null | wc -l" | grep -qx 2 || need_w=$((need_w + 96))
  (( $(worker 1 "du -sb $W_PREP 2>/dev/null | cut -f1") > 80 * 1024 ** 3 )) || need_w=$((need_w + 100))
  free_w=$(gib "$(worker 1 "df -B1 --output=avail $W_ENGRAM | tail -1")")
  (( free_w >= need_w )) || die "$(worker_host 1):$WORKER_JL_ROOT has $free_w GiB free; ENGINE=jl still has to write ~$need_w GiB there. Free the disk or set WORKER_JL_ROOT; SKIP_DISK_CHECK=1 skips this check"
fi

# ---------------------------------------------------------------- 2. the images
hash=$(image_hash)
built=$(docker image inspect -f '{{index .Config.Labels "tf.patches"}}' "$IMAGE" 2>/dev/null || true)
if [[ $REBUILD -eq 1 || "$built" != "$hash" ]] || ! docker image inspect "$ASSETS_IMAGE" >/dev/null 2>&1; then
  log "Building $IMAGE (his engine ${JL_REF:0:12} on $JL_CUDA_DEVEL, Zig $ZIG_VERSION; the Zig build compiles the kernels for sm_121, ~15 min on a Spark)"
  ctx=$(mktemp -d "$STATE_DIR/build.XXXXXX")
  trap 'rm -rf -- "$ctx"' EXIT
  cp jl/Dockerfile "$ctx/Dockerfile"
  nocache=(); [[ $REBUILD -eq 1 ]] && nocache=(--no-cache)
  bargs=(--build-arg BASE_IMAGE="$BASE_IMAGE" --build-arg JL_REPO="$JL_REPO" --build-arg JL_REF="$JL_REF"
         --build-arg JL_PY_REPO="$JL_PY_REPO" --build-arg JL_PY_REF="$JL_PY_REF"
         --build-arg CUDA_DEVEL="$JL_CUDA_DEVEL" --build-arg CUDA_RUNTIME="$JL_CUDA_RUNTIME"
         --build-arg ZIG_VERSION="$ZIG_VERSION" --build-arg ZIG_SHA256="$ZIG_SHA256" --build-arg PATCHES_HASH="$hash")
  docker build "${nocache[@]}" --target assets -t "$ASSETS_IMAGE" -f "$ctx/Dockerfile" "${bargs[@]}" "$ctx"
  docker build -t "$IMAGE" -f "$ctx/Dockerfile" "${bargs[@]}" "$ctx"
  rm -rf -- "$ctx"; trap - EXIT
else
  log "Image $IMAGE already built (hash $hash; --rebuild forces it)"
fi
ident=$(image_ident "$IMAGE")
if [[ "$(worker_image_ident 1 "$IMAGE")" != "$ident" ]]; then
  log "Copying $IMAGE to $(worker_host 1) (docker save | docker load; only missing layers are stored)"
  docker save "$IMAGE" | worker 1 docker load >/dev/null
  [[ "$(worker_image_ident 1 "$IMAGE")" == "$ident" ]] || die "$(worker_host 1)'s $IMAGE differs from this Spark's"
fi
log "Image $IMAGE identical on both Sparks"
# the worker runs BASE_IMAGE's Python for Engram's packing and its file checks (the engine image has none)
if ! worker 1 "docker image inspect '$BASE_IMAGE' >/dev/null 2>&1"; then
  log "Pulling $BASE_IMAGE on $(worker_host 1)"
  worker 1 "docker pull '$BASE_IMAGE' >/dev/null" || die "$(worker_host 1) cannot pull $BASE_IMAGE: pull or load it there, then run this again"
fi

# ---------------------------------------------------------------- 3. the checkpoint, Engram's source shards, the served folder
# (the same downloads, checks and ABLIT overlay as scripts/prepare.sh, with the assets image's Python)
command -v hf >/dev/null || die "the Hugging Face CLI ('hf') is not installed on this Spark: pip install -U huggingface_hub"
log "Downloading $MODEL_ID${MODEL_REVISION:+ @ ${MODEL_REVISION:0:8}} into $HF_CACHE/hub (196 GiB the first time; resumes)"
if ! hf download "$MODEL_ID" ${MODEL_REVISION:+--revision "$MODEL_REVISION"} --cache-dir "$HF_CACHE/hub" >/dev/null; then
  [[ -n "$MODEL_REVISION" && -f "$(model_cache_dir)/snapshots/$MODEL_REVISION/model.safetensors.index.json" ]] || die "$MODEL_ID: the download failed"
  warn "$MODEL_ID: could not reach Hugging Face; using the snapshot already here"
fi
SNAP="$(model_cache_dir)/snapshots/$(snapshot_rev)"
[[ -f "$SNAP/model.safetensors.index.json" ]] || die "$MODEL_ID: no complete snapshot at $SNAP"
log "Checkpoint: $SNAP ($(du -shL "$SNAP" | cut -f1))"
shards=($ENGRAM_SHARDS)
inc=(--include model.safetensors.index.json --include config.json); for f in "${shards[@]}"; do inc+=(--include "$f"); done
log "Downloading Engram's source shards: ${ENGRAM_SHARDS// /, } of $ENGRAM_ID${ENGRAM_REVISION:+ @ ${ENGRAM_REVISION:0:8}} (~203 GB the first time; resumes)"
if ! hf download "$ENGRAM_ID" ${ENGRAM_REVISION:+--revision "$ENGRAM_REVISION"} --cache-dir "$HF_CACHE/hub" "${inc[@]}" >/dev/null; then
  [[ -n "$ENGRAM_REVISION" ]] || die "$ENGRAM_ID: the download failed"
  warn "$ENGRAM_ID: could not reach Hugging Face; using the files already here"
fi
ESNAP="$(engram_cache_dir)/snapshots/$(engram_rev)"
declare -A want_size=([model-00047-of-00048.safetensors]=101535150936 [model-00048-of-00048.safetensors]=101537926640)
declare -A want_sha=([model-00047-of-00048.safetensors]=76a05106ece259be83d1bfea0dcb54f23377864ee60fd321690f35e6698a2af5
                     [model-00048-of-00048.safetensors]=9dc51433e195bc78b5ad846b68643cc0351d3b174e5e4309222d3b7402c83afd)
for f in model.safetensors.index.json config.json "${shards[@]}"; do [[ -s "$ESNAP/$f" ]] || die "$ENGRAM_ID: $ESNAP/$f is missing"; done
if [[ "$ENGRAM_ID" == deepseek-ai/DeepSeek-V4.1-Flash-1017 ]]; then
  for f in "${shards[@]}"; do
    [[ -n "${want_size[$f]:-}" ]] || continue
    [[ "$(stat -L -c %s "$ESNAP/$f")" == "${want_size[$f]}" ]] ||
      die "$f is $(stat -L -c %s "$ESNAP/$f") bytes, not the 1017 release's ${want_size[$f]}: remove $ESNAP and download again"
    if [[ "${VERIFY_SHA:-0}" == 1 ]]; then
      log "sha256 of $f"
      [[ "$(sha256sum "$ESNAP/$f" | cut -d' ' -f1)" == "${want_sha[$f]}" ]] || die "$f does not match the model card's sha256"
    fi
  done
fi
log "Engram source: $ESNAP ($(du -shL "$ESNAP" | cut -f1))"
if [[ "$ABLIT" == 1 ]]; then
  overlay_sub="hub/models--${ABLIT_ID//\//--}/snapshots/$ABLIT_REVISION"
  for f in apply_mia29_wo_b_graft.py "$ABLIT_SIDECAR" EXL3_MIA29_ABLIT_META.json; do
    [[ -s "$HF_CACHE/$overlay_sub/$f" ]] || die "matching Mia overlay file is missing: $f"
  done
  mkdir -p "$DATA_DIR"
  if [[ ! -f "$DATA_DIR/checkpoint/.ablit-ready" ]]; then
    log "Applying the Mia EAQ 2.9 bpw overlay in $DATA_DIR/checkpoint (stock stays intact; changed shards need extra disk)"
    rm -rf "$DATA_DIR/checkpoint.new" "$DATA_DIR/stock.new"
    mkdir -p "$DATA_DIR/stock.new"
    cp -alL "$SNAP/." "$DATA_DIR/stock.new/"
    in_hf --entrypoint python3 "$ASSETS_IMAGE" "/hf/$overlay_sub/apply_mia29_wo_b_graft.py" \
      --src "/hf/$DATA_SUB/stock.new" --dst "/hf/$DATA_SUB/checkpoint.new" \
      --wo-b "/hf/$overlay_sub/$ABLIT_SIDECAR" || die "applying the matching Mia overlay failed; rerun prepare.sh to retry"
    python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["n_edited"] == 104, "expected 104 Mia overlay tensors"' \
      "$DATA_DIR/checkpoint.new/ABLIT_META.json" || die "Mia overlay did not replace all 104 tensors"
    touch "$DATA_DIR/checkpoint.new/.ablit-ready"
    rm -rf "$DATA_DIR/checkpoint"
    mv "$DATA_DIR/checkpoint.new" "$DATA_DIR/checkpoint"
    rm -rf "$DATA_DIR/stock.new"
  else
    log "Matching Mia overlay checkpoint: ready"
  fi
  SNAP="$DATA_DIR/checkpoint"
fi
SNAP_C=$(model_in_container)
ESNAP_C="/hf/hub/models--${ENGRAM_ID//\//--}/snapshots/$(engram_rev)"
# the image routing bias: the engine reads the 43 gate.bias_vl tensors from the folder TF_DSV41_BIAS_VL names (the served folder)
nbias=$(python3 -I -c 'import json,sys; print(sum("bias_vl" in k for k in json.load(open(sys.argv[1]))["weight_map"]))' "$SNAP/model.safetensors.index.json")
[[ "$nbias" == 43 ]] || die "$MODEL_ID holds $nbias of the 43 gate.bias_vl tensors: the engine refuses to boot images without them (TF_DSV41_BIAS_VL names the served folder). Use a checkpoint that keeps them"
# the served folder: every file of the snapshot as a relative link (it resolves under /hf in a container too), and the
# recipe's chat template
mkdir -p "$DATA_DIR"
VIEW="$DATA_DIR/model"
rm -rf "$VIEW.new" && mkdir -p "$VIEW.new"
for f in "$SNAP"/*; do ln -s "$(realpath -s --relative-to="$VIEW.new" "$f")" "$VIEW.new/"; done
rm -f "$VIEW.new/chat_template.jinja"
cp model/chat_template.jinja "$VIEW.new/chat_template.jinja"
# his engine loads a router bias only as F32; Mia's pack keeps the three DSpark blocks' biases as F16 (an exact widening, in
# copies of the shards that hold them, beside the checkpoint: scripts/jl-fixup-pack.py)
mapfile -t fixed < <(in_hf -v "$PWD/scripts/jl-fixup-pack.py:/fixup.py:ro" --entrypoint python3 "$ASSETS_IMAGE" /fixup.py "$SNAP_C" "/hf/$DATA_SUB/jl-shards") ||
  die "could not widen the DSpark router biases to F32 (scripts/jl-fixup-pack.py)"
for f in "${fixed[@]}"; do
  [[ -n "$f" ]] || continue
  log "Served folder: $f with the DSpark router biases and confidence head widened from F16 to F32 (his engine loads them only as F32)"
  rm -f "$VIEW.new/$f"; ln -s "$(realpath -s --relative-to="$VIEW.new" "$DATA_DIR/jl-shards/$f")" "$VIEW.new/$f"
done
rm -rf "$VIEW" && mv "$VIEW.new" "$VIEW"
[[ -s "$VIEW/config.json" ]] || die "the served folder $VIEW does not reach the checkpoint"
log "Served folder: $VIEW (the checkpoint linked, the recipe's chat template)"
# the worker's read-only NFS volume of HF_CACHE
manifest() {
  (cd "$HF_CACHE" && find -L "hub/models--${MODEL_ID//\//--}/snapshots/$(snapshot_rev)" \
     "hub/models--${ENGRAM_ID//\//--}/snapshots/$(engram_rev)" "$DATA_SUB/model" \
     -path '*/.git' -prune -o -type f -printf '%p %s\n' | LC_ALL=C sort)
}
want=$(manifest)
ensure_nfs_volume 1
if ! out=$(worker 1 "docker run --rm --entrypoint true -v '$NFS_VOLUME:/hf:ro' '$IMAGE'" 2>&1); then
  die "$(worker_host 1) cannot mount this Spark's :$NFS_PATH from $(nfs_server 1) over NFS ($NFS_VOLUME): $(tail -1 <<<"$out")
    This Spark must export HF_CACHE (as $NFS_PATH) read-only to that worker's address on its link (README: NFS)"
fi
have=$(worker 1 "docker run --rm --network none -v '$NFS_VOLUME:/hf:ro' -w /hf --entrypoint find '$BASE_IMAGE' -L 'hub/models--${MODEL_ID//\//--}/snapshots/$(snapshot_rev)' 'hub/models--${ENGRAM_ID//\//--}/snapshots/$(engram_rev)' '$DATA_SUB/model' -path '*/.git' -prune -o -type f -printf '%p %s\n'" 2>/dev/null | LC_ALL=C sort || true)
[[ "$have" == "$want" ]] || { diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") | head -10 >&2
  die "$(worker_host 1) does not see every file over NFS ($NFS_VOLUME)"; }
log "Worker ($(worker_host 1)) reads the checkpoint, the Engram source shards and the served folder over NFS"

# ---------------------------------------------------------------- 4. Engram's per-rank shards, on each node's own disk
PACK=/opt/tensorfold-jl/pack_engram.py
pack_args=(--src "$ESNAP_C" --config "$SNAP_C/config.json")
if (( SKIP_ENGRAM )); then
  warn "--skip-engram: Engram's per-rank shards are not packed or checked"
elif engram_done "$H_ENGRAM" && in_hf --entrypoint python3 -v "$H_ENGRAM:/engram:ro" "$ASSETS_IMAGE" $PACK "${pack_args[@]}" --check /engram --rank 0 >/dev/null 2>&1; then
  log "Engram shards of rank 0: ready and checked against the source ($H_ENGRAM)"
else
  log "Packing Engram's shards of rank 0 into $H_ENGRAM (~94 GiB; reads $(( $(stat -L -c %s "$ESNAP/${shards[0]}") * 2 / 1024 ** 3 )) GiB of source)"
  in_hf --entrypoint python3 -v "$H_ENGRAM:/engram" "$ASSETS_IMAGE" $PACK "${pack_args[@]}" --out /engram --rank 0 | tr '\r' '\n' | grep -v '%' || true
  in_hf --entrypoint python3 -v "$H_ENGRAM:/engram:ro" "$ASSETS_IMAGE" $PACK "${pack_args[@]}" --check /engram --rank 0 ||
    die "the packed Engram shards of rank 0 do not match the source"
fi
wpack() { # <extra pack args...>: his pack_engram.py (from the assets image here), run on the worker from the NFS volume
  docker run --rm --entrypoint cat "$ASSETS_IMAGE" $PACK |
    worker 1 "docker run -i --rm --network none --user \$(id -u):\$(id -g) -e HOME=/tmp -v '$NFS_VOLUME:/hf:ro' -v $W_ENGRAM:/engram '$BASE_IMAGE' python3 - ${pack_args[*]} $*"
}
if (( SKIP_ENGRAM )); then :
elif worker 1 "ls $W_ENGRAM/engram-l*-r1of2.bin 2>/dev/null | wc -l" | grep -qx 2 && wpack --check /engram --rank 1 >/dev/null 2>&1; then
  log "Engram shards of rank 1 on $(worker_host 1): ready and checked against the source"
else
  log "Packing Engram's shards of rank 1 on $(worker_host 1) into $W_ENGRAM (~94 GiB, from the NFS volume)"
  wpack --out /engram --rank 1 | tr '\r' '\n' | grep -v '%' || true
  wpack --check /engram --rank 1 || die "the packed Engram shards of rank 1 do not match the source"
fi

# ---------------------------------------------------------------- 5. assets: sigs.json, rope.bin, engram-host.bin, the AOT set
jl_env_build; jl_env_args
envhash=$(jl_env_aot_hash)
TOOLS=/opt/tensorfold-jl/tools
PYSRC=/opt/tensorfold-jl/py/src
cfg_c="$SNAP_C/config.json"
in_assets() { in_hf -v "$H_ASSETS:/assets" -e TRITON_CACHE_DIR=/tmp/triton-cache "$@"; }
[[ -s "$H_ASSETS/sigs.json" ]] || { log "Triton signatures of the reference tree (sigs.json)"
  in_assets --entrypoint python3 "$ASSETS_IMAGE" $TOOLS/triton_fill.py sigs --py $PYSRC --out /assets/sigs.json >/dev/null; }
need_rows=$(( CONTEXT + 2048 ))
rope_rows=0; [[ -s "$H_ASSETS/rope.bin" ]] && rope_rows=$(od -An -t u4 -j 8 -N 4 "$H_ASSETS/rope.bin" | tr -d ' ')
if (( rope_rows < need_rows )); then
  log "RoPE tables for a $CONTEXT-token window ($need_rows rows)"
  in_assets --entrypoint python3 -e PYTHONPATH=$PYSRC "$ASSETS_IMAGE" $TOOLS/dsv41_rope_tables.py --config "$cfg_c" --rows "$need_rows" --out /assets/rope.bin >/dev/null
fi
[[ -s "$H_ASSETS/engram-host.bin" ]] || { log "Engram's host lookup (engram-host.bin) from the checkpoint's tokenizer"
  in_assets --entrypoint python3 -e PYTHONPATH=$PYSRC "$ASSETS_IMAGE" $TOOLS/dsv41_engram_host.py --py-src $PYSRC --config "$cfg_c" \
    --tokenizer "$SNAP_C/tokenizer.json" --out /assets/engram-host.bin >/dev/null; }
# the AOT set: aot-needs (host work, the runtime image) lists every Triton program this environment launches; what aot/ lacks
# is compiled (the assets image: Triton 3.7.1, ptxas 13.3.73) and the set checked again. A mark records the environment and image
# it covers, so a re-run with the same settings skips the ~11 minutes the listing takes.
aot_mark="$envhash $ident"
aot_needs() { # [aot dir]: tf-dsv41-m1 aot-needs over this environment; exit 1 lists what the dir lacks
  docker run --rm --init --network none --user "$UIDGID" -e HOME=/tmp -v "$H_ASSETS:/assets" "${JL_ARGS[@]}" -e TF_TP_WORLD=2 "$IMAGE" \
    tf-dsv41-m1 aot-needs /assets/sigs.json /assets/needs.json "$@"
}
if [[ -f "$H_ASSETS/aot/aot.json" && "$(cat "$H_ASSETS/.aot-ok" 2>/dev/null)" == "$aot_mark" ]]; then
  log "AOT set: covers this environment (mark $envhash)"
else
  if [[ -f "$H_ASSETS/aot/aot.json" ]] && aot_needs /assets/aot >/dev/null 2>&1; then
    log "AOT set: covers this environment"
  else
    log "AOT set: listing the programs this environment launches (host only, ~11 minutes)"
    aot_needs >/dev/null || die "aot-needs failed: see above"
    haveargs=(); [[ -f "$H_ASSETS/aot/aot.json" ]] && haveargs=(--have /assets/aot)
    log "AOT set: compiling the missing Triton programs (CPU, ptxas 13.3.73; the first time ~1 hour)"
    in_assets ${JL_COMPILE_CPUS:+--cpus "$JL_COMPILE_CPUS"} --entrypoint python3 -e PYTHONPATH=$PYSRC "$ASSETS_IMAGE" $TOOLS/triton_fill.py compile --py $PYSRC --needs /assets/needs.json \
      --options $TOOLS/dsv41_triton_options.json --arch 121 "${haveargs[@]}" --out /assets/aot ||
      die "the Triton compile failed: see above"
    aot_needs /assets/aot >/dev/null || die "aot/ still lacks programs this environment launches (see $H_ASSETS/needs.json)"
  fi
  printf '%s\n' "$aot_mark" > "$H_ASSETS/.aot-ok"
fi
# the dense-prefill tuning table (his GB10 measurements), beside the state on both nodes
docker run --rm --entrypoint cat "$ASSETS_IMAGE" /opt/tensorfold-jl/pfdense-table.json > "$H_CACHE/pfdense-table.json.new" && mv "$H_CACHE/pfdense-table.json.new" "$H_CACHE/pfdense-table.json"
worker 1 "cat > $W_CACHE/pfdense-table.json" < "$H_CACHE/pfdense-table.json"
# the assets to the worker (the same files serve both ranks), unless it already has them
amanifest() { find rope.bin engram-host.bin sigs.json aot -type f -printf '%p %s\n' | LC_ALL=C sort | sha256sum | cut -c1-16; }
h_sum=$(cd "$H_ASSETS" && amanifest)
w_sum=$(worker 1 "cd $W_ASSETS && $(declare -f amanifest) && amanifest" 2>/dev/null || true)
if [[ "$h_sum" != "$w_sum" ]]; then
  log "Copying the assets to $(worker_host 1) ($(du -sh "$H_ASSETS" | cut -f1))"
  worker 1 "rm -rf $W_ASSETS && mkdir -p $W_ASSETS"
  tar -C "$H_ASSETS" -cf - rope.bin engram-host.bin sigs.json aot | worker 1 "tar -C $W_ASSETS -xf -"
  w_sum=$(worker 1 "cd $W_ASSETS && $(declare -f amanifest) && amanifest")
  [[ "$h_sum" == "$w_sum" ]] || die "the assets on $(worker_host 1) differ from this Spark's after the copy"
fi
log "Assets: identical on both Sparks"

if (( SKIP_ENGRAM )); then
  log "Done, except Engram's shards (--skip-engram): the setup is not marked ready; run this again without it to pack them."
  exit 0
fi
prepared_state > "$PREPARED_MARKER"
log "Done: both Sparks are ready. Start the server with ENGINE=jl ./start.sh (port $PORT). The engine writes its prepared weight images (~95 GB a node) on its first start, so that start takes longer."

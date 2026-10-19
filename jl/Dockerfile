# The ENGINE=jl image (both ranks): Jay Leaton's CUDA DeepSeek-V4.1 Zig engine, the `engine/zig` export of
# https://github.com/jayleaton/deepseek-v41-tensorfold-spark (JL_REPO at JL_REF), built on TensorFold 1.0.2. The build
# stage and the runtime stage follow that repository's docker/zig/Dockerfile (Jay Leaton, Apache-2.0); what differs is
# that the source is fetched at the pinned commit instead of copied from a checkout, Zig comes with a checked sha256, and
# two more stages exist:
#   assets   FROM the NVIDIA PyTorch container (Triton 3.7.1 and ptxas 13.3.73, the toolchain his Triton fill was
#            qualified with): the reference Python tree (TensorFold at JL_PY_REF with his patches/*.patch applied),
#            his asset generators (engine/zig/tools/zig), scripts/pack_engram.py and config/pfdense-table.json. It makes
#            the per-rank assets (sigs.json, aot/, rope.bin, engram-host.bin) and packs Engram; it never serves.
#   (last)   the runtime image: tensorfold-dsv41 and tf-dsv41-m1 on the CUDA base, with NCCL, verbs and cuBLAS 13.6.0.2.
# Built by scripts/jl-prepare.sh, never by hand: it passes the build arguments and a build context of this file only.
# No GPU is needed to build.
ARG CUDA_DEVEL=nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04
ARG CUDA_RUNTIME=nvcr.io/nvidia/cuda:13.0.1-base-ubuntu24.04
ARG BASE_IMAGE=nvcr.io/nvidia/pytorch:26.07-py3

FROM ${CUDA_DEVEL} AS build
ARG ZIG_VERSION
ARG ZIG_SHA256
# the GB10's ARMv8 crypto extensions for the host code (his Dockerfile: std's SHA-256 runs in software on the generic
# aarch64 baseline; adds instructions only, no float code changes)
ARG ZIG_CPU=baseline+sha2+aes
ARG ZIG_TARGET=aarch64-linux-gnu
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates xz-utils git patch \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-linux-${ZIG_VERSION}.tar.xz" && \
    echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - && \
    mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz && \
    /opt/zig/zig version
ENV PATH=/opt/zig:/usr/local/cuda/bin:$PATH

ARG JL_REPO
ARG JL_REF
RUN git init -q /ctx && cd /ctx && git remote add origin "${JL_REPO}" && \
    git fetch -q --depth 1 origin "${JL_REF}" && git checkout -q --detach FETCH_HEAD && \
    test "$(git rev-parse HEAD)" = "${JL_REF}"
WORKDIR /ctx/engine/zig
# no prebuilt fatbins: tp_mailbox with nvcc here, the rest through zig build -Dnvcc (as his Dockerfile does without fatbins/)
RUN set -eu; \
    echo "building with $(nvcc --version | tail -1)"; \
    nvcc -fatbin -O3 -std=c++17 -gencode=arch=compute_120,code=sm_120 -gencode=arch=compute_121,code=sm_121 \
        -gencode=arch=compute_90,code=compute_90 -o /tp_mailbox.fatbin zig/src/fabric/tp/mailbox.cu; \
    zig build -Dtarget="$ZIG_TARGET" -Dcpu="$ZIG_CPU" -Dnvcc=/usr/local/cuda/bin/nvcc -Dtp-fatbin=/tp_mailbox.fatbin \
        -Dsm=121 -Doptimize=ReleaseSafe -j4 --prefix /out install; \
    test -x /out/bin/tensorfold-dsv41 && test -x /out/bin/tf-dsv41-m1

# the reference Python tree the asset generators read: TensorFold at JL_PY_REF with his patches applied in order (his
# docs/ZIG-SERVE.md, "Generate runtime assets")
ARG JL_PY_REPO
ARG JL_PY_REF
RUN git init -q /py-git && cd /py-git && git remote add origin "${JL_PY_REPO}" && \
    git fetch -q --depth 1 origin "${JL_PY_REF}" && git checkout -q --detach FETCH_HEAD && \
    test "$(git rev-parse HEAD)" = "${JL_PY_REF}" && \
    mkdir /py && git archive HEAD | tar -x -C /py && \
    for p in /ctx/patches/*.patch; do echo "applying $p"; patch -d /py -p1 < "$p" || exit 1; done

FROM ${BASE_IMAGE} AS assets
COPY --from=build /py /opt/tensorfold-jl/py
COPY --from=build /ctx/engine/zig/tools/zig /opt/tensorfold-jl/tools
COPY --from=build /ctx/scripts/pack_engram.py /opt/tensorfold-jl/pack_engram.py
COPY --from=build /ctx/config/pfdense-table.json /opt/tensorfold-jl/pfdense-table.json
RUN python3 -m pip install --no-cache-dir safetensors
ENV TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas TRITON_PTXAS_BLACKWELL_PATH=/usr/local/cuda/bin/ptxas \
    PY_SOURCE=/opt/tensorfold-jl/py/src
WORKDIR /opt/tensorfold-jl/tools

FROM ${CUDA_RUNTIME}
ARG JL_REF=unknown
ARG PATCHES_HASH
# libnccl2 from the CUDA apt repo the nvidia images ship configured; libibverbs + the mlx5 provider for RoCE; cuBLAS /
# cuBLASLt pinned at 13.6.0.2 (libcublas-13-3, the same repo): the build the vision tower's bit-exact proof ran on, dlopened
# only with TF_DSV41_IMAGES=native. Its directory goes on the loader path (the base image's points at its own CUDA).
RUN apt-get update && apt-get install -y --no-install-recommends libnccl2 libibverbs1 ibverbs-providers rdma-core \
        curl ca-certificates libcublas-13-3=13.6.0.2-1 \
    && apt-mark hold libcublas-13-3 \
    && dirname "$(dpkg -L libcublas-13-3 | grep '/libcublas\.so\.13$')" > /etc/ld.so.conf.d/990_cublas-13-3.conf && ldconfig \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/bin/tensorfold-dsv41 /out/bin/tf-dsv41-m1 /opt/tensorfold/bin/
COPY --from=build /tp_mailbox.fatbin /opt/tensorfold/share/tp_mailbox.fatbin
COPY --from=build /ctx/engine/zig/LICENSE /ctx/engine/zig/NOTICE /ctx/engine/zig/THIRD_PARTY_NOTICES.md /opt/tensorfold/share/doc/tensorfold/
COPY --from=build /ctx/engine/zig/LICENSES /opt/tensorfold/share/doc/tensorfold/LICENSES
# libproof (his docker/zig/Dockerfile): every library name the engine can dlopen is covered, each resolves here with its
# whole NEEDED chain, and cuBLAS / cuBLASLt are the pinned 13.6.0.2 files by sha256; any miss or other build fails the build
COPY <<'EOF' /opt/tensorfold/share/libproof.sh
#!/bin/bash
set -u
need="libnccl.so.2 libibverbs.so.1 libcublas.so.13 libcublasLt.so.13"
pins="8062c27c479c249292b48c4bc73af1deb22edee4dfff191fb48a7491ac506410  libcublas.so.13.6.0.2
4198b8726952fbf25a4e78f07178d66509aca4919b7324e935fe3915bff3efc8  libcublasLt.so.13.6.0.2"
known=" libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 libcuda.so.1 libcublas.so libcublasLt.so $need "
fail=0
names=$(grep -aohE 'lib[A-Za-z0-9_]+\.so(\.[0-9]+)*' /opt/tensorfold/bin/* | sort -u | tr '\n' ' ')
echo "libproof: engine dlopen names: $names"
for n in $names; do case "$known" in *" $n "*) ;; *) echo "libproof: UNCOVERED dlopen name $n"; fail=1 ;; esac; done
for s in $need; do
    f=$(ldconfig -p | awk -v s="$s" '$1 == s {print $NF; exit}')
    [ -n "$f" ] || { echo "libproof: $s MISSING"; fail=1; continue; }
    r=$(readlink -f "$f"); h=$(sha256sum "$r" | cut -c1-64); u=$(ldd "$r" 2>&1 | grep -c 'not found'); note=""
    [ "$u" = 0 ] || { note=" NEEDED NOT RESOLVED"; fail=1; }
    case $s in libcublas*) if printf '%s\n' "$pins" | grep -qx "$h  ${r##*/}"; then note="$note = pin"; else note="$note != PIN"; fail=1; fi ;; esac
    echo "libproof: $s -> $r ${h:0:12}$note"
done
ls /usr/lib/*-linux-gnu/libibverbs/ 2>/dev/null | grep -q mlx5 || { echo "libproof: mlx5 provider MISSING"; fail=1; }
[ "$fail" = 0 ] && echo "LIBPROOF PASS" || echo "LIBPROOF FAIL"
exit "$fail"
EOF
RUN bash /opt/tensorfold/share/libproof.sh
ENV PATH=/opt/tensorfold/bin:$PATH \
    TF_TP_KERNEL_IMAGE=/opt/tensorfold/share/tp_mailbox.fatbin
LABEL tf.patches=${PATCHES_HASH} tf.engine=jl tf.ref=${JL_REF}

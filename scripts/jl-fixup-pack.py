#!/usr/bin/env python3
"""ENGINE=jl: give a checkpoint the storage Jay Leaton's engine loads, without touching the checkpoint.

His engine accepts a router bias (`*.ffn.gate.bias`) only as F32 and DSpark's confidence head (`*.confidence_head.proj.weight`) as
F32 or BF16 (zig/src/families/deepseek_v41/names.zig, Store.f32; plan.zig refuses anything else with UnexpectedTensor). Mia's EAQ
pack stores the three DSpark blocks' biases (`mtp.N.ffn.gate.bias`) and the confidence head as F16. F16 and BF16 widen to F32
exactly, so the values are the pack's own.

    jl-fixup-pack.py SRC_SNAPSHOT_DIR OUT_DIR

writes into OUT_DIR a copy of every shard that holds such a tensor in another dtype, with that tensor widened to F32 (every other
byte copied as it is; the header is rewritten for the shifted offsets). Shards that need nothing are not copied. Prints the names of
the shards written, one a line; nothing when the checkpoint needs no change. A shard already in OUT_DIR that is fully widened is kept.
"""
import json
import os
import struct
import sys

import numpy as np

SUFFIXES = (".ffn.gate.bias", ".confidence_head.proj.weight")
WIDE = {"F16", "BF16"}


def needs(k, t):
    return k.endswith(SUFFIXES) and t["dtype"] in WIDE


def header(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        return json.loads(f.read(n)), 8 + n


def widen(raw: bytes, dtype: str) -> bytes:
    if dtype == "F16":
        return np.frombuffer(raw, dtype="<f2").astype("<f4").tobytes()
    u = np.frombuffer(raw, dtype="<u2").astype("<u4") << 16        # BF16
    return u.astype("<u4").tobytes()


def rewrite(src, dst, h, base):
    meta = h.pop("__metadata__", None)
    order = sorted(h, key=lambda k: h[k]["data_offsets"][0])
    new, pos = {}, 0
    for k in order:
        t = dict(h[k])
        lo, hi = t["data_offsets"]
        size = hi - lo
        if needs(k, t):
            t["dtype"] = "F32"
            size *= 2
        t["data_offsets"] = [pos, pos + size]
        new[k] = t
        pos += size
    if meta is not None:
        new = {"__metadata__": meta, **new}
    blob = json.dumps(new, separators=(",", ":")).encode()
    blob += b" " * (-len(blob) % 8)
    tmp = dst + ".tmp"
    with open(src, "rb") as fi, open(tmp, "wb") as fo:
        fo.write(struct.pack("<Q", len(blob)))
        fo.write(blob)
        for k in order:
            lo, hi = h[k]["data_offsets"]
            fi.seek(base + lo)
            left = hi - lo
            if needs(k, h[k]):
                fo.write(widen(fi.read(left), h[k]["dtype"]))
                continue
            while left:
                chunk = fi.read(min(left, 64 << 20))
                if not chunk:
                    raise SystemExit(f"{src}: short read in {k}")
                fo.write(chunk)
                left -= len(chunk)
        fo.flush()
        os.fsync(fo.fileno())
    os.replace(tmp, dst)


def main():
    src_dir, out_dir = sys.argv[1], sys.argv[2]
    idx = json.load(open(os.path.join(src_dir, "model.safetensors.index.json")))["weight_map"]
    shards = sorted({f for k, f in idx.items() if k.endswith(SUFFIXES)})
    os.makedirs(out_dir, exist_ok=True)
    for f in shards:
        src = os.path.join(src_dir, f)
        h, base = header(src)
        if not any(needs(k, t) for k, t in h.items() if k != "__metadata__"):
            continue
        dst = os.path.join(out_dir, f)
        done = os.path.exists(dst) and not any(needs(k, t) for k, t in header(dst)[0].items() if k != "__metadata__")
        if not done:
            rewrite(os.path.realpath(src), dst, h, base)
        print(f)


if __name__ == "__main__":
    main()

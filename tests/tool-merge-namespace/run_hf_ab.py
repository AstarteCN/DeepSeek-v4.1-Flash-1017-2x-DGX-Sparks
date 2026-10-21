"""Bounded offline Linux HfText A/B. Plan only unless --execute is explicit.

Run inside an externally configured --network none, no-GPU, 3GiB hard-limit
container with metadata/source/binaries mounted readonly and fresh output RW.
This runner never starts containers, builds binaries, or contacts any service.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

GIB3 = 3 * 1024 ** 3


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def cgroup():
    root = Path("/sys/fs/cgroup")
    maximum = (root / "memory.max").read_text().strip()
    swap = (root / "memory.swap.max").read_text().strip()
    if maximum == "max" or not 0 < int(maximum) <= GIB3:
        raise RuntimeError("A finite hard cgroup memory.max <= 3GiB is required")
    if swap != "0":
        raise RuntimeError("Require memory.swap.max=0 so excess memory cannot escape into swap")
    if any(Path("/dev").glob("nvidia*")):
        raise RuntimeError("GPU device exposed; refuse this CPU-only run")
    if set(os.listdir("/sys/class/net")) - {"lo"}:
        raise RuntimeError("Non-loopback interface present; require network-none container")
    return {"memory_max": int(maximum), "swap_max": swap, "events": (root / "memory.events").read_text(),
            "memory_current": int((root / "memory.current").read_text()),
            "memory_peak": int((root / "memory.peak").read_text()) if (root / "memory.peak").exists() else None}


def rss(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) * 1024
    except (FileNotFoundError, ProcessLookupError):
        pass
    return None


def median(values):
    return statistics.median(values) if values else None


def run_one(binary, metadata, fixture, output, timeout):
    started = time.monotonic()
    samples, metrics = [], []
    phase = "load"
    ready_at = clean_at = None
    g_sent = q_sent = False
    offset = 0
    partial = b""
    reason = None
    with (output / "stdout.txt").open("wb") as stdout, (output / "stderr.txt").open("wb") as stderr:
        child = subprocess.Popen([str(binary), str(metadata), str(fixture)], stdin=subprocess.PIPE, stdout=stdout, stderr=stderr)
        try:
            with (output / "stderr.txt").open("rb") as monitor:
                while child.poll() is None:
                    now = time.monotonic()
                    value = rss(child.pid)
                    if value is not None:
                        samples.append((now - started, phase, value))
                    monitor.seek(offset)
                    chunk = monitor.read()
                    offset += len(chunk)
                    partial += chunk
                    lines = partial.split(b"\n")
                    partial = lines.pop()
                    for line in lines:
                        if line.startswith(b"METRIC "):
                            item = {"at_seconds": now - started, "text": line.decode("ascii")}
                            metrics.append(item)
                            if b"phase=model_loaded " in line:
                                ready_at, phase = now, "loaded_baseline"
                            elif b"phase=ready_to_exit" in line:
                                clean_at, phase = now, "after_cleanup"
                    if ready_at is not None and not g_sent and now - ready_at >= .10:
                        child.stdin.write(b"G")
                        child.stdin.flush()
                        g_sent, phase = True, "request"
                    if clean_at is not None and not q_sent and now - clean_at >= .10:
                        child.stdin.write(b"Q")
                        child.stdin.flush()
                        q_sent, phase = True, "model_deinit"
                    if now - started > timeout:
                        reason = "owned_child_timeout"
                        child.terminate()
                        try:
                            child.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait(timeout=2)
                        break
                    time.sleep(.005)
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)
            child.stdin.close()
    raw = (output / "stderr.txt").read_bytes()
    data = [line for line in raw.splitlines(keepends=True) if line.startswith(b"DATA ")]
    all_metrics = [line.decode("ascii") for line in raw.splitlines() if line.startswith(b"METRIC ")]
    cleaned = any("phase=request_cleanup " in line and "owner_live=0 " in line for line in all_metrics)
    ready = any("phase=ready_to_exit" in line for line in all_metrics)
    values = {p: [r for _, phase_, r in samples if phase_ == p] for p in {s[1] for s in samples}}
    baseline = median(values.get("loaded_baseline", []))
    request_peak = max(values.get("request", []), default=None)
    after = median(values.get("after_cleanup", []))
    report = {
        "returncode": child.returncode, "stop_reason": reason, "elapsed_seconds": time.monotonic() - started,
        "pass": child.returncode == 0 and reason is None and cleaned and ready and g_sent and q_sent,
        "pass_scope": "process success and caller-owner lifetime only; pair DATA parity checked separately; memory improvement requires review",
        "binary_sha256": sha(binary), "fixture_sha256": sha(fixture),
        "data_sha256": hashlib.sha256(b"".join(data)).hexdigest(), "data_lines": len(data),
        "stderr_sha256": sha(output / "stderr.txt"), "metrics": all_metrics,
        "request_backing_fully_released": cleaned,
        "sample_interval_requested_ms": 5, "sample_count": len(samples),
        "sample_count_by_phase": {k: len(v) for k, v in values.items()},
        "memory_sampling_valid": len(values.get("loaded_baseline", [])) >= 10 and len(values.get("after_cleanup", [])) >= 10 and len(values.get("request", [])) >= 1,
        "memory_gate_manual_required": True,
        "rss_loaded_baseline_median_bytes": baseline, "rss_request_peak_sampled_bytes": request_peak,
        "rss_request_peak_above_baseline_bytes": request_peak - baseline if request_peak is not None and baseline is not None else None,
        "rss_post_cleanup_median_bytes": after,
        "rss_post_cleanup_minus_baseline_bytes": after - baseline if after is not None and baseline is not None else None,
        "rss_load_peak_sampled_bytes": max(values.get("load", []), default=None),
        "warning": "5ms sampling gives a lower bound on true transient peak; owner allocator counter excludes candidate independent scratch.",
    }
    with (output / "rss.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["seconds_monotonic", "phase", "rss_bytes"])
        w.writerows(samples)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report, data


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--baseline-bin", type=Path, required=True)
    p.add_argument("--candidate-bin", type=Path, required=True)
    p.add_argument("--metadata", type=Path, required=True)
    p.add_argument("--candidate-metadata", type=Path, required=True)
    p.add_argument("--fixtures", type=Path, default=Path(__file__).parent / "fixtures")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--include-8192", action="store_true", help="Explicit optional larger case; no automatic retry or budget increase")
    p.add_argument("--case", action="append", default=[])
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--total-seconds", type=float, default=600)
    args = p.parse_args()
    if not 0 < args.timeout <= 30 or not 0 < args.total_seconds <= 600:
        p.error("Bounds cannot exceed 30 seconds/process or 600 seconds/batch")
    manifest = json.loads((args.fixtures / "manifest.json").read_text())
    cases = [x for x in manifest if (x["default_run"] or args.include_8192) and (not args.case or x["id"] in args.case)]
    if not cases or any(c not in {x["id"] for x in cases} for c in args.case):
        p.error("No matching cases, or an optional 8192 case requires --include-8192")
    plan = {"execute": args.execute, "cases": [x["id"] for x in cases], "max_processes": len(cases) * 2, "timeout_seconds": args.timeout, "total_seconds": args.total_seconds, "hard_memory_limit_max_bytes": GIB3, "max_messages_in_this_batch": 16640, "automatic_retry": False}
    if not args.execute:
        print(json.dumps(plan, indent=2))
        return
    if sys.platform != "linux":
        raise RuntimeError("Execution requires the isolated Linux CPU container")
    before = cgroup()
    for binary in (args.baseline_bin, args.candidate_bin):
        if not binary.is_file():
            raise RuntimeError(f"Missing binary: {binary}")
    for case in cases:
        if sha(args.fixtures / case["file"]) != case["sha256"]:
            raise RuntimeError("Fixture hash mismatch: " + case["file"])
    args.output.mkdir(parents=True, exist_ok=False)
    metadata_hashes = {x.name: sha(x) for x in args.metadata.iterdir() if x.is_file() and x.name in {"tokenizer.json", "tokenizer_config.json", "config.json", "chat_template.jinja", "chat_template.json"}}
    required = {"tokenizer.json", "tokenizer_config.json", "config.json"}
    if not required <= metadata_hashes.keys() or not {"chat_template.jinja", "chat_template.json"} & metadata_hashes.keys():
        raise RuntimeError("Missing real public metadata files")
    expected = json.loads((Path(__file__).parent / "metadata_expected.json").read_text())
    if metadata_hashes != expected:
        raise RuntimeError("Public metadata hashes differ from the pinned public metadata; do not silently substitute")
    candidate_hashes = {x.name: sha(x) for x in args.candidate_metadata.iterdir() if x.is_file() and x.name in metadata_hashes}
    candidate_expected = json.loads((Path(__file__).parent / "candidate_metadata_expected.json").read_text(encoding='utf-8'))
    if candidate_hashes != candidate_expected:
        raise RuntimeError("Candidate metadata differs from frozen public copy/template")
    if {k:v for k,v in candidate_hashes.items() if k != "chat_template.jinja"} != {k:v for k,v in metadata_hashes.items() if k != "chat_template.jinja"}:
        raise RuntimeError("Only the candidate template may differ")
    result = {"plan": plan, "metadata_sha256": metadata_hashes, "candidate_metadata_sha256": candidate_hashes, "cgroup_before": before, "cases": [], "complete": False,
              "completion_scope": "bounded offline execution and DATA parity; not deployment approval or a validated memory fix",
              "memory_gate_manual_required": True}
    summary = args.output / "summary.json"
    summary.write_text(json.dumps(result, indent=2) + "\n")
    started = time.monotonic()
    for case in cases:
        pair = []
        data = []
        for label, binary in (("baseline", args.baseline_bin), ("candidate", args.candidate_bin)):
            if time.monotonic() - started + args.timeout + 2 > args.total_seconds:
                result["stop_reason"] = "batch_time_bound"
                summary.write_text(json.dumps(result, indent=2) + "\n")
                raise SystemExit(2)
            out = args.output / case["id"] / label
            out.mkdir(parents=True)
            report, lines = run_one(binary.resolve(), (args.metadata if label == "baseline" else args.candidate_metadata).resolve(), (args.fixtures / case["file"]).resolve(), out, args.timeout)
            pair.append({"variant": label, **report})
            data.append(lines)
            result["current"] = {"id": case["id"], "variants": pair}
            result["cgroup_latest"] = cgroup()
            summary.write_text(json.dumps(result, indent=2) + "\n")
            if not report["pass"] or result["cgroup_latest"]["events"] != before["events"]:
                result["stop_reason"] = "case_failure_or_memory_event_no_retry"
                summary.write_text(json.dumps(result, indent=2) + "\n")
                raise SystemExit(2)
        equal = data[0] == data[1]
        result["cases"].append({"id": case["id"], "data_exact_equal": equal, "variants": pair})
        result.pop("current", None)
        summary.write_text(json.dumps(result, indent=2) + "\n")
        if not equal:
            result["stop_reason"] = "output_mismatch_no_retry"
            summary.write_text(json.dumps(result, indent=2) + "\n")
            raise SystemExit(2)
    result["complete"] = True
    result["elapsed_seconds"] = time.monotonic() - started
    summary.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"complete": True, "pairs": len(result["cases"]), "summary": str(summary)}))


if __name__ == "__main__":
    main()

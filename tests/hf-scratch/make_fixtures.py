"""Generate synthetic fixtures only; never contacts a service or reads user history."""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "fixtures"


def main():
    OUT.mkdir(exist_ok=True)
    ordinary = [
        {"role": "system", "content": "Answer precisely. 保留字符。"},
        {"role": "user", "content": "傅里叶 e\u0301 / é / 中文 😀 / <think> literal & <xml>\n第二行"},
        {"role": "assistant", "content": "结果：π≈3.14159", "reasoning_content": "检查周期。"},
        {"role": "user", "content": "请继续。"},
    ]
    tool = {"type": "function", "function": {"name": "measure", "description": "测量波形", "parameters": {"type": "object", "properties": {"x": {"type": "number"}, "label": {"type": "string"}}}}}
    tool_msgs = [
        {"role": "system", "content": "Use the tools."},
        {"role": "user", "content": "测量两次。"},
        {"role": "assistant", "content": "", "reasoning_content": "分两步测量。", "tool_calls": [
            {"id": "a", "type": "function", "function": {"name": "measure", "arguments": {"x": 1, "label": "甲😀"}}},
            {"id": "b", "type": "function", "function": {"name": "measure", "arguments": {"x": 2, "label": "e\u0301"}}},
        ]},
        {"role": "tool", "tool_call_id": "b", "content": {"result": 2}},
        {"role": "tool", "tool_call_id": "a", "content": "结果 1"},
        {"role": "user", "content": "归纳结果。"},
    ]
    cases = []
    for thinking in (False, True):
        cases.append({"id": f"unicode_thinking_{int(thinking)}", "messages": ordinary, "thinking": thinking, "effort": "high"})
        cases.append({"id": f"tools_thinking_{int(thinking)}", "messages": tool_msgs, "tools": [tool], "thinking": thinking, "effort": "max"})
    cases += [
        {"id": "explicit_prefix_suffix", "messages": ordinary, "force_boundary_tokens": True},
        {"id": "dynamic_invalid_effort", "messages": ordinary, "effort": "invalid-中文-😀", "expected_error": "Template"},
        {"id": "dynamic_invalid_role", "messages": [{"role": "unknown-中文", "content": "test"}], "expected_error": "Template"},
    ]
    for mode in ("cancel_after_render", "cancel_after_encode", "oom_render", "oom_encode"):
        cases.append({"id": mode, "messages": ordinary, "mode": mode, "thinking": True})
    cases.append({"id": "oom_diagnostic_copy", "messages": ordinary, "mode": "oom_render", "effort": "invalid-diagnostic"})
    for n in (128, 1024, 4096, 8192):
        # Fixed synthetic content word count, not calibrated token length.
        per = 24576 // n
        msgs = [{"role": "assistant" if i % 2 == 0 else "user", "content": "wave " * per} for i in range(n)]
        cases.append({"id": f"memory_m{n}", "messages": msgs, "memory_probe": True, "default_run": n != 8192})
    manifest = []
    for case in cases:
        path = OUT / (case["id"] + ".json")
        data = (json.dumps(case, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        path.write_bytes(data)
        manifest.append({"file": path.name, "id": case["id"], "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "default_run": case.get("default_run", True), "memory_probe": case.get("memory_probe", False)})
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"generated": len(manifest), "default_cases": sum(x["default_run"] for x in manifest), "max_default_messages": 4096}))


if __name__ == "__main__":
    main()

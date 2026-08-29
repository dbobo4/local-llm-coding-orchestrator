from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass, asdict, replace
from datetime import datetime
from pathlib import Path
from typing import Any

VERSION = "4.0-verification"

REPO_ROOT = Path(__file__).resolve().parents[1]
QWEN_ROOT_VALUE = os.environ.get("QWEN_ROOT")
if not QWEN_ROOT_VALUE:
    raise RuntimeError("QWEN_ROOT environment variable is required. See config/local.example.ps1.")
ROOT = Path(QWEN_ROOT_VALUE)

SERVER_EXE = Path(os.environ.get("LLAMA_SERVER_EXE", str(ROOT / r"runtime\llama.cpp\llama-server.exe")))
MODEL = Path(os.environ.get("MODEL_PATH", str(ROOT / r"models\Qwen3.8-27B\Qwen3.8-27B-UD-Q3_K_XL.gguf")))
STOP_PS1 = Path(os.environ.get("STOP_QWEN_SERVER_PS1", str(REPO_ROOT / "scripts" / "stop_qwen_server.ps1")))
QWEN_STANDALONE = Path(os.environ.get("QWEN_CODE_CLI", str(ROOT / r"runtime\qwen-code\standalone\qwen-code\bin\qwen.cmd")))
QWEN_SMOKE_ROOT = Path(os.environ.get("QWEN_SMOKE_ROOT", str(ROOT / r"runtime\qwen-code\smoke-test")))
AGENT_WORKSPACE = QWEN_SMOKE_ROOT / "auto-agent-benchmark"

RESULT_ROOT = Path(os.environ.get("QWEN_BENCH_RESULT_ROOT", str(REPO_ROOT / "results" / "generated" / "full_auto_v4")))
RUN_RESULTS = RESULT_ROOT / "results"
SERVER_LOGS = RESULT_ROOT / "server_logs"
AGENT_LOGS = RESULT_ROOT / "agent_logs"

HOST = os.environ.get("QWEN_HOST", "127.0.0.1")
PORT = int(os.environ.get("QWEN_PORT", "8080"))
BASE_URL = f"http://{HOST}:{PORT}/v1"
MODEL_ALIAS = os.environ.get("QWEN_MODEL_ALIAS", "qwen3.8-27b-local")

SYNTHETIC_REPEATS = 3
FINAL_REPEATS = 3
AGENT_TIMEOUT_SECONDS = 600
SAFE_VRAM_FREE_MB = 512

SYNTH_PROMPT = (
    "Write only Python code. Implement a self-contained LRU cache class with get, put, "
    "delete, contains, clear, capacity resizing, hit/miss statistics, iteration from "
    "most-recently-used to least-recently-used, type hints, docstrings, and a "
    "comprehensive unittest test suite. Do not explain the code."
)

AGENT_PROMPT = (
    "Work only inside the current benchmark directory. "
    "Fix cache.py so that all tests in test_cache.py pass. "
    "Do NOT modify test_cache.py. Run the test suite yourself before finishing. "
    "Do not use the network. Do not use git. "
    "Do not create or modify files outside the current directory. "
    "Follow the configured normal Qwen Code orchestration, hooks and agent/subagent workflow where appropriate. "
    "Return a concise final status when the implementation is correct and the tests pass."
)

CACHE_PY_BUGGY = r'''from collections import OrderedDict

class LRUCache:
    def __init__(self, capacity: int):
        if capacity <= 0:
            raise ValueError("capacity must be positive")
        self.capacity = capacity
        self._data = OrderedDict()
        self.hits = 0
        self.misses = 0

    def get(self, key, default=None):
        if key not in self._data:
            self.hits += 1  # BUG
            return default
        self.misses += 1  # BUG
        value = self._data[key]
        # BUG: successful get must make key most recently used
        return value

    def put(self, key, value):
        if key in self._data:
            self._data[key] = value
            # BUG: updating an existing key must make it MRU
            return
        self._data[key] = value
        if len(self._data) > self.capacity:
            self._data.popitem(last=True)  # BUG: evicts MRU, not LRU

    def delete(self, key):
        return self._data.pop(key, None)

    def contains(self, key):
        return key in self._data

    def clear(self):
        self._data.clear()
        self.hits = 0
        self.misses = 0

    def resize(self, new_capacity: int):
        if new_capacity <= 0:
            raise ValueError("capacity must be positive")
        self.capacity = new_capacity
        # BUG: should evict repeatedly until size <= capacity
        if len(self._data) > self.capacity:
            self._data.popitem(last=False)

    def items_mru_to_lru(self):
        # BUG: OrderedDict iteration is LRU -> MRU
        return list(self._data.items())
'''

TEST_CACHE_PY = r'''import unittest
from cache import LRUCache

class TestLRUCache(unittest.TestCase):
    def test_get_updates_recency_and_stats(self):
        c = LRUCache(2)
        c.put("a", 1)
        c.put("b", 2)
        self.assertEqual(c.get("a"), 1)
        self.assertEqual(c.hits, 1)
        self.assertEqual(c.misses, 0)
        c.put("c", 3)
        self.assertTrue(c.contains("a"))
        self.assertFalse(c.contains("b"))

    def test_miss_stats(self):
        c = LRUCache(2)
        self.assertIsNone(c.get("missing"))
        self.assertEqual(c.hits, 0)
        self.assertEqual(c.misses, 1)

    def test_update_existing_is_mru(self):
        c = LRUCache(2)
        c.put("a", 1)
        c.put("b", 2)
        c.put("a", 10)
        c.put("c", 3)
        self.assertTrue(c.contains("a"))
        self.assertFalse(c.contains("b"))
        self.assertEqual(c.get("a"), 10)

    def test_resize_evicts_until_fit(self):
        c = LRUCache(5)
        for i in range(5):
            c.put(i, i)
        c.resize(2)
        self.assertEqual(len(c._data), 2)
        self.assertEqual(set(c._data.keys()), {3, 4})

    def test_iteration_mru_to_lru(self):
        c = LRUCache(3)
        c.put("a", 1)
        c.put("b", 2)
        c.put("c", 3)
        c.get("a")
        self.assertEqual(
            c.items_mru_to_lru(),
            [("a", 1), ("c", 3), ("b", 2)],
        )

    def test_delete_clear_and_validation(self):
        c = LRUCache(2)
        c.put("a", 1)
        self.assertEqual(c.delete("a"), 1)
        self.assertIsNone(c.delete("missing"))
        c.put("b", 2)
        c.get("b")
        c.get("missing")
        c.clear()
        self.assertEqual(len(c._data), 0)
        self.assertEqual(c.hits, 0)
        self.assertEqual(c.misses, 0)
        with self.assertRaises(ValueError):
            c.resize(0)

if __name__ == "__main__":
    unittest.main()
'''


@dataclass(frozen=True)
class Config:
    name: str
    reasoning_effort: str = "xhigh"
    ctx_size: int = 24576
    threads: int = 20
    batch_size: int = 1024
    ubatch_size: int = 512
    cache_k: str = "q8_0"
    cache_v: str = "q8_0"
    spec_type: str = "draft-mtp,ngram-mod"
    spec_draft_n_max: int = 2
    ngram_n_min: int = 48
    ngram_n_max: int = 64
    ngram_n_match: int = 24
    draft_p_min: float = 0.0


def ensure_dirs():
    for p in (RESULT_ROOT, RUN_RESULTS, SERVER_LOGS, AGENT_LOGS, QWEN_SMOKE_ROOT):
        p.mkdir(parents=True, exist_ok=True)


def stop_server():
    if not STOP_PS1.exists():
        return
    p = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(STOP_PS1)],
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    text = ((p.stdout or "") + "\n" + (p.stderr or "")).strip()
    if text and "ALREADY_STOPPED" not in text:
        print(text)


def kill_process_tree(pid: int):
    subprocess.run(
        ["taskkill.exe", "/PID", str(pid), "/T", "/F"],
        text=True,
        capture_output=True,
        check=False,
        timeout=20,
    )


def http_json(path: str, body: dict | None = None, timeout: int = 300):
    url = BASE_URL + path
    if body is None:
        req = urllib.request.Request(url, method="GET")
    else:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def wait_ready(proc: subprocess.Popen, timeout: int = 120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"llama-server exited early with code {proc.returncode}")
        try:
            data = http_json("/models", timeout=2)
            ids = [x.get("id") for x in data.get("data", [])]
            if MODEL_ALIAS in ids:
                return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Server readiness timeout")


def gpu_memory_mb() -> dict[str, int | None]:
    try:
        p = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used,memory.free,memory.total", "--format=csv,noheader,nounits"],
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        if p.returncode != 0 or not p.stdout.strip():
            return {"used": None, "free": None, "total": None}
        first = p.stdout.strip().splitlines()[0]
        used, free, total = [int(x.strip()) for x in first.split(",")[:3]]
        return {"used": used, "free": free, "total": total}
    except Exception:
        return {"used": None, "free": None, "total": None}


def server_args(cfg: Config) -> list[str]:
    return [
        str(SERVER_EXE),
        "--model", str(MODEL),
        "--alias", MODEL_ALIAS,
        "--host", HOST,
        "--port", str(PORT),
        "--ctx-size", str(cfg.ctx_size),
        "--parallel", "1",
        "--n-gpu-layers", "99",
        "--fit", "off",
        "--spec-type", cfg.spec_type,
        "--spec-draft-n-max", str(cfg.spec_draft_n_max),
        "--threads", str(cfg.threads),
        "--threads-batch", str(cfg.threads),
        "--spec-draft-threads", str(cfg.threads),
        "--spec-draft-threads-batch", str(cfg.threads),
        "--flash-attn", "on",
        "--cache-type-k", cfg.cache_k,
        "--cache-type-v", cfg.cache_v,
        "--batch-size", str(cfg.batch_size),
        "--ubatch-size", str(cfg.ubatch_size),
        "--spec-ngram-mod-n-min", str(cfg.ngram_n_min),
        "--spec-ngram-mod-n-max", str(cfg.ngram_n_max),
        "--spec-ngram-mod-n-match", str(cfg.ngram_n_match),
        "--spec-draft-p-min", str(cfg.draft_p_min),
        "--jinja",
        "--reasoning", "on",
        "--reasoning-effort", cfg.reasoning_effort,
        "--reasoning-budget", "-1",
        "--reasoning-preserve",
    ]


def parse_server_log(text: str) -> dict[str, Any]:
    prompt_entries = re.findall(
        r"prompt eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*tokens per second",
        text, re.I,
    )
    eval_entries = re.findall(
        r"(?<!prompt )eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*tokens per second",
        text, re.I,
    )
    accept_entries = re.findall(
        r"draft acceptance\s*=\s*([\d.]+)\s*\(\s*(\d+)\s*accepted\s*/\s*(\d+)\s*generated\),\s*mean len\s*=\s*([\d.]+)",
        text, re.I,
    )

    result: dict[str, Any] = {}

    if prompt_entries:
        total_ms = sum(float(x[0]) for x in prompt_entries)
        total_tokens = sum(int(x[1]) for x in prompt_entries)
        result["prompt_eval_ms_total"] = round(total_ms, 3)
        result["prompt_tokens_log_total"] = total_tokens
        result["prompt_tps_aggregate"] = round(total_tokens / (total_ms / 1000.0), 2) if total_ms else None
        result["prompt_request_count"] = len(prompt_entries)

    if eval_entries:
        total_ms = sum(float(x[0]) for x in eval_entries)
        total_tokens = sum(int(x[1]) for x in eval_entries)
        result["eval_ms_total"] = round(total_ms, 3)
        result["completion_tokens_log_total"] = total_tokens
        result["decode_tps_aggregate"] = round(total_tokens / (total_ms / 1000.0), 2) if total_ms else None
        result["generation_request_count"] = len(eval_entries)
        result["decode_tps_last"] = float(eval_entries[-1][2])

    if accept_entries:
        accepted = sum(int(x[1]) for x in accept_entries)
        generated = sum(int(x[2]) for x in accept_entries)
        result["draft_accepted_total"] = accepted
        result["draft_generated_total"] = generated
        result["draft_acceptance_aggregate"] = round(accepted / generated, 5) if generated else None
        result["draft_request_count"] = len(accept_entries)

    return result


def start_server(cfg: Config, tag: str):
    stop_server()
    time.sleep(0.5)

    stderr_path = SERVER_LOGS / f"{tag}.stderr.log"
    stdout_path = SERVER_LOGS / f"{tag}.stdout.log"
    out = open(stdout_path, "w", encoding="utf-8")
    err = open(stderr_path, "w", encoding="utf-8")

    proc = subprocess.Popen(
        server_args(cfg),
        stdout=out,
        stderr=err,
        cwd=str(SERVER_EXE.parent),
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    try:
        wait_ready(proc)
    except Exception:
        out.close()
        err.close()
        try:
            kill_process_tree(proc.pid)
        except Exception:
            pass
        stop_server()
        raise

    return proc, out, err, stderr_path


def close_server(proc, out, err):
    try:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)
    except Exception:
        try:
            kill_process_tree(proc.pid)
        except Exception:
            pass
    try:
        out.close()
    except Exception:
        pass
    try:
        err.close()
    except Exception:
        pass
    stop_server()


def result_path(kind: str, tag: str) -> Path:
    return RUN_RESULTS / f"{kind}__{tag}.json"


def load_cached(kind: str, tag: str) -> dict | None:
    p = result_path(kind, tag)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def save_result(kind: str, tag: str, data: dict):
    result_path(kind, tag).write_text(json.dumps(data, indent=2), encoding="utf-8")


def synthetic_once(cfg: Config, tag: str, max_tokens: int = 1200) -> dict:
    cached = load_cached("synthetic", tag)
    if (
        cached
        and cached.get("status") == "ok"
        and cached.get("config") == asdict(cfg)
    ):
        print(f"  [cached] {tag}")
        return cached

    print(f"  [synthetic] {tag}")
    proc = out = err = None
    try:
        proc, out, err, stderr_path = start_server(cfg, tag)
        vram = gpu_memory_mb()

        body = {
            "model": MODEL_ALIAS,
            "reasoning_effort": cfg.reasoning_effort,
            "messages": [{"role": "user", "content": SYNTH_PROMPT}],
            "max_tokens": max_tokens,
            "temperature": 0.2,
            "stream": False,
        }

        t0 = time.perf_counter()
        response = http_json("/chat/completions", body, timeout=600)
        wall = time.perf_counter() - t0
        time.sleep(0.4)

        err.flush()
        parsed = parse_server_log(stderr_path.read_text(encoding="utf-8", errors="replace"))
        usage = response.get("usage", {})

        data = {
            "status": "ok",
            "kind": "synthetic",
            "tag": tag,
            "config": asdict(cfg),
            "wall_seconds": round(wall, 3),
            "completion_tokens": usage.get("completion_tokens"),
            "prompt_tokens": usage.get("prompt_tokens"),
            "vram_mb": vram,
            **parsed,
        }
    except Exception as e:
        data = {"status": "failed", "kind": "synthetic", "tag": tag, "config": asdict(cfg), "error": repr(e)}
    finally:
        if proc is not None:
            close_server(proc, out, err)

    save_result("synthetic", tag, data)
    return data


def synthetic_group(cfg: Config, group_name: str, repeats: int = SYNTHETIC_REPEATS, max_tokens: int = 1200) -> dict:
    runs = [synthetic_once(cfg, f"{group_name}__r{i}", max_tokens=max_tokens) for i in range(1, repeats + 1)]
    oks = [r for r in runs if r.get("status") == "ok" and r.get("decode_tps_aggregate") is not None]

    summary = {
        "group": group_name,
        "config": asdict(cfg),
        "runs": runs,
        "ok_runs": len(oks),
        "total_runs": len(runs),
    }

    if oks:
        summary["median_decode_tps"] = round(statistics.median(r["decode_tps_aggregate"] for r in oks), 2)
        summary["median_prompt_tps"] = round(statistics.median(r.get("prompt_tps_aggregate", 0) for r in oks), 2)
        acc = [r["draft_acceptance_aggregate"] for r in oks if r.get("draft_acceptance_aggregate") is not None]
        summary["median_acceptance"] = round(statistics.median(acc), 5) if acc else None
        summary["median_wall_seconds"] = round(statistics.median(r["wall_seconds"] for r in oks), 3)
        frees = [r.get("vram_mb", {}).get("free") for r in oks]
        frees = [x for x in frees if isinstance(x, int)]
        summary["min_vram_free_mb"] = min(frees) if frees else None

    (RUN_RESULTS / f"group__{group_name}.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def write_agent_workspace(reasoning_effort: str):
    if AGENT_WORKSPACE.exists():
        shutil.rmtree(AGENT_WORKSPACE)
    AGENT_WORKSPACE.mkdir(parents=True, exist_ok=True)

    (AGENT_WORKSPACE / "cache.py").write_text(CACHE_PY_BUGGY, encoding="utf-8")
    (AGENT_WORKSPACE / "test_cache.py").write_text(TEST_CACHE_PY, encoding="utf-8")

    qwen_dir = AGENT_WORKSPACE / ".qwen"
    qwen_dir.mkdir(parents=True, exist_ok=True)
    (qwen_dir / "settings.json").write_text(
        json.dumps({"model": {"reasoningEffort": reasoning_effort}}, indent=2),
        encoding="utf-8",
    )


def run_tests_external() -> tuple[bool, str]:
    p = subprocess.run(
        [sys.executable, "-m", "unittest", "-v", "test_cache.py"],
        cwd=str(AGENT_WORKSPACE),
        text=True,
        capture_output=True,
        check=False,
        timeout=60,
    )
    return p.returncode == 0, (p.stdout or "") + "\n" + (p.stderr or "")


def qwen_command(prompt: str) -> list[str]:
    # Qwen Code 0.22.2 prefers the positional prompt.  Do NOT combine it
    # with --prompt/-p.  Keeping this prompt on one line also avoids cmd.exe
    # treating embedded newlines as separate commands.
    return [
        str(QWEN_STANDALONE),
        "--output-format", "json",
        "--approval-mode", "yolo",
        "--model", MODEL_ALIAS,
        "--max-session-turns", "30",
        "--max-wall-time", "8m",
        "--max-tool-calls", "60",
        prompt,
    ]


def run_batch_file(args: list[str], cwd: Path, timeout: int) -> subprocess.CompletedProcess:
    # qwen.cmd is a batch file, so invoke it through cmd.exe with CALL.
    # subprocess.list2cmdline handles Windows argument quoting.
    cmdline = "call " + subprocess.list2cmdline(args)
    return subprocess.run(
        ["cmd.exe", "/d", "/s", "/c", cmdline],
        cwd=str(cwd),
        text=True,
        capture_output=True,
        check=False,
        timeout=timeout,
    )


def agent_once(cfg: Config, tag: str) -> dict:
    cached = load_cached("agent", tag)
    if (
        cached
        and cached.get("status") == "ok"
        and cached.get("config") == asdict(cfg)
    ):
        print(f"  [cached] {tag}")
        return cached

    print(f"  [agent] {tag}")
    write_agent_workspace(cfg.reasoning_effort)

    proc = out = err = None
    try:
        proc, out, err, stderr_path = start_server(cfg, f"agent__{tag}")
        vram = gpu_memory_mb()

        t0 = time.perf_counter()
        timed_out = False
        try:
            q = run_batch_file(qwen_command(AGENT_PROMPT), AGENT_WORKSPACE, AGENT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            q = None
            timed_out = True
        wall = time.perf_counter() - t0

        tests_ok, test_output = run_tests_external()
        time.sleep(0.4)
        err.flush()
        parsed = parse_server_log(stderr_path.read_text(encoding="utf-8", errors="replace"))

        if q is not None:
            qout = (q.stdout or "") + "\n" + (q.stderr or "")
            qrc = q.returncode
        else:
            qout = "QWEN_HEADLESS_TIMEOUT"
            qrc = None

        (AGENT_LOGS / f"{tag}.qwen.txt").write_text(qout, encoding="utf-8", errors="replace")
        (AGENT_LOGS / f"{tag}.tests.txt").write_text(test_output, encoding="utf-8", errors="replace")

        status = "ok" if (not timed_out and qrc == 0 and tests_ok) else "agent_failed"
        data = {
            "status": status,
            "kind": "agent",
            "tag": tag,
            "config": asdict(cfg),
            "agent_wall_seconds": round(wall, 3),
            "qwen_returncode": qrc,
            "qwen_timed_out": timed_out,
            "external_tests_passed": tests_ok,
            "vram_mb": vram,
            **parsed,
        }
    except Exception as e:
        data = {"status": "failed", "kind": "agent", "tag": tag, "config": asdict(cfg), "error": repr(e)}
    finally:
        if proc is not None:
            close_server(proc, out, err)

    save_result("agent", tag, data)
    return data


def agent_group(cfg: Config, group_name: str, repeats: int = 1) -> dict:
    runs = [agent_once(cfg, f"{group_name}__r{i}") for i in range(1, repeats + 1)]
    success = [r for r in runs if r.get("status") == "ok" and r.get("external_tests_passed")]

    summary = {
        "group": group_name,
        "config": asdict(cfg),
        "runs": runs,
        "success_runs": len(success),
        "total_runs": len(runs),
    }

    if success:
        summary["median_agent_wall_seconds"] = round(statistics.median(r["agent_wall_seconds"] for r in success), 3)
        tps = [r.get("decode_tps_aggregate") for r in success if r.get("decode_tps_aggregate") is not None]
        summary["median_agent_decode_tps"] = round(statistics.median(tps), 2) if tps else None
        acc = [r.get("draft_acceptance_aggregate") for r in success if r.get("draft_acceptance_aggregate") is not None]
        summary["median_agent_acceptance"] = round(statistics.median(acc), 5) if acc else None
        ct = [r.get("completion_tokens_log_total") for r in success if r.get("completion_tokens_log_total") is not None]
        pt = [r.get("prompt_tokens_log_total") for r in success if r.get("prompt_tokens_log_total") is not None]
        rq = [r.get("generation_request_count") for r in success if r.get("generation_request_count") is not None]
        summary["median_agent_completion_tokens"] = round(statistics.median(ct), 1) if ct else None
        summary["median_agent_prompt_tokens"] = round(statistics.median(pt), 1) if pt else None
        summary["median_agent_generation_requests"] = round(statistics.median(rq), 1) if rq else None

    (RUN_RESULTS / f"agent_group__{group_name}.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def choose_quality_gated_fastest(
    candidates: list[tuple[Config, dict, dict]],
    fallback: Config,
) -> Config:
    """
    Inference-only speculative parameters should not be selected from one
    stochastic agent wall-time trajectory.  Require every agent validation
    run to pass, then rank by repeated synthetic decode median.
    """
    good = []
    for cfg, synthetic, agent in candidates:
        all_agent_runs_passed = (
            agent.get("total_runs", 0) > 0
            and agent.get("success_runs", 0) == agent.get("total_runs", 0)
        )
        speed = synthetic.get("median_decode_tps")
        if all_agent_runs_passed and speed is not None:
            good.append((speed, cfg))
    if not good:
        return fallback
    good.sort(key=lambda x: x[0], reverse=True)
    return good[0][1]


def phase_header(n: int, title: str):
    print("\n" + "=" * 78)
    print(f"PHASE {n}: {title}")
    print("=" * 78)


def phase_baseline(base: Config):
    phase_header(1, "BEST XHIGH BASELINE + REAL QWEN CODE AGENT")
    syn = synthetic_group(base, "baseline_xhigh", repeats=SYNTHETIC_REPEATS)
    ag = agent_group(base, "baseline_agent_xhigh", repeats=1)

    # Fail early if headless Qwen Code itself is not working.  This prevents
    # a CLI/configuration problem from contaminating all later winner choices.
    if ag.get("success_runs", 0) < 1:
        log = AGENT_LOGS / "baseline_agent_xhigh__r1.qwen.txt"
        raise RuntimeError(
            "Baseline Qwen Code agent did not complete successfully. "
            f"Inspect: {log}. Synthetic results remain cached and will be reused."
        )

    return syn, ag


def phase_ngram(base: Config):
    phase_header(2, "NGRAM-MOD TOP-CANDIDATE VERIFICATION")

    # These were the three leaders in the valid v3 synthetic sweep.
    triples = [
        (48, 64, 24),
        (32, 64, 16),
        (48, 64, 16),
    ]

    candidates = []
    groups = []
    for nmin, nmax, nmatch in triples:
        cfg = replace(
            base,
            name=f"ngram_{nmin}_{nmax}_{nmatch}",
            ngram_n_min=nmin,
            ngram_n_max=nmax,
            ngram_n_match=nmatch,
        )
        sg = synthetic_group(cfg, cfg.name, repeats=3)
        ag = agent_group(cfg, f"{cfg.name}_agent", repeats=2)
        groups.append((cfg, sg))
        candidates.append((cfg, sg, ag))

    winner = choose_quality_gated_fastest(candidates, base)
    print("\nNGRAM VERIFICATION:")
    for cfg, sg, ag in candidates:
        print(
            f"  {cfg.name}: synthetic={sg.get('median_decode_tps')} tok/s"
            f" | agent={ag.get('success_runs')}/{ag.get('total_runs')}"
            f" | agent_wall={ag.get('median_agent_wall_seconds')} s"
        )
    print(f"NGRAM WINNER: {winner.name}")
    return winner, groups

def phase_mtp_ngram(base: Config):
    phase_header(3, "MTP2 + NGRAM P-MIN VERIFICATION")

    candidates = []
    groups = []
    for pmin in (0.0, 0.025, 0.05):
        cfg = replace(base, name=f"mtp2_pmin_{pmin:g}", draft_p_min=pmin)
        sg = synthetic_group(cfg, cfg.name, repeats=3)
        ag = agent_group(cfg, f"{cfg.name}_agent", repeats=2)
        groups.append((cfg, sg))
        candidates.append((cfg, sg, ag))

    winner = choose_quality_gated_fastest(candidates, base)
    print("\nP-MIN VERIFICATION:")
    for cfg, sg, ag in candidates:
        print(
            f"  p-min={cfg.draft_p_min:g}: synthetic={sg.get('median_decode_tps')} tok/s"
            f" | acceptance={sg.get('median_acceptance')}"
            f" | agent={ag.get('success_runs')}/{ag.get('total_runs')}"
            f" | agent_wall={ag.get('median_agent_wall_seconds')} s"
        )
    print(f"MTP+NGRAM WINNER: {winner.name}")
    return winner, groups

def stable_context_group(g: dict) -> bool:
    if g.get("ok_runs", 0) < 1:
        return False
    free = g.get("min_vram_free_mb")
    return not (isinstance(free, int) and free < SAFE_VRAM_FREE_MB)


def phase_context_kv(base: Config):
    phase_header(4, "CONTEXT / KV-CACHE OPTIMIZATION")

    q8_groups = []
    for ctx in (24576, 32768, 40960, 49152):
        cfg = replace(base, name=f"context_q8q8_{ctx}", ctx_size=ctx, cache_k="q8_0", cache_v="q8_0")
        g = synthetic_group(cfg, cfg.name, repeats=1, max_tokens=600)
        q8_groups.append((cfg, g))

    stable_q8 = [(c, g) for c, g in q8_groups if stable_context_group(g)]
    quality_cfg = max(stable_q8, key=lambda x: x[0].ctx_size)[0] if stable_q8 else base

    q8q5_groups = []
    for ctx in (32768, 40960, 49152, 57344, 65536):
        cfg = replace(base, name=f"context_q8q5_{ctx}", ctx_size=ctx, cache_k="q8_0", cache_v="q5_0")
        g = synthetic_group(cfg, cfg.name, repeats=1, max_tokens=600)
        q8q5_groups.append((cfg, g))

    stable_q8q5 = [(c, g) for c, g in q8q5_groups if stable_context_group(g)]
    max_context_cfg = max(stable_q8q5, key=lambda x: x[0].ctx_size)[0] if stable_q8q5 else quality_cfg

    agent_group(quality_cfg, "context_quality_q8q8_agent", repeats=2)

    if max_context_cfg.cache_v == "q5_0" and max_context_cfg.ctx_size > quality_cfg.ctx_size:
        agent_group(max_context_cfg, "context_extended_q8q5_agent", repeats=1)

    print(f"QUALITY PROFILE CONTEXT: {quality_cfg.ctx_size} ({quality_cfg.cache_k}/{quality_cfg.cache_v})")
    print(f"MAX CONTEXT CANDIDATE:   {max_context_cfg.ctx_size} ({max_context_cfg.cache_k}/{max_context_cfg.cache_v})")
    return quality_cfg, max_context_cfg, q8_groups, q8q5_groups


def phase_effort(base: Config):
    phase_header(5, "FINAL XHIGH vs HIGH A/B")
    efforts = []
    for effort in ("xhigh", "high"):
        cfg = replace(base, name=f"final_{effort}", reasoning_effort=effort)
        sg = synthetic_group(cfg, f"final_{effort}_synthetic", repeats=FINAL_REPEATS)
        ag = agent_group(cfg, f"final_{effort}_agent", repeats=FINAL_REPEATS)
        efforts.append((cfg, sg, ag))
    return efforts


def write_summary(baseline_syn, baseline_agent, ngram_winner, ngram_groups, mtp_winner, mtp_groups, quality_cfg, max_context_cfg, q8_groups, q8q5_groups, final_efforts):
    data = {
        "harness_version": VERSION,
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "baseline_synthetic": baseline_syn,
        "baseline_agent": baseline_agent,
        "ngram_winner": asdict(ngram_winner),
        "mtp_ngram_winner": asdict(mtp_winner),
        "quality_profile_before_effort_ab": asdict(quality_cfg),
        "max_context_candidate": asdict(max_context_cfg),
        "ngram_sweep": [{"config": asdict(c), "summary": g} for c, g in ngram_groups],
        "mtp_sweep": [{"config": asdict(c), "summary": g} for c, g in mtp_groups],
        "context_q8q8": [{"config": asdict(c), "summary": g} for c, g in q8_groups],
        "context_q8q5": [{"config": asdict(c), "summary": g} for c, g in q8q5_groups],
        "final_effort_ab": [{"config": asdict(c), "synthetic": sg, "agent": ag} for c, sg, ag in final_efforts],
    }

    (RESULT_ROOT / "FINAL_REPORT.json").write_text(json.dumps(data, indent=2), encoding="utf-8")

    lines = [
        f"Local Qwen Full-Auto Benchmark Harness v{VERSION}",
        "=" * 72,
        "",
        "BASELINE",
        f"  synthetic median decode: {baseline_syn.get('median_decode_tps')} tok/s",
        f"  agent success: {baseline_agent.get('success_runs')}/{baseline_agent.get('total_runs')}",
        "",
        "SELECTED BEFORE EFFORT A/B",
        f"  ngram winner: {ngram_winner.ngram_n_min}/{ngram_winner.ngram_n_max}/{ngram_winner.ngram_n_match}",
        f"  draft p-min: {mtp_winner.draft_p_min}",
        f"  quality context: {quality_cfg.ctx_size}",
        f"  quality KV: {quality_cfg.cache_k}/{quality_cfg.cache_v}",
        f"  optional max context: {max_context_cfg.ctx_size} ({max_context_cfg.cache_k}/{max_context_cfg.cache_v})",
        "",
        "FINAL XHIGH vs HIGH",
    ]

    for cfg, sg, ag in final_efforts:
        lines.append(
            f"  {cfg.reasoning_effort:5s} | synthetic={sg.get('median_decode_tps')} tok/s"
            f" | acceptance={sg.get('median_acceptance')}"
            f" | agent_success={ag.get('success_runs')}/{ag.get('total_runs')}"
            f" | agent_wall={ag.get('median_agent_wall_seconds')} s"
            f" | agent_decode={ag.get('median_agent_decode_tps')} tok/s"
            f" | completion_tokens={ag.get('median_agent_completion_tokens')}"
            f" | requests={ag.get('median_agent_generation_requests')}"
        )

    lines += [
        "",
        "NOTE",
        "  Production start_qwen_server.ps1 was NOT modified.",
        "  q8/q5 is reported only as an optional extended-context candidate.",
        "  The automatically selected quality profile keeps q8/q8.",
    ]

    report = "\n".join(lines) + "\n"
    (RESULT_ROOT / "FINAL_REPORT.txt").write_text(report, encoding="utf-8")

    rows = []
    for c, g in ngram_groups:
        rows.append({
            "phase": "ngram",
            "name": c.name,
            "effort": c.reasoning_effort,
            "ctx": c.ctx_size,
            "kv": f"{c.cache_k}/{c.cache_v}",
            "ngram": f"{c.ngram_n_min}/{c.ngram_n_max}/{c.ngram_n_match}",
            "pmin": c.draft_p_min,
            "median_decode_tps": g.get("median_decode_tps"),
            "median_acceptance": g.get("median_acceptance"),
            "median_wall_seconds": g.get("median_wall_seconds"),
        })

    for c, g in mtp_groups:
        rows.append({
            "phase": "mtp_pmin",
            "name": c.name,
            "effort": c.reasoning_effort,
            "ctx": c.ctx_size,
            "kv": f"{c.cache_k}/{c.cache_v}",
            "ngram": f"{c.ngram_n_min}/{c.ngram_n_max}/{c.ngram_n_match}",
            "pmin": c.draft_p_min,
            "median_decode_tps": g.get("median_decode_tps"),
            "median_acceptance": g.get("median_acceptance"),
            "median_wall_seconds": g.get("median_wall_seconds"),
        })

    for c, sg, ag in final_efforts:
        rows.append({
            "phase": "effort_final",
            "name": c.name,
            "effort": c.reasoning_effort,
            "ctx": c.ctx_size,
            "kv": f"{c.cache_k}/{c.cache_v}",
            "ngram": f"{c.ngram_n_min}/{c.ngram_n_max}/{c.ngram_n_match}",
            "pmin": c.draft_p_min,
            "median_decode_tps": sg.get("median_decode_tps"),
            "median_acceptance": sg.get("median_acceptance"),
            "median_wall_seconds": ag.get("median_agent_wall_seconds"),
        })

    if rows:
        with open(RESULT_ROOT / "FINAL_TABLE.csv", "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)

    recommended = replace(quality_cfg, reasoning_effort="xhigh")
    (RESULT_ROOT / "RECOMMENDED_XHIGH_ARGS.txt").write_text("\n".join(server_args(recommended)) + "\n", encoding="utf-8")
    return report


def validate_environment():
    missing = [p for p in (SERVER_EXE, MODEL, STOP_PS1, QWEN_STANDALONE) if not p.exists()]
    if missing:
        raise RuntimeError("Missing required paths:\n" + "\n".join(str(p) for p in missing))

    p = subprocess.run([str(SERVER_EXE), "--help"], text=True, capture_output=True, check=False, timeout=30)
    help_text = (p.stdout or "") + "\n" + (p.stderr or "")
    required = [
        "--spec-ngram-mod-n-min",
        "--spec-ngram-mod-n-max",
        "--spec-ngram-mod-n-match",
        "--spec-draft-p-min",
        "--cache-type-k",
        "--cache-type-v",
    ]
    absent = [x for x in required if x not in help_text]
    if absent:
        raise RuntimeError("llama-server is missing required switches: " + ", ".join(absent))

    # Do not parse human-readable Qwen --help text here.
    # Its wording/encoding can vary between Windows builds even when the CLI
    # capabilities are present.  The real headless baseline in phase 1 is the
    # authoritative preflight and will fail fast before any winner selection
    # if invocation is not actually working.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fresh", action="store_true", help="Delete full_auto_v4 results and run everything again.")
    args = parser.parse_args()

    if args.fresh and RESULT_ROOT.exists():
        shutil.rmtree(RESULT_ROOT)

    ensure_dirs()
    validate_environment()

    print("=" * 78)
    print(f"LOCAL QWEN FULL-AUTO BENCHMARK HARNESS v{VERSION}")
    print("=" * 78)
    print(f"Model:   {MODEL}")
    print(f"Results: {RESULT_ROOT}")
    print("Production server config will NOT be modified.")
    print("Completed results are reused automatically after interruption.")
    print("")
    print("Automatic phases:")
    print("  1) xhigh baseline + real Qwen Code agent")
    print("  2) top-3 ngram verification: 3 synthetic + 2 agent runs each")
    print("  3) p-min 0/.025/.05: 3 synthetic + 2 agent runs each")
    print("  4) q8/q8 context sweep + optional q8/q5 extended context")
    print("  5) final xhigh vs high synthetic + real agent A/B")

    base = Config(name="best_xhigh_start")

    try:
        baseline_syn, baseline_agent = phase_baseline(base)
        ngram_winner, ngram_groups = phase_ngram(base)
        mtp_winner, mtp_groups = phase_mtp_ngram(ngram_winner)
        quality_cfg, max_context_cfg, q8_groups, q8q5_groups = phase_context_kv(mtp_winner)
        final_efforts = phase_effort(quality_cfg)

        report = write_summary(
            baseline_syn, baseline_agent,
            ngram_winner, ngram_groups,
            mtp_winner, mtp_groups,
            quality_cfg, max_context_cfg,
            q8_groups, q8q5_groups,
            final_efforts,
        )

        print("\n" + "=" * 78)
        print("ALL AUTOMATED TESTS FINISHED")
        print("=" * 78)
        print(report)
        print(f"Full JSON: {RESULT_ROOT / 'FINAL_REPORT.json'}")
        print(f"Text:      {RESULT_ROOT / 'FINAL_REPORT.txt'}")
        print(f"CSV:       {RESULT_ROOT / 'FINAL_TABLE.csv'}")
        print("\nProduction configuration was not changed.")

    finally:
        stop_server()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nInterrupted by user. Completed results were saved.")
        stop_server()
        raise
    except Exception as e:
        stop_server()
        print("\nFULL-AUTO HARNESS FAILED:")
        print(repr(e))
        print(f"Completed results remain in: {RESULT_ROOT}")
        raise

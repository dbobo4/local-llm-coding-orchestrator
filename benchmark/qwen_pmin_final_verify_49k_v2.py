from __future__ import annotations
import importlib.util, json, os, sys
from dataclasses import asdict, replace
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
V4 = REPO_ROOT / "benchmark" / "qwen_full_auto_benchmark_v4.py"
OUT = Path(os.environ.get("QWEN_PMIN_RESULT_ROOT", str(REPO_ROOT / "results" / "generated" / "pmin_final_verify_49k")))
SYNTH_REPEATS = 3
AGENT_REPEATS = 5

def load_v4():
    spec = importlib.util.spec_from_file_location("qwen_bench_v4", V4)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import: {V4}")
    mod = importlib.util.module_from_spec(spec)

    # Python 3.14 dataclasses expects the module to already exist in
    # sys.modules while class decorators are being evaluated.
    sys.modules[spec.name] = mod
    try:
        spec.loader.exec_module(mod)
    except Exception:
        sys.modules.pop(spec.name, None)
        raise

    return mod

def main():
    if not V4.exists():
        raise RuntimeError(f"Missing v4 harness: {V4}")
    b = load_v4()
    b.RESULT_ROOT = OUT
    b.RUN_RESULTS = OUT / "results"
    b.SERVER_LOGS = OUT / "server_logs"
    b.AGENT_LOGS = OUT / "agent_logs"
    b.ensure_dirs()
    b.validate_environment()

    print("=" * 78)
    print("FINAL P-MIN VERIFICATION @ 49K Q8/Q8 XHIGH")
    print("=" * 78)
    print("Fixed: ctx=49152, KV=q8/q8, MTP2, ngram=32/64/16, xhigh")
    print(f"Per p-min: {SYNTH_REPEATS} synthetic + {AGENT_REPEATS} agent runs")
    print("Production configuration will NOT be modified.")

    base = b.Config(
        name="pmin_final_base",
        reasoning_effort="xhigh",
        ctx_size=49152,
        threads=20,
        batch_size=1024,
        ubatch_size=512,
        cache_k="q8_0",
        cache_v="q8_0",
        spec_type="draft-mtp,ngram-mod",
        spec_draft_n_max=2,
        ngram_n_min=32,
        ngram_n_max=64,
        ngram_n_match=16,
        draft_p_min=0.0,
    )

    rows, full = [], []
    try:
        for pmin in (0.0, 0.025, 0.05):
            cfg = replace(base, name=f"pmin_{pmin:g}", draft_p_min=pmin)
            print("\n" + "-" * 78)
            print(f"P-MIN={pmin:g}")
            print("-" * 78)

            sg = b.synthetic_group(cfg, f"pmin_{pmin:g}_synthetic", repeats=SYNTH_REPEATS)
            ag = b.agent_group(cfg, f"pmin_{pmin:g}_agent", repeats=AGENT_REPEATS)

            all_pass = ag.get("success_runs") == AGENT_REPEATS and ag.get("total_runs") == AGENT_REPEATS
            row = {
                "p_min": pmin,
                "all_agent_runs_passed": all_pass,
                "agent_success": f"{ag.get('success_runs')}/{ag.get('total_runs')}",
                "agent_wall_s_median": ag.get("median_agent_wall_seconds"),
                "agent_decode_tps_median": ag.get("median_agent_decode_tps"),
                "agent_acceptance_median": ag.get("median_agent_acceptance"),
                "agent_completion_tokens_median": ag.get("median_agent_completion_tokens"),
                "agent_prompt_tokens_median": ag.get("median_agent_prompt_tokens"),
                "agent_requests_median": ag.get("median_agent_generation_requests"),
                "synthetic_decode_tps_median": sg.get("median_decode_tps"),
                "synthetic_acceptance_median": sg.get("median_acceptance"),
            }
            rows.append(row)
            full.append({"config": asdict(cfg), "synthetic": sg, "agent": ag})
            print(json.dumps(row, indent=2))

        eligible = [r for r in rows if r["all_agent_runs_passed"] and r["agent_wall_s_median"] is not None]
        decision = (
            {
                "status": "winner",
                "selection_rule": "Require 5/5 agent success, then minimize median real-agent wall time.",
                "winner": min(eligible, key=lambda r: r["agent_wall_s_median"]),
            }
            if eligible
            else {"status": "no_winner", "selection_rule": "No p-min achieved 5/5 agent success."}
        )

        report = {
            "fixed_config": asdict(base),
            "results": rows,
            "decision": decision,
            "full_results": full,
        }
        (OUT / "FINAL_PMIN_REPORT.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

        lines = ["Final p-min verification @ 49152 Q8/Q8 xhigh", "=" * 72, ""]
        for r in rows:
            lines.append(
                f"p-min={r['p_min']:g} | agent={r['agent_success']} | wall={r['agent_wall_s_median']} s "
                f"| completion={r['agent_completion_tokens_median']} | prompt={r['agent_prompt_tokens_median']} "
                f"| requests={r['agent_requests_median']} | agent_decode={r['agent_decode_tps_median']} tok/s "
                f"| synth_decode={r['synthetic_decode_tps_median']} tok/s"
            )
        lines += ["", "DECISION", json.dumps(decision, indent=2)]
        txt = "\n".join(lines) + "\n"
        (OUT / "FINAL_PMIN_REPORT.txt").write_text(txt, encoding="utf-8")

        print("\n" + "=" * 78)
        print("FINAL P-MIN VERIFICATION FINISHED")
        print("=" * 78)
        print(txt)
        print(f"Report: {OUT / 'FINAL_PMIN_REPORT.txt'}")
        print("Production configuration was not changed.")
    finally:
        b.stop_server()

if __name__ == "__main__":
    main()

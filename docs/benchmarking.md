# Benchmarking

## Purpose

The benchmark suite was used to select a practical local inference configuration for coding-agent workloads.

The goal was not to maximize a single synthetic tokens-per-second number.

The final configuration was selected using a combination of:

- successful real-agent completion;
- end-to-end wall-clock time;
- decode throughput;
- generated token count;
- request count;
- speculative decoding behavior;
- context capacity;
- KV-cache quality;
- reproducibility.

The results in this repository should be interpreted as reference engineering results for the tested hardware/software stack, not as universal model rankings.

## Reference hardware

The reference system used:

```text
GPU: NVIDIA GeForce RTX 5070 Ti
VRAM: 16 GB

CPU: Intel Core i7-14700K

System RAM: 32 GB DDR5

Operating system: Windows
```

## Reference software

The current validated production environment uses:

```text
Qwen Code:
  0.22.3

llama.cpp:
  build b10636
  commit 4d19b287691e8f47fc303be420f630c40ec45684

CUDA:
  13.3
```
## Reference model

Final model:

```text
Qwen3.8-27B-UD-Q3_K_XL.gguf
```

Reference SHA256:

```text
8c2a45ff85e7674ca185ec8eb6cdeab0e617ed9d8018caed0b64380eb2a67a5e
```

The model weights are not included in this repository.

## Benchmark file

The current public implementation is a single PowerShell runner:

```text
benchmark/
└── benchmark_qwen.ps1
```

The previous split Python/wrapper benchmark implementation has been retired from the runnable public surface.

Its historical machine-readable reports remain under:

```text
results/reference/
```

Those reports are retained as provenance and tuning evidence; the unified runner does not rewrite them.

## Unified adaptive benchmark

Run the complete benchmark with:

```powershell
.\benchmark\benchmark_qwen.ps1
```

Machine-specific paths, aliases, endpoint information, and benchmark-tunable production values are obtained from:

```text
config/local.ps1
```

The default invocation is non-interactive during measurement. It executes the stages sequentially and asks for user input only after the final recommendation has been produced.

Pipeline:

```text
preflight
-> NGRAM candidates
   -> synthetic screening
   -> real-agent quality gate
-> p-min candidates
   -> repeated real-agent measurements
   -> adaptive escalation when results are noisy or close
-> Q8/Q8 context candidates
   -> VRAM/capacity checks
   -> real-agent quality gate for the selected primary context
-> Q8/Q5 extended-context candidates
   -> capacity-only optional result
-> final primary recommendation
-> explicit Y/N apply prompt
```

The primary result is the recommended quality-gated configuration within the tested candidate set. The runner does not claim a global optimum.

During measurement, production configuration is read-only. After an explicit `Y`, only this tested whitelist is written transactionally to Git-ignored `config/local.ps1`:

```text
ContextWindowSize
SpecDraftPMin
SpecNgramModNMin
SpecNgramModNMax
SpecNgramModNMatch
CacheTypeK
CacheTypeV
```

The same transaction synchronizes the three managed Qwen Code provider `generationConfig.contextWindowSize` values so Qwen Code context accounting and compression use the same limit as llama.cpp.

Reasoning effort is report-only and unchanged. The runner does not auto-apply role-specific reasoning changes. Thread counts, batch size, and ubatch size likewise remain the established baseline.

The optional Q8/Q5 maximum-context result is capacity-only unless separately quality-gated; it is not auto-applied as the primary recommendation.

The benchmark uses isolated temporary servers/workspaces and cleans temporary artifacts on success and failure paths. The validated interruption path also cleans the benchmark listener and workspace.

A fast environment check without benchmark workloads uses the same file:

```powershell
.\benchmark\benchmark_qwen.ps1 -PreflightOnly
```

## What the benchmark is optimizing

The benchmark is intentionally multi-dimensional.

Inference dimensions include:

```text
model quantization
context size
KV-cache quantization
CPU thread count
batch / ubatch
speculative decoding mode
MTP draft length
ngram settings
p-min
reasoning effort
```

Orchestration dimensions additionally include:

```text
number of model rounds
tool-call count
redundant repository inspection
duplicate validation probes
handoff size
cached versus uncached input
compaction frequency
independent verification success
```

The final choice prioritizes successful useful completion and end-to-end behavior. A larger isolated tok/s number or a lower cumulative-token number is not sufficient if correctness or independent verification degrades.
## Native CUDA selection

Native CUDA execution was retained for the final system.

Alternative runtime paths were tested during development, but the final benchmarked Windows CUDA configuration provided the preferred overall result for this hardware.

## Context and KV-cache selection

The current quality-oriented reference configuration uses:

```text
context = 40960
KV cache K = q8_0
KV cache V = q8_0
```

The unified adaptive benchmark also reports larger Q8/Q5 context candidates when they pass the VRAM-capacity gate. Those are capacity-only candidates and are not automatically applied without the real-agent quality gate.

## Speculative decoding

The final system combines:

```text
draft-mtp
+
ngram-mod
```

Selected settings:

```text
draft n-max = 2
p-min = 0.025

ngram n-min = 32
ngram n-max = 64
ngram n-match = 16
```

## MTP draft length

A larger MTP draft was not automatically faster for the real workload.

The final configuration retained:

```text
draft n-max = 2
```

because it produced the better practical operating point when combined with the selected ngram configuration.

This illustrates an important benchmark principle:

```text
more speculative draft tokens
does not necessarily mean
lower end-to-end latency
```

## Ngram configuration

Selected ngram configuration:

```text
n-min = 48
n-max = 64
n-match = 16
```

This was the winner of the automated ngram comparison used by the final benchmark pipeline.

## Historical reasoning-effort comparison

The earlier benchmark directly compared:

```text
xhigh
vs
high
```

Both completed all tested agent tasks.

Reference results:

```text
xhigh
  success:            3 / 3
  median wall time:   112.409 s
  decode throughput:  83.37 tok/s
  completion tokens:  6360
  requests:           13

high
  success:            3 / 3
  median wall time:   129.997 s
  decode throughput:  81.20 tok/s
  completion tokens:  7786
  requests:           13
```

`xhigh` was retained as the server-wide reference default.

The choice was based on successful completion and lower end-to-end wall time, not on the reasoning-effort label itself.

This comparison predates the role-specific reasoning policy and should not be interpreted as requiring every orchestration role to use `xhigh`.

## Role-specific reasoning end-to-end comparison

The role-specific reasoning policy is:

```text
PROMPT     -> xhigh
ALGORITHM  -> xhigh
TEST       -> medium
```

All roles use the same physical Qwen3.8-27B GGUF and the same `llama.cpp` process. The difference is request-level provider configuration.

Historical v3 ? v4 observation:

```text
uniform-xhigh orchestration
  cumulative tokens: 339536

role-specific orchestration
  cumulative tokens: 234973

reduction
  104563 tokens
  approximately 30.8%
```

Independent TEST verification remained PASS.

### Execution-efficiency follow-up

A later fresh FastAPI task exposed specialist round-trip overhead unrelated to inference tuning.

Before specialist-efficiency rules:

```text
PROMPT       98419
ALGORITHM   256559
TEST         32200
TOTAL       387178
```

After ALGORITHM execution-efficiency rules:

```text
TOTAL       340769
```

After both ALGORITHM and TEST execution-efficiency rules:

```text
PROMPT      101203
ALGORITHM   128631
TEST         32198
TOTAL       262032
```

The final run used:

```text
ALGORITHM
  7 model rounds
  10 tools

TEST
  3 model rounds
  4 tools

compactions
  0

wall clock
  approximately 238 s
```

Relative changes:

```text
387178 -> 262032
  approximately -32.3%

340769 -> 262032
  approximately -23.1%

234973 -> 262032
  approximately +11.5%
```

The final TEST independently reran the bounded test and returned PASS.

The cumulative-token metric repeats request prefixes and cached context. It should therefore be interpreted together with request count, cache behavior, tool topology, and wall time rather than as unique model work.

### Compression validation

Compression was tested separately from the zero-compaction FastAPI run.

Observed compaction:

```text
approximately 34772
-> approximately 21867 tokens
```

Execution then continued to independent TEST PASS with 9 tests passing.

This supports the local compression optimization as a fix for the prior low-threshold/re-compaction behavior, but it is not a raw inference-throughput benchmark.
## Historical final p-min comparison

The historical dedicated p-min verification compared:

```text
p-min = 0
p-min = 0.025
p-min = 0.05
```

Each candidate completed five out of five tested workloads.

### p-min = 0

```text
success:
  5 / 5

median wall time:
  131.537 s

completion tokens:
  7040

prompt tokens:
  38076

requests:
  12

agent decode:
  75.46 tok/s

synthetic throughput:
  74.14 tok/s
```

### p-min = 0.025

```text
success:
  5 / 5

median wall time:
  80.029 s

completion tokens:
  4263

prompt tokens:
  29937

requests:
  8

agent decode:
  81.43 tok/s

synthetic throughput:
  77.55 tok/s
```

### p-min = 0.05

```text
success:
  5 / 5

median wall time:
  97.736 s

completion tokens:
  5278

prompt tokens:
  36643

requests:
  12

agent decode:
  82.83 tok/s

synthetic throughput:
  79.14 tok/s
```

## Why p-min 0.025 won

Selection rule:

```text
1. Require successful completion.
2. Among fully successful candidates, minimize median real-agent wall time.
```

All three candidates achieved:

```text
5 / 5 success
```

Median wall times:

```text
0       -> 131.537 s
0.025   ->  80.029 s
0.05    ->  97.736 s
```

Therefore:

```text
p-min = 0.025
```

was selected.

This demonstrates why synthetic throughput alone is insufficient.

`p-min = 0.05` achieved a slightly higher decode/synthetic rate, but produced more tokens, more requests, and a longer real-agent completion time.

For an interactive coding orchestrator, end-to-end useful completion time is the more relevant metric.

## Final reference inference configuration

The resulting production-oriented configuration is:

```text
Model:
  Qwen3.8-27B-UD-Q3_K_XL.gguf

Context:
  40960

Parallel:
  1

GPU layers:
  99

Fit:
  off

Flash Attention:
  on

KV cache:
  q8_0 / q8_0

Batch:
  1024

Ubatch:
  512

Threads:
  20

Threads batch:
  20

Threads draft:
  20

Threads draft batch:
  20

Speculative decoding:
  draft-mtp,ngram-mod

Draft n-max:
  2

p-min:
  0.025

Ngram:
  n-min 32
  n-max 64
  n-match 16

Reasoning:
  on

Server default reasoning effort:
  xhigh

Role-specific request policy:
  PROMPT     xhigh
  ALGORITHM  xhigh
  TEST       medium

Reasoning budget:
  -1

Reasoning preserve:
  enabled
```

## Benchmark interpretation

The unified benchmark combines synthetic inference measurements with real-agent workflow measurements; the sections below also retain historical tuning evidence.

Synthetic throughput is useful for diagnosing raw inference behavior.

Coding-agent workloads also depend on:

```text
prompt processing
reasoning length
completion length
tool-call count
model-request count
cached prefix reuse
specialist handoff size
verification behavior
compaction behavior
agent stopping discipline
```

Cumulative request-token totals can substantially overstate unique input because each model round can include a repeated cached prefix.

For that reason, final selection prioritizes:

1. successful implementation;
2. independent verification;
3. bounded model/tool topology;
4. end-to-end wall time;
5. token/cache behavior;
6. raw throughput only in context.
## Headless benchmark caveat

Automated benchmark execution and interactive production capability are separate concerns.

Qwen Code non-interactive `-p` behavior is version-sensitive and can apply stricter permission behavior than the normal interactive workflow.

Therefore:

- benchmark numbers remain useful for inference/workload comparison;
- headless permission behavior is not proof of interactive ALGORITHM/TEST capability;
- interactive role capability is validated through the normal production path;
- the repository does not add a compatibility patch merely to bypass Qwen Code headless safety policy.

This prevents CLI permission semantics from being confused with the orchestration role design.
## Running the current benchmark

First configure:

```text
config/local.ps1
```

Then run the single unified entry point:

```powershell
.\benchmark\benchmark_qwen.ps1
```

The runner uses the configured local model, llama.cpp runtime, Qwen Code installation, endpoint, and local production baseline.

Hardware, drivers, model builds, llama.cpp builds, and Qwen Code versions can materially change the outcome, so exact numeric reproduction should not be expected on different machines.

The reproducible part is the methodology: fixed candidate sets, explicit quality gates, adaptive repeated measurements where needed, context-capacity constraints, a final recommendation within the tested candidate set, and no configuration change before explicit approval.

The historical reports under `results/reference/` were produced by the earlier benchmark implementations. They remain useful as provenance and comparison data but are not fresh output from `benchmark_qwen.ps1`.

## Reference reports

Retained historical machine-readable inference reports include:

```text
results/reference/full_auto_v4/
??? FINAL_REPORT.json
??? FINAL_REPORT.txt
??? FINAL_TABLE.csv
??? RECOMMENDED_XHIGH_ARGS.txt
```

and:

```text
results/reference/pmin_final_verify_49k/
??? FINAL_PMIN_REPORT.json
??? FINAL_PMIN_REPORT.txt
```

The later orchestration-efficiency and compression E2E observations are documented in this file, while the current end-to-end orchestration flow is documented in `docs/session_hook_flow.md`; these should not be silently mixed into the older inference-report datasets.
## Benchmark design principle

The final configuration was not selected by asking:

```text
Which configuration has the largest tok/s number?
```

Instead:

```text
Which configuration reliably completes the coding-agent workload
with the best practical end-to-end behavior
while preserving the desired context and quality constraints?
```

That distinction is central to the benchmark methodology used by this project.

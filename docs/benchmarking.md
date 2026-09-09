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

## Benchmark files

Implementation:

```text
benchmark/
├── qwen_full_auto_benchmark_v4.py
├── qwen_pmin_final_verify_49k_v2.py
├── run_full_benchmark.ps1
└── run_pmin_verify.ps1
```

Reference outputs:

```text
results/reference/
```

New locally generated output:

```text
results/generated/
```

`results/generated/` is excluded from Git.

## Full automated benchmark

Run:

```powershell
.\benchmark\run_full_benchmark.ps1
```

The runner obtains installation paths and endpoint configuration from:

```text
config/local.ps1
```

The Python benchmark receives machine-specific paths through environment/configuration rather than embedding the reference machine's private paths in the public source.

## Final p-min verification

Run:

```powershell
.\benchmark\run_pmin_verify.ps1
```

This benchmark focuses on the final 49k-context configuration and compares the selected `p-min` candidates using repeated agent workloads.

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

The quality-oriented reference configuration uses:

```text
context = 49152
KV cache K = q8_0
KV cache V = q8_0
```

A larger reference configuration was technically possible with:

```text
context = 65536
K = q8_0
V = q5_0
```

but the final system uses the 49,152-token Q8/Q8 configuration as the quality-first operating point.

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
n-min = 32
n-max = 64
n-match = 16
```

This was the winner of the automated ngram comparison used by the final benchmark pipeline.

## Reasoning-effort comparison

The final benchmark directly compared:

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
## Final p-min comparison

The final verification compared:

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
  49152

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

The benchmark suite contains both synthetic inference measurements and real-agent workflow measurements.

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
## Reproducing the results

First configure:

```text
config/local.ps1
```

Then run:

```powershell
.\benchmark\run_full_benchmark.ps1
```

For final `p-min` comparison:

```powershell
.\benchmark\run_pmin_verify.ps1
```

The benchmark scripts use the configured local model, llama.cpp runtime, Qwen Code installation, endpoint, and test workspace.

Hardware, drivers, model builds, llama.cpp builds, and Qwen Code versions can change performance, so exact numeric reproduction should not be expected on different machines.

The methodology, configuration capture, and relative comparison process are the reproducible parts.

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

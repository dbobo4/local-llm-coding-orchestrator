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

The validated environment used:

```text
Qwen Code:
  0.22.2

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

Relevant dimensions include:

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

The final choice prioritizes successful useful completion and end-to-end behavior.

A configuration is not preferred merely because one isolated throughput measurement is larger.

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

`xhigh` was retained.

The choice was based on successful completion and lower end-to-end wall time, not on the reasoning-effort label itself.

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

Reasoning effort:
  xhigh

Reasoning budget:
  -1

Reasoning preserve:
  enabled
```

## Benchmark interpretation

The benchmark contains both synthetic and real-agent measurements.

Synthetic throughput is useful for diagnosing raw inference behavior.

Coding-agent workloads also depend on:

```text
prompt processing
reasoning length
completion length
tool-call count
number of model requests
speculative acceptance
agent behavior
verification behavior
```

For this reason, final selection prioritizes successful real-agent execution and end-to-end wall time.

## Headless benchmark caveat

Automated benchmark execution and permission validation are different concerns.

Qwen Code 0.22.2 has stricter built-in behavior for non-interactive `-p` execution than for the normal interactive workflow.

In particular, non-interactive `auto` startup can synthesize deny rules affecting shell/edit/write tools.

Therefore:

- benchmark numbers remain useful for inference/workload comparison;
- headless permission behavior should not be used as proof of interactive ALGORITHM/TEST capabilities;
- interactive agent tool capability is validated separately through the normal production path;
- the repository does not remove Qwen Code's built-in headless restrictions with an extra runtime patch.

This distinction prevents a headless CLI safety policy from being confused with the production role architecture.

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

Retained reference artifacts:

```text
results/reference/full_auto_v4/
├── FINAL_REPORT.json
├── FINAL_REPORT.txt
├── FINAL_TABLE.csv
└── RECOMMENDED_XHIGH_ARGS.txt
```

and:

```text
results/reference/pmin_final_verify_49k/
├── FINAL_PMIN_REPORT.json
└── FINAL_PMIN_REPORT.txt
```

The JSON files contain structured results suitable for further analysis.

The text and CSV files provide human-readable summaries.

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

# Local LLM Coding Orchestrator

A fully local, Windows-first coding-agent stack built around Qwen Code, `llama.cpp`, and Qwen3.8-27B.

The project adds a structured orchestration layer on top of local model inference:

```text
User
  |
  v
Qwen Code
  |
  +--> PROMPT      coordination, routing, project context
  |
  +--> ALGORITHM   implementation and technical reasoning
  |
  +--> TEST        independent verification
  |
  v
llama.cpp
  |
  v
Qwen3.8-27B
```

The objective is not simply to run a local coding model. The repository focuses on the engineering required to make a local coding-agent workflow more structured, reproducible, stateful across sessions, independently verifiable, lifecycle-aware, and safe around local process management.

## Highlights

- Fully local inference through `llama-server`
- OpenAI-compatible local endpoint
- PROMPT / ALGORITHM / TEST role separation
- Independent TEST-agent verification
- Stable project identity and isolated project state
- Shared durable project memory plus role-private memory
- Role journals and explicit workflow state outside the model context
- Controlled optional cross-project memory
- Qwen Code lifecycle hooks
- Anti-loop behavior
- Bounded smoke-validation policy
- Automatic local inference server startup and shutdown
- Fail-closed process ownership checks
- Qwen Code compatibility patch management
- Non-destructive, idempotent Qwen settings installation
- Reproducible benchmark suite
- Hardware-specific reference configuration and benchmark results

## Reference stack

The reference implementation was validated with:

```text
Operating system
  Windows

GPU
  NVIDIA GeForce RTX 5070 Ti
  16 GB VRAM

CPU
  Intel Core i7-14700K

System RAM
  32 GB DDR5

Qwen Code
  0.22.2

llama.cpp
  build b10636
  commit 4d19b287691e8f47fc303be420f630c40ec45684

CUDA
  13.3

Model
  Qwen3.8-27B-UD-Q3_K_XL.gguf
```

Reference model SHA256:

```text
8c2a45ff85e7674ca185ec8eb6cdeab0e617ed9d8018caed0b64380eb2a67a5e
```

The model, Qwen Code runtime, and llama.cpp binaries are **not** distributed in this repository.

## Why this project exists

Running an LLM locally is relatively straightforward. Building a useful local coding-agent workflow requires additional engineering.

A single unconstrained agent can easily:

```text
analyze
-> edit
-> test
-> reconsider
-> edit again
-> test again
-> ...
```

It can also verify its own implementation, lose coordination state as context grows, mix unrelated projects, leave inference processes running, or depend on configuration that cannot be reproduced on another machine.

This project adds an explicit orchestration layer to address those problems.

The main Qwen Code process coordinates the task, an implementation-focused ALGORITHM agent handles implementation-heavy work, and a separate TEST agent independently verifies important changes.

## Architecture

The architecture separates four layers:

```text
MODEL
Qwen3.8-27B
    |
    v
INFERENCE
llama.cpp
    |
    v
CODING INTERFACE
Qwen Code
    |
    v
ORCHESTRATION
roles + hooks + project identity + memory + state + validation + lifecycle control
```

The main orchestration components are:

```text
orchestration/
├── QWEN.md
├── hook_dispatcher.py
├── maintenance_hook.py
├── memory_protocol.py
├── memory_store.py
├── project_identity.py
├── project_registry.py
├── workflow_state.py
└── agents/
    ├── algorithm-agent.md
    └── test-agent.md
```

For the detailed design, see [Architecture](docs/architecture.md).

## Role model

### PROMPT

The main Qwen Code process acts as coordinator.

It handles:

- task understanding;
- context gathering;
- planning;
- delegation decisions;
- integration of agent results;
- deciding when independent verification is needed;
- maintaining the user-facing task thread.

PROMPT is the orchestrator. It is not intended to replace the implementation role for code-changing work.

### ALGORITHM

The ALGORITHM role focuses on:

- implementation;
- algorithmic reasoning;
- targeted technical investigation;
- code changes;
- failure-mode analysis;
- bounded implementation-side checks.

Its configured tool surface includes read/search tools, direct edit/write tools, notebook editing, and shell execution.

### TEST

The TEST role is intentionally independent from implementation.

It focuses on:

- reviewing the resulting change;
- checking invariants;
- running bounded tests;
- identifying regressions;
- determining whether the requested task is actually complete.

The TEST agent is configured without the direct `edit` and `write_file` tools. It does retain `run_shell_command` for verification. Because shell execution can technically mutate files, TEST is **not capability-level read-only**; its role policy prohibits intentional persistent source modification and uses shell execution for bounded verification.

All roles use the same local model endpoint. The separation is created through orchestration, role-specific instructions, and role-specific tool lists rather than separate model deployments.

## Memory and project state

The orchestration layer keeps durable project context outside the model context window instead of relying on Qwen Code's managed auto-memory features.

Each working project receives a stable project identity and isolated storage. Global Qwen configuration such as `~/.qwen/settings.json` is deliberately not treated as a project marker, so unrelated directories do not collapse into the same project identity.

The durable-memory model is:

```text
project
├── prompt_agent/
│   └── memory.md          # shared durable project memory
├── algorithm_agent/
│   └── memory.md          # ALGORITHM-private durable memory
└── test_agent/
    └── memory.md          # TEST-private durable memory
```

`prompt_agent/memory.md` is the shared durable project memory. It is not a fourth independent store.

Recent role journals and workflow state are maintained separately from durable memory. At lifecycle boundaries, the dispatcher injects only context appropriate for the receiving role:

| Receiving role | Injected context |
| --- | --- |
| PROMPT | Shared durable project memory plus recent role journals needed for coordination |
| ALGORITHM | Shared project memory, recent PROMPT context, ALGORITHM-private memory, ALGORITHM journal |
| TEST | Shared project memory, recent PROMPT context, TEST-private memory, TEST journal |

Cross-project memory is optional and intentionally controlled rather than globally mixed into every task.

The implementation is split across:

- `project_identity.py`
- `project_registry.py`
- `memory_protocol.py`
- `memory_store.py`
- `workflow_state.py`
- `hook_dispatcher.py`

This keeps project history persistent across sessions while preserving project isolation and role separation.

## Lifecycle

The orchestration layer integrates with Qwen Code lifecycle events:

```text
SessionStart
UserPromptSubmit
SubagentStart
SubagentStop
Stop
SessionEnd
PreToolUse
```

The dispatcher uses those events to resolve project context, load/store orchestration state, prepare role-specific subagent context, update journals, and maintain bounded workflow coordination.

`PreToolUse` is used by the maintenance layer for controlled shell-command maintenance behavior.

A separate `SessionEnd` server-stop hook participates in normal cleanup, while the outer wrapper still performs deterministic server shutdown in `finally`.

## Repository structure

```text
local-llm-coding-orchestrator/
├── benchmark/
│   ├── qwen_full_auto_benchmark_v4.py
│   ├── qwen_pmin_final_verify_49k_v2.py
│   ├── run_full_benchmark.ps1
│   └── run_pmin_verify.ps1
│
├── config/
│   ├── local.example.ps1
│   └── settings.example.json
│
├── docs/
│   ├── architecture.md
│   ├── benchmarking.md
│   └── usage.md
│
├── orchestration/
│   ├── QWEN.md
│   ├── hook_dispatcher.py
│   ├── maintenance_hook.py
│   ├── memory_protocol.py
│   ├── memory_store.py
│   ├── project_identity.py
│   ├── project_registry.py
│   ├── workflow_state.py
│   └── agents/
│       ├── algorithm-agent.md
│       └── test-agent.md
│
├── patches/
│   └── ensure_qwen_code_patches.ps1
│
├── results/
│   └── reference/
│       ├── full_auto_v4/
│       └── pmin_final_verify_49k/
│
├── scripts/
│   ├── ensure_qwen_server.ps1
│   ├── install_orchestrator.ps1
│   ├── qwen.cmd
│   ├── qwen.ps1
│   ├── start_qwen_server.ps1
│   └── stop_qwen_server.ps1
│
├── .gitignore
├── LICENSE
├── README.md
└── THIRD_PARTY_NOTICES.md
```

`config/local.ps1` is intentionally excluded from Git because it contains machine-specific paths.

## Quick start

The project is Windows-first and the reference setup uses:

```text
C:\LocalAI\qwen
```

as the local runtime root.

You can use another location by editing `config/local.ps1`.

### 1. Clone this repository

```powershell
git clone https://github.com/<YOUR_USERNAME>/local-llm-coding-orchestrator.git
cd local-llm-coding-orchestrator
```

Replace the GitHub URL placeholder with the final repository URL after publishing.

### 2. Create the local runtime layout

```powershell
New-Item -ItemType Directory -Force C:\LocalAI\qwen\runtime\qwen-code\standalone,C:\LocalAI\qwen\runtime\llama.cpp,C:\LocalAI\qwen\models\Qwen3.8-27B | Out-Null
```

### 3. Install the tested Qwen Code version

This project was validated against:

```text
Qwen Code 0.22.2
```

For maximum reproducibility, use that version rather than automatically upgrading to the newest release.

Official releases:

```text
https://github.com/QwenLM/qwen-code/releases
```

The Windows standalone release archive is:

```text
qwen-code-win-x64.zip
```

Extract it into:

```text
C:\LocalAI\qwen\runtime\qwen-code\standalone\
```

The resulting runtime should contain:

```text
C:\LocalAI\qwen\runtime\qwen-code\standalone\qwen-code\bin\qwen.cmd
```

Qwen Code also provides a standalone installer. If you use another installation location, update `QwenCodeRoot` in `config/local.ps1`.

### 4. Install the tested llama.cpp build

Reference build:

```text
b10636
commit 4d19b287691e8f47fc303be420f630c40ec45684
```

Official releases:

```text
https://github.com/ggml-org/llama.cpp/releases
```

For the reference NVIDIA Windows configuration, use:

```text
llama-b10636-bin-win-cuda-13.3-x64.zip
cudart-llama-bin-win-cuda-13.3-x64.zip
```

Extract both archives into:

```text
C:\LocalAI\qwen\runtime\llama.cpp\
```

Verify that this exists:

```text
C:\LocalAI\qwen\runtime\llama.cpp\llama-server.exe
```

Other llama.cpp backends may work, but the published benchmark results correspond to the CUDA configuration above.

### 5. Download the reference model

Model repository:

```text
https://huggingface.co/unsloth/Qwen3.8-27B-GGUF
```

Reference file:

```text
Qwen3.8-27B-UD-Q3_K_XL.gguf
```

Place it at:

```text
C:\LocalAI\qwen\models\Qwen3.8-27B\Qwen3.8-27B-UD-Q3_K_XL.gguf
```

Verify the checksum:

```powershell
Get-FileHash "C:\LocalAI\qwen\models\Qwen3.8-27B\Qwen3.8-27B-UD-Q3_K_XL.gguf" -Algorithm SHA256
```

Expected SHA256:

```text
8C2A45FF85E7674CA185EC8EB6CDEAB0E617ED9D8018CAED0B64380EB2A67A5E
```

### 6. Create local configuration

From the repository root:

```powershell
Copy-Item .\config\local.example.ps1 .\config\local.ps1
```

Edit:

```text
config\local.ps1
```

if your paths differ from the reference layout.

The local configuration is ignored by Git.

### 7. Install the orchestration layer

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install_orchestrator.ps1
```

The installer:

- installs the global orchestration policy (`QWEN.md`);
- installs the ALGORITHM and TEST agent definitions;
- installs the complete orchestration runtime: dispatcher, maintenance, memory protocol/store, project identity/registry, and workflow-state modules;
- installs the managed lifecycle and maintenance hooks;
- configures the local OpenAI-compatible provider and reference reasoning settings;
- preserves unrelated existing providers, environment settings, permission deny rules, UI/settings fields, and third-party hooks;
- backs up existing managed files and `settings.json` before replacement;
- uses millisecond-resolution backup directory names;
- is safe to run repeatedly without duplicating managed providers, hooks, or deny rules.

The installer does not start Qwen Code or `llama-server`. It deploys and verifies the orchestration/configuration layer only.

### 8. Start the coding orchestrator

Use:

```powershell
.\scripts\qwen.cmd
```

This is the recommended production entry point.

The wrapper performs:

```text
Qwen Code compatibility verification
        |
        v
llama-server verification/start
        |
        v
interactive Qwen Code session
        |
        v
deterministic llama-server shutdown
```

## Local inference configuration

The reference production configuration uses:

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

These settings were selected through the benchmark suite included in this repository. They are a validated reference configuration for the tested machine, not a universal optimum.

## Qwen Code compatibility layer

The project carries two runtime compatibility patches required by this orchestration design.

### SubagentStart context propagation

Foreground `SubagentStart` hook `additionalContext` is propagated into the effective subagent task prompt.

This is required for role-specific project memory and orchestration context to reach the delegated agent.

### PreToolUse argument rewriting

A rewritten `tool_input` returned through `PreToolUse` becomes the effective tool invocation input.

This is required for the maintenance hook to make controlled argument rewrites effective.

The patch manager is:

```text
patches/ensure_qwen_code_patches.ps1
```

It operates fail-closed:

```text
already patched
    -> verify

known compatible unpatched runtime
    -> backup
    -> patch
    -> JavaScript syntax check
    -> verify

unknown or mixed runtime
    -> stop
```

The validated patched runtime baseline for the reference Qwen Code 0.22.2 build is:

```text
753C03204D5B6388DCB9885ED5766AC496B449BDA291D27EFB5A110E159DB7ED
```

The patcher does not blindly modify an unknown runtime.

## Interactive and headless permission semantics

Normal production use is interactive:

```powershell
.\scripts\qwen.cmd
```

In that path, the validated role behavior is:

```text
PROMPT
  coordinator

ALGORITHM
  direct read/edit/write + shell capability

TEST
  read/search + shell capability
  no direct edit/write_file tools
```

Qwen Code 0.22.2 applies stricter built-in behavior to non-interactive `-p` execution. In non-interactive `auto` mode it can synthesize deny rules for shell/edit/write capabilities before a subagent override is created.

Therefore:

- a failing `-p --approval-mode auto` write probe is **not** evidence that the normal interactive ALGORITHM role cannot write;
- interactive role capability must be validated through the interactive production path;
- headless tests should be treated as a separate execution mode with separate permission semantics.

No third runtime patch is used to bypass those headless safety rules.

## Lifecycle management

The orchestration layer uses:

```text
SessionStart
UserPromptSubmit
SubagentStart
SubagentStop
Stop
SessionEnd
PreToolUse
```

Qwen Code's `SessionEnd` hook participates in normal cleanup.

The wrapper also performs server shutdown in a `finally` block because headless execution may not reliably deliver `SessionEnd`.

This gives deterministic cleanup even when the lifecycle event is absent.

## Fail-closed server ownership

The server scripts do not terminate an arbitrary process merely because it is listening on the configured port.

Before reuse or termination, they verify that the listener belongs to the expected local `llama-server` runtime. A conflicting or ambiguous process causes startup/shutdown verification to fail rather than killing the unrelated process.

## Bounded validation

The orchestration policy favors:

```text
syntax/import check
-> initialization
-> focused functional path
-> small smoke/unit test
```

over automatically launching expensive workloads such as:

```text
full training
full datasets
large benchmark suites
long integration workloads
```

Large validation jobs remain explicit user actions.

## Installation validation

The installer has been exercised in an isolated temporary environment for:

- fresh installation;
- deployment of all required orchestration files;
- repeated installation without managed duplicate entries;
- backup creation;
- preservation of an unrelated provider;
- preservation of unrelated environment settings;
- preservation of unrelated permission deny rules;
- preservation of a third-party hook.

This validates the repository installer independently from the already-working local production installation.

## Benchmark methodology

The benchmark does not select a configuration solely by synthetic tokens per second.

Selection considers:

- successful real-agent completion;
- end-to-end wall time;
- decode throughput;
- completion length;
- prompt length;
- request count;
- speculative decoding behavior;
- context/KV-cache constraints.

The principle is:

```text
successful useful completion
>
largest isolated tok/s number
```

See [Benchmark methodology and results](docs/benchmarking.md).

## Selected benchmark results

### Reasoning effort

```text
xhigh
  success:            3 / 3
  median wall time:   112.409 s
  decode throughput:  83.37 tok/s
  completion tokens:  6360

high
  success:            3 / 3
  median wall time:   129.997 s
  decode throughput:  81.20 tok/s
  completion tokens:  7786
```

`xhigh` was retained because both configurations completed successfully while `xhigh` produced lower end-to-end wall time.

### Final p-min verification

```text
p-min    success    median agent wall time
0        5 / 5      131.537 s
0.025    5 / 5       80.029 s
0.05     5 / 5       97.736 s
```

Selection rule:

```text
1. Require full task success.
2. Among fully successful candidates, minimize median real-agent wall time.
```

Therefore:

```text
p-min = 0.025
```

was retained.

Reference machine-readable reports are available under:

```text
results/reference/
```

## Running the benchmarks

Full automated benchmark:

```powershell
.\benchmark\run_full_benchmark.ps1
```

Final 49k-context `p-min` verification:

```powershell
.\benchmark\run_pmin_verify.ps1
```

Generated benchmark output is written under:

```text
results/generated/
```

and excluded from Git.

## Documentation

Detailed documentation:

- [Architecture](docs/architecture.md)
- [Usage](docs/usage.md)
- [Benchmarking](docs/benchmarking.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## Scope

This repository intentionally does **not** include:

- Qwen Code binaries;
- llama.cpp binaries;
- GGUF model weights;
- local machine configuration;
- generated benchmark logs;
- local runtime state;
- project memory generated during use.

Those components must be obtained or generated separately.

## Compatibility

The reference configuration is specifically validated against:

```text
Qwen Code 0.22.2
llama.cpp b10636
Qwen3.8-27B-UD-Q3_K_XL.gguf
Windows + CUDA 13.3
```

Newer versions may work, but Qwen Code upgrades should be treated deliberately because the compatibility patcher depends on known runtime semantics.

## License

The original code and documentation in this repository are licensed under the Apache License 2.0.

See [LICENSE](LICENSE).

Third-party projects retain their own licenses.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Project focus

This project is primarily an orchestration and local-inference engineering project.

Its main contribution is not the underlying Qwen model, Qwen Code, or llama.cpp. The contribution is the system around them:

```text
local inference
+ role separation
+ stable project identity
+ controlled durable memory
+ role journals and workflow state
+ lifecycle hooks
+ compatibility management
+ deterministic cleanup
+ independent verification
+ benchmark-driven configuration
```

The result is a reproducible local coding-agent workflow designed to behave more like a controlled engineering system than a single unconstrained chat model.

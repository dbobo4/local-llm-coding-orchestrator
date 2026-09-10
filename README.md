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
- Bounded stable-ID durable memory instead of role journals
- PROMPT-, ALGORITHM-, TEST-, and cross-project memory ownership (`P/A/T/C`)
- Role-isolated specialist context and compact task-specific handoffs
- Delayed PROMPT-memory persistence through the `PreToolUse` carrier
- Cross-project memory limited to `SessionStart` / PROMPT synthesis
- Explicit bounded workflow and anti-loop state
- Role-specific reasoning effort on one physical GGUF
- Qwen Code lifecycle hooks
- Two compatibility patches plus a separate compression optimization
- Bounded compaction handoff using `<state_snapshot>`
- Automatic shared local inference router startup and idle-aware shutdown
- Optional plain llama.cpp Web UI through `qwen chat`
- CLI/chat client leases so either interface can keep the shared model alive
- Fail-closed listener/process ownership checks
- Non-destructive, idempotent Qwen settings installation
- Reproducible benchmark suite
- Hardware-specific reference configuration and benchmark results
## Reference stack

The current production reference implementation was validated with:

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
  0.22.3

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

The orchestration layer keeps selected durable project knowledge outside the model context window. It does not use role journals and does not rely on Qwen Code managed auto-memory.

Each working project receives a stable project identity and isolated storage. Global Qwen configuration such as `~/.qwen/settings.json` is deliberately not treated as a project marker.

Logical durable-memory ownership is:

```text
Pxxx  PROMPT / project durable knowledge
Axxx  ALGORITHM-private durable knowledge
Txxx  TEST-private durable knowledge
Cxxx  controlled cross-project knowledge
```

The current implementation uses bounded compact stores rather than append-only execution history. `ADD` receives its stable ID from Python; `REPLACE` and `REMOVE` must reference an existing ID owned by the correct role. Invalid or oversized durable updates are rejected instead of being converted into free-form history.

Default bounds include:

```text
project/PROMPT facts     12
ALGORITHM facts          12
TEST facts               12
cross-project facts       8
durable update chars    650
durable update sentences  3
```

Context is intentionally asymmetric:

| Receiving role | Durable/context input |
| --- | --- |
| PROMPT | Compact project/PROMPT memory; controlled cross-project memory only at `SessionStart` |
| ALGORITHM | Small PROMPT task delta plus ALGORITHM-private compact memory |
| TEST | Small verification delta plus TEST-private compact memory and objective implementation facts |

ALGORITHM does not receive PROMPT memory wholesale. TEST does not inherit ALGORITHM rationale or private memory.

PROMPT durable writes use a delayed `<PROMPT_MEMORY>` carrier. A fact written during user turn N may only be based on information that already existed before prompt N. The carrier is attached only to the first already-needed `Agent` delegation, processed by `PreToolUse`, then stripped before the specialist receives the task. The orchestrator never creates an extra agent call solely to save memory.

Cross-project memory is read only for `SessionStart` / first PROMPT synthesis and is never injected into specialists.

The main implementation is split across `project_identity.py`, `project_registry.py`, `memory_protocol.py`, `memory_store.py`, `workflow_state.py`, and `hook_dispatcher.py`.
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

Key behavior:

- `SessionStart` resolves project identity and supplies PROMPT with compact project memory plus controlled cross-project memory.
- `UserPromptSubmit` advances bounded turn/workflow state.
- `SubagentStart` supplies only role-appropriate specialist memory/context.
- `SubagentStop` records bounded objective completion state.
- `Stop` and `SessionEnd` finalize workflow/session state.
- `PreToolUse` has two distinct uses: controlled shell maintenance and the `agent` prompt-memory carrier.
- The prompt-memory carrier persists eligible `Pxxx` updates and removes `<PROMPT_MEMORY>` before the delegated specialist sees the task.

A separate `SessionEnd` server-stop hook participates in normal cleanup, while the outer wrapper still performs deterministic shutdown in `finally`.

For the complete `SessionStart` ? PROMPT ? ALGORITHM ? TEST ? `Stop` ? server-cleanup path, see [Detailed session and hook data flow](docs/session_hook_flow.md).

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
│   ├── qwen_chat.ps1
│   ├── watch_qwen_chat.ps1
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
Qwen Code 0.22.3
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
- configures three role-specific logical OpenAI-compatible providers for PROMPT, ALGORITHM, and TEST, including their reasoning profiles;
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

This remains the recommended coding entry point.

The wrapper performs:

```text
Qwen Code compatibility verification
        |
        v
shared llama.cpp router verification/start
        |
        v
interactive Qwen Code session
        |
        v
idle-aware shared-server cleanup
```

The CLI holds an exclusive client lease while Qwen Code is active. When Qwen Code exits, the wrapper asks the shared server to stop only if no coding CLI and no plain-chat client still owns a lease.

### 9. Start the plain chat UI

Use:

```powershell
.\scripts\qwen.cmd chat
```

This path bypasses Qwen Code orchestration, hooks, project memory, and agent roles. It opens the built-in llama.cpp Web UI in a dedicated Chrome app window, with Edge as fallback.

Chat browser data is isolated under:

```text
%USERPROFILE%\.qwen\chat_ui\
```

including the dedicated browser profile and export directory.

The shared inference router uses:

```text
canonical model ID
  qwen3.8-27b-chat

Qwen Code role aliases
  qwen3.8-27b-local
  qwen3.8-27b-algorithm
  qwen3.8-27b-test
```

Only one physical GGUF is loaded. `--models-max 1` and `--parallel 1` remain the reference production policy.
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

Server default reasoning effort:
  xhigh

Reasoning budget:
  -1

Reasoning preserve:
  enabled
```

These settings were selected through the benchmark suite included in this repository. They are a validated reference configuration for the tested machine, not a universal optimum.

### Role-specific model and reasoning routing

The reference production server runs llama.cpp in router mode with one preset and one physical GGUF.

The canonical router model ID is:

```text
qwen3.8-27b-chat
```

Qwen Code continues to address the same model through three role aliases:

```text
qwen3.8-27b-local      -> PROMPT     -> xhigh
qwen3.8-27b-algorithm  -> ALGORITHM  -> xhigh
qwen3.8-27b-test       -> TEST       -> medium
```

The canonical `chat` ID is used by the built-in llama.cpp Web UI. The role aliases are API aliases for Qwen Code; they do not create extra model instances or extra VRAM copies.

The generated router preset uses:

```text
[qwen3.8-27b-chat]
model = <configured GGUF path>
alias = qwen3.8-27b-local,qwen3.8-27b-algorithm,qwen3.8-27b-test
load-on-startup = true
```

and the router is limited to one loaded model with `--models-max 1`.

All Qwen Code providers use the same OpenAI-compatible base URL and the same physical model.

The agent frontmatter selects the logical provider:

```yaml
# algorithm-agent.md
model: qwen3.8-27b-algorithm
```

```yaml
# test-agent.md
model: qwen3.8-27b-test
```

The corresponding provider entry in `settings.json` controls the reasoning profile. For example, the TEST role uses:

```json
"generationConfig": {
  "reasoning": {
    "effort": "medium"
  },
  "extra_body": {
    "reasoning_effort": "medium"
  }
}
```

`generationConfig.reasoning.effort` represents the Qwen Code-side reasoning configuration. The explicit `extra_body.reasoning_effort` field is the wire-level override sent through the OpenAI-compatible request to `llama.cpp`.

The server-level `--reasoning-effort xhigh` remains the reference fallback/default. Role-specific requests can override that default without loading another GGUF or another inference router.
# algorithm-agent.md
model: qwen3.8-27b-algorithm
```

```yaml
# test-agent.md
model: qwen3.8-27b-test
```

The corresponding provider entry in `settings.json` controls the reasoning profile. For example, the TEST role uses:

```json
"generationConfig": {
  "reasoning": {
    "effort": "medium"
  },
  "extra_body": {
    "reasoning_effort": "medium"
  }
}
```

`generationConfig.reasoning.effort` represents the Qwen Code-side reasoning configuration. The explicit `extra_body.reasoning_effort` field is the wire-level override sent through the OpenAI-compatible request to `llama.cpp`.

The server-level `--reasoning-effort xhigh` remains the reference fallback/default. Role-specific requests can override that default without loading another GGUF or another inference server.

## Qwen Code compatibility layer

The runtime manager intentionally distinguishes **two compatibility patches** from a separate **compression optimization**.

### SubagentStart context propagation

Foreground `SubagentStart` hook `additionalContext` is appended to the effective delegated task prompt.

This is required for the role-specific handoff produced by the orchestration layer to reach ALGORITHM or TEST.

### PreToolUse argument rewriting

A rewritten `tool_input` returned through `PreToolUse` becomes the effective tool invocation input.

This is required both for controlled maintenance behavior and for the prompt-memory carrier to be removed before the real `Agent` call.

### Compression optimization

Compression is a separate local optimization layer rather than a compatibility patch.

For the current Qwen Code 0.22.3 runtime the production path is:

```text
COMPACT_MAX_OUTPUT_TOKENS
  stock 2e4 / 20000
  -> first production optimization 4096
  -> final production 3072

auto-compaction threshold at 49152 context
  stock approximately 16152
  -> 4096 cap: 32056
  -> final 3072 cap: 33080

compression directive
  analysis + large historical summary
  ->
  direct compact <state_snapshot>

state snapshot
  goal
  durable_constraints
  current_state
  open_issues
  next_step
```

The target snapshot is roughly 800-1500 tokens and omits full messages, long source listings, routine tool calls, and transient exploration.

The final cap was selected after exact 4096/3072/2048 compaction runs and strict semantic-retention tests. All three tested caps preserved the required state semantics, but 3072 was selected as the production balance between later compaction and output-budget safety headroom. Production compaction keeps `xhigh` reasoning because the tested medium override materially reduced cache sharing.

See [Compression tuning](docs/compression_tuning.md) for the measured A/B/C results and final decision.

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

Qwen Code 0.22.3 applies stricter built-in behavior to non-interactive `-p` execution. In non-interactive `auto` mode it can synthesize deny rules for shell/edit/write capabilities before a subagent override is created.

Therefore:

- a failing `-p --approval-mode auto` write probe is **not** evidence that the normal interactive ALGORITHM role cannot write;
- interactive role capability must be validated through the interactive production path;
- headless tests should be treated as a separate execution mode with separate permission semantics.

No third runtime patch is used to bypass those headless safety rules.

## Lifecycle management

The production runtime is shared by two client paths:

```text
coding CLI
  .\scripts\qwen.cmd
  -> Qwen Code
  -> CLI lease

plain chat
  .\scripts\qwen.cmd chat
  -> llama.cpp Web UI
  -> chat lease
```

Both paths use the same router listener and the same single loaded GGUF.

The lifecycle invariant is:

```text
CLI active
  -> server stays running

chat active
  -> server stays running

CLI + chat active
  -> server stays running

CLI exits while chat remains
  -> QWEN_SERVER_STATUS=KEPT_FOR_CHAT

chat closes while CLI remains
  -> QWEN_SERVER_STATUS=KEPT_FOR_CLI

last client exits
  -> unload model child
  -> stop router
```

Qwen Code's `SessionEnd` server-stop hook uses idle-aware shutdown. The outer CLI wrapper also performs `-IfIdle` cleanup after releasing its CLI lease, so missing `SessionEnd` delivery does not leave the runtime unmanaged.

The chat watcher owns an exclusive `chat.lock` while the dedicated browser app is active. Browser absence must persist for multiple samples before that lease is released, avoiding shutdown from a transient Chrome process-list miss.
## Fail-closed server ownership

Server shutdown starts from the authoritative listener owner for the configured host/port; it does not kill by process name alone.

The stop path:

```text
resolve listener PID
-> require exactly one owner
-> inspect Win32_Process through CIM
-> verify exact executable name
-> prefer exact ExecutablePath match
-> otherwise require strict host/port plus legacy-model or router-preset command-line evidence
-> if -IfIdle: keep server while any CLI/chat lease is active
-> if router mode: request /models/unload for qwen3.8-27b-chat
-> wait for the model child to exit
-> revalidate listener ownership
-> terminate router
-> wait until the port is free
```

The router preset is generated from `config/local.ps1` values at server start and stored under the configured Qwen root, not in the Git repository.

A vanished process is handled as a benign race only when the listener is no longer owned by that PID. Ambiguous identity, a conflicting process, an unexpected model topology, or a listener-owner change fails closed.

The PID printed during startup may differ from the final router listener PID; listener ownership is authoritative.
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

`xhigh` remained the server-wide fallback/default. The current role policy uses:

```text
PROMPT     xhigh
ALGORITHM  xhigh
TEST       medium
```

The earlier v3 ? v4 orchestration change reduced cumulative tokens from `339536` to `234973`, approximately `30.8%`, while final TEST verification still passed.

### Agent execution-efficiency follow-up

A later fresh FastAPI orchestration benchmark exposed excessive specialist tool/model round trips.

Observed cumulative-token chain:

```text
pre-efficiency-patch
  387178

after ALGORITHM execution-efficiency rules
  340769

after ALGORITHM + TEST execution-efficiency rules
  262032
```

The final `262032` run was approximately `32.3%` below the pre-patch `387178` run and approximately `23.1%` below the intermediate `340769` run. It remained about `11.5%` above the earlier `234973` v4 benchmark while preserving independent TEST PASS.

Final fresh-run topology:

```text
ALGORITHM
  7 rounds
  10 tools

TEST
  3 rounds
  4 tools

compactions
  0
```

The cumulative-token metric repeats cached prefixes across requests, so it is not identical to unique uncached model work. In the final run the cached-input ratio was high and uncached input was substantially smaller than cumulative input.

### Compression E2E

The first fresh compression validation after the runtime optimization produced one visible compaction:

```text
approximately 34772 tokens
-> approximately 21867 tokens
```

Execution then continued successfully through independent TEST verification with 9 tests passing. This is evaluated separately from the no-compaction FastAPI efficiency benchmark.

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

Therefore `p-min = 0.025` remains the reference setting.

Machine-readable historical benchmark reports remain under `results/reference/`.
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

The current production reference configuration is specifically validated against:

```text
Qwen Code 0.22.3
llama.cpp b10636
Qwen3.8-27B-UD-Q3_K_XL.gguf
Windows + CUDA 13.3
```

Qwen Code upgrades must still be treated deliberately because both compatibility patches and the separate compression optimization depend on known runtime semantics. Unknown or mixed runtime structures fail closed.
## License

The original code and documentation in this repository are licensed under the Apache License 2.0.

See [LICENSE](LICENSE).

Third-party projects retain their own licenses.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Project focus

This project is primarily an orchestration and local-inference engineering project.

Its contribution is the system around the underlying Qwen model, Qwen Code, and llama.cpp:

```text
local inference
+ shared router-backed coding and plain-chat interfaces
+ PROMPT / ALGORITHM / TEST role separation
+ stable project identity
+ bounded stable-ID durable memory
+ role-isolated specialist context
+ delayed prompt-memory transport
+ explicit workflow state
+ lifecycle hooks
+ compatibility management
+ compact context compression
+ deterministic server cleanup
+ independent verification
+ benchmark-driven configuration
```

The result is a reproducible local coding-agent workflow designed to behave like a controlled engineering system rather than a single unconstrained chat model.

# Architecture

## Overview

This project turns a fully local Qwen Code installation into a structured coding orchestrator backed by `llama.cpp`.

The goal is not simply to run a local coding model. The system adds explicit role separation, lifecycle control, stable project identity, controlled durable memory, workflow state, independent verification, bounded maintenance, deterministic server ownership, and reproducible inference configuration around the local model.

```text
User
  |
  v
Qwen Code
  |
  +--> PROMPT role
  |      Main interaction, planning, routing, project coordination
  |
  +--> ALGORITHM role
  |      Implementation and focused technical reasoning
  |
  +--> TEST role
         Independent verification and bounded test execution
```

All roles use the same local model endpoint, but they operate under different instructions, tool lists, context injection rules, and responsibilities.

## Main components

### Qwen Code

Qwen Code provides the interactive coding CLI, tool execution, agent infrastructure, session handling, and lifecycle hook system.

The reference implementation was developed and validated against:

```text
Qwen Code 0.22.2
```

### llama.cpp

`llama-server` provides the OpenAI-compatible local inference endpoint.

Reference endpoint:

```text
http://127.0.0.1:8080/v1
```

The server is started on demand and stopped after the Qwen Code process exits.

### Local model

The reference configuration uses:

```text
Qwen3.8-27B-UD-Q3_K_XL.gguf
```

The model itself is not included in this repository.

### Orchestration layer

The orchestration source is:

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

Responsibilities are intentionally split:

| Component | Responsibility |
| --- | --- |
| `QWEN.md` | Main PROMPT-role orchestration policy |
| `agents/algorithm-agent.md` | ALGORITHM role instructions and tool surface |
| `agents/test-agent.md` | TEST role instructions and tool surface |
| `hook_dispatcher.py` | Lifecycle dispatch, context injection, orchestration coordination |
| `maintenance_hook.py` | Controlled `PreToolUse` maintenance behavior |
| `project_identity.py` | Stable project identity resolution |
| `project_registry.py` | Project registry and project-level bookkeeping |
| `memory_protocol.py` | Structured memory-update protocol |
| `memory_store.py` | Durable memory/journal storage operations |
| `workflow_state.py` | Explicit bounded workflow/delegation state |

## Role separation

### PROMPT role

The main Qwen Code process acts as coordinator.

Responsibilities include:

- understanding the user's task;
- gathering relevant context;
- deciding whether delegation is needed;
- coordinating implementation;
- integrating results;
- deciding when independent verification is required;
- preserving the user-facing task thread.

PROMPT should not mechanically delegate every request.

### ALGORITHM role

The ALGORITHM agent is intended for implementation-heavy work and focused technical reasoning.

Typical responsibilities include:

- implementing requested changes;
- analyzing algorithms;
- tracing technical failure modes;
- making targeted code changes;
- running bounded implementation-side checks;
- reporting what changed and why.

Its configured tool list includes:

```text
read_file
grep_search
glob
edit
notebook_edit
write_file
run_shell_command
```

The ALGORITHM role is the primary writer.

### TEST role

The TEST agent acts as an independent verifier.

Typical responsibilities include:

- reviewing implementation independently;
- checking important invariants;
- running bounded smoke tests;
- identifying regressions or unresolved failures;
- reporting whether the task is actually complete.

Its configured tool list includes:

```text
read_file
grep_search
glob
run_shell_command
```

It intentionally does not receive direct `edit` or `write_file` tools.

However, `run_shell_command` is inherently capable of modifying files. TEST is therefore **not capability-level read-only**. The role instruction prohibits intentional persistent repository source modification and reserves shell use for bounded verification.

The separation between ALGORITHM and TEST reduces self-verification bias without pretending that shell execution is technically immutable.

## Approval and permission semantics

The normal production workflow is interactive. The parent PROMPT process runs as the coordinator, while specialized agents use their configured agent approval mode and tool surface.

Interactive validation confirmed:

```text
PROMPT
  coordinator

ALGORITHM
  direct edit/write + shell capability

TEST
  read/search + shell capability
  no direct edit/write_file tools
```

### Headless `-p` caveat

Qwen Code 0.22.2 has stricter non-interactive behavior.

During non-interactive `-p` startup, Qwen can synthesize deny entries before the subagent configuration is resolved. In `auto` mode this can include:

```text
run_shell_command
monitor
edit
write_file
```

Those entries are part of the already-built effective config, so a later subagent override is not equivalent to the normal interactive path.

Consequences:

- headless `-p --approval-mode auto` is not a faithful capability probe for the normal interactive ALGORITHM agent;
- interactive role capability is validated through the production interactive path;
- headless benchmarks and smoke tests must be interpreted as a separate execution mode;
- the project does not add a third runtime patch that removes those built-in headless restrictions.

## Lifecycle

The orchestration layer integrates with:

```text
SessionStart
UserPromptSubmit
SubagentStart
SubagentStop
Stop
SessionEnd
PreToolUse
```

### SessionStart

Establishes session-level orchestration context and prepares project-aware state.

### UserPromptSubmit

Updates PROMPT-side coordination context and participates in state/journal handling for the current project.

### SubagentStart

Builds role-specific context for ALGORITHM or TEST.

This is where shared project memory, selected recent PROMPT context, role-private durable memory, and role journal context are injected according to the receiving role.

### SubagentStop

Captures bounded subagent completion information and updates orchestration state.

### Stop

Participates in bounded task-finalization state handling.

### SessionEnd

Participates in session cleanup and state finalization.

A separate server-stop hook is also installed for `SessionEnd`.

### PreToolUse

Invokes the maintenance hook for controlled behavior around shell-command execution.

## Qwen Code compatibility patches

The repository contains:

```text
patches\ensure_qwen_code_patches.ps1
```

The patcher handles two compatibility requirements used by the orchestration design.

### Patch 1: SubagentStart context propagation

Foreground `SubagentStart` hook `additionalContext` must become part of the effective subagent task prompt.

Without this behavior, hook-generated role context can be returned but not actually reach the foreground delegated agent.

The patch appends the hook-produced context into the subagent task passed to the model.

### Patch 2: PreToolUse argument rewriting

The maintenance layer can return a rewritten `tool_input` through `PreToolUse`.

The patch ensures that the rewritten input becomes the actual tool invocation input rather than merely being observed.

### Patch safety

The patcher uses semantic anchors rather than blindly modifying a fixed filename.

Behavior:

```text
already patched
    -> verify

known compatible unpatched runtime
    -> backup
    -> patch
    -> JavaScript syntax check
    -> verify

unknown or mixed runtime
    -> fail closed
```

The validated patched SHA256 for the reference Qwen Code 0.22.2 runtime is:

```text
753C03204D5B6388DCB9885ED5766AC496B449BDA291D27EFB5A110E159DB7ED
```

The patcher is deliberately conservative across Qwen Code upgrades.

## Project identity

Durable state only works correctly if unrelated directories do not collapse into the same project.

The project-identity layer therefore resolves a stable project identity from project-local context and persists the mapping through the registry.

A critical invariant is:

```text
global ~/.qwen/settings.json
!=
project marker
```

Global Qwen configuration exists for every project and must not make unrelated working directories appear identical.

The project-identity implementation is designed so that:

- the same project resolves consistently across processes;
- unrelated projects remain isolated;
- project identity survives session restarts;
- global Qwen settings do not define project identity.

## Durable memory model

Qwen Code managed auto-memory features are disabled in the reference configuration.

Instead, this project uses explicit durable stores controlled by the orchestration layer.

Logical durable-memory layout:

```text
project
├── prompt_agent/
│   └── memory.md
├── algorithm_agent/
│   └── memory.md
└── test_agent/
    └── memory.md
```

The semantics are important:

```text
prompt_agent/memory.md
=
shared durable project memory
```

It is the shared project store, not a PROMPT-private fourth memory.

The other two files are role-private:

```text
algorithm_agent/memory.md
=
ALGORITHM-private durable memory

test_agent/memory.md
=
TEST-private durable memory
```

## Journals versus durable memory

Durable memory and recent operational history are intentionally separate concepts.

### Durable memory

Used for project knowledge intended to survive across sessions and remain useful later.

Examples include stable project constraints, implementation invariants, or durable role-specific knowledge.

### Role journals

Used for recent execution context and handoff information.

They support coordination without turning every recent event into permanent memory.

### Workflow state

Used for bounded orchestration mechanics such as current coordination/delegation state, anti-loop information, and lifecycle state.

This separation prevents a temporary execution trace from automatically becoming permanent project knowledge.

## Context injection matrix

The dispatcher injects context by role.

| Context source | PROMPT | ALGORITHM | TEST |
| --- | :---: | :---: | :---: |
| Shared durable project memory | yes | yes | yes |
| Recent PROMPT project context | coordination path | yes | yes |
| Recent ALGORITHM journal | as needed for coordination | own role | no private access |
| Recent TEST journal | as needed for coordination | no private access | own role |
| ALGORITHM-private durable memory | no | yes | no |
| TEST-private durable memory | no | no | yes |
| Controlled cross-project memory | optional | optional through policy | optional through policy |

The invariant is role isolation: an agent should not receive another specialized role's private durable memory merely because it exists.

## Controlled cross-project memory

Cross-project memory is not globally injected into every task.

It is optional and intentionally controlled.

The purpose is to allow deliberate reuse of genuinely transferable knowledge without destroying project isolation.

The default conceptual boundary remains:

```text
project A durable state
!=
project B durable state
```

## Memory update protocol

Durable memory writes are not treated as arbitrary free-form filesystem edits by every component.

`memory_protocol.py` defines the structured memory-update contract, while `memory_store.py` applies storage operations.

This keeps memory updates explicit and makes the distinction between:

- shared project memory;
- ALGORITHM-private memory;
- TEST-private memory;
- recent journals;
- workflow state

visible in the implementation.

## Workflow state and anti-loop behavior

A local coding agent can otherwise repeatedly cycle:

```text
analyze
-> modify
-> test
-> analyze
-> modify
-> test
-> ...
```

`workflow_state.py` and dispatcher state track enough bounded coordination information to reduce unnecessary repeated delegation and repeated work.

The objective is:

```text
bounded completion
not
autonomous indefinite iteration
```

Anti-loop state is coordination state, not a substitute for durable project memory.

## Hook failure behavior

Different failure classes intentionally use different safety policies.

### Orchestration hook errors

The dispatcher records internal hook failures and can fail open so that an orchestration bug does not necessarily make Qwen Code unusable.

The cost is reduced orchestration reliability for that event, which is surfaced through logging/context.

### Runtime compatibility and process ownership

Runtime patch compatibility and server ownership checks fail closed.

An unknown runtime or ambiguous port owner is not silently modified or terminated.

This distinction is deliberate:

```text
coordination failure
-> preserve usability where possible

unsafe runtime/process ambiguity
-> stop
```

## Server lifecycle

The public wrapper is:

```text
scripts\qwen.cmd
    |
    v
scripts\qwen.ps1
    |
    +--> verify Qwen Code compatibility patches
    |
    +--> ensure llama-server is running
    |
    +--> start Qwen Code
    |
    +--> preserve Qwen Code exit status
    |
    +--> stop llama-server in finally
```

A `SessionEnd` hook also requests server shutdown.

Wrapper-level cleanup remains necessary because headless Qwen Code execution may not reliably emit `SessionEnd`.

The wrapper therefore provides deterministic cleanup independently of hook delivery.

## Server safety

Server management is fail-closed.

Before reusing or terminating a process on the configured port, the scripts verify that it matches the expected local `llama-server` runtime.

The scripts do not intentionally terminate an unrelated process merely because it occupies the same port.

## Installer architecture

`scripts/install_orchestrator.ps1` deploys the orchestration layer into the configured Qwen user directory.

Managed source files include:

```text
QWEN.md
algorithm-agent.md
test-agent.md
hook_dispatcher.py
maintenance_hook.py
memory_protocol.py
memory_store.py
project_identity.py
project_registry.py
workflow_state.py
```

The installer also merges the project-managed settings into `settings.json`.

Important properties:

- unrelated providers are preserved;
- unrelated environment values are preserved;
- existing unrelated deny rules are preserved;
- third-party hooks are preserved;
- managed hooks/providers are replaced rather than duplicated;
- existing managed files and settings are backed up first;
- backup directories use millisecond-resolution timestamps;
- repeated installation is idempotent with respect to managed entries.

The installer does not start the inference server.

## Verification philosophy

Default validation is intentionally bounded.

Typical execution should prefer:

```text
syntax/import check
-> initialization check
-> focused functional path
-> small smoke test
```

rather than automatically executing:

```text
full datasets
long training jobs
large benchmark suites
long integration workloads
```

Large tests remain explicit user actions.

## Validated orchestration paths

The orchestration design has been exercised through separate categories of checks:

### Memory/state

- durable memory write/read across a new process;
- project isolation;
- role isolation;
- stable project identity;
- context isolation;
- SubagentStart memory injection;
- real-model delivery of role-private memory through the full storage-to-model path.

### Interactive role capability

- foreground ALGORITHM delegation created and verified a file;
- foreground TEST delegation executed a read-only shell verification;
- parent remained coordinator.

### Installer

- isolated fresh install;
- complete file deployment;
- repeated install;
- backup creation;
- preservation of unrelated provider/env/deny/hook entries.

These checks intentionally distinguish interactive production behavior from headless Qwen Code behavior.

## Inference architecture

The production design uses one physical GGUF, one `llama-server` process, and three logical Qwen Code model/provider identities:

```text
PROMPT
  -> qwen3.8-27b-local
  -> xhigh

ALGORITHM
  -> qwen3.8-27b-algorithm
  -> xhigh

TEST
  -> qwen3.8-27b-test
  -> medium
```

The three logical model IDs do not represent three separately loaded neural networks. They all target the same OpenAI-compatible `llama.cpp` endpoint and the same loaded GGUF.

Routing is split across two configuration layers:

```text
agent frontmatter
    model: <logical model id>
            |
            v
Qwen Code settings.json provider
    generationConfig.reasoning.effort
    generationConfig.extra_body.reasoning_effort
            |
            v
llama.cpp OpenAI-compatible request
```

For example:

```text
test-agent.md
    model: qwen3.8-27b-test

settings.json
    qwen3.8-27b-test
    -> reasoning.effort = medium
    -> extra_body.reasoning_effort = medium
```

The explicit `extra_body.reasoning_effort` value is used as the wire-level reasoning override for the local OpenAI-compatible provider.

The repository-wide runtime compatibility baseline remains Qwen Code 0.22.2. The role-specific provider routing and request-level reasoning behavior were additionally validated on the production Qwen Code 0.22.3 runtime. The existing 0.22.2 runtime-patch hashes and compatibility statements therefore remain historical reference data rather than being silently relabeled as 0.22.3 results.

`llama-server` is started with all three aliases advertised together. The server's `--reasoning-effort xhigh` remains the fallback/default; the role-specific provider request can override it.

The reference server configuration uses one model instance and one concurrent inference slot:

```text
parallel = 1
context = 49152
GPU layers = 99
fit = off
Flash Attention = on
KV cache = q8_0 / q8_0
batch = 1024
ubatch = 512
threads = 20
threads-batch = 20
threads-draft = 20
threads-draft-batch = 20
reasoning = on
server default reasoning effort = xhigh
reasoning budget = -1
reasoning preserve = enabled
```

Speculative decoding combines:

```text
draft-mtp
+
ngram-mod
```

with:

```text
draft n-max = 2
p-min = 0.025
ngram n-min = 32
ngram n-max = 64
ngram n-match = 16
```

These values are reference results for the tested hardware/model/runtime combination, not universal optimums.

## Design principle

The architecture separates four concerns:

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
roles
+ project identity
+ durable memory
+ journals
+ workflow state
+ hooks
+ validation
+ lifecycle control
```

The portfolio value of the project is therefore not the local model itself. It is the engineering layer that makes local coding inference more structured, controllable, reproducible, stateful, and testable.

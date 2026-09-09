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

The current production reference is:

```text
Qwen Code 0.22.3
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
??? QWEN.md
??? hook_dispatcher.py
??? maintenance_hook.py
??? memory_protocol.py
??? memory_store.py
??? project_identity.py
??? project_registry.py
??? workflow_state.py
??? agents/
    ??? algorithm-agent.md
    ??? test-agent.md
```

Responsibilities are intentionally split:

| Component | Responsibility |
| --- | --- |
| `QWEN.md` | PROMPT orchestration, minimal specialist handoffs, memory-carrier policy |
| `agents/algorithm-agent.md` | Implementation role, private memory policy, execution-efficiency rules |
| `agents/test-agent.md` | Independent verification role, private memory policy, verification-efficiency rules |
| `hook_dispatcher.py` | Lifecycle dispatch, role-context construction, prompt-memory carrier, workflow coordination |
| `maintenance_hook.py` | Controlled shell-command `PreToolUse` maintenance |
| `project_identity.py` | Stable project identity resolution |
| `project_registry.py` | Project registry and project-level bookkeeping |
| `memory_protocol.py` | Stable-ID structured durable-memory protocol |
| `memory_store.py` | Bounded compact durable-memory storage |
| `workflow_state.py` | Explicit turn, delegation, verification, anti-loop, and memory-write state |
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

Qwen Code 0.22.3 has stricter non-interactive behavior.

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

Resolves project/session context and supplies PROMPT with compact project memory. Controlled cross-project memory is read only here for the first PROMPT synthesis.

### UserPromptSubmit

Advances the real-user-turn state used by delegation, verification, and delayed durable-memory provenance.

### SubagentStart

Builds role-specific specialist context.

ALGORITHM receives its own compact `Axxx` memory plus the smallest useful PROMPT task delta. TEST receives its own compact `Txxx` memory plus an independent verification delta and limited objective implementation facts.

Neither specialist receives PROMPT/project memory wholesale, cross-project memory, or the other specialist's private memory.

### SubagentStop

Captures bounded completion facts and updates workflow state.

### Stop

Participates in finalization and verification gating.

### SessionEnd

Finalizes session state. A separate server-stop hook also participates in normal server cleanup.

### PreToolUse

Two independent uses exist:

1. shell-command maintenance;
2. `agent` prompt-memory carrier handling.

The second path processes an eligible `<PROMPT_MEMORY>` update and strips the carrier from `tool_input` before the specialist task is invoked.
For the complete event-by-event execution path, see [Detailed Qwen Code session and hook data flow](session_hook_flow.md).

## Qwen Code compatibility patches

The repository contains:

```text
patches\ensure_qwen_code_patches.ps1
```

The patcher manages two compatibility requirements plus one deliberately separate compression optimization.

### Patch 1: SubagentStart context propagation

Foreground `SubagentStart` hook `additionalContext` becomes part of the effective delegated task prompt.

### Patch 2: PreToolUse argument rewriting

A rewritten `tool_input` returned by `PreToolUse` becomes the actual invocation input.

This is required for both controlled maintenance rewrites and reliable prompt-memory carrier stripping.

### Compression optimization

This is documented separately because it is an optimization rather than a compatibility prerequisite.

It reduces the compression output cap from the original `2e4` form to `4096`, requests a compact `<state_snapshot>` directly, and retains only:

```text
goal
durable_constraints
current_state
open_issues
next_step
```

The target is roughly 800?1500 summary tokens.

### Patch safety

State is classified as `patched`, `unpatched`, or `incompatible`.

```text
patched
    -> validate / no-op

known unpatched
    -> backup
    -> transform
    -> node --check
    -> post-validate

mixed / unknown
    -> fail closed
    -> no modification
```

Current Qwen Code 0.22.3 validated hashes:

```text
byte-identical CRLF runtime
662A99EB4C5B80CADE456856754AA9D4B5A005033AF4B6D4228557E237C45DF4

newline-normalized runtime
A326F41C11DD99E30A3FEA26A2FCF2C4E6B69118EC81D8A47ACF1B072746AE70
```

The normalized hash permits equivalent LF/CRLF runtime content while still rejecting unknown semantic structures.
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

Qwen Code managed auto-memory is not used for orchestration memory.

The current design uses bounded stable-ID durable facts:

```text
Pxxx  PROMPT / project
Axxx  ALGORITHM-private
Txxx  TEST-private
Cxxx  cross-project
```

Logical storage still uses role-specific compact memory files, but their contents are not journals or transcripts.

A durable fact should contain only:

```text
durable decision
+ why it matters
+ durable consequence
```

Transient exploration, routine command history, progress narration, and temporary failures do not belong in durable memory.

Default bounds:

```text
MAX_PROJECT_MEMORY_FACTS       12
MAX_AGENT_MEMORY_FACTS         12
MAX_CROSS_PROJECT_MEMORY_FACTS  8
MAX_DURABLE_UPDATE_CHARS      650
MAX_DURABLE_UPDATE_SENTENCES    3
```

`ADD` receives a new stable ID from Python. `REPLACE` and `REMOVE` must name an existing ID owned by the correct role. Invalid or oversized operations are rejected.
## Durable memory and workflow state

The current architecture has **no role journals**.

Two concepts remain separate:

### Durable memory

Small stable-ID facts that should survive sessions and still matter later.

### Workflow state

Bounded transient orchestration mechanics such as:

- real user turn ID;
- delegation selected/started/completed state;
- implementation completion;
- verification state;
- fix cycles;
- misunderstanding counters;
- stop blocks;
- fingerprints;
- `turn_closed`;
- `prompt_memory_written`.

Workflow state prevents loops and coordinates the current execution but is not promoted automatically into durable memory.
## Context injection matrix

Context is deliberately asymmetric:

| Context source | PROMPT | ALGORITHM | TEST |
| --- | :---: | :---: | :---: |
| PROMPT/project compact durable memory | yes | no wholesale injection | no wholesale injection |
| ALGORITHM-private `Axxx` memory | no | yes | no |
| TEST-private `Txxx` memory | no | no | yes |
| Cross-project `Cxxx` memory | `SessionStart` only | no | no |
| Small PROMPT task delta | n/a | yes | verification-specific only |
| ALGORITHM rationale | synthesize only if needed | own execution | no |
| Objective implementation facts | synthesis | own execution | limited factual receipt |
| Workflow state | coordination | phase-relevant only | phase-relevant only |

The invariant is information minimization: a specialist receives only the smallest role-relevant state needed for the current action.
## Controlled cross-project memory

Cross-project memory is intentionally restricted.

It is read only during `SessionStart` / first PROMPT synthesis. Later PROMPT specialist calls do not re-inject it, and ALGORITHM/TEST never receive it.

The boundary is therefore:

```text
cross-project durable knowledge
    -> PROMPT synthesis at SessionStart
    -> task-specific local consequence if relevant
    -> never wholesale into specialists
```

Project-specific durable stores remain isolated.
## Memory update protocol

`memory_protocol.py` defines stable-ID operations and role ownership. `memory_store.py` stores the resulting bounded compact state.

Ownership prefixes are:

```text
P  PROMPT/project
A  ALGORITHM
T  TEST
C  cross-project
```

The model does not choose a new ID for `ADD`; Python allocates it. `REPLACE` and `REMOVE` operate only on existing IDs for the correct role.

PROMPT writes have an additional timing/provenance rule:

```text
turn N may persist only knowledge
whose factual basis existed before prompt N
```

The eligible update is carried on the first already-required `Agent` call as `<PROMPT_MEMORY>`. If the first delegation is sent without the carrier, the turn does not get a later memory-only delegation. The carrier is stripped before the specialist receives its prompt.

This keeps durable persistence off the critical path and prevents current-turn user content from being prematurely promoted into durable memory.
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

Server management is fail-closed and listener-owner based.

For shutdown the script:

1. resolves the process currently owning `127.0.0.1:8080`;
2. requires an unambiguous owner;
3. reads `Win32_Process` through CIM;
4. verifies the expected executable name;
5. prefers exact `ExecutablePath` identity;
6. falls back only to exact name plus command-line host/port/model evidence when the executable path is unavailable;
7. revalidates that the same PID still owns the listener immediately before termination;
8. waits for the port to become free.

No process is terminated merely because its name resembles `llama-server`.

The startup PID and final listener PID can legitimately differ; the listener PID is authoritative.
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

All three logical model IDs target the same OpenAI-compatible endpoint and the same loaded GGUF.

Routing is split across agent frontmatter and provider configuration:

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

The explicit `extra_body.reasoning_effort` field is the wire-level request override used by the local OpenAI-compatible provider.

The current repository/runtime reference is Qwen Code `0.22.3`.

`llama-server` advertises all three aliases together. Server-level `--reasoning-effort xhigh` remains the fallback/default.

Reference inference settings:

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

Speculative decoding:

```text
draft-mtp + ngram-mod

draft n-max = 2
p-min = 0.025
ngram n-min = 32
ngram n-max = 64
ngram n-match = 16
```

These values are specific reference results for the tested hardware/model/runtime combination.
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

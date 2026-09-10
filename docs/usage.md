# Usage

## Overview

The repository provides a Windows-first wrapper around Qwen Code that automatically:

1. verifies the required Qwen Code compatibility patches;
2. starts the local `llama-server` when necessary;
3. launches Qwen Code;
4. preserves the Qwen Code exit status;
5. stops the local inference server when the Qwen process exits.

The normal entry point is:

```powershell
.\scripts\qwen.cmd
```

Normal production use is interactive.

## Initial repository configuration

Copy the example configuration:

```powershell
Copy-Item .\config\local.example.ps1 .\config\local.ps1
```

Edit:

```text
config\local.ps1
```

and set paths for the local installation.

The local configuration file is excluded from Git.

Important values include:

```text
QwenRoot
QwenCodeRoot
LlamaCppRoot
ModelPath
QwenUserRoot
OrchestrationRoot
ModelAlias
AlgorithmModelAlias
TestModelAlias
PromptReasoningEffort
AlgorithmReasoningEffort
TestReasoningEffort
ServerHost
ServerPort
```

The default example root is:

```text
C:\LocalAI\qwen
```

but another location can be used.

## Install the orchestration layer

After configuring `local.ps1`, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install_orchestrator.ps1
```

The installer deploys:

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

into the configured Qwen user/orchestration directories.

It also merges the Qwen Code settings required by this project.

The installer:

- preserves unrelated model providers;
- preserves unrelated environment variables;
- preserves unrelated permission deny rules;
- preserves unrelated settings fields;
- preserves third-party hooks;
- replaces only hooks/providers managed by this project;
- backs up existing managed files and `settings.json`;
- uses millisecond-resolution backup directory names;
- can be run repeatedly without duplicating managed providers, hooks, or deny rules.

The installer does **not** start Qwen Code or `llama-server`.

## Start Qwen Code

From the repository root:

```powershell
.\scripts\qwen.cmd
```

Arguments are forwarded to Qwen Code.

For example:

```powershell
.\scripts\qwen.cmd --version
```

For normal coding use, start without `-p`:

```powershell
.\scripts\qwen.cmd
```

This starts the interactive production workflow.

## Normal coding workflow

A typical interaction is intentionally simple.

Start Qwen Code:

```powershell
.\scripts\qwen.cmd
```

Then describe the coding task normally.

Example:

```text
Add input validation to the parser, update the affected unit tests,
and verify the change with a bounded smoke test.
```

The main PROMPT role coordinates the request.

Depending on the task, it can delegate:

```text
ALGORITHM
  implementation / technical reasoning

TEST
  independent verification
```

You do not need to manually invoke each role for normal use.

## Role behavior

### PROMPT

PROMPT is the main user-facing coordinator.

It handles task interpretation, project context, routing, delegation, and integration of results.

### ALGORITHM

ALGORITHM is the primary implementation role.

Configured tools:

```text
read_file
grep_search
glob
edit
notebook_edit
write_file
run_shell_command
```

It can directly change repository files.

### TEST

TEST is the independent verification role.

Configured tools:

```text
read_file
grep_search
glob
run_shell_command
```

It does not receive direct `edit` or `write_file` tools.

Because `run_shell_command` can technically modify files, TEST is not capability-level read-only. Its role policy prohibits intentional persistent source modification and uses shell execution for bounded verification.

## Memory and project continuity

The orchestrator maintains bounded project-aware state outside the active model context.

Ordinary use does not require manually editing memory files.

### Project identity

Each project receives a stable identity that survives sessions while keeping unrelated workspaces isolated. Global `~/.qwen/settings.json` is not a project marker.

### Durable memory

The current system uses compact stable-ID facts rather than role journals:

```text
Pxxx  PROMPT / project
Axxx  ALGORITHM-private
Txxx  TEST-private
Cxxx  cross-project
```

Durable memory is for stable decisions, constraints, invariants, and consequences?not recent command history.

### Workflow state

Workflow mechanics such as delegation, verification, fix cycles, stop blocks, and per-turn memory-write state are stored separately and are not durable knowledge.

### Cross-project memory

Cross-project memory is considered only at `SessionStart` for PROMPT synthesis. It is never injected wholesale into ALGORITHM or TEST.
## What each role receives

The dispatcher minimizes specialist context.

```text
PROMPT
  compact P/project memory
  + controlled C/cross-project memory at SessionStart only

ALGORITHM
  small task-specific PROMPT delta
  + ALGORITHM-private A memory

TEST
  small verification-specific PROMPT delta
  + TEST-private T memory
  + limited objective implementation facts
```

ALGORITHM does not receive PROMPT/project memory wholesale.

TEST does not inherit ALGORITHM rationale, verdict-like claims, or ALGORITHM-private memory. It independently chooses what to inspect and what checks are sufficient.

Prompt-memory transport is also hidden from specialists: an eligible `<PROMPT_MEMORY>` carrier is processed by `PreToolUse` and stripped before the real `Agent` invocation.
## Context management versus durable memory

The reference model context window is:

```text
49152 tokens
```

Qwen Code session context still has normal context-window limits. Durable project memory and conversational compaction solve different problems.

The local runtime compression optimization uses:

```text
COMPACT_MAX_OUTPUT_TOKENS = 3072
AUTO_COMPACTION_THRESHOLD = 33080
CONTEXT_WINDOW = 49152

<state_snapshot>
  <goal>
  <durable_constraints>
  <current_state>
  <open_issues>
  <next_step>
</state_snapshot>
```

The summary targets roughly 800-1500 tokens and omits full messages, long code, routine tool calls, and transient exploration.

The runtime manager accepts the previous optimized `4096` state as `legacy` and migrates it to the current `3072` state. Unknown or mixed compression structures fail closed.

Durable memory persists selected stable facts across sessions; compaction preserves only enough active execution state to continue the current conversation.

Measured 4096/3072/2048 results and the semantic-retention checks are documented in [Compression tuning](compression_tuning.md).
## Interactive versus headless execution

This distinction matters for tool permissions.

### Interactive production path

Recommended:

```powershell
.\scripts\qwen.cmd
```

Interactive validation confirmed that:

- ALGORITHM receives its direct write/edit capability;
- TEST receives shell capability without direct edit/write tools;
- PROMPT remains the coordinator.

### Non-interactive `-p`

Qwen Code 0.22.3 applies additional safety restrictions in non-interactive mode.

A command such as:

```text
qwen ... --approval-mode auto -p "..."
```

can synthesize deny rules for:

```text
run_shell_command
monitor
edit
write_file
```

during CLI configuration.

Therefore a headless `auto` permission probe is not equivalent to the interactive production workflow.

Do not interpret a failed headless ALGORITHM write probe as proof that interactive ALGORITHM writing is broken.

The project intentionally does not patch away these headless restrictions.

## Validation behavior

The orchestration policy prefers bounded validation.

Typical validation:

```text
syntax check
import check
initialization
focused execution path
small unit or smoke test
```

It should not automatically launch expensive workloads such as:

```text
full model training
full dataset processing
large benchmark suites
long integration runs
```

unless the task explicitly requires them.

## Server lifecycle

You normally do not need to manage `llama-server` manually.

The wrapper performs:

```text
runtime patch/optimization verification
-> server ownership verification/start
-> Qwen Code
-> deterministic server shutdown
```

Shutdown occurs even when Qwen Code exits with an error.

The listener on `127.0.0.1:8080` is authoritative. Shutdown verifies process identity through CIM, rechecks that the same PID still owns the listener, terminates it only when the evidence matches the configured runtime, then waits for the port to become free.

The startup PID may differ from the eventual listener PID.

A `SessionEnd` hook participates in normal cleanup; wrapper `finally` cleanup is the deterministic fallback.
## Manual server commands

### Ensure the server is running

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\ensure_qwen_server.ps1
```

### Start the server directly

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start_qwen_server.ps1
```

### Stop the server

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop_qwen_server.ps1
```

The server scripts are fail-closed around process ownership. They verify the process before reusing or terminating a listener on the configured port.

## Qwen Code session commands

Useful interactive Qwen Code commands include:

```text
/help
/resume
/continue
/summary
/compress
/compress-fast
/recap
/restore
/branch
/rewind
/export md
/doctor
/model
/quit
```

Exact command availability can depend on the installed Qwen Code version.

The reference environment was validated against Qwen Code 0.22.3.

## Reasoning mode

The reference configuration uses role-specific logical model/provider profiles:

```text
PROMPT
  ModelAlias = qwen3.8-27b-local
  PromptReasoningEffort = xhigh

ALGORITHM
  AlgorithmModelAlias = qwen3.8-27b-algorithm
  AlgorithmReasoningEffort = xhigh

TEST
  TestModelAlias = qwen3.8-27b-test
  TestReasoningEffort = medium
```

Each custom agent selects its logical provider through the `model:` field in its Markdown frontmatter.

For example:

```yaml
# algorithm-agent.md
model: qwen3.8-27b-algorithm
```

```yaml
# test-agent.md
model: qwen3.8-27b-test
```

The installer creates corresponding provider entries in `settings.json`. A role provider contains both the Qwen Code-side reasoning value and the explicit request-body override:

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

For the local OpenAI-compatible provider, `extra_body.reasoning_effort` is the explicit wire-level value sent to `llama.cpp`.

All role providers point to the same local endpoint. Only one physical GGUF is loaded.

The corresponding `llama-server` configuration enables reasoning with:

```text
--reasoning on
--reasoning-effort xhigh
--reasoning-budget -1
--reasoning-preserve
```

The server-level `xhigh` setting is the fallback/default. PROMPT and ALGORITHM currently use `xhigh` requests; TEST overrides the server default with `medium`.

## Updating Qwen Code

The project depends on two Qwen Code compatibility behaviors and one separate compression optimization.

After upgrading Qwen Code, launch through:

```powershell
.\scripts\qwen.cmd
```

The runtime manager classifies all required structures.

Possible outcomes:

```text
known patched
    -> validate and continue

known compatible unpatched
    -> backup
    -> apply required compatibility changes
    -> apply compression optimization
    -> node --check
    -> post-validate

known legacy compression state
    -> optimized prompt/directive already present
    -> migrate 4096 cap to 3072
    -> node --check
    -> post-validate

mixed or unknown
    -> fail closed
    -> modify nothing
```

Do not force the transformations onto an unsupported runtime. Re-audit the changed Qwen Code implementation and update the semantic fingerprints deliberately.
## Installer behavior on an existing Qwen setup

The installer is designed to coexist with unrelated Qwen configuration.

Validated preservation cases include:

```text
unrelated OpenAI-compatible provider
unrelated environment variable
unrelated permission deny rule
third-party hook
```

Managed project entries are replaced/merged without duplicating them.

Before overwriting managed files, the installer creates a backup under the configured Qwen root.

## Benchmarking

Benchmark execution is separate from ordinary coding use.

Existing inference suites:

```powershell
.\benchmark\run_full_benchmark.ps1
```

and:

```powershell
.\benchmark\run_pmin_verify.ps1
```

Historical machine-readable reference outputs remain under:

```text
results\reference\
```

The later orchestration-efficiency validation used a fresh FastAPI implementation task and compared:

```text
387178  pre-efficiency patch
340769  after ALGORITHM efficiency rules
262032  after ALGORITHM + TEST efficiency rules
```

All three numbers are cumulative request-token metrics and therefore include repeated/cached prefixes. The final `262032` run retained independent TEST PASS.

Compression was validated separately because the fresh FastAPI efficiency run had zero compactions.

See [Benchmarking](benchmarking.md) for methodology and interpretation.
## Troubleshooting

### Qwen Code does not start

Check:

```text
config\local.ps1
```

and verify that the configured Qwen Code CLI exists.

### llama-server does not start

Verify:

```text
LlamaServerExe
ModelPath
ServerPort
```

in local configuration.

Inspect the local server logs generated by the runtime scripts.

### Port 8080 is already occupied

The server scripts will not blindly terminate the listener.

If the listener is not the expected local `llama-server`, the scripts fail instead.

Resolve the conflicting process or configure another port.

### Patch verification fails after a Qwen Code update

The installed build may no longer match known compatibility anchors.

Use the tested version or inspect/update the compatibility patch deliberately rather than bypassing the fail-closed check.

### ALGORITHM can write interactively but fails in `-p`

This can be expected when `-p` is running with the stricter non-interactive permission path.

Validate normal role capability through the interactive production workflow.

### Project context appears wrong

Start Qwen Code from the intended project directory.

The project-identity layer is designed to isolate projects and does not use global `~/.qwen/settings.json` as the project marker.

### Memory is not reaching a subagent

First verify runtime compatibility/optimization status:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\patches\ensure_qwen_code_patches.ps1
```

Then distinguish the intended data path:

- ALGORITHM should receive its own `Axxx` memory plus a small PROMPT task delta.
- TEST should receive its own `Txxx` memory plus a verification delta.
- Neither specialist should receive PROMPT/project or cross-project memory wholesale.
- `<PROMPT_MEMORY>` should **not** appear in the final specialist prompt; `PreToolUse` processes and strips it.

If PROMPT-memory persistence is missing, verify that `settings.json` has the `PreToolUse` `agent` carrier hook in addition to the shell-maintenance hook.
## Recommended entry point

For normal use, prefer:

```powershell
.\scripts\qwen.cmd
```

rather than starting Qwen Code or `llama-server` independently.

That wrapper provides the complete patch verification, inference lifecycle, exit-code handling, and deterministic cleanup behavior.

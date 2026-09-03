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

The orchestrator automatically maintains project-aware state outside the model context window.

You normally do not need to manually manage the memory files during ordinary use.

### Project identity

Each project receives a stable project identity.

The identity is designed to remain stable across processes/sessions while keeping unrelated projects isolated.

Global Qwen configuration such as:

```text
~/.qwen/settings.json
```

is intentionally **not** treated as a project marker.

Run Qwen Code from the intended project/workspace directory so project-local context can be resolved correctly.

### Shared durable memory

The shared durable project memory is logically stored as:

```text
prompt_agent/memory.md
```

Despite the directory name, this is the **shared project store**, not PROMPT-private memory.

### ALGORITHM-private memory

```text
algorithm_agent/memory.md
```

is private durable memory for ALGORITHM.

### TEST-private memory

```text
test_agent/memory.md
```

is private durable memory for TEST.

### Role journals

Recent role journals are maintained separately from durable memory.

They are used for recent handoff/coordination context rather than automatically becoming permanent project knowledge.

### Workflow state

Workflow state is also separate from durable memory.

It tracks bounded orchestration mechanics such as coordination/delegation state and anti-loop information.

### Cross-project memory

Cross-project memory is optional and controlled.

Project-specific memory is isolated by default; unrelated projects are not globally mixed together.

## What each role receives

The dispatcher injects context according to the receiving role.

```text
PROMPT
  shared project memory
  + recent role journals needed for coordination

ALGORITHM
  shared project memory
  + recent PROMPT context
  + ALGORITHM-private memory
  + ALGORITHM journal

TEST
  shared project memory
  + recent PROMPT context
  + TEST-private memory
  + TEST journal
```

A specialized role does not automatically receive the other specialized role's private durable memory.

## Context management versus durable memory

The reference model context window is:

```text
49152 tokens
```

Qwen Code session context still has normal context-window limits.

Interactive context-management commands such as:

```text
/compress
/summary
/recap
```

manage the active conversation.

The external orchestration memory serves a different purpose: selected project knowledge can survive beyond the current context window and across sessions.

Do not treat conversational compression and durable project memory as the same mechanism.

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

Qwen Code 0.22.2 applies additional safety restrictions in non-interactive mode.

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
patch verification
-> server verification/start
-> Qwen Code
-> deterministic server shutdown
```

Shutdown occurs even if Qwen Code exits with an error.

The Qwen exit code remains primary unless Qwen itself succeeded and cleanup failed.

A `SessionEnd` hook also participates in normal server cleanup, but wrapper-level `finally` cleanup is the deterministic fallback.

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

The reference environment was validated against Qwen Code 0.22.2.

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

The repository reference runtime remains Qwen Code 0.22.2. The role-specific provider/reasoning configuration was additionally validated in the production environment with Qwen Code 0.22.3; this does not by itself constitute a complete migration of the repository runtime-patch baseline to 0.22.3.

## Updating Qwen Code

The project patches specific Qwen Code runtime behavior.

After upgrading Qwen Code, launch through:

```powershell
.\scripts\qwen.cmd
```

The compatibility patcher inspects the installed runtime.

Possible outcomes:

```text
compatible and already patched
    -> verify and continue

known compatible but unpatched
    -> backup, patch, syntax-check, verify

unknown or incompatible
    -> fail closed
```

Do not manually force the patch onto an unsupported build.

If Qwen Code changes the relevant runtime semantics, update and revalidate the compatibility patch deliberately.

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

Benchmark execution is separate from normal coding use.

Full benchmark:

```powershell
.\benchmark\run_full_benchmark.ps1
```

Final `p-min` verification:

```powershell
.\benchmark\run_pmin_verify.ps1
```

These can be significantly more expensive than normal smoke validation.

Reference outputs:

```text
results\reference\
```

New runs:

```text
results\generated\
```

`results\generated\` is excluded from Git.

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

First verify the Qwen Code compatibility patch status:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\patches\ensure_qwen_code_patches.ps1
```

Role-context delivery depends on the `SubagentStart` compatibility behavior being active.

## Recommended entry point

For normal use, prefer:

```powershell
.\scripts\qwen.cmd
```

rather than starting Qwen Code or `llama-server` independently.

That wrapper provides the complete patch verification, inference lifecycle, exit-code handling, and deterministic cleanup behavior.

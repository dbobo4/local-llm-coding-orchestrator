# Usage

## Overview

The repository provides a Windows-first wrapper around a shared local llama.cpp runtime.

Two normal entry points are available:

```powershell
.\scripts\qwen.cmd
```

for the full Qwen Code coding orchestrator, and:

```powershell
.\scripts\qwen.cmd chat
```

for a plain browser chat that bypasses Qwen Code orchestration.

The coding path automatically:

1. acquires a CLI client lease;
2. verifies the required Qwen Code compatibility patches;
3. starts or reuses the shared llama.cpp router;
4. launches Qwen Code;
5. preserves the Qwen Code exit status;
6. releases the CLI lease;
7. stops the shared runtime only when no CLI or chat client remains active.

The chat path starts or reuses the same router, opens the built-in llama.cpp Web UI in a dedicated Chrome app window, and keeps a chat lease active until that window is closed.

Normal production coding use remains interactive.
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
ChatModelAlias
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

This starts the interactive production workflow and acquires a CLI lease for the lifetime of the Qwen Code process.

## Plain chat UI

For direct chat without Qwen Code orchestration:

```powershell
.\scripts\qwen.cmd chat
```

The chat path:

```text
browser
  -> built-in llama.cpp Web UI
  -> shared llama.cpp router
  -> qwen3.8-27b-chat
```

It intentionally bypasses:

```text
Qwen Code
PROMPT / ALGORITHM / TEST
lifecycle hooks
project identity
orchestration durable memory
workflow state
```

Chrome is preferred and Microsoft Edge is used only as fallback.

The dedicated browser data root is:

```text
%USERPROFILE%\.qwen\chat_ui
```

with:

```text
browser-profile\
exports\
```

The dedicated profile keeps llama.cpp Web UI browser storage separate from the user's ordinary browser profile.

If the chat app is already open, running `qwen chat` again reuses it instead of opening another dedicated app window.

The router canonical model ID is:

```text
qwen3.8-27b-chat
```

while the existing Qwen Code model names remain aliases to the same GGUF:

```text
qwen3.8-27b-local
qwen3.8-27b-algorithm
qwen3.8-27b-test
```
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
40960 tokens
```

Qwen Code session context still has normal context-window limits. Durable project memory and conversational compaction solve different problems.

The local runtime compression optimization uses:

```text
COMPACT_MAX_OUTPUT_TOKENS = 3072
AUTO_COMPACTION_THRESHOLD = 24888
CONTEXT_WINDOW = 40960

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

The production server runs in router mode with one generated model preset and one loaded model maximum.

The shared lifecycle is:

```text
qwen
  -> CLI lease
  -> Qwen Code

qwen chat
  -> chat lease
  -> dedicated browser Web UI

either lease active
  -> keep shared router/model alive

no lease active
  -> explicit model unload
  -> router shutdown
```

`qwen` and `qwen chat` can therefore coexist. Requests still use the reference `--parallel 1` policy, so simultaneous generation is serialized rather than creating multiple model slots.

When Qwen Code exits while chat remains open, idle cleanup reports:

```text
QWEN_SERVER_STATUS=KEPT_FOR_CHAT
```

When the chat window closes while a CLI remains active, cleanup reports:

```text
QWEN_SERVER_STATUS=KEPT_FOR_CLI
```

When the last client exits, the stop path explicitly unloads the canonical model child through the router before terminating the router listener.

The listener on the configured host/port remains authoritative for process identity. Shutdown verifies the listener owner through CIM, prefers exact executable-path validation, supports a strict legacy-model/router-preset command-line fallback, and waits for the port to become free.

The startup PID may differ from the eventual router listener PID.

The Qwen Code `SessionEnd` hook uses `-IfIdle`; wrapper cleanup is the deterministic fallback. The chat watcher owns an exclusive `chat.lock` and releases it only after sustained absence of the dedicated browser app process.
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

The reference llama.cpp router exposes one canonical model ID plus three Qwen Code role aliases:

```text
canonical chat model
  ChatModelAlias = qwen3.8-27b-chat

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

The canonical chat ID and all three role aliases resolve to the same physical GGUF.

Each custom Qwen Code agent selects its role alias through the `model:` field in its Markdown frontmatter.

For example:

```yaml
# algorithm-agent.md
model: qwen3.8-27b-algorithm
```

```yaml
# test-agent.md
model: qwen3.8-27b-test
```

The installer creates corresponding Qwen Code provider entries in `settings.json`. A role provider contains both the Qwen Code-side reasoning value and the explicit request-body override:

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

The server-level configuration enables:

```text
--reasoning on
--reasoning-effort xhigh
--reasoning-budget -1
--reasoning-preserve
```

The server-level `xhigh` setting is the fallback/default. PROMPT and ALGORITHM currently use `xhigh` requests; TEST overrides the server default with `medium`.

Plain chat does not use the Qwen Code role-provider routing layer; it addresses the canonical `qwen3.8-27b-chat` router model directly.
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
    -> create transient rollback snapshot
    -> apply required compatibility changes
    -> apply compression optimization
    -> node --check
    -> post-validate
    -> delete snapshot on success

known legacy compression state
    -> optimized prompt/directive already present
    -> migrate 4096 cap to 3072
    -> node --check
    -> post-validate

mixed or unknown
    -> fail closed
    -> modify nothing
```

The patch rollback snapshot is transactional rather than historical. A failed patch restores the original runtime from the snapshot and then removes it; a successful post-validation also removes the snapshot. Persistent patch-backup retention is zero.

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

Benchmark execution is optional and separate from ordinary coding use.

There is one public benchmark entry point:

```powershell
.\benchmark\benchmark_qwen.ps1
```

With no switches it runs the full adaptive sequence automatically: preflight, NGRAM screening and real-agent gate, adaptive `p-min` comparison, Q8/Q8 context/KV selection and quality gate, optional Q8/Q5 capacity exploration, then the final recommendation.

The result is a recommendation within the tested candidate set for the current machine; it is not a claim of a global optimum.

The benchmark does not modify production configuration while testing. At the end it asks whether to apply the primary tested recommendation. Only an explicit `Y` transactionally updates the benchmark-tunable values in Git-ignored `config\local.ps1` and synchronizes the managed Qwen Code provider context-window metadata. Reasoning effort remains unchanged and is not auto-tuned.

Temporary benchmark servers and workspaces are cleaned up on completion and error paths.

Historical machine-readable reports from the earlier benchmark implementations remain under:

```text
results\reference\
```

For a preflight-only environment check:

```powershell
.\benchmark\benchmark_qwen.ps1 -PreflightOnly
```

See [Benchmarking](benchmarking.md) for methodology, candidate-selection rules, historical reference measurements, and interpretation.

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

### Chat closes the server while Qwen Code is still active

The shared lifecycle uses client leases. Verify that the coding wrapper was used through `scripts\qwen.cmd` and that `~\.qwen\runtime_clients\cli\` contains a locked lease while Qwen Code is active.

For chat, the watcher owns `~\.qwen\runtime_clients\chat.lock` while the dedicated browser app is open.

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

For normal coding use, prefer:

```powershell
.\scripts\qwen.cmd
```

For plain local chat without coding orchestration, use:

```powershell
.\scripts\qwen.cmd chat
```

Do not start a second standalone llama.cpp server for the chat path. Both entry points intentionally share the same router and physical GGUF, with client leases controlling idle shutdown.

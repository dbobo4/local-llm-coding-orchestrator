# Detailed Qwen Code Session and Hook Data Flow

This document describes the **current** orchestration architecture. The former journal-based context-injection design is not part of this flow.

## End-to-end flow

```text
QWEN CODE SESSION STARTS
        |
        v

====================== HOOK: SessionStart ======================

settings.json
        |
        | SessionStart -> hook_dispatcher.py
        v
Qwen Code -> hook_dispatcher.py
        |
        +--> resolve project identity
        |
        +--> initialize session/workflow state
        |
        +--> build PROMPT SessionStart context
        |
        |     includes:
        |       - PROMPT/project durable memory (Pxxx)
        |       - cross-project durable memory (Cxxx), if present
        |
        |     excludes:
        |       - ALGORITHM-private memory
        |       - TEST-private memory
        |       - execution journals
        |
        |     cross-project context is allowed only at this
        |     SessionStart / first-PROMPT-synthesis boundary
        |
        +--> return additionalContext to Qwen Code
              compact Pxxx + optional Cxxx context

==================== END HOOK: SessionStart ====================

        |
        v
Qwen Code
        |
        | SessionStart additionalContext becomes part
        | of the main session context
        |
        v
USER PROMPT
        |
        v
Qwen Code
        |
        | event: UserPromptSubmit
        v

=================== HOOK: UserPromptSubmit =====================

hook_dispatcher.py
        |
        +--> identify new real user turn
        |
        +--> create/update workflow_state.py state
        |
        +--> reset per-turn gating
        |
        +--> continue = true
        |
        |     no specialist-memory injection
        |     no cross-project reinjection

================= END HOOK: UserPromptSubmit ===================

        |
        v
PROMPT input
        |
        +--> Qwen Code system instructions
        +--> tool schemas
        +--> ~/.qwen/QWEN.md
        +--> SessionStart additionalContext
        |       Pxxx project memory
        |       Cxxx cross-project memory from SessionStart only
        +--> current user prompt
        |
        v
qwen3.8-27b-local
        |
        | reasoning_effort = xhigh
        v
llama.cpp
        |
        v
+-----------------+
|   QWEN3.8-27B   |
|   PROMPT ROLE   |
+-----------------+
        |
        +--> decide that ALGORITHM is required
        |
        +--> synthesize smallest useful task-specific delta
        |
        |     typical fields:
        |       OBJECTIVE
        |       REQUIREMENTS
        |       AVOID
        |       TASK CONTEXT
        |
        |     target size: roughly 120 words
        |
        +--> if a delayed PROMPT-memory update is eligible:
        |       attach temporary <PROMPT_MEMORY> carrier
        |       to the first already-required Agent call
        |
        |     invariants:
        |       - never create Agent call only to save memory
        |       - maximum one PROMPT-memory op per user turn
        |       - if first real Agent call leaves without carrier,
        |         no later P-memory update is allowed that turn
        |
        v
AGENT TOOL CALL
        |
        | agent = algorithm-agent
        | task = explicit PROMPT delta
        | optional temporary <PROMPT_MEMORY> carrier
        v

====================== HOOK: PreToolUse ========================

Agent matcher -> hook_dispatcher.py
        |
        +--> valid <PROMPT_MEMORY>:
        |       memory_protocol.py validates operation
        |       ownership must be PROMPT / Pxxx
        |       memory_store.py applies durable update
        |       workflow_state.prompt_memory_written updates
        |
        +--> malformed or suspicious carrier:
        |       no memory write
        |       suspicious metadata removed
        |
        +--> carrier is always removed before specialist task
        |
        +--> compatibility Patch 2 makes rewritten tool_input
              the actual Agent invocation input

==================== END HOOK: PreToolUse ======================

        |
        v
Qwen Code
        |
        +--> load algorithm-agent.md
        +--> model = qwen3.8-27b-algorithm
        |
        | event: SubagentStart
        v

===================== HOOK: SubagentStart ======================

hook_dispatcher.py
        |
        | agent_type = algorithm-agent
        |
        +--> workflow state:
        |       algorithm_selected = true
        |       algorithm_started = true
        |
        +--> ALGORITHM additionalContext:
        |       own Axxx durable memory only
        |
        |     excludes:
        |       - Pxxx memory wholesale
        |       - Cxxx cross-project memory
        |       - Txxx memory
        |       - execution journals
        |       - redundant phase-context reconstruction

=================== END HOOK: SubagentStart ====================

        |
        v
ALGORITHM input
        |
        +--> Qwen Code subagent system instructions
        +--> algorithm-agent.md
        +--> explicit PROMPT task delta
        +--> Axxx private durable memory
        |
        v
qwen3.8-27b-algorithm
        |
        | reasoning_effort = xhigh
        v
llama.cpp
        |
        v
+-----------------+
|   QWEN3.8-27B   |
| ALGORITHM ROLE  |
+-----------------+
        |
        +--> implement
        +--> retrieve current library docs when materially required
        +--> perform bounded implementation-side validation
        +--> return compact implementation receipt
        |
        v

===================== HOOK: SubagentStop =======================

hook_dispatcher.py
        |
        +--> algorithm_completed = true
        +--> update implementation state
        +--> capture concrete receipt / warning / blocker facts

=================== END HOOK: SubagentStop =====================

        |
        v
PROMPT role
        |
        +--> normalize ALGORITHM receipt
        |
        +--> TEST receives only objective subset:
        |       changed-file claims
        |       reported check/result
        |       concrete warning/blocker/uncertainty
        |
        |     does not inherit:
        |       ALGORITHM rationale wholesale
        |       interpretation
        |       self-asserted verdict
        |       verification requirements invented from
        |       ALGORITHM implementation choices
        |
        +--> synthesize smallest useful TEST delta
        |
        |     typical fields:
        |       VERIFY
        |       IMPLEMENTATION CONTEXT
        |       REPORTED CHECK
        |       REPORTED NOTE
        |
        |     target size: roughly 100 words
        |
        v
AGENT TOOL CALL
        |
        | agent = test-agent
        v

===================== HOOK: SubagentStart ======================

hook_dispatcher.py
        |
        | agent_type = test-agent
        |
        +--> workflow state:
        |       test_selected = true
        |       final_test_started = true
        |
        +--> TEST additionalContext:
        |       own Txxx durable memory
        |       minimal verification phase guard
        |
        |     representative guard:
        |       Final independent verification after implementation.
        |       Do not modify repository files.
        |       Return PASS, FAIL, or BLOCKED.
        |
        |     excludes:
        |       - Pxxx memory wholesale
        |       - Axxx memory
        |       - Cxxx memory
        |       - execution journals
        |       - ALGORITHM rationale

=================== END HOOK: SubagentStart ====================

        |
        v
qwen3.8-27b-test
        |
        | reasoning_effort = medium
        v
llama.cpp
        |
        v
+-----------------+
|   QWEN3.8-27B   |
|    TEST ROLE    |
+-----------------+
        |
        +--> independently reread relevant repository files
        +--> choose smallest sufficient verification set
        +--> at most one targeted extra probe per uncovered issue
        +--> do not intentionally modify repository source
        +--> return PASS / FAIL / BLOCKED
        |
        v

===================== HOOK: SubagentStop =======================

hook_dispatcher.py
        |
        +--> final_test_completed
        +--> verification_status
        +--> verification_after_implementation
        +--> failure fingerprint / fix-cycle state as needed
        |
        v
PROMPT role
        |
        +--> synthesize result
        +--> enter bounded fix cycle if required
        +--> otherwise attempt completion
        |
        v

========================== HOOK: Stop ===========================

hook_dispatcher.py
        |
        +--> verify:
        |       whether final verification is required
        |       whether verification occurred after implementation
        |       whether blocker/failure remains open
        |       whether stop-loop state permits closure
        |
        +--> if not closable:
        |       block Stop
        |
        +--> if closable:
                turn_closed = true

======================== END HOOK: Stop =========================

        |
        v
USER receives final response
        |
        v
SessionEnd, when emitted by the Qwen Code path
        |
        +--> session-state cleanup
        |
        v
Qwen Code process exits
        |
        v
outer qwen wrapper
        |
        +--> release CLI lease
        |
        +--> stop_qwen_server.ps1 -IfIdle runs as deterministic fallback
        |
        +--> if chat lease is active:
        |       keep shared llama.cpp router/model running
        |
        +--> otherwise:
                resolve port 8080 listener OwningProcess
                validate identity through Win32_Process
                explicitly unload router model child when applicable
                stop validated llama.cpp router
                verify port is free
        |
        v
QWEN LIFECYCLE ENDS
```

## State boundaries

The flow intentionally separates four kinds of state:

```text
durable memory
    Pxxx / Axxx / Txxx / Cxxx

workflow state
    per-turn delegation / implementation / verification state

active conversation context
    Qwen Code session context + compact task deltas

runtime process state
    llama.cpp router/model-child ownership + CLI/chat client leases
```

The boundaries are deliberate:

- durable memory is not an execution journal;
- specialist context is not a copy of PROMPT state;
- cross-project memory is not reinjected after `SessionStart`;
- TEST does not inherit ALGORITHM rationale;
- `<PROMPT_MEMORY>` transport is stripped before specialist execution;
- process ownership is not inferred from process name alone.

## Shared CLI / plain-chat server lifecycle

The hook flow above describes the Qwen Code coding path. A second user-facing path is intentionally outside the orchestration layer:

```text
qwen chat
    -> built-in llama.cpp Web UI
    -> qwen3.8-27b-chat canonical router model
```

Plain chat does not emit the Qwen Code orchestration hooks and does not read or write orchestration project memory.

The coding CLI and chat UI share the same local router/model through external client leases:

```text
CLI active
    -> ~/.qwen/runtime_clients/cli/<pid>.lock

chat active
    -> ~/.qwen/runtime_clients/chat.lock

either lease locked
    -> stop -IfIdle keeps server running

no active lease
    -> model child unload
    -> router stop
```

The dedicated chat browser profile is stored under `~/.qwen/chat_ui/browser-profile`. A watcher holds the chat lease while the dedicated app window exists and requires sustained process absence before releasing the lease.

The runtime process state therefore includes both router/model-child ownership and client-lease ownership; neither is orchestration durable memory.

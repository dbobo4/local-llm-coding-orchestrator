from __future__ import annotations

import hashlib
import json
import re
import sys
import traceback
from datetime import datetime, timezone
from typing import Any

from memory_protocol import (
    MemoryUpdate,
    apply_memory_update,
    process_agent_memory_message,
    strip_memory_blocks,
)
from memory_store import (
    INITIAL_CROSS_PROJECT_MEMORY_CONTENT,
    INITIAL_JOURNAL_CONTENT,
    INITIAL_MEMORY_CONTENT,
    INITIAL_MISUNDERSTANDINGS_CONTENT,
    append_journal,
    initialize_memory_structure,
    read_cross_project_memory,
    read_journal,
    read_memory,
    read_misunderstandings,
)
from project_identity import (
    ORCHESTRATION_ROOT,
    ProjectIdentity,
    identify_project,
)
from workflow_state import (
    WorkflowState,
    begin_fix_cycle,
    can_finish_turn,
    create_state,
    delete_session_state,
    equivalent_failure_limit_reached,
    get_active_state,
    get_agent_state,
    increment_stop_block_count,
    mark_algorithm_completed,
    mark_algorithm_started,
    mark_contract_ready,
    mark_final_test_started,
    mark_misunderstandings_read,
    mark_turn_closed,
    mark_verification_blocked,
    mark_verification_pass,
    record_failure,
    register_agent_root_turn,
    requires_fix_cycle,
    set_active_root_turn,
    start_or_resume_user_turn,
    unregister_agent_root_turn,
)


ERROR_LOG_ROOT = ORCHESTRATION_ROOT / "logs"
ERROR_LOG_PATH = ERROR_LOG_ROOT / "hook_errors.log"

# Keep injected Qwen hook context compact.
MAX_AGENT_CONTEXT_CHARS = 3_000

# Fresh PROMPT_AGENT session context.
MAX_SHARED_PROJECT_CONTEXT_CHARS = 700
MAX_PROMPT_SESSION_JOURNAL_CONTEXT_CHARS = 500
MAX_PROMPT_SESSION_ALGORITHM_JOURNAL_CONTEXT_CHARS = 550
MAX_PROMPT_SESSION_TEST_JOURNAL_CONTEXT_CHARS = 650
MAX_CROSS_PROJECT_CONTEXT_CHARS = 100

# Compact subagent context.
MAX_PROMPT_JOURNAL_CONTEXT_CHARS = 350
MAX_ROLE_MEMORY_CONTEXT_CHARS = 350
MAX_ROLE_JOURNAL_CONTEXT_CHARS = 250

MAX_JOURNAL_ENTRY_CHARS = 4_000
MAX_FAILURE_SUMMARY_CHARS = 3_000
MAX_AUTO_MISUNDERSTANDING_CHARS = 1_200


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def _read_hook_input() -> dict[str, Any]:
    raw_bytes = sys.stdin.buffer.read()

    if not raw_bytes:
        return {}

    raw = raw_bytes.decode(
        "utf-8-sig"
    )

    if not raw.strip():
        return {}

    payload = json.loads(
        raw
    )

    if not isinstance(
        payload,
        dict,
    ):
        raise ValueError(
            "Hook input must be a JSON object."
        )

    return payload


def _write_json(
    payload: dict[str, Any],
) -> None:
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
    ).encode(
        "utf-8"
    )

    sys.stdout.buffer.write(
        encoded
    )
    sys.stdout.buffer.flush()


def _log_error(
    event_name: str,
    error: BaseException,
) -> None:
    try:
        ERROR_LOG_ROOT.mkdir(
            parents=True,
            exist_ok=True,
        )

        with ERROR_LOG_PATH.open(
            "a",
            encoding="utf-8",
            newline="\n",
        ) as handle:
            handle.write(
                f"\n## {_utc_timestamp()} | {event_name}\n"
            )

            handle.write(
                "".join(
                    traceback.format_exception(
                        type(error),
                        error,
                        error.__traceback__,
                    )
                )
            )

    except OSError:
        pass


def _normalize_text(
    text: str | None,
) -> str:
    if not text:
        return ""

    return (
        text.replace("\r\n", "\n")
        .replace("\r", "\n")
        .strip()
    )


def _truncate(
    text: str,
    max_chars: int,
) -> str:
    text = _normalize_text(
        text
    )

    if len(text) <= max_chars:
        return text

    marker = "\n\n[... truncated ...]"

    keep = max(
        0,
        max_chars - len(marker),
    )

    return (
        text[:keep]
        + marker
    )


def _truncate_tail(
    text: str,
    max_chars: int,
) -> str:
    text = _normalize_text(
        text
    )

    if len(text) <= max_chars:
        return text

    marker = (
        "[... older journal context omitted ...]\n\n"
    )

    keep = max(
        0,
        max_chars - len(marker),
    )

    return (
        marker
        + text[-keep:]
    )


def _is_default_memory(
    content: str,
) -> bool:
    return (
        _normalize_text(content)
        == _normalize_text(
            INITIAL_MEMORY_CONTENT
        )
    )


def _is_default_journal(
    content: str,
) -> bool:
    return (
        _normalize_text(content)
        == _normalize_text(
            INITIAL_JOURNAL_CONTENT
        )
    )


def _is_default_cross_project_memory(
    content: str,
) -> bool:
    return (
        _normalize_text(content)
        == _normalize_text(
            INITIAL_CROSS_PROJECT_MEMORY_CONTENT
        )
    )


def _is_default_misunderstandings(
    content: str,
) -> bool:
    return (
        _normalize_text(content)
        == _normalize_text(
            INITIAL_MISUNDERSTANDINGS_CONTENT
        )
    )


def _additional_context_output(
    event_name: str,
    context: str,
) -> dict[str, Any]:
    return {
        "continue": True,
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": context,
        },
    }


def _project_identity(
    payload: dict[str, Any],
) -> ProjectIdentity:
    cwd = payload.get(
        "cwd"
    )

    if (
        isinstance(cwd, str)
        and cwd.strip()
    ):
        return identify_project(
            cwd
        )

    return identify_project()


def _get_required_string(
    payload: dict[str, Any],
    key: str,
) -> str | None:
    value = payload.get(
        key
    )

    if not isinstance(
        value,
        str,
    ):
        return None

    value = value.strip()

    return value or None


def _user_prompt_text(
    payload: dict[str, Any],
) -> str:
    for key in (
        "submitted_prompt",
        "prompt",
    ):
        value = payload.get(key)

        if isinstance(value, str):
            normalized = value.strip()

            if normalized:
                return normalized

    return ""


def _synthetic_qwen_turn_id(
    payload: dict[str, Any],
) -> str:
    session_id = _get_required_string(
        payload,
        "session_id",
    ) or "unknown-session"

    timestamp = _get_required_string(
        payload,
        "timestamp",
    ) or _utc_timestamp()

    prompt = _user_prompt_text(
        payload
    )

    material = "\0".join(
        (
            session_id,
            timestamp,
            prompt,
        )
    )

    digest = hashlib.sha256(
        material.encode("utf-8")
    ).hexdigest()[:20]

    return f"qwen-{digest}"


def _normalize_agent_type(
    value: Any,
) -> str:
    normalized = str(
        value or ""
    ).strip()

    aliases = {
        "algorithm-agent": "algorithm_agent",
        "algorithm_agent": "algorithm_agent",
        "test-agent": "test_agent",
        "test_agent": "test_agent",
    }

    return aliases.get(
        normalized,
        normalized,
    )


def _ensure_active_state(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> WorkflowState | None:
    session_id = _get_required_string(
        payload,
        "session_id",
    )

    if session_id is None:
        return None

    state = get_active_state(
        session_id
    )

    if state is not None:
        return state

    observed_turn_id = _get_required_string(
        payload,
        "turn_id",
    )

    if observed_turn_id is None:
        return None

    state = create_state(
        session_id=session_id,
        turn_id=observed_turn_id,
        project_id=identity.project_id,
        overwrite=False,
    )

    set_active_root_turn(
        session_id,
        state.turn_id,
    )

    return state


def _get_subagent_state(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> WorkflowState | None:
    session_id = _get_required_string(
        payload,
        "session_id",
    )

    if session_id is None:
        return None

    agent_id = _get_required_string(
        payload,
        "agent_id",
    )

    if agent_id is not None:
        state = get_agent_state(
            session_id,
            agent_id,
        )

        if state is not None:
            return state

    return _ensure_active_state(
        payload,
        identity,
    )


def _append_context_part(
    parts: list[str],
    heading: str,
    content: str,
    *,
    max_chars: int,
    tail: bool = False,
) -> None:
    if not content:
        return

    if tail:
        rendered = _truncate_tail(
            content,
            max_chars,
        )
    else:
        rendered = _truncate(
            content,
            max_chars,
        )

    parts.append(
        heading
        + rendered
    )


def _build_agent_memory_context(
    identity: ProjectIdentity,
    agent: str,
) -> str:
    shared_project_memory = read_memory(
        identity,
        "prompt_agent",
    )

    prompt_journal = read_journal(
        identity,
        "prompt_agent",
    )

    cross_project_memory = (
        read_cross_project_memory()
    )

    parts: list[str] = []

    if (
        shared_project_memory
        and not _is_default_memory(
            shared_project_memory
        )
    ):
        _append_context_part(
            parts,
            "Shared durable project memory:\n",
            shared_project_memory,
            max_chars=(
                MAX_SHARED_PROJECT_CONTEXT_CHARS
            ),
        )

    if agent == "prompt_agent":
        algorithm_journal = read_journal(
            identity,
            "algorithm_agent",
        )

        test_journal = read_journal(
            identity,
            "test_agent",
        )

        if (
            prompt_journal
            and not _is_default_journal(
                prompt_journal
            )
        ):
            _append_context_part(
                parts,
                "Recent PROMPT_AGENT project journal:\n",
                prompt_journal,
                max_chars=(
                    MAX_PROMPT_SESSION_JOURNAL_CONTEXT_CHARS
                ),
                tail=True,
            )

        if (
            algorithm_journal
            and not _is_default_journal(
                algorithm_journal
            )
        ):
            _append_context_part(
                parts,
                "Recent ALGORITHM_AGENT implementation journal:\n",
                algorithm_journal,
                max_chars=(
                    MAX_PROMPT_SESSION_ALGORITHM_JOURNAL_CONTEXT_CHARS
                ),
                tail=True,
            )

        if (
            test_journal
            and not _is_default_journal(
                test_journal
            )
        ):
            _append_context_part(
                parts,
                "Recent TEST_AGENT verification journal:\n",
                test_journal,
                max_chars=(
                    MAX_PROMPT_SESSION_TEST_JOURNAL_CONTEXT_CHARS
                ),
                tail=True,
            )

    else:
        role_memory = read_memory(
            identity,
            agent,
        )

        role_journal = read_journal(
            identity,
            agent,
        )

        if (
            prompt_journal
            and not _is_default_journal(
                prompt_journal
            )
        ):
            _append_context_part(
                parts,
                "Recent PROMPT_AGENT project context:\n",
                prompt_journal,
                max_chars=(
                    MAX_PROMPT_JOURNAL_CONTEXT_CHARS
                ),
                tail=True,
            )

        if (
            role_memory
            and not _is_default_memory(
                role_memory
            )
        ):
            _append_context_part(
                parts,
                "Role-specific durable memory:\n",
                role_memory,
                max_chars=(
                    MAX_ROLE_MEMORY_CONTEXT_CHARS
                ),
            )

        if (
            role_journal
            and not _is_default_journal(
                role_journal
            )
        ):
            _append_context_part(
                parts,
                "Recent role-specific journal:\n",
                role_journal,
                max_chars=(
                    MAX_ROLE_JOURNAL_CONTEXT_CHARS
                ),
                tail=True,
            )

    if (
        cross_project_memory
        and not _is_default_cross_project_memory(
            cross_project_memory
        )
    ):
        _append_context_part(
            parts,
            "Relevant cross-project memory:\n",
            cross_project_memory,
            max_chars=(
                MAX_CROSS_PROJECT_CONTEXT_CHARS
            ),
        )

    if not parts:
        return ""

    return _truncate(
        "\n\n".join(
            parts
        ),
        MAX_AGENT_CONTEXT_CHARS,
    )


def _append_agent_result_to_journal(
    identity: ProjectIdentity,
    agent: str,
    message: str | None,
) -> None:
    normalized = _normalize_text(
        message
    )

    if not normalized:
        return

    append_journal(
        identity,
        agent,
        _truncate(
            normalized,
            MAX_JOURNAL_ENTRY_CHARS,
        ),
    )


def _process_subagent_message(
    identity: ProjectIdentity,
    agent: str,
    message: str | None,
) -> str:
    if not message:
        return ""

    return process_agent_memory_message(
        identity,
        agent,
        message,
    )


def _extract_test_status(
    message: str | None,
) -> str | None:
    normalized = _normalize_text(
        message
    )

    if not normalized:
        return None

    match = re.search(
        r"(?im)^\s*(?:status\s*:\s*)?"
        r"(PASS|FAIL|BLOCKED)\b",
        normalized,
    )

    if match is None:
        return None

    return match.group(1).upper()


def _failure_summary(
    message: str | None,
) -> str:
    normalized = _normalize_text(
        message
    )

    if not normalized:
        return (
            "TEST_AGENT reported FAIL without "
            "a usable failure summary."
        )

    return _truncate(
        normalized,
        MAX_FAILURE_SUMMARY_CHARS,
    )


def _record_automatic_misunderstanding(
    identity: ProjectIdentity,
    fact: str,
) -> None:
    normalized = _truncate(
        fact,
        MAX_AUTO_MISUNDERSTANDING_CHARS,
    )

    if not normalized:
        return

    apply_memory_update(
        identity,
        "prompt_agent",
        MemoryUpdate(
            misunderstandings=[
                normalized
            ]
        ),
    )


def _handle_session_start(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> None:
    initialize_memory_structure(
        identity
    )

    context = _build_agent_memory_context(
        identity,
        "prompt_agent",
    )

    if not context:
        _write_json(
            {
                "continue": True,
            }
        )
        return

    _write_json(
        _additional_context_output(
            "SessionStart",
            context,
        )
    )


def _handle_session_end(
    payload: dict[str, Any],
) -> None:
    session_id = _get_required_string(
        payload,
        "session_id",
    )

    if session_id is None:
        return

    delete_session_state(
        session_id
    )

    _write_json(
        {
            "continue": True,
        }
    )


def _handle_user_prompt_submit(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> None:
    initialize_memory_structure(
        identity
    )

    session_id = _get_required_string(
        payload,
        "session_id",
    )

    if session_id is None:
        return

    # Qwen Code emits an empty UserPromptSubmit event when execution
    # continues after a foreground subagent. That is not a new user turn.
    if not _user_prompt_text(
        payload
    ):
        _write_json(
            {
                "continue": True,
            }
        )
        return

    observed_turn_id = _get_required_string(
        payload,
        "turn_id",
    )

    if observed_turn_id is None:
        active_state = get_active_state(
            session_id
        )

        if (
            active_state is not None
            and not active_state.turn_closed
        ):
            observed_turn_id = active_state.turn_id
        else:
            observed_turn_id = _synthetic_qwen_turn_id(
                payload
            )

    start_or_resume_user_turn(
        session_id=session_id,
        observed_turn_id=observed_turn_id,
        project_id=identity.project_id,
    )

    _write_json(
        {
            "continue": True,
        }
    )


def _register_subagent(
    payload: dict[str, Any],
    state: WorkflowState,
) -> None:
    session_id = _get_required_string(
        payload,
        "session_id",
    )

    agent_id = _get_required_string(
        payload,
        "agent_id",
    )

    if (
        session_id is None
        or agent_id is None
    ):
        return

    register_agent_root_turn(
        session_id=session_id,
        agent_id=agent_id,
        root_turn_id=state.turn_id,
    )


def _handle_algorithm_start(
    payload: dict[str, Any],
    identity: ProjectIdentity,
    state: WorkflowState,
) -> None:
    _register_subagent(
        payload,
        state,
    )

    if not state.contract_ready:
        mark_contract_ready(
            state
        )

    mark_algorithm_started(
        state
    )

    context = _build_agent_memory_context(
        identity,
        "algorithm_agent",
    )

    if context:
        _write_json(
            _additional_context_output(
                "SubagentStart",
                context,
            )
        )
        return

    _write_json(
        {
            "continue": True,
        }
    )


def _handle_test_start(
    payload: dict[str, Any],
    identity: ProjectIdentity,
    state: WorkflowState,
) -> None:
    _register_subagent(
        payload,
        state,
    )

    if not state.contract_ready:
        mark_contract_ready(
            state
        )

    mark_final_test_started(
        state
    )

    if state.verification_after_implementation:
        if state.algorithm_completed:
            phase_context = (
                "Perform final independent verification of "
                "the completed repository changes. Reconstruct "
                "the relevant acceptance criteria from the task "
                "contract and actual repository state. Return "
                "PASS, FAIL, or BLOCKED."
            )

        else:
            phase_context = (
                "Implementation has been selected in this "
                "workflow but is not recorded as complete. "
                "Do not claim PASS for a repository state that "
                "may still be changing. If a stable completed "
                "implementation cannot be verified, return "
                "BLOCKED."
            )

    else:
        phase_context = (
            "This is a verification-only audit. Do not modify "
            "persistent repository content. PASS, FAIL, and "
            "BLOCKED are all valid terminal audit results. "
            "A FAIL does not imply that you should implement "
            "a fix."
        )

    memory_context = _build_agent_memory_context(
        identity,
        "test_agent",
    )

    if memory_context:
        context = (
            phase_context
            + "\n\n"
            + memory_context
        )
    else:
        context = phase_context

    _write_json(
        _additional_context_output(
            "SubagentStart",
            _truncate(
                context,
                MAX_AGENT_CONTEXT_CHARS,
            ),
        )
    )


def _handle_subagent_start(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> None:
    state = _ensure_active_state(
        payload,
        identity,
    )

    if state is None:
        _write_json(
            {
                "continue": True,
            }
        )
        return

    agent_type = _normalize_agent_type(
        payload.get(
            "agent_type"
        )
    )

    if agent_type == "algorithm_agent":
        _handle_algorithm_start(
            payload,
            identity,
            state,
        )
        return

    if agent_type == "test_agent":
        _handle_test_start(
            payload,
            identity,
            state,
        )
        return

    _write_json(
        {
            "continue": True,
        }
    )


def _unregister_subagent(
    payload: dict[str, Any],
) -> None:
    session_id = _get_required_string(
        payload,
        "session_id",
    )

    agent_id = _get_required_string(
        payload,
        "agent_id",
    )

    if (
        session_id is None
        or agent_id is None
    ):
        return

    unregister_agent_root_turn(
        session_id,
        agent_id,
    )


def _handle_algorithm_stop(
    payload: dict[str, Any],
    identity: ProjectIdentity,
    state: WorkflowState,
) -> None:
    raw_message = payload.get(
        "last_assistant_message"
    )

    message = (
        raw_message
        if isinstance(
            raw_message,
            str,
        )
        else None
    )

    clean_message = (
        _process_subagent_message(
            identity,
            "algorithm_agent",
            message,
        )
    )

    _append_agent_result_to_journal(
        identity,
        "algorithm_agent",
        clean_message,
    )

    mark_algorithm_completed(
        state
    )

    _unregister_subagent(
        payload
    )

    _write_json(
        {
            "continue": True,
        }
    )


def _handle_missing_test_status(
    payload: dict[str, Any],
    identity: ProjectIdentity,
    state: WorkflowState,
    clean_message: str,
) -> None:
    stop_hook_active = bool(
        payload.get(
            "stop_hook_active"
        )
    )

    if not stop_hook_active:
        _write_json(
            {
                "decision": "block",
                "reason": (
                    "Your final verification result must begin "
                    "with exactly one explicit status: PASS, "
                    "FAIL, or BLOCKED. Return that status and "
                    "only the material verification evidence. "
                    "Do not modify repository files."
                ),
            }
        )
        return

    summary = (
        "TEST_AGENT did not provide the required "
        "PASS/FAIL/BLOCKED status after one protocol retry."
    )

    mark_verification_blocked(
        state,
        summary,
    )

    _append_agent_result_to_journal(
        identity,
        "test_agent",
        clean_message or summary,
    )

    _unregister_subagent(
        payload
    )

    _write_json(
        {
            "continue": True,
            "systemMessage": (
                "Independent verification could not be "
                "classified because TEST_AGENT did not follow "
                "the required PASS/FAIL/BLOCKED protocol."
            ),
        }
    )


def _handle_test_stop(
    payload: dict[str, Any],
    identity: ProjectIdentity,
    state: WorkflowState,
) -> None:
    raw_message = payload.get(
        "last_assistant_message"
    )

    message = (
        raw_message
        if isinstance(
            raw_message,
            str,
        )
        else None
    )

    status_preview = strip_memory_blocks(
        message
    )

    status = _extract_test_status(
        status_preview
    )

    if status is None:
        _handle_missing_test_status(
            payload,
            identity,
            state,
            status_preview,
        )
        return

    clean_message = (
        _process_subagent_message(
            identity,
            "test_agent",
            message,
        )
    )

    _append_agent_result_to_journal(
        identity,
        "test_agent",
        clean_message,
    )

    if status == "PASS":
        mark_verification_pass(
            state
        )

        _unregister_subagent(
            payload
        )

        _write_json(
            {
                "continue": True,
            }
        )
        return

    if status == "BLOCKED":
        mark_verification_blocked(
            state,
            _failure_summary(
                clean_message
            ),
        )

        _unregister_subagent(
            payload
        )

        _write_json(
            {
                "continue": True,
            }
        )
        return

    summary = _failure_summary(
        clean_message
    )

    fingerprint, count, threshold_reached = (
        record_failure(
            state,
            failure_type=(
                "test_agent_verification"
            ),
            summary=summary,
        )
    )

    if state.verification_after_implementation:
        automatic_fact = (
            "Independent verification of repository changes "
            "failed. "
            f"Failure fingerprint={fingerprint}; "
            f"equivalent occurrence count={count}. "
            "Failure evidence: "
            + _truncate(
                summary,
                800,
            )
        )

        if threshold_reached:
            automatic_fact += (
                " The equivalent-failure anti-loop threshold "
                "was reached; the next correction must use a "
                "materially different strategy."
            )

        _record_automatic_misunderstanding(
            identity,
            automatic_fact,
        )

    _unregister_subagent(
        payload
    )

    _write_json(
        {
            "continue": True,
        }
    )


def _handle_subagent_stop(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> None:
    state = _get_subagent_state(
        payload,
        identity,
    )

    if state is None:
        _write_json(
            {
                "continue": True,
            }
        )
        return

    agent_type = _normalize_agent_type(
        payload.get(
            "agent_type"
        )
    )

    if agent_type == "algorithm_agent":
        _handle_algorithm_stop(
            payload,
            identity,
            state,
        )
        return

    if agent_type == "test_agent":
        _handle_test_stop(
            payload,
            identity,
            state,
        )
        return

    _write_json(
        {
            "continue": True,
        }
    )


def _handle_failed_implementation_workflow(
    identity: ProjectIdentity,
    state: WorkflowState,
) -> None:
    repeated_failure = (
        equivalent_failure_limit_reached(
            state
        )
    )

    misunderstandings = read_misunderstandings(
        identity
    )

    mark_misunderstandings_read(
        state
    )

    begin_fix_cycle(
        state
    )

    increment_stop_block_count(
        state
    )

    if repeated_failure:
        reason = (
            "Independent verification of the implementation "
            "failed repeatedly with the same or equivalent "
            "failure. Do not repeat the same implementation, "
            "command, or debugging strategy. Re-evaluate the "
            "task contract and evidence, choose a materially "
            "different corrective strategy, delegate the fix "
            "to ALGORITHM_AGENT, then run TEST_AGENT once more "
            "for focused independent verification."
        )

    else:
        reason = (
            "Independent verification of the implementation "
            "reported FAIL. Review the failure evidence, "
            "delegate the necessary correction to "
            "ALGORITHM_AGENT, then run focused TEST_AGENT "
            "verification again. Do not repeat an equivalent "
            "failed strategy without new evidence or a "
            "meaningful implementation change."
        )

    if (
        misunderstandings
        and not _is_default_misunderstandings(
            misunderstandings
        )
    ):
        reason += (
            "\n\nRelevant PROMPT_AGENT misunderstanding/"
            "failure memory:\n"
            + _truncate(
                misunderstandings,
                3_000,
            )
        )

    _write_json(
        {
            "decision": "block",
            "reason": reason,
        }
    )


def _handle_stop(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> None:
    state = _ensure_active_state(
        payload,
        identity,
    )

    if state is None:
        _write_json(
            {
                "continue": True,
            }
        )
        return

    if requires_fix_cycle(
        state
    ):
        _handle_failed_implementation_workflow(
            identity,
            state,
        )
        return

    can_finish, reason = can_finish_turn(
        state
    )

    if can_finish:
        last_message = payload.get(
            "last_assistant_message"
        )

        if isinstance(
            last_message,
            str,
        ):
            _append_agent_result_to_journal(
                identity,
                "prompt_agent",
                last_message,
            )

        mark_turn_closed(
            state
        )

        _write_json(
            {
                "continue": True,
            }
        )
        return

    increment_stop_block_count(
        state
    )

    continuation_reason = (
        reason
        + " Complete only the missing phase of the workflow "
        "that PROMPT_AGENT already selected. Do not add "
        "unnecessary agents. Keep handoffs concise and use "
        "focused validation so the task finishes with minimal "
        "extra latency and token use."
    )

    _write_json(
        {
            "decision": "block",
            "reason": continuation_reason,
        }
    )


def _dispatch(
    payload: dict[str, Any],
) -> None:
    event_name = str(
        payload.get(
            "hook_event_name"
        )
        or ""
    ).strip()

    if event_name == "SessionEnd":
        _handle_session_end(
            payload
        )
        return

    identity = _project_identity(
        payload
    )

    if event_name == "SessionStart":
        _handle_session_start(
            payload,
            identity,
        )
        return

    if event_name == "UserPromptSubmit":
        _handle_user_prompt_submit(
            payload,
            identity,
        )
        return

    if event_name == "SubagentStart":
        _handle_subagent_start(
            payload,
            identity,
        )
        return

    if event_name == "SubagentStop":
        _handle_subagent_stop(
            payload,
            identity,
        )
        return

    if event_name == "Stop":
        _handle_stop(
            payload,
            identity,
        )
        return


def main() -> None:
    payload: dict[str, Any] = {}
    event_name = "unknown"

    try:
        payload = _read_hook_input()

        event_name = str(
            payload.get(
                "hook_event_name"
            )
            or "unknown"
        )

        _dispatch(
            payload
        )

    except Exception as error:
        _log_error(
            event_name,
            error,
        )

        if event_name in {
            "SubagentStop",
            "Stop",
        }:
            _write_json(
                {
                    "continue": True,
                    "systemMessage": (
                        "Qwen orchestration hook encountered "
                        "an internal error and failed open. "
                        "Orchestration reliability for this "
                        "event is reduced; inspect "
                        f"{ERROR_LOG_PATH}."
                    ),
                }
            )


if __name__ == "__main__":
    main()
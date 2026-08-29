from __future__ import annotations

import hashlib
import json
import os
import shutil
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from project_identity import STATE_ROOT


VerificationStatus = Literal[
    "not_started",
    "pending",
    "pass",
    "fail",
    "blocked",
]

WorkflowKind = Literal[
    "prompt_only",
    "algorithm_only",
    "test_only",
    "algorithm_and_test",
]

MAX_EQUIVALENT_FAILURES = 3

# Session-local routing metadata intentionally does not use .json
# so workflow-state diagnostics that enumerate *.json files only
# see actual root-turn state files.
ROUTING_STATE_FILENAME = "_routing_state.dat"


@dataclass
class WorkflowState:
    session_id: str
    turn_id: str
    project_id: str

    created_at: str
    updated_at: str

    contract_ready: bool = False

    algorithm_selected: bool = False
    algorithm_started: bool = False
    algorithm_completed: bool = False

    test_selected: bool = False
    final_test_started: bool = False
    final_test_completed: bool = False

    verification_status: VerificationStatus = "not_started"
    verification_after_implementation: bool = False

    fix_cycle_count: int = 0

    misunderstandings_required: bool = False
    misunderstandings_read: bool = False

    stop_block_count: int = 0

    failure_fingerprints: dict[str, int] = field(
        default_factory=dict
    )

    last_failure_fingerprint: str | None = None
    last_failure_summary: str | None = None

    # Becomes true only after the main Stop hook has accepted the
    # workflow as terminal. This distinguishes a real next user turn
    # from an internal continuation prompt created by Stop blocking.
    turn_closed: bool = False


def _utc_timestamp() -> str:
    return datetime.now(
        timezone.utc
    ).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def _safe_component(
    value: str,
) -> str:
    value = value.strip()

    if not value:
        return "unknown"

    safe = "".join(
        char
        if char.isalnum()
        or char in "._-"
        else "_"
        for char in value
    )

    return safe[:160] or "unknown"


def _session_root(
    session_id: str,
) -> Path:
    return (
        STATE_ROOT
        / _safe_component(
            session_id
        )
    )


def _state_path(
    session_id: str,
    turn_id: str,
) -> Path:
    return (
        _session_root(
            session_id
        )
        / (
            f"{_safe_component(turn_id)}"
            ".json"
        )
    )


def _routing_state_path(
    session_id: str,
) -> Path:
    return (
        _session_root(
            session_id
        )
        / ROUTING_STATE_FILENAME
    )


def _atomic_write_json(
    path: Path,
    payload: dict[str, Any],
) -> None:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    temporary_path = path.with_name(
        f".{path.name}.{os.getpid()}.tmp"
    )

    try:
        temporary_path.write_text(
            json.dumps(
                payload,
                indent=2,
                ensure_ascii=False,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

        os.replace(
            temporary_path,
            path,
        )

    finally:
        if temporary_path.exists():
            try:
                temporary_path.unlink()
            except OSError:
                pass


def _read_json_document(
    path: Path,
) -> dict[str, Any] | None:
    if not path.exists():
        return None

    try:
        payload = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )
    except (
        OSError,
        json.JSONDecodeError,
    ):
        return None

    if not isinstance(
        payload,
        dict,
    ):
        return None

    return payload


def _normalize_failure_text(
    text: str,
) -> str:
    return " ".join(
        text.strip()
        .lower()
        .split()
    )[:4000]


def make_failure_fingerprint(
    failure_type: str,
    summary: str,
) -> str:
    payload = (
        f"{_normalize_failure_text(failure_type)}\n"
        f"{_normalize_failure_text(summary)}"
    )

    return hashlib.sha256(
        payload.encode(
            "utf-8"
        )
    ).hexdigest()[:20]


# ---------------------------------------------------------------------
# Root workflow state
# ---------------------------------------------------------------------


def create_state(
    session_id: str,
    turn_id: str,
    project_id: str,
    *,
    overwrite: bool = False,
) -> WorkflowState:
    path = _state_path(
        session_id,
        turn_id,
    )

    if (
        path.exists()
        and not overwrite
    ):
        return load_state(
            session_id,
            turn_id,
        )

    now = _utc_timestamp()

    state = WorkflowState(
        session_id=session_id,
        turn_id=turn_id,
        project_id=project_id,
        created_at=now,
        updated_at=now,
    )

    save_state(
        state
    )

    return state


def load_state(
    session_id: str,
    turn_id: str,
) -> WorkflowState:
    path = _state_path(
        session_id,
        turn_id,
    )

    payload = json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    return WorkflowState(
        **payload
    )


def try_load_state(
    session_id: str,
    turn_id: str,
) -> WorkflowState | None:
    path = _state_path(
        session_id,
        turn_id,
    )

    if not path.exists():
        return None

    try:
        return load_state(
            session_id,
            turn_id,
        )
    except (
        OSError,
        json.JSONDecodeError,
        TypeError,
    ):
        return None


def save_state(
    state: WorkflowState,
) -> None:
    state.updated_at = (
        _utc_timestamp()
    )

    _atomic_write_json(
        _state_path(
            state.session_id,
            state.turn_id,
        ),
        asdict(
            state
        ),
    )


# ---------------------------------------------------------------------
# Session-level routing
#
# Qwen Code subagents do not need to expose the same turn identifier
# as the root user workflow. All related executions are mapped to one
# orchestration root-turn state here.
#
# The Qwen hook adapter may supply a synthetic root-turn identifier
# when the native hook payload has no stable turn_id.
# ---------------------------------------------------------------------


def _empty_routing_state(
    session_id: str,
) -> dict[str, Any]:
    return {
        "session_id": session_id,
        "active_root_turn_id": None,
        "agent_root_turns": {},
        "updated_at": _utc_timestamp(),
    }


def _load_routing_state(
    session_id: str,
) -> dict[str, Any]:
    path = _routing_state_path(
        session_id
    )

    payload = _read_json_document(
        path
    )

    if payload is None:
        return _empty_routing_state(
            session_id
        )

    active_root_turn_id = (
        payload.get(
            "active_root_turn_id"
        )
    )

    if not isinstance(
        active_root_turn_id,
        str,
    ):
        active_root_turn_id = None

    agent_root_turns = (
        payload.get(
            "agent_root_turns"
        )
    )

    if not isinstance(
        agent_root_turns,
        dict,
    ):
        agent_root_turns = {}

    clean_agent_map: dict[
        str,
        str,
    ] = {}

    for (
        agent_id,
        root_turn_id,
    ) in agent_root_turns.items():
        if (
            isinstance(
                agent_id,
                str,
            )
            and agent_id
            and isinstance(
                root_turn_id,
                str,
            )
            and root_turn_id
        ):
            clean_agent_map[
                agent_id
            ] = root_turn_id

    return {
        "session_id": session_id,
        "active_root_turn_id": (
            active_root_turn_id
        ),
        "agent_root_turns": (
            clean_agent_map
        ),
        "updated_at": str(
            payload.get(
                "updated_at"
            )
            or ""
        ),
    }


def _save_routing_state(
    session_id: str,
    routing: dict[str, Any],
) -> None:
    routing[
        "session_id"
    ] = session_id

    routing[
        "updated_at"
    ] = _utc_timestamp()

    _atomic_write_json(
        _routing_state_path(
            session_id
        ),
        routing,
    )


def set_active_root_turn(
    session_id: str,
    root_turn_id: str,
) -> None:
    routing = _load_routing_state(
        session_id
    )

    routing[
        "active_root_turn_id"
    ] = root_turn_id

    _save_routing_state(
        session_id,
        routing,
    )


def get_active_root_turn_id(
    session_id: str,
) -> str | None:
    routing = _load_routing_state(
        session_id
    )

    root_turn_id = routing.get(
        "active_root_turn_id"
    )

    if (
        isinstance(
            root_turn_id,
            str,
        )
        and root_turn_id
    ):
        return root_turn_id

    return None


def get_active_state(
    session_id: str,
) -> WorkflowState | None:
    root_turn_id = (
        get_active_root_turn_id(
            session_id
        )
    )

    if root_turn_id is None:
        return None

    return try_load_state(
        session_id,
        root_turn_id,
    )


def start_or_resume_user_turn(
    session_id: str,
    observed_turn_id: str,
    project_id: str,
) -> tuple[
    WorkflowState,
    bool,
]:
    active_state = (
        get_active_state(
            session_id
        )
    )

    # A blocked Stop may cause an internal continuation. It belongs
    # to the same orchestration workflow until the main Stop hook
    # accepts the workflow as terminal.
    if (
        active_state is not None
        and not active_state.turn_closed
    ):
        return (
            active_state,
            False,
        )

    state = create_state(
        session_id=session_id,
        turn_id=observed_turn_id,
        project_id=project_id,
        overwrite=False,
    )

    set_active_root_turn(
        session_id,
        state.turn_id,
    )

    return (
        state,
        True,
    )


def register_agent_root_turn(
    session_id: str,
    agent_id: str,
    root_turn_id: str,
) -> None:
    routing = _load_routing_state(
        session_id
    )

    agent_map = routing[
        "agent_root_turns"
    ]

    agent_map[
        agent_id
    ] = root_turn_id

    routing[
        "active_root_turn_id"
    ] = root_turn_id

    _save_routing_state(
        session_id,
        routing,
    )


def get_agent_root_turn_id(
    session_id: str,
    agent_id: str,
) -> str | None:
    routing = _load_routing_state(
        session_id
    )

    root_turn_id = (
        routing[
            "agent_root_turns"
        ].get(
            agent_id
        )
    )

    if (
        isinstance(
            root_turn_id,
            str,
        )
        and root_turn_id
    ):
        return root_turn_id

    return None


def get_agent_state(
    session_id: str,
    agent_id: str,
) -> WorkflowState | None:
    root_turn_id = (
        get_agent_root_turn_id(
            session_id,
            agent_id,
        )
    )

    if root_turn_id is not None:
        state = try_load_state(
            session_id,
            root_turn_id,
        )

        if state is not None:
            return state

    # Fallback is useful if a start event was missed but the parent
    # workflow is still active.
    return get_active_state(
        session_id
    )


def unregister_agent_root_turn(
    session_id: str,
    agent_id: str,
) -> None:
    routing = _load_routing_state(
        session_id
    )

    routing[
        "agent_root_turns"
    ].pop(
        agent_id,
        None,
    )

    _save_routing_state(
        session_id,
        routing,
    )


def mark_turn_closed(
    state: WorkflowState,
) -> None:
    state.turn_closed = True

    save_state(
        state
    )


# ---------------------------------------------------------------------
# Workflow transitions
# ---------------------------------------------------------------------


def get_workflow_kind(
    state: WorkflowState,
) -> WorkflowKind:
    if (
        state.algorithm_selected
        and state.test_selected
    ):
        return "algorithm_and_test"

    if state.algorithm_selected:
        return "algorithm_only"

    if state.test_selected:
        return "test_only"

    return "prompt_only"


def mark_contract_ready(
    state: WorkflowState,
) -> None:
    state.contract_ready = True

    save_state(
        state
    )


def _invalidate_previous_verification(
    state: WorkflowState,
) -> None:
    if not state.test_selected:
        return

    state.final_test_started = False
    state.final_test_completed = False
    state.verification_status = "pending"
    state.verification_after_implementation = True


def mark_algorithm_started(
    state: WorkflowState,
) -> None:
    state.turn_closed = False
    state.algorithm_selected = True

    if (
        state.test_selected
        and (
            state.final_test_started
            or state.final_test_completed
        )
    ):
        _invalidate_previous_verification(
            state
        )

    elif state.test_selected:
        state.verification_after_implementation = True

    state.algorithm_started = True
    state.algorithm_completed = False

    save_state(
        state
    )


def mark_algorithm_completed(
    state: WorkflowState,
) -> None:
    state.algorithm_selected = True
    state.algorithm_started = True
    state.algorithm_completed = True

    if state.test_selected:
        state.verification_after_implementation = True

    save_state(
        state
    )


def mark_final_test_started(
    state: WorkflowState,
) -> None:
    state.turn_closed = False
    state.test_selected = True

    state.final_test_started = True
    state.final_test_completed = False

    state.verification_after_implementation = (
        state.algorithm_selected
    )

    state.verification_status = "pending"

    save_state(
        state
    )


def mark_verification_pass(
    state: WorkflowState,
) -> None:
    state.test_selected = True
    state.final_test_started = True
    state.final_test_completed = True
    state.verification_status = "pass"

    state.last_failure_fingerprint = None
    state.last_failure_summary = None

    save_state(
        state
    )


def mark_verification_blocked(
    state: WorkflowState,
    summary: str,
) -> None:
    state.test_selected = True
    state.final_test_started = True
    state.final_test_completed = True
    state.verification_status = "blocked"

    normalized = summary.strip()

    state.last_failure_summary = (
        normalized[:4000]
        if normalized
        else None
    )

    save_state(
        state
    )


def record_failure(
    state: WorkflowState,
    *,
    failure_type: str,
    summary: str,
) -> tuple[
    str,
    int,
    bool,
]:
    state.test_selected = True

    fingerprint = (
        make_failure_fingerprint(
            failure_type,
            summary,
        )
    )

    count = (
        state.failure_fingerprints.get(
            fingerprint,
            0,
        )
        + 1
    )

    state.failure_fingerprints[
        fingerprint
    ] = count

    state.last_failure_fingerprint = (
        fingerprint
    )

    normalized_summary = (
        summary.strip()
    )

    state.last_failure_summary = (
        normalized_summary[:4000]
        if normalized_summary
        else None
    )

    state.final_test_started = True
    state.final_test_completed = True
    state.verification_status = "fail"

    if (
        state.verification_after_implementation
    ):
        state.misunderstandings_required = True
        state.misunderstandings_read = False

    threshold_reached = (
        count
        >= MAX_EQUIVALENT_FAILURES
    )

    save_state(
        state
    )

    return (
        fingerprint,
        count,
        threshold_reached,
    )


def begin_fix_cycle(
    state: WorkflowState,
) -> None:
    state.turn_closed = False
    state.fix_cycle_count += 1

    state.algorithm_selected = True
    state.algorithm_started = False
    state.algorithm_completed = False

    state.test_selected = True
    state.final_test_started = False
    state.final_test_completed = False

    state.verification_after_implementation = True
    state.verification_status = "pending"

    save_state(
        state
    )


def mark_misunderstandings_required(
    state: WorkflowState,
) -> None:
    state.misunderstandings_required = True
    state.misunderstandings_read = False

    save_state(
        state
    )


def mark_misunderstandings_read(
    state: WorkflowState,
) -> None:
    state.misunderstandings_read = True

    save_state(
        state
    )


def increment_stop_block_count(
    state: WorkflowState,
) -> int:
    state.stop_block_count += 1

    save_state(
        state
    )

    return state.stop_block_count


def equivalent_failure_limit_reached(
    state: WorkflowState,
) -> bool:
    if not state.last_failure_fingerprint:
        return False

    return (
        state.failure_fingerprints.get(
            state.last_failure_fingerprint,
            0,
        )
        >= MAX_EQUIVALENT_FAILURES
    )


def requires_fix_cycle(
    state: WorkflowState,
) -> bool:
    return (
        state.verification_status
        == "fail"
        and state.verification_after_implementation
    )


def is_verification_only(
    state: WorkflowState,
) -> bool:
    return (
        state.test_selected
        and not state.algorithm_selected
    )


def can_finish_turn(
    state: WorkflowState,
) -> tuple[
    bool,
    str,
]:
    workflow_kind = (
        get_workflow_kind(
            state
        )
    )

    if workflow_kind == "prompt_only":
        return (
            True,
            "PROMPT_AGENT-only workflow is complete.",
        )

    if state.algorithm_selected:
        if not state.algorithm_started:
            return (
                False,
                "ALGORITHM_AGENT is required for the selected "
                "workflow but the current implementation cycle "
                "has not started.",
            )

        if not state.algorithm_completed:
            return (
                False,
                "ALGORITHM_AGENT is still incomplete.",
            )

    if not state.test_selected:
        return (
            True,
            "Implementation completed; independent verification "
            "was not selected.",
        )

    if not state.final_test_started:
        return (
            False,
            "TEST_AGENT was selected but verification has not "
            "started.",
        )

    if not state.final_test_completed:
        return (
            False,
            "TEST_AGENT verification has not completed.",
        )

    if state.verification_status == "pass":
        return (
            True,
            "Independent verification passed.",
        )

    if state.verification_status == "blocked":
        return (
            True,
            "Independent verification is blocked and the "
            "limitation must be reported.",
        )

    if state.verification_status == "fail":
        if (
            state.verification_after_implementation
        ):
            return (
                False,
                "Verification of repository changes failed and "
                "requires a correction cycle.",
            )

        return (
            True,
            "Verification-only workflow completed with FAIL; "
            "the failure is the requested audit result.",
        )

    return (
        False,
        "TEST_AGENT was selected but no terminal verification "
        "status is available.",
    )


# ---------------------------------------------------------------------
# Cleanup / diagnostics
# ---------------------------------------------------------------------


def delete_state(
    session_id: str,
    turn_id: str,
) -> bool:
    path = _state_path(
        session_id,
        turn_id,
    )

    if not path.exists():
        return False

    try:
        path.unlink()
    except OSError:
        return False

    return True


def get_state_path(
    session_id: str,
    turn_id: str,
) -> Path:
    return _state_path(
        session_id,
        turn_id,
    )


def get_session_state_root(
    session_id: str,
) -> Path:
    return _session_root(
        session_id
    )


def delete_session_state(
    session_id: str,
) -> bool:
    session_directory = (
        get_session_state_root(
            session_id
        )
    )

    if not session_directory.exists():
        return False

    shutil.rmtree(
        session_directory
    )

    return True
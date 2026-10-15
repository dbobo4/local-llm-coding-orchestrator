from __future__ import annotations

import copy

import hashlib
import json
import msvcrt
import os
import shutil
import time
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from project_identity import STATE_ROOT
from local_paths import assert_local_path, assert_local_tree


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
MAX_DELEGATION_FAILURES = 9
MAX_DELEGATION_FAILURE_KEYS = 16
MAX_STOP_STAGNATION = 3
MAX_SLICE_TOOLS = 32
MAX_SLICE_FILES = 16
MAX_PROCESSED_STOPS = 64
MAX_AUDIT_EVENTS = 32
ADMISSION_PRIOR_FIELDS = (
    "algorithm_scope_files", "algorithm_scope_objectives",
    "growth_recovery_completed_objectives", "growth_recovery_residual_objectives",
    "growth_recovery_required", "growth_recovery_guard_active", "growth_recovery_final_slice",
    "partial_side_effects_possible", "delegation_failures", "delegation_failure_total", "delegation_blocked_reason",
)

# Session-local routing metadata intentionally does not use .json
# so workflow-state diagnostics that enumerate *.json files only
# see actual root-turn state files.
ROUTING_STATE_FILENAME = "_routing_state.dat"


class WorkflowStateError(RuntimeError):
    pass


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
    implementation_verification_required: bool | None = None

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

    # Non-success terminal latch for runtime-enforced aborts. A set
    # value closes the current root workflow without pretending that
    # the selected specialist phase completed successfully.
    terminal_abort_reason: str | None = None

    # A runtime guard may stop a specialist after tools already changed state.
    # Preserve this uncertainty explicitly for root-side recovery/summary.
    partial_side_effects_possible: bool = False

    # V5.14 recoverable specialist growth state.
    # PROMPT/root owns semantic decomposition; code only enforces monotonic scope.
    algorithm_scope_files: list[str] = field(default_factory=list)
    algorithm_scope_objectives: list[str] = field(default_factory=list)

    growth_recovery_required: bool = False
    growth_recovery_guard_active: bool = False
    growth_recovery_generation: int = 0

    growth_recovery_anchor_objectives: list[str] = field(default_factory=list)
    growth_recovery_failed_files: list[str] = field(default_factory=list)
    growth_recovery_failed_objectives: list[str] = field(default_factory=list)
    growth_recovery_reread_files: list[str] = field(default_factory=list)
    growth_recovery_absent_files: list[str] = field(default_factory=list)

    growth_recovery_completed_objectives: list[str] = field(default_factory=list)
    growth_recovery_residual_objectives: list[str] = field(default_factory=list)
    growth_recovery_final_slice: bool = False

    # Repair attempts belong to the root workflow, separate from TEST failures.
    delegation_failures: dict[str, int] = field(default_factory=dict)
    delegation_failure_total: int = 0
    delegation_blocked_reason: str | None = None
    last_successful_algorithm_objectives: list[str] = field(default_factory=list)
    resumable_end_reason: str | None = None
    progress_epoch: int = 0
    stop_progress_epoch: int = 0
    stop_stagnation_count: int = 0
    stop_blocked_reason: str | None = None
    pending_admission: dict[str, Any] | None = None
    active_agents: dict[str, dict[str, Any]] = field(default_factory=dict)
    processed_stops: dict[str, str] = field(default_factory=dict)
    audit_events: list[dict[str, Any]] = field(default_factory=list)
    closure_outcome: str | None = None
    scope_requires_refinement: bool = False


    # At most one successful PROMPT-owned durable-memory mutation may
    # be committed during one real root user turn.
    prompt_memory_written: bool = False



@contextmanager
def session_transition_lock(session_id: str):
    # All hook transitions for one session share this bounded Windows lock.
    path = STATE_ROOT / "_locks" / (_safe_component(session_id) + ".lock")
    assert_local_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as handle:
        if handle.seek(0, 2) == 0:
            handle.write(b"\0")
            handle.flush()
        deadline = time.monotonic() + 5
        while True:
            try:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise WorkflowStateError("Session transition lock is busy; no state was changed.")
                time.sleep(0.02)
        try:
            yield
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def scope_digest(files: list[str], objectives: list[str], generation: int) -> str:
    return hashlib.sha256(json.dumps([files, objectives, generation], separators=(",", ":")).encode()).hexdigest()


def recovery_reference(state: WorkflowState) -> str:
    values = [state.project_id, state.session_id, state.turn_id, state.growth_recovery_generation,
              state.growth_recovery_anchor_objectives, state.growth_recovery_completed_objectives,
              state.growth_recovery_residual_objectives, state.growth_recovery_failed_files]
    return hashlib.sha256(json.dumps(values, separators=(",", ":")).encode()).hexdigest()


def advance_progress(state: WorkflowState) -> None:
    state.progress_epoch += 1
    state.stop_progress_epoch = state.progress_epoch
    state.stop_stagnation_count = 0
    state.stop_blocked_reason = None


def record_stop_stagnation(state: WorkflowState) -> None:
    if state.stop_progress_epoch != state.progress_epoch:
        state.stop_progress_epoch = state.progress_epoch
        state.stop_stagnation_count = 0
    state.stop_stagnation_count += 1
    state.stop_block_count += 1
    if state.stop_stagnation_count >= MAX_STOP_STAGNATION:
        state.stop_blocked_reason = "Root continuation stagnated without verified execution progress."
    save_state(state)


def append_audit(state: WorkflowState, agent_id: str, role: str, outcome: str, binding: dict[str, Any]) -> None:
    state.audit_events.append({"agent_id": agent_id, "role": role, "outcome": outcome,
                               "generation": binding.get("generation"), "scope_digest": binding.get("digest"),
                               "receipt_summary": binding.get("receipt_summary", "")[:800],
                               "objectives": binding.get("objectives", []), "time": _utc_timestamp()})
    state.audit_events = state.audit_events[-MAX_AUDIT_EVENTS:]


def bind_specialist(state: WorkflowState, agent_id: str, role: str, parent_call_id: str) -> None:
    active = state.active_agents.get(agent_id)
    if active and active.get("role") == role and active.get("call_id") == parent_call_id:
        return
    if state.active_agents:
        raise WorkflowStateError("Specialist identity is already active or consumed.")
    admission = state.pending_admission
    if (not admission or admission.get("role") != role
            or admission.get("call_id") != parent_call_id
            or admission.get("interruption")
            or parent_call_id in state.processed_stops):
        raise WorkflowStateError("Specialist start has no matching accepted admission.")
    state.active_agents[agent_id] = dict(admission, tools={}, write_targets=[], interruption=None)
    state.pending_admission = None
    if role == "algorithm_agent":
        state.algorithm_started = True
        state.algorithm_completed = False
        if state.test_selected:
            state.final_test_started = False
            state.final_test_completed = False
            state.verification_status = "pending"
    else:
        state.test_selected = True
        state.verification_after_implementation = state.algorithm_selected
        if state.algorithm_selected:
            state.implementation_verification_required = True
        state.final_test_started = True
        state.final_test_completed = False
        state.verification_status = "pending"
    state.turn_closed = False
    save_state(state)


def capture_admission_state(state: WorkflowState) -> dict[str, Any]:
    return copy.deepcopy({name: getattr(state, name) for name in ADMISSION_PRIOR_FIELDS})


def retire_not_started_admission(state: WorkflowState) -> bool:
    admission = state.pending_admission
    prior = admission.get("prior_state") if admission else None
    if not isinstance(prior, dict) or set(prior) != set(ADMISSION_PRIOR_FIELDS):
        return False
    for name, value in prior.items():
        if name.endswith(("_files", "_objectives")):
            valid = isinstance(value, list) and all(isinstance(item, str) for item in value)
        elif name == "delegation_failures":
            valid = isinstance(value, dict) and all(isinstance(k, str) and type(v) is int and v >= 0 for k, v in value.items())
        elif name == "delegation_failure_total":
            valid = type(value) is int and value >= 0
        elif name == "delegation_blocked_reason":
            valid = value is None or isinstance(value, str)
        else:
            valid = type(value) is bool
        if not valid:
            return False
    for name, value in prior.items():
        setattr(state, name, copy.deepcopy(value))
    append_audit(state, "pending", admission["role"], "NOT_STARTED", admission)
    state.processed_stops[admission["call_id"]] = "NOT_STARTED"
    while len(state.processed_stops) > MAX_PROCESSED_STOPS:
        del state.processed_stops[next(iter(state.processed_stops))]
    state.pending_admission = None
    state.closure_outcome = "interrupted"
    if admission["role"] == "algorithm_agent":
        state.algorithm_completed = False
    else:
        state.final_test_completed = False
        state.verification_status = "pending"
    # Caller commits restoration, consumption and the bounded repair counter in one save.
    return True


def commit_specialist_stop(state: WorkflowState, agent_id: str, role: str, outcome: str) -> None:
    binding = state.active_agents.pop(agent_id)
    append_audit(state, agent_id, role, outcome, binding)
    state.processed_stops[binding["call_id"]] = outcome
    while len(state.processed_stops) > MAX_PROCESSED_STOPS:
        del state.processed_stops[next(iter(state.processed_stops))]
    successful = outcome == "PASS"
    if role == "algorithm_agent" and successful:
        state.algorithm_completed = True
        state.last_successful_algorithm_objectives = list(binding["objectives"])
        state.scope_requires_refinement = binding.get("phase") == "discover"
        if state.growth_recovery_guard_active and state.growth_recovery_final_slice:
            state.growth_recovery_guard_active = False
            state.growth_recovery_required = False
            state.growth_recovery_anchor_objectives = []
            state.growth_recovery_failed_files = []
            state.growth_recovery_failed_objectives = []
            state.growth_recovery_reread_files = []
            state.growth_recovery_absent_files = []
            state.growth_recovery_completed_objectives = []
            state.growth_recovery_residual_objectives = []
            state.growth_recovery_final_slice = False
        state.partial_side_effects_possible = False
    elif role == "test_agent" and outcome in {"PASS", "FAIL", "BLOCKED"}:
        state.final_test_completed = True
        state.verification_status = outcome.lower()
        if outcome == "FAIL":
            fingerprint = make_failure_fingerprint("test_agent_verification", binding.get("receipt_summary", "Verification failed."))
            state.failure_fingerprints[fingerprint] = state.failure_fingerprints.get(fingerprint, 0) + 1
            state.last_failure_fingerprint = fingerprint
            state.last_failure_summary = binding.get("receipt_summary", "Verification failed.")[:4000]
            state.misunderstandings_required = state.verification_after_implementation
            state.misunderstandings_read = False
        else:
            state.last_failure_fingerprint = None
            state.last_failure_summary = binding.get("receipt_summary", "Verification is blocked.")[:4000] if outcome == "BLOCKED" else None
    else:
        state.closure_outcome = "interrupted"
        state.partial_side_effects_possible = True
        if role == "algorithm_agent":
            state.algorithm_completed = False
            if not state.growth_recovery_guard_active:
                state.growth_recovery_anchor_objectives = list(binding["objectives"])
                state.growth_recovery_completed_objectives = []
                state.growth_recovery_residual_objectives = list(binding["objectives"])
            state.growth_recovery_failed_files = list(binding["files"])
            state.growth_recovery_failed_objectives = list(binding["objectives"])
            state.growth_recovery_reread_files = []
            state.growth_recovery_absent_files = []
            state.growth_recovery_required = True
            state.growth_recovery_guard_active = True
            state.growth_recovery_final_slice = False
            state.growth_recovery_generation += 1
        else:
            state.final_test_completed = False
            state.verification_status = "pending"
    if successful or (role == "test_agent" and outcome in {"FAIL", "BLOCKED"}):
        advance_progress(state)
        state.delegation_failures = {}
        state.delegation_failure_total = 0
        state.delegation_blocked_reason = None
        state.closure_outcome = None
        if successful:
            state.terminal_abort_reason = None
            if role == "test_agent":
                state.partial_side_effects_possible = False
    save_state(state)


def abandon_specialists(state: WorkflowState) -> None:
    for agent_id in list(state.active_agents):
        role = state.active_agents[agent_id]["role"]
        commit_specialist_stop(state, agent_id, role, "ABANDONED")
    if state.pending_admission:
        admission = state.pending_admission
        append_audit(state, "pending", admission["role"], "ABANDONED_ADMISSION", admission)
        state.processed_stops[admission["call_id"]] = "ABANDONED_ADMISSION"
        while len(state.processed_stops) > MAX_PROCESSED_STOPS:
            del state.processed_stops[next(iter(state.processed_stops))]
        state.pending_admission = None
        state.closure_outcome = "interrupted"
        state.partial_side_effects_possible = True
        if admission["role"] == "algorithm_agent":
            state.algorithm_completed = False
            mark_growth_recovery_required(state)
        else:
            state.final_test_completed = False
            state.verification_status = "pending"
            save_state(state)


def archive_session_outcome(state: WorkflowState) -> None:
    directory = STATE_ROOT / "_audit" / _safe_component(state.session_id)
    path = directory / (_safe_component(state.turn_id) + ".json")
    _atomic_write_json(path, {"session_id": state.session_id, "project_id": state.project_id,
                              "turn_id": state.turn_id, "outcome": state.closure_outcome,
                              "events": state.audit_events})
    assert_local_tree(directory)
    owned = []
    for candidate in directory.glob("*.json"):
        value = _read_json_document(candidate)
        if value and value.get("project_id") == state.project_id:
            owned.append(candidate)
    for candidate in sorted(owned, key=lambda entry: entry.stat().st_mtime_ns)[:-8]:
        candidate.unlink()


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
    assert_local_path(path)
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    temporary_path = path.with_name(
        f".{path.name}.{os.getpid()}.tmp"
    )
    assert_local_path(temporary_path)

    try:
        with temporary_path.open("w", encoding="utf-8") as stream:
            stream.write(json.dumps(
                payload,
                indent=2,
                ensure_ascii=False,
                sort_keys=True,
            ) + "\n")
            stream.flush()
            os.fsync(stream.fileno())

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
    assert_local_path(path)
    if not path.exists():
        return None

    try:
        payload = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )
    except (OSError, json.JSONDecodeError) as error:
        raise WorkflowStateError("Stored workflow metadata cannot be read safely.") from error

    if not isinstance(
        payload,
        dict,
    ):
        raise WorkflowStateError("Stored workflow metadata must be an object.")

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
    assert_local_path(path)

    try:
        payload = _read_json_document(path)
        if payload is None:
            raise WorkflowStateError("Referenced workflow state is missing.")
        state = WorkflowState(**payload)
        if state.session_id != session_id or state.turn_id != turn_id or not isinstance(state.project_id, str):
            raise WorkflowStateError("Stored workflow identity does not match its reference.")
        for name, value in asdict(state).items():
            default = WorkflowState.__dataclass_fields__[name].default
            if isinstance(default, bool) and type(value) is not bool:
                raise WorkflowStateError("Stored workflow flags are malformed.")
        if not isinstance(state.active_agents, dict) or not isinstance(state.processed_stops, dict):
            raise WorkflowStateError("Stored execution bindings are malformed.")
        for name in ("growth_recovery_generation", "progress_epoch", "stop_progress_epoch", "stop_stagnation_count", "delegation_failure_total"):
            if type(getattr(state, name)) is not int or getattr(state, name) < 0:
                raise WorkflowStateError("Stored workflow counters are malformed.")
        for name in ("algorithm_scope_files", "algorithm_scope_objectives", "growth_recovery_anchor_objectives",
                     "growth_recovery_completed_objectives", "growth_recovery_residual_objectives", "growth_recovery_reread_files"):
            value = getattr(state, name)
            if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
                raise WorkflowStateError("Stored workflow scope is malformed.")
        bindings = list(state.active_agents.values()) + ([state.pending_admission] if state.pending_admission is not None else [])
        for binding in bindings:
            if (not isinstance(binding, dict) or not all(isinstance(binding.get(key), str) and binding[key] for key in ("call_id", "role", "digest"))
                    or binding["role"] not in {"algorithm_agent", "test_agent"}
                    or type(binding.get("generation")) is not int
                    or not isinstance(binding.get("files"), list) or not isinstance(binding.get("objectives"), list)):
                raise WorkflowStateError("Stored admission snapshot is malformed.")
        return state
    except (OSError, ValueError, TypeError) as error:
        raise WorkflowStateError("Stored workflow state is malformed; it was preserved for review.") from error


def try_load_state(
    session_id: str,
    turn_id: str,
) -> WorkflowState | None:
    path = _state_path(
        session_id,
        turn_id,
    )
    assert_local_path(path)

    if not path.exists():
        return None

    try:
        return load_state(
            session_id,
            turn_id,
        )
    except (OSError, json.JSONDecodeError, TypeError) as error:
        raise WorkflowStateError("Stored workflow state could not be loaded.") from error


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
        root = get_session_state_root(session_id)
        assert_local_path(root)
        if root.exists() and any(root.glob("*.json")):
            raise WorkflowStateError("Session routing is missing while workflow state remains.")
        return _empty_routing_state(
            session_id
        )

    active_root_turn_id = (
        payload.get(
            "active_root_turn_id"
        )
    )

    states_remain = any(get_session_state_root(session_id).glob("*.json"))
    if (payload.get("session_id") != session_id
            or (active_root_turn_id is not None and (not isinstance(active_root_turn_id, str) or not active_root_turn_id))
            or (states_remain and not active_root_turn_id)):
        raise WorkflowStateError("Session routing has an invalid or missing active workflow pointer.")

    agent_root_turns = (
        payload.get(
            "agent_root_turns"
        )
    )

    if not isinstance(
        agent_root_turns,
        dict,
    ):
        raise WorkflowStateError("Session routing child map is malformed or missing.")

    clean_agent_map: dict[
        str,
        str,
    ] = {}

    for (
        agent_id,
        root_turn_id,
    ) in agent_root_turns.items():
        if not (
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
            raise WorkflowStateError("Session routing child identity is malformed.")
        else:
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
    path = _routing_state_path(session_id)
    if not path.exists():
        load_state(session_id, root_turn_id)
        routing = _empty_routing_state(session_id)
    else:
        routing = _load_routing_state(session_id)

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

    state = try_load_state(
        session_id,
        root_turn_id,
    )
    if state is None:
        raise WorkflowStateError("Session routing references missing workflow state.")
    return state


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
    if active_state is not None and active_state.project_id != project_id:
        raise WorkflowStateError("A user turn cannot replace another project's workflow.")

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

    if active_state is not None:
        terminal = (active_state.closure_outcome == "success" or (
            not active_state.algorithm_selected and active_state.closure_outcome in {"verification_fail", "verification_blocked"}))
        if not terminal or not can_finish_turn(active_state)[0]:
            return active_state, False
        archive_session_outcome(active_state)
        delete_state(active_state.session_id, active_state.turn_id)

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


def has_registered_agents(session_id: str) -> bool:
    return bool(_load_routing_state(session_id)["agent_root_turns"])


def clear_registered_agents(session_id: str) -> None:
    routing = _load_routing_state(session_id)
    routing["agent_root_turns"] = {}
    _save_routing_state(session_id, routing)


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



def set_algorithm_scope(
    state: WorkflowState,
    *,
    files: list[str],
    objectives: list[str],
    persist: bool = True,
) -> None:
    state.algorithm_scope_files = list(dict.fromkeys(files))
    state.algorithm_scope_objectives = list(dict.fromkeys(objectives))
    if persist:
        save_state(state)


def mark_growth_recovery_required(
    state: WorkflowState,
) -> None:
    failed_objectives = list(
        dict.fromkeys(state.algorithm_scope_objectives)
    )
    if not failed_objectives:
        failed_objectives = ["legacy_unscoped_work"]

    if not state.growth_recovery_guard_active:
        state.growth_recovery_anchor_objectives = list(failed_objectives)
        state.growth_recovery_completed_objectives = []
        state.growth_recovery_residual_objectives = list(failed_objectives)

    state.growth_recovery_failed_files = list(
        dict.fromkeys(state.algorithm_scope_files)
    )
    state.growth_recovery_failed_objectives = list(failed_objectives)
    state.growth_recovery_reread_files = []
    state.growth_recovery_absent_files = []
    state.growth_recovery_required = True
    state.growth_recovery_guard_active = True
    state.growth_recovery_generation += 1
    state.growth_recovery_final_slice = False

    # A specialist growth stop is recoverable. It is not a terminal root abort.
    state.terminal_abort_reason = None
    state.partial_side_effects_possible = True
    save_state(state)


def record_growth_recovery_reread(
    state: WorkflowState,
    file_path: str,
    *, missing: bool = False,
) -> None:
    if not state.growth_recovery_required:
        return
    value = str(file_path).strip().replace("\\", "/").lower()
    absent_changed = missing != (value in state.growth_recovery_absent_files)
    if missing and value not in state.growth_recovery_absent_files:
        state.growth_recovery_absent_files.append(value)
    elif not missing and value in state.growth_recovery_absent_files:
        state.growth_recovery_absent_files.remove(value)
    if value and value not in state.growth_recovery_reread_files:
        state.growth_recovery_reread_files.append(value)
        advance_progress(state)
        reset_delegation_repairs(state)
    elif absent_changed:
        save_state(state)


def reset_delegation_repairs(state: WorkflowState, *, persist: bool = True) -> None:
    state.delegation_failures = {}
    state.delegation_failure_total = 0
    state.delegation_blocked_reason = None
    if persist:
        save_state(state)


def record_delegation_failure(state: WorkflowState, category: str, reason: str) -> None:
    if state.delegation_blocked_reason:
        return
    fingerprint = hashlib.sha256(reason.encode("utf-8")).hexdigest()[:20]
    key = category + ":" + fingerprint
    if key not in state.delegation_failures and len(state.delegation_failures) >= MAX_DELEGATION_FAILURE_KEYS:
        state.delegation_blocked_reason = "Repair fingerprint capacity reached."
    else:
        count = state.delegation_failures.get(key, 0) + 1
        state.delegation_failures[key] = count
        state.delegation_failure_total += 1
        if count >= MAX_EQUIVALENT_FAILURES or state.delegation_failure_total >= MAX_DELEGATION_FAILURES:
            state.delegation_blocked_reason = (
                f"Bounded repair exhausted ({category}; equivalent={count}, total={state.delegation_failure_total})."
            )
    save_state(state)


def set_growth_recovery_plan(
    state: WorkflowState,
    *,
    completed: list[str],
    residual: list[str],
    delegate_files: list[str],
    delegate_objectives: list[str],
    final_slice: bool,
    persist: bool = True,
) -> None:
    state.growth_recovery_completed_objectives = list(completed)
    state.growth_recovery_residual_objectives = list(residual)
    state.algorithm_scope_files = list(delegate_files)
    state.algorithm_scope_objectives = list(delegate_objectives)
    state.growth_recovery_required = False
    state.growth_recovery_guard_active = True
    state.growth_recovery_final_slice = bool(final_slice)
    state.partial_side_effects_possible = False
    if persist:
        save_state(state)


def mark_growth_recovery_algorithm_success(
    state: WorkflowState,
) -> None:
    if not state.growth_recovery_guard_active:
        return
    if state.growth_recovery_required:
        return
    if not state.growth_recovery_final_slice:
        save_state(state)
        return

    state.growth_recovery_required = False
    state.growth_recovery_guard_active = False
    state.growth_recovery_anchor_objectives = []
    state.growth_recovery_failed_files = []
    state.growth_recovery_failed_objectives = []
    state.growth_recovery_reread_files = []
    state.growth_recovery_absent_files = []
    state.growth_recovery_completed_objectives = []
    state.growth_recovery_residual_objectives = []
    state.growth_recovery_final_slice = False
    state.partial_side_effects_possible = False
    save_state(state)


def mark_terminal_abort(
    state: WorkflowState,
    reason: str,
    *,
    partial_side_effects_possible: bool = False,
) -> None:
    normalized = reason.strip()

    if not normalized:
        raise ValueError(
            "terminal abort reason must not be empty"
        )

    state.terminal_abort_reason = normalized[:4000]
    state.partial_side_effects_possible = bool(
        partial_side_effects_possible
    )

    save_state(
        state
    )


def mark_turn_closed(
    state: WorkflowState,
) -> None:
    state.turn_closed = True

    save_state(
        state
    )


def has_prior_closed_turn(
    state: WorkflowState,
) -> bool:
    """
    Return True only when this session already contains another
    completed root user turn for the same project.
    """

    root = _session_root(
        state.session_id
    )
    assert_local_path(root)

    if not root.exists():
        return False

    current_path = _state_path(
        state.session_id,
        state.turn_id,
    )

    for path in root.glob("*.json"):
        if path == current_path:
            continue

        payload = _read_json_document(
            path
        )

        if payload is None:
            continue

        if (
            payload.get("project_id")
            == state.project_id
            and payload.get("turn_closed")
            is True
        ):
            return True

    return False


def mark_prompt_memory_written(
    state: WorkflowState,
) -> None:
    state.prompt_memory_written = True

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


def select_implementation_workflow(
    state: WorkflowState,
    *,
    require_test: bool,
) -> None:
    state.turn_closed = False
    state.algorithm_selected = True

    # Verification may be upgraded to required, but never downgraded
    # after the workflow has already selected TEST.
    if state.implementation_verification_required is True:
        require_test = True

    if state.test_selected:
        require_test = True

    state.implementation_verification_required = require_test

    if require_test:
        state.test_selected = True
        state.final_test_started = False
        state.final_test_completed = False
        state.verification_status = "pending"
        state.verification_after_implementation = True
    else:
        state.verification_after_implementation = False

    save_state(
        state
    )


def mark_algorithm_started(
    state: WorkflowState,
) -> None:
    state.turn_closed = False
    state.algorithm_selected = True

    # Fail safe: if the Agent PreToolUse routing latch was missed,
    # implementation requires independent TEST rather than silently
    # becoming ALGORITHM-only.
    if state.implementation_verification_required is None:
        state.implementation_verification_required = True
        state.test_selected = True

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

    if state.implementation_verification_required is None:
        state.implementation_verification_required = True
        state.test_selected = True

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

    if state.algorithm_selected:
        state.implementation_verification_required = True

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
    state.implementation_verification_required = True

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

    if state.active_agents or state.pending_admission:
        return False, "An admitted specialist execution is still unresolved."
    if state.scope_requires_refinement:
        return False, "Read-only discovery finished; concrete implementation refinement is still required."
    if state.stop_blocked_reason:
        return False, state.stop_blocked_reason
    if state.delegation_failure_total or state.delegation_blocked_reason:
        return False, "Agent delegation still requires a valid repaired handoff; the task is incomplete."

    if state.growth_recovery_guard_active:
        if state.growth_recovery_required:
            return (
                False,
                "ALGORITHM GROWTH_LIMIT recovery requires actual-state re-read and a strictly smaller residual delegation.",
            )
        return (
            False,
            "ALGORITHM GROWTH_LIMIT recovery still has residual implementation work; continue smaller ALGORITHM slices before TEST/final.",
        )

    if state.terminal_abort_reason:
        return False, "A runtime interruption remains unresolved; successful completion is unproven."

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

    if state.algorithm_selected:
        if state.implementation_verification_required is None:
            return (
                False,
                "Implementation verification routing was not established. "
                "Independent TEST is required as the fail-safe path.",
            )

        if (
            state.implementation_verification_required
            and not state.test_selected
        ):
            return (
                False,
                "Independent TEST is required for this implementation "
                "workflow but TEST_AGENT is not selected.",
            )

    if not state.test_selected:
        return (
            True,
            "Implementation completed; independent verification "
            "was explicitly not required.",
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
    assert_local_path(path)

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
    assert_local_tree(session_directory)

    if not session_directory.exists():
        return False

    shutil.rmtree(
        session_directory
    )

    return True


def delete_project_session_state(session_id: str, project_id: str) -> bool:
    # The deleted ID can differ from the caller's current session.
    if (not session_id or not session_id[0].isalnum() or len(session_id) > 160
            or session_id != _safe_component(session_id)):
        return False
    directory = get_session_state_root(session_id)
    assert_local_tree(directory)
    states = list(directory.glob("*.json"))
    audit_directory = STATE_ROOT / "_audit" / _safe_component(session_id)
    assert_local_tree(audit_directory)
    audits = list(audit_directory.glob("*.json"))
    if not states and not audits:
        return False
    for path in states:
        state = try_load_state(session_id, path.stem)
        if state is None or state.session_id != session_id or state.project_id != project_id:
            return False
    for path in audits:
        audit = _read_json_document(path)
        if not audit or audit.get("session_id") != session_id or audit.get("project_id") != project_id:
            return False
    if directory.exists():
        delete_session_state(session_id)
    if audit_directory.exists():
        shutil.rmtree(audit_directory)
    return True

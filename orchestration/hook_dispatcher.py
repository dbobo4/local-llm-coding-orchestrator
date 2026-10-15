from __future__ import annotations

import hashlib
import json
import msvcrt
import os
import re
import stat
import sys
import time
import traceback
from contextlib import nullcontext
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from local_paths import assert_local_path

import workflow_state as _localai_workflow_state

from memory_protocol import (
    MemoryUpdate,
    apply_memory_update,
    extract_memory_update,
    process_agent_memory_message,
    strip_memory_blocks,
)
from memory_store import (
    INITIAL_CROSS_PROJECT_MEMORY_CONTENT,
    INITIAL_MEMORY_CONTENT,
    INITIAL_MISUNDERSTANDINGS_CONTENT,
    initialize_memory_structure,
    read_cross_project_memory,
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
    has_prior_closed_turn,
    increment_stop_block_count,
    mark_algorithm_completed,
    mark_algorithm_started,
    mark_contract_ready,
    mark_final_test_started,
    mark_misunderstandings_read,
    mark_prompt_memory_written,
    mark_terminal_abort,
    mark_turn_closed,
    mark_verification_blocked,
    mark_verification_pass,
    record_failure,
    register_agent_root_turn,
    requires_fix_cycle,
    select_implementation_workflow,
    set_active_root_turn,
    start_or_resume_user_turn,
    unregister_agent_root_turn,
)


ERROR_LOG_ROOT = ORCHESTRATION_ROOT / "logs"
ERROR_LOG_PATH = ERROR_LOG_ROOT / "hook_errors.log"

# Keep injected Qwen hook context compact.

# Fresh PROMPT_AGENT session context.

# Compact subagent context.

MAX_FAILURE_SUMMARY_CHARS = 3_000
MAX_AUTO_MISUNDERSTANDING_CHARS = 1_200
MAX_ALGORITHM_DELTA_CHARS = 3000
MAX_TEST_DELTA_CHARS = 2500
MAX_INITIAL_OBJECTIVES = 2
MAX_INITIAL_SCOPE_ENTRIES = 3
MAX_INITIAL_SCOPE_FILES = 16
WORKFLOW_PAUSE_MARKER = "LOCALAI_WORKFLOW_INCOMPLETE:"


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
    assert_local_path(ERROR_LOG_PATH)
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


def _is_default_memory(
    content: str,
) -> bool:
    return (
        _normalize_text(content)
        == _normalize_text(
            INITIAL_MEMORY_CONTENT
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



_LOCALAI_V514_SCOPE_RE = re.compile(
    r"<ALGORITHM_SCOPE>\s*(.*?)\s*</ALGORITHM_SCOPE>",
    flags=re.IGNORECASE | re.DOTALL,
)
_LOCALAI_V514_SCOPE_MARKER_RE = re.compile(
    r"<\s*/?\s*ALGORITHM_SCOPE\s*>",
    flags=re.IGNORECASE,
)
_LOCALAI_V514_RECOVERY_RE = re.compile(
    r"<GROWTH_RECOVERY>\s*(.*?)\s*</GROWTH_RECOVERY>",
    flags=re.IGNORECASE | re.DOTALL,
)
_LOCALAI_V514_RECOVERY_MARKER_RE = re.compile(
    r"<\s*/?\s*GROWTH_RECOVERY\s*>",
    flags=re.IGNORECASE,
)


def _localai_v514_carrier(
    prompt: str,
    *,
    pattern: re.Pattern[str],
    marker: re.Pattern[str],
    label: str,
    required: bool,
) -> tuple[dict[str, Any] | None, str, str | None]:
    markers = list(marker.finditer(prompt))
    matches = list(pattern.finditer(prompt))

    if not markers:
        if required:
            return None, prompt, f"Missing required <{label}> JSON carrier."
        return None, prompt, None

    if len(markers) != 2 or len(matches) != 1:
        return None, prompt, f"Malformed <{label}> carrier."

    try:
        value = json.loads(matches[0].group(1))
    except Exception as exc:
        return None, prompt, f"Invalid <{label}> JSON: {type(exc).__name__}: {exc}"

    if not isinstance(value, dict):
        return None, prompt, f"<{label}> must contain one JSON object."

    return value, pattern.sub("", prompt, count=1), None


def _localai_v514_list(
    value: Any,
    *,
    label: str,
    normalize_path: bool = False,
) -> tuple[list[str] | None, str | None]:
    if not isinstance(value, list):
        return None, f"{label} must be a JSON list."

    result: list[str] = []
    for raw in value:
        if not isinstance(raw, str) or not raw.strip():
            return None, f"{label} entries must be non-empty strings."
        item = raw.strip()
        if normalize_path:
            item = item.replace("\\", "/").lower()
        else:
            item = item.lower()
        if item in result:
            return None, f"{label} contains duplicate entry {raw!r}."
        result.append(item)

    return result, None


def _localai_v514_project_path(root: Path, value: str) -> Path:
    path = Path(value)
    if path.drive and not path.is_absolute():
        raise ValueError("Drive-relative paths are ambiguous.")
    path = Path(os.path.abspath(path if path.is_absolute() else root / path))
    if not path.is_relative_to(root):
        raise ValueError("Scope path escapes the project root.")
    candidate = path
    while candidate != root.parent:
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            pass
        else:
            if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError("Redirected scope paths cannot prove recovery coverage.")
        candidate = candidate.parent
    return path


def _localai_v514_scope_files(
    files: list[str], project_root: str, *, require_coverage: bool = True,
) -> list[str]:
    root = Path(project_root).absolute()
    resolved: set[str] = set()
    entries = 0
    for item in files:
        if item == '<discover>':
            continue
        subtree = item.endswith('/**')
        value = item[:-3] if subtree else item
        if not value or '<discover>' in value or any(char in value for char in '*?[]'):
            raise ValueError("Only concrete files or directory/** subtrees are supported; <discover> must be a whole entry.")
        path = _localai_v514_project_path(root, value)
        if not subtree:
            if path.is_dir():
                raise ValueError("A directory is not a concrete file.")
            resolved.add(path.as_posix().lower())
            continue
        if not path.is_dir():
            if not require_coverage and not path.exists():
                continue
            raise ValueError("The declared subtree does not exist.")
        pending = [path]
        subtree_files = set()
        while pending:
            with os.scandir(pending.pop()) as children:
                for child in children:
                    entries += 1
                    if entries > 2048:
                        raise ValueError("Scope enumeration exceeds the 2048-entry limit.")
                    child_path = _localai_v514_project_path(root, child.path)
                    if child.is_dir(follow_symlinks=False):
                        pending.append(child_path)
                    elif child.is_file(follow_symlinks=False):
                        subtree_files.add(child_path.as_posix().lower())
                    else:
                        raise ValueError("A subtree entry is not a regular file or directory.")
        if require_coverage and not subtree_files:
            raise ValueError("The declared subtree contains no concrete files.")
        resolved.update(subtree_files)
        if len(resolved) > 256:
            raise ValueError("Scope enumeration exceeds the 256-file limit.")
    return sorted(resolved)


def _localai_v5141_authoritative_recovery_hint(state: WorkflowState, project_root: str | None = None) -> str:
    payload = {
        "generation": state.growth_recovery_generation,
        "guard_active": state.growth_recovery_guard_active,
        "reread_required": state.growth_recovery_required,
        "anchor_count": len(state.growth_recovery_anchor_objectives),
        "completed_objectives": state.growth_recovery_completed_objectives,
        "residual_objectives": state.growth_recovery_residual_objectives,
        "repair_attempts": state.delegation_failure_total,
        "repair_blocked": state.delegation_blocked_reason,
        "last_successful_slice": state.last_successful_algorithm_objectives,
        "resumable_end_reason": state.resumable_end_reason,
        "verified_absent_files": state.growth_recovery_absent_files[:3],
    }
    current_files = []
    missing_reads = []
    if project_root and state.growth_recovery_failed_files:
        try:
            current_files = _localai_v514_scope_files(state.growth_recovery_failed_files, project_root)
            missing_reads = sorted(set(current_files) - set(state.growth_recovery_reread_files))
            payload["missing_read_count"] = len(missing_reads)
            payload["missing_reads"] = missing_reads[:3]
            payload["read_details_omitted"] = len(missing_reads) > 3 or len(state.growth_recovery_absent_files) > 3
        except (OSError, ValueError):
            payload["coverage_status"] = "UNPROVABLE; enumerate trusted actual scope before delegation"
    residual = state.growth_recovery_residual_objectives
    if residual:
        payload["example_status"] = "Illustration only; not ready until complete valid reread and truthful partition"
        observed = set(state.algorithm_scope_objectives + state.last_successful_algorithm_objectives)
        recent_roots = {item.split("::", 1)[0] for item in state.last_successful_algorithm_objectives}
        parents = sorted(residual, key=lambda parent: parent in recent_roots)
        candidate = next((parent + "::" + suffix for parent in parents
                          for suffix in ("verify_actual_state", "verify_remaining_state", "verify_final_state")
                          if parent + "::" + suffix not in observed), None)
        if candidate:
            payload["example"] = {
                "ALGORITHM_SCOPE": {"files": current_files[:1] or ["<discover>"], "objectives": [candidate]},
                "GROWTH_RECOVERY": {"completed": state.growth_recovery_completed_objectives,
                                    "residual": residual, "final_slice": len(residual) == 1},
            }
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    if len(encoded) > 2400:
        # Indexed claims refer to exact saved IDs; the same semantic validators still apply.
        anchor = state.growth_recovery_anchor_objectives
        completed_indices = [i for i, item in enumerate(anchor) if item in state.growth_recovery_completed_objectives]
        residual_indices = [i for i, item in enumerate(anchor) if item in residual]
        payload = {
            "generation": state.growth_recovery_generation,
            "guard_active": state.growth_recovery_guard_active,
            "reread_required": state.growth_recovery_required,
            "details_omitted": True,
            "counts": {key: len(value) for key, value in payload.items() if isinstance(value, list)},
            "anchor_count": len(anchor),
            "state_ref": _localai_workflow_state.recovery_reference(state),
            "completed_indices": completed_indices,
            "residual_indices": residual_indices,
            "next_missing_read": (missing_reads[0] if project_root and current_files and missing_reads else None),
            "repair_attempts": state.delegation_failure_total,
            "repair_blocked": state.delegation_blocked_reason,
            "instruction": "Exact saved IDs are referenced by zero-based anchor indices. Keep ALGORITHM_SCOPE.files, omit its objectives and use GROWTH_RECOVERY.objective_refs with index/child; no invented completed claims. Full reread still required.",
        }
        encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return " AUTHORITATIVE_GROWTH_RECOVERY_STATE=" + encoded


def _is_explicit_child(payload: dict[str, Any]) -> bool:
    return bool(payload.get("agent_id")) or any(
        _normalize_agent_type(payload.get(key)) in {"algorithm_agent", "test_agent", "subagent"}
        for key in ("agent_type", "source_type")
    )


def _root_workflow_state(payload: dict[str, Any], identity: ProjectIdentity) -> WorkflowState | None:
    session_id = _get_required_string(payload, "session_id")
    if not session_id or _is_explicit_child(payload) or _localai_workflow_state.has_registered_agents(session_id):
        return None
    state = get_active_state(session_id)
    return state if state and state.project_id == identity.project_id and not state.active_agents else None


def _workflow_context(state: WorkflowState | None, project_root: str | None = None) -> str:
    if state is None or state.turn_closed or can_finish_turn(state)[0]:
        return ""
    prefix = WORKFLOW_PAUSE_MARKER if state.delegation_blocked_reason or state.stop_blocked_reason else "LOCALAI_ROOT_CONTINUATION:"
    action = " Continue the next smaller ALGORITHM slice before TEST." if state.growth_recovery_guard_active else " Continue remaining implementation slices, then required independent TEST."
    return prefix + " Root workflow remains incomplete; preserve its state." + action + _localai_v5141_authoritative_recovery_hint(state, project_root)


def _delegation_repair_reason(state: WorkflowState, reason: str, *, category: str | None = None, project_root: str | None = None) -> str:
    plain = reason.split(" AUTHORITATIVE_GROWTH_RECOVERY_STATE=", 1)[0]
    if plain.startswith(WORKFLOW_PAUSE_MARKER):
        plain = plain[len(WORKFLOW_PAUSE_MARKER):].lstrip()
    if category is None:
        category = next((name for needle, name in (
            ("missing required <growth_recovery>", "recovery_carrier"),
            ("missing required <algorithm_scope>", "scope_carrier"),
            ("re-read", "reread"), ("coverage", "coverage"), ("partition", "partition"),
            ("parent", "parent"), ("same-scope", "same_scope"), ("identical residual", "same_scope"),
            ("hard limit", "delta"), ("initial", "initial_scope"),
        ) if needle in plain.lower()), "metadata")
    _localai_workflow_state.record_delegation_failure(state, category, plain)
    prefix = WORKFLOW_PAUSE_MARKER + " " if state.delegation_blocked_reason else ""
    action = {
        "recovery_carrier": "Attach GROWTH_RECOVERY with the stored exact completed/residual partition and final_slice boolean.",
        "scope_carrier": "Attach one bounded ALGORITHM_SCOPE with project files and semantic objective IDs.",
        "reread": "Read every missing failed-scope file; independently verified missing concrete files require read_file failure evidence.",
        "parent": "Keep each delegated parent in current residual; implemented but unchecked work is not completed.",
    }.get(category, "Correct the stated condition using authoritative state before retrying.")
    return (prefix + plain[:700] + f" REPAIR_CATEGORY={category} REPAIR_ATTEMPTS={state.delegation_failure_total}. NEXT_ACTION={action} "
            "Repair the stated cause; repeating equivalent invalid handoffs is bounded."
            + _localai_v5141_authoritative_recovery_hint(state, project_root))


def _write_workflow_block(identity: ProjectIdentity, state: WorkflowState, reason: str) -> None:
    _localai_workflow_state.record_stop_stagnation(state)
    paused = bool(state.stop_blocked_reason or state.delegation_blocked_reason)
    message = ((WORKFLOW_PAUSE_MARKER if paused else "LOCALAI_ROOT_CONTINUATION:")
               + " " + reason[:700] + _localai_v5141_authoritative_recovery_hint(state, identity.canonical_project_root))
    _write_json({"continue": not paused, "decision": "block", "reason": message, "systemMessage": message,
                 "hookSpecificOutput": {"hookEventName": "Stop", "localai_workflow": {
                     "version": 1, "session_id": state.session_id, "turn_id": state.turn_id,
                     "progress_epoch": state.progress_epoch, "stagnation_count": state.stop_stagnation_count}}})


def _localai_v514_prepare_algorithm(
    prompt: str,
    state: WorkflowState,
    project_root: str,
    *, proposal: dict[str, Any],
) -> tuple[str | None, str | None]:
    scope, clean, error = _localai_v514_carrier(
        prompt,
        pattern=_LOCALAI_V514_SCOPE_RE,
        marker=_LOCALAI_V514_SCOPE_MARKER_RE,
        label="ALGORITHM_SCOPE",
        required=True,
    )
    if error:
        return None, error
    assert scope is not None

    recovery, clean, error = _localai_v514_carrier(
        clean, pattern=_LOCALAI_V514_RECOVERY_RE, marker=_LOCALAI_V514_RECOVERY_MARKER_RE,
        label="GROWTH_RECOVERY", required=bool(state.growth_recovery_guard_active))
    if error:
        return None, error
    if recovery is not None and "state_ref" in recovery:
        if (not state.growth_recovery_guard_active or recovery["state_ref"] != _localai_workflow_state.recovery_reference(state)
                or "objectives" in scope or "completed" in recovery or "residual" in recovery):
            return None, "Stale or mixed indexed recovery carrier; obtain the current bounded state reference."
        anchor = state.growth_recovery_anchor_objectives
        def indices(value):
            if (not isinstance(value, list) or any(type(i) is not int or i < 0 or i >= len(anchor) for i in value)
                    or len(set(value)) != len(value)):
                raise ValueError("Recovery indices must be unique in-range integers, not booleans.")
            return [anchor[i] for i in value]
        try:
            recovery["completed"] = indices(recovery.get("completed_indices"))
            recovery["residual"] = indices(recovery.get("residual_indices"))
            refs = recovery.get("objective_refs")
            if not isinstance(refs, list) or not refs:
                raise ValueError("Indexed recovery needs bounded delegated objective_refs.")
            objectives = []
            for ref in refs:
                if (not isinstance(ref, dict) or set(ref) != {"index", "child"}
                        or not isinstance(ref["child"], str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", ref["child"])):
                    raise ValueError("Each objective reference needs an anchor index and a short concrete child ID.")
                objectives.append(indices([ref["index"]])[0] + "::" + ref["child"])
            scope["objectives"] = objectives
        except ValueError as error:
            return None, str(error)
    elif recovery is not None and any(key in recovery for key in ("completed_indices", "residual_indices", "objective_refs")):
        return None, "Indexed recovery claims require the current state_ref."

    files, error = _localai_v514_list(
        scope.get("files"),
        label="ALGORITHM_SCOPE.files",
        normalize_path=True,
    )
    if error:
        return None, error

    objectives, error = _localai_v514_list(
        scope.get("objectives"),
        label="ALGORITHM_SCOPE.objectives",
    )
    if error:
        return None, error

    assert files is not None
    assert objectives is not None

    if not files or not objectives:
        return None, "ALGORITHM_SCOPE requires non-empty files and objectives."
    try:
        resolved_files = _localai_v514_scope_files(
            files, project_root, require_coverage=state.growth_recovery_guard_active,
        )
        failed_files = _localai_v514_scope_files(state.growth_recovery_failed_files, project_root) if state.growth_recovery_required else []
        previous_files = _localai_v514_scope_files(state.algorithm_scope_files, project_root) if state.growth_recovery_guard_active else []
    except (OSError, ValueError) as error:
        return None, (
            f"Cannot establish complete file coverage: {error} "
            "Use concrete project files or <discover>; saved recovery remains guarded."
            + _localai_v5141_authoritative_recovery_hint(state, project_root)
        )

    if not state.growth_recovery_guard_active:
        if (len(objectives) > MAX_INITIAL_OBJECTIVES or len(files) > MAX_INITIAL_SCOPE_ENTRIES
                or len(resolved_files) > MAX_INITIAL_SCOPE_FILES):
            return None, "Initial ALGORITHM scope exceeds 2 objective entries, 3 scope entries or 16 current files. Delegate a smaller cohesive slice."
        if recovery is not None:
            return None, "GROWTH_RECOVERY is valid only during active growth recovery."
        proposal.update(files=files, objectives=objectives, recovery=False)
        return clean, None

    assert recovery is not None

    completed, error = _localai_v514_list(
        recovery.get("completed"),
        label="GROWTH_RECOVERY.completed",
    )
    if error:
        return None, error

    residual, error = _localai_v514_list(
        recovery.get("residual"),
        label="GROWTH_RECOVERY.residual",
    )
    if error:
        return None, error

    assert completed is not None
    assert residual is not None

    anchor = set(state.growth_recovery_anchor_objectives)
    completed_set = set(completed)
    residual_set = set(residual)

    if completed_set & residual_set:
        return None, "GROWTH_RECOVERY.completed and residual must be disjoint."
    if completed_set | residual_set != anchor:
        return None, (
            "GROWTH_RECOVERY.completed + residual must exactly partition "
            "the original failed semantic objective IDs."
            + _localai_v5141_authoritative_recovery_hint(state, project_root)
        )
    if not set(state.growth_recovery_completed_objectives).issubset(completed_set):
        return None, "Completed growth-recovery objectives are monotonic."

    delegate_roots = {
        item.split("::", 1)[0]
        for item in objectives
    }
    missing_parents = sorted(delegate_roots - residual_set)
    if not residual_set or missing_parents:
        return None, (
            ("Empty residual cannot close active GROWTH_LIMIT recovery. " if not residual_set else "")
            + "Delegated parent IDs missing from residual: " + ", ".join(missing_parents) + ". "
            "Keep genuinely unverified original parents in residual and delegate a bounded "
            "parent_id::child_id check; set final_slice=true only when it covers all residual parents. "
            "Implemented but unchecked work is not completed. Already accepted completed IDs cannot be reopened."
            + _localai_v5141_authoritative_recovery_hint(state, project_root)
        )

    if state.growth_recovery_required:
        rereads = list(state.growth_recovery_reread_files)
        explicit_failed = failed_files

        if explicit_failed:
            missing = [
                item
                for item in explicit_failed
                if not any(
                    read.replace('\\', '/').lower() == item
                    for read in rereads
                )
            ]
            if missing:
                return None, (
                    "GROWTH_LIMIT recovery requires root re-read of every "
                    "explicit failed-scope file. Missing: "
                    + ", ".join(missing)
                    + ". Obtain valid file contents; skipped binary responses do not satisfy recovery."
                    + _localai_v5141_authoritative_recovery_hint(state, project_root)
                )
        elif not rereads:
            return None, (
                "GROWTH_LIMIT recovery requires at least one root read_file "
                "of actual repository state."
                + _localai_v5141_authoritative_recovery_hint(state, project_root)
            )

        failed_roots = {
            item.split("::", 1)[0]
            for item in state.growth_recovery_failed_objectives
        }
        failed_files = set(failed_files)
        delegate_files = set(resolved_files)
        child_refinement = any("::" in item for item in objectives)

        if (
            delegate_roots == failed_roots
            and (not failed_files or delegate_files == failed_files)
            and not child_refinement
        ):
            return None, (
                "GROWTH_LIMIT recovery denied same-scope retry. "
                "Delegate a strictly smaller semantic residual slice."
            )
    elif (
        set(resolved_files) == set(previous_files)
        and objectives == state.algorithm_scope_objectives
    ):
        return None, (
            "GROWTH_LIMIT recovery denied repeated identical residual scope."
        )

    final_slice = recovery.get("final_slice")
    if not isinstance(final_slice, bool):
        return None, "GROWTH_RECOVERY.final_slice must be true or false."
    if final_slice and delegate_roots != residual_set:
        return None, (
            "final_slice=true requires delegated semantic roots to cover "
            "all currently residual objectives."
        )

    plan = dict(completed=completed, residual=residual, delegate_files=files,
                delegate_objectives=objectives, final_slice=final_slice)
    proposal.update(plan, recovery=True)
    return clean, None


def _localai_v514_track_reread(
    payload: dict[str, Any],
) -> None:
    if str(payload.get("tool_name") or "").strip().lower() != "read_file":
        return
    session_id = _get_required_string(payload, "session_id")
    if session_id is None:
        return
    # Pinned child tool hooks share the root session and may omit agent_id.
    if _localai_workflow_state.has_registered_agents(session_id):
        return
    state = get_active_state(session_id)
    if state is None or state.active_agents or not state.growth_recovery_required:
        return
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return
    file_path = tool_input.get("file_path")
    if not isinstance(file_path, str):
        return
    identity = _project_identity(payload)
    if identity.project_id != state.project_id:
        return
    try:
        path = _localai_v514_project_path(Path(identity.canonical_project_root), file_path)
        expected = _localai_v514_scope_files(state.growth_recovery_failed_files, identity.canonical_project_root)
    except (OSError, ValueError):
        return
    if '<discover>' not in state.growth_recovery_failed_files and path.as_posix().lower() not in expected:
        return
    if payload.get('hook_event_name') == 'PostToolUseFailure' and path.as_posix().lower() not in expected:
        return
    _localai_workflow_state.record_growth_recovery_reread(
        state,
        path.as_posix(),
        missing=payload.get("hook_event_name") == "PostToolUseFailure",
    )


def _localai_v514_trace(
    payload: dict[str, Any],
) -> None:
    # B is diagnostic only in V5.14: no terminal-completion behavior change.
    try:
        event = str(payload.get("hook_event_name") or "").strip()
        tool = str(payload.get("tool_name") or "").strip()
        if event == "PreToolUse" and tool.lower() not in {
            "agent", "read_file", "glob", "grep_search"
        }:
            return
        if event not in {"PreToolUse", "SubagentStop", "Stop"}:
            return

        session_id = str(payload.get("session_id") or "").strip()
        state = get_active_state(session_id) if session_id else None
        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "session_id": session_id,
            "event": event,
            "tool": tool,
            "growth_recovery_required": (
                state.growth_recovery_required if state else None
            ),
            "growth_recovery_guard_active": (
                state.growth_recovery_guard_active if state else None
            ),
            "turn_closed": state.turn_closed if state else None,
            "terminal_abort_reason": (
                state.terminal_abort_reason if state else None
            ),
        }
        assert_local_path(ERROR_LOG_ROOT / "terminal_completion_trace_v5_14.jsonl")
        ERROR_LOG_ROOT.mkdir(parents=True, exist_ok=True)
        with (
            ERROR_LOG_ROOT / "terminal_completion_trace_v5_14.jsonl"
        ).open("a", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    record,
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                + "\n"
            )
    except Exception:
        pass


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
        return state if state.project_id == identity.project_id else None

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




def _build_agent_memory_context(
    identity: ProjectIdentity,
    agent: str,
    *,
    include_cross_project: bool = False,
) -> str:
    parts: list[str] = []

    if agent == "prompt_agent":
        prompt_memory = read_memory(
            identity,
            "prompt_agent",
        )

        if (
            prompt_memory
            and not _is_default_memory(
                prompt_memory
            )
        ):
            parts.append(
                "Durable PROMPT/project memory:\n"
                + _normalize_text(
                    prompt_memory
                )
            )

        if include_cross_project:
            cross_project_memory = (
                read_cross_project_memory()
            )

            if (
                cross_project_memory
                and not _is_default_cross_project_memory(
                    cross_project_memory
                )
            ):
                parts.append(
                    "Cross-project memory for initial session synthesis only. "
                    "Use only genuinely relevant lessons and do not forward "
                    "this memory wholesale to specialists:\n"
                    + _normalize_text(
                        cross_project_memory
                    )
                )

    else:
        role_memory = read_memory(
            identity,
            agent,
        )

        if (
            role_memory
            and not _is_default_memory(
                role_memory
            )
        ):
            parts.append(
                "Role-specific durable memory:\n"
                + _normalize_text(
                    role_memory
                )
            )

    return "\n\n".join(parts)

def _process_subagent_message(
    identity: ProjectIdentity,
    agent: str,
    message: str | None,
) -> str:
    if not message:
        return ""

    clean_message = process_agent_memory_message(
        identity,
        agent,
        message,
    )

    clean_message = re.sub(
        r"(?mi)^\s*MEMORY:\s*NONE\s*$",
        "",
        clean_message,
    )

    return clean_message.strip()



def _has_specialist_memory_decision(
    message: str | None,
) -> bool:
    if not message:
        return False

    update = extract_memory_update(
        message
    )

    if not update.is_empty():
        return True

    clean_message = strip_memory_blocks(
        message
    )

    return (
        re.search(
            r"(?mi)^\s*MEMORY:\s*NONE\s*$",
            clean_message,
        )
        is not None
    )



def _extract_test_status(message: str | None) -> str | None:
    normalized = _normalize_text(message)
    match = re.match(r"^(PASS|FAIL|BLOCKED)(?:\s|$)", normalized) if normalized else None
    return match.group(1) if match else None


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
    session_id = _get_required_string(payload, "session_id")
    if _is_explicit_child(payload):
        _write_json({"continue": True})
        return
    if session_id and payload.get("source") == "resume":
        state = get_active_state(session_id)
        if state and state.project_id == identity.project_id:
            _localai_workflow_state.abandon_specialists(state)
            _localai_workflow_state.clear_registered_agents(session_id)
    if session_id and _localai_workflow_state.has_registered_agents(session_id):
        _write_json({"continue": True})
        return
    initialize_memory_structure(
        identity
    )

    context = _build_agent_memory_context(
        identity,
        "prompt_agent",
        include_cross_project=True,
    )

    continuation = _workflow_context(_root_workflow_state(payload, identity), identity.canonical_project_root)
    context = "\n".join(part for part in (context, continuation) if part)
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

    if session_id is None or _is_explicit_child(payload):
        _write_json({"continue": True})
        return

    state = get_active_state(session_id)
    identity = _project_identity(payload)
    if state is not None and state.project_id != identity.project_id:
        _write_json({"continue": True})
        return
    terminal_audit = bool(state and state.turn_closed and not state.algorithm_selected
                          and state.closure_outcome in {"verification_fail", "verification_blocked"})
    if state is not None and (not state.turn_closed or (state.closure_outcome != "success" and not terminal_audit)):
        _localai_workflow_state.abandon_specialists(state)
        _localai_workflow_state.clear_registered_agents(session_id)
        state.resumable_end_reason = "Session ended before root workflow closure; retained for same-ID resumable review."
        _localai_workflow_state.save_state(state)
        _write_json({"continue": True, "systemMessage": WORKFLOW_PAUSE_MARKER + " " + state.resumable_end_reason})
        return
    if state is not None:
        _localai_workflow_state.archive_session_outcome(state)
    delete_session_state(
        session_id
    )

    _write_json(
        {
            "continue": True,
        }
    )


def _handle_session_delete(payload: dict[str, Any]) -> None:
    target = payload.get("deleted_session_id")
    deleted = False
    if not _is_explicit_child(payload) and isinstance(target, str):
        identity = _project_identity(payload)
        deleted = _localai_workflow_state.delete_project_session_state(target, identity.project_id)
    _write_json({"continue": True, "systemMessage": (
        "Deleted session workflow removed." if deleted else
        "Session workflow cleanup skipped: missing or unverified target ownership; caller state preserved."
    )})


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

    if _is_explicit_child(payload) or _localai_workflow_state.has_registered_agents(session_id):
        _write_json({"continue": True})
        return
    active_state = get_active_state(session_id)
    if active_state and active_state.project_id != identity.project_id:
        _write_json({"continue": True})
        return
    submitted = payload.get("submitted_prompt")
    if active_state and isinstance(submitted, str) and submitted.strip():
        _localai_workflow_state.reset_delegation_repairs(active_state, persist=False)
        if (active_state.turn_closed and active_state.algorithm_selected and active_state.algorithm_completed
                and active_state.closure_outcome == "verification_blocked"):
            active_state.turn_closed = False
            active_state.final_test_started = False
            active_state.final_test_completed = False
            active_state.verification_status = "pending"
            active_state.closure_outcome = "interrupted"
        active_state.stop_stagnation_count = 0
        active_state.stop_blocked_reason = None
        _localai_workflow_state.save_state(active_state)
    if not _user_prompt_text(payload):
        context = _workflow_context(active_state, identity.canonical_project_root)
        _write_json(_additional_context_output("UserPromptSubmit", context) if context else {"continue": True})
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

    state, _ = start_or_resume_user_turn(
        session_id=session_id,
        observed_turn_id=observed_turn_id,
        project_id=identity.project_id,
    )

    context = _workflow_context(state, identity.canonical_project_root)
    _write_json(_additional_context_output("UserPromptSubmit", context) if context else {"continue": True})


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
        raise _localai_workflow_state.WorkflowStateError("Specialist start requires an explicit child identity.")

    role = _normalize_agent_type(payload.get("agent_type"))
    parent_call_id = _get_required_string(payload, "parent_tool_call_id")
    if not parent_call_id:
        raise _localai_workflow_state.WorkflowStateError("Specialist start requires its accepted parent tool call ID.")
    _localai_workflow_state.bind_specialist(state, agent_id, role, parent_call_id)
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


def _test_admission_error(state: WorkflowState) -> str | None:
    if any(key.startswith("agent_not_started_algorithm_agent:") for key in state.delegation_failures):
        return "A required ALGORITHM admission did not execute; repair that bounded implementation handoff before TEST."
    if state.scope_requires_refinement:
        return "Read-only discovery requires a concrete implementation/refinement ALGORITHM slice before TEST; no GROWTH_RECOVERY carrier is needed unless recovery is actually active."
    if state.growth_recovery_guard_active:
        return "GROWTH_LIMIT recovery still has residual ALGORITHM work; TEST must wait for successful final_slice completion."
    if state.algorithm_selected and not state.algorithm_completed:
        return "Implementation is incomplete; finish the admitted or next bounded ALGORITHM slice before independent TEST."
    return None


def _handle_test_start(
    payload: dict[str, Any],
    identity: ProjectIdentity,
    state: WorkflowState,
) -> None:
    reason = _test_admission_error(state)
    if reason:
        _write_json({
            "continue": False,
            "stopReason": reason,
        })
        return
    _register_subagent(
        payload,
        state,
    )

    if not state.contract_ready:
        mark_contract_ready(
            state
        )



    if state.verification_after_implementation:
        if state.algorithm_completed:
            phase_context = (
                "Final independent verification after implementation. "
                "Do not modify repository files. Return PASS, FAIL, "
                "or BLOCKED."
            )

        else:
            phase_context = (
                "Implementation is not recorded as complete. "
                "Do not modify repository files; return BLOCKED "
                "unless a stable completed state can be verified."
            )

    else:
        phase_context = (
            "Verification-only audit. Do not modify repository "
            "files. Return PASS, FAIL, or BLOCKED."
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
            context,
        )
    )


def _handle_subagent_start(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> None:
    session_id = _get_required_string(payload, "session_id")
    state = get_active_state(session_id) if session_id else None
    if state is None or state.project_id != identity.project_id:
        raise _localai_workflow_state.WorkflowStateError("Specialist start has no owned accepted workflow.")

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




def _handle_subagent_stop(payload: dict[str, Any], identity: ProjectIdentity) -> None:
    session_id = _get_required_string(payload, "session_id")
    agent_id = _get_required_string(payload, "agent_id")
    state = get_active_state(session_id) if session_id else None
    role = _normalize_agent_type(payload.get("agent_type"))
    if state is None or state.project_id != identity.project_id:
        raise _localai_workflow_state.WorkflowStateError("Specialist receipt has no owned root workflow.")
    parent_call_id = _get_required_string(payload, "parent_tool_call_id")
    if parent_call_id and parent_call_id in state.processed_stops:
        _write_json({"continue": True})
        return
    binding = state.active_agents.get(agent_id or "")
    if (not parent_call_id or not binding or binding.get("call_id") != parent_call_id or binding.get("role") != role
            or binding.get("generation") != state.growth_recovery_generation):
        _write_json({"continue": True, "systemMessage": "LOCALAI_ROOT_CONTINUATION: Unregistered or stale specialist receipt was not credited."})
        return
    message = payload.get("last_assistant_message")
    message = message if isinstance(message, str) else None
    clean = strip_memory_blocks(message)
    clean = re.sub(r"(?mi)^\s*MEMORY:\s*NONE\s*$", "", clean).strip()
    pattern = r"^(PASS|FAIL)(?:\s|$)" if role == "algorithm_agent" else r"^(PASS|FAIL|BLOCKED)(?:\s|$)"
    status = re.match(pattern, clean)
    mode = payload.get("terminate_reason")
    if role == "algorithm_agent" and not binding.get("interruption"):
        binding["interruption"] = _slice_inventory_error(binding, identity.canonical_project_root)
    valid = (mode == "GOAL" and status is not None and len(clean.split()) > 1 and _has_specialist_memory_decision(message)
             and not binding.get("interruption"))
    if role == "test_agent" and clean.splitlines()[:1] not in [["PASS"], ["FAIL"], ["BLOCKED"]]:
        valid = False
    if mode == "GOAL" and not valid and not binding.get("interruption") and not payload.get("stop_hook_active"):
        _write_json({"decision": "block", "reason": "Return a valid opening PASS/FAIL status (TEST may BLOCKED), material receipt, and explicit MEMORY decision. This is the one protocol correction."})
        return
    outcome = status.group(1) if valid else (binding.get("interruption") or (mode if mode != "GOAL" else None) or "INVALID_RECEIPT")
    if valid:
        clean = _process_subagent_message(identity, role, message)
        binding["receipt_summary"] = _failure_summary(clean) if role == "test_agent" else clean[:3000]
    _localai_workflow_state.commit_specialist_stop(state, agent_id, role, outcome)
    if valid and role == "test_agent" and outcome == "FAIL" and state.verification_after_implementation:
        fingerprint = state.last_failure_fingerprint
        count = state.failure_fingerprints[fingerprint]
        fact = ("Independent verification of repository changes failed. "
                f"Failure fingerprint={fingerprint}; equivalent occurrence count={count}. Failure evidence: "
                + _truncate(state.last_failure_summary or "", 800))
        if count >= _localai_workflow_state.MAX_EQUIVALENT_FAILURES:
            fact += " The equivalent-failure anti-loop threshold was reached; the next correction must use a materially different strategy."
        _record_automatic_misunderstanding(identity, fact)
    _unregister_subagent(payload)
    pending = not can_finish_turn(state)[0]
    context = _workflow_context(state, identity.canonical_project_root) if pending else ""
    _write_json({"continue": True, **({"systemMessage": context} if context else {})})


def _slice_inventory_error(binding: dict[str, Any], project_root: str) -> str | None:
    try:
        files = _localai_v514_scope_files(binding["files"], project_root, require_coverage=False)
        if len(files) > _localai_workflow_state.MAX_SLICE_FILES:
            return "SCOPE_FILE_LIMIT"
    except (OSError, ValueError):
        return "SCOPE_INVENTORY_UNPROVABLE"
    return None


def _slice_tool_event(payload: dict[str, Any]) -> dict[str, Any] | None:
    if not _is_explicit_child(payload):
        return None
    identity = _project_identity(payload)
    session_id = _get_required_string(payload, "session_id")
    state = get_active_state(session_id) if session_id else None
    agent_id = _get_required_string(payload, "agent_id")
    binding = state.active_agents.get(agent_id or "") if state else None
    if (not state or state.project_id != identity.project_id or not binding
            or binding["role"] != _normalize_agent_type(payload.get("agent_type"))):
        raise _localai_workflow_state.WorkflowStateError("Tool event has no authoritative active child ownership.")
    if binding["role"] != "algorithm_agent":
        return None
    event = payload["hook_event_name"]
    name = str(payload.get("tool_name", "")).lower()
    reason = binding.get("interruption")
    if event == "PreToolUse" and not reason:
        call_id = _get_required_string(payload, "tool_call_id")
        request_digest = hashlib.sha256(json.dumps([name, payload.get("tool_input")],sort_keys=True,separators=(",", ":")).encode()).hexdigest()
        if not call_id:
            reason = "TOOL_CALL_ID_MISSING"
        elif call_id in binding["tools"] and binding["tools"][call_id] != request_digest:
            reason = "TOOL_CALL_ID_CONFLICT"
        elif call_id not in binding["tools"]:
            if len(binding["tools"]) >= _localai_workflow_state.MAX_SLICE_TOOLS:
                reason = "SLICE_TOOL_LIMIT"
            else:
                binding["tools"][call_id] = request_digest
        read_only = {"read_file", "read_many_files", "glob", "grep_search", "list_directory", "tool_search"}
        if name == "agent":
            reason = "NESTED_AGENT_DENIED"
        if binding["phase"] == "discover" and name not in read_only:
            reason = "DISCOVERY_READ_ONLY"
        if binding["phase"] == "creation" and name not in read_only | {"write_file", "edit"}:
            reason = "CREATION_REQUIRES_ACCOUNTABLE_WRITE"
        if name in {"write_file", "edit"}:
            tool_input = payload.get("tool_input")
            try:
                required = ("file_path", "content") if name == "write_file" else ("file_path", "old_string", "new_string")
                if not isinstance(tool_input, dict) or any(not isinstance(tool_input.get(key), str) for key in required):
                    raise ValueError("Incomplete or malformed direct mutation input.")
                value = tool_input["file_path"]
                if not value.strip():
                    raise ValueError("Missing direct write target.")
                root = Path(identity.canonical_project_root).absolute()
                target = _localai_v514_project_path(root, value)
                allowed = any(item != "<discover>" and (
                    target.is_relative_to(_localai_v514_project_path(root, item[:-3])) if item.endswith("/**")
                    else target == _localai_v514_project_path(root, item)) for item in binding["files"])
                if not allowed:
                    raise ValueError("Write target is outside admitted scope.")
                canonical = target.as_posix().lower()
                inventory = set(_localai_v514_scope_files(binding["files"], identity.canonical_project_root, require_coverage=False))
                if len(inventory | set(binding["write_targets"]) | {canonical}) > _localai_workflow_state.MAX_SLICE_FILES:
                    reason = "SLICE_WRITE_TARGET_LIMIT"
                if canonical not in binding["write_targets"]:
                    if len(binding["write_targets"]) >= _localai_workflow_state.MAX_SLICE_FILES:
                        reason = "SLICE_WRITE_TARGET_LIMIT"
                    else:
                        binding["write_targets"].append(canonical)
            except (OSError, ValueError):
                reason = "WRITE_TARGET_UNPROVABLE"
    if event != "PreToolUse" and not reason:
        reason = _slice_inventory_error(binding, identity.canonical_project_root)
    binding["interruption"] = reason
    _localai_workflow_state.save_state(state)
    if event == "PreToolUse":
        return {"continue": True, "hookSpecificOutput": {"hookEventName": event,
                "permissionDecision": "deny" if reason else "allow",
                "permissionDecisionReason": ("Slice interrupted: " + reason + "; return actual partial-state evidence before a smaller root recovery slice.") if reason else "Bounded owned slice tool admitted."}}
    return {"continue": True}


def _root_agent_failure(payload: dict[str, Any]) -> dict[str, Any] | None:
    if (str(payload.get("tool_name", "")).lower() != "agent" or _is_explicit_child(payload)):
        return None
    identity = _project_identity(payload)
    state = _root_workflow_state(payload, identity)
    call_id = _get_required_string(payload, "tool_call_id")
    if not state or not call_id or call_id in state.processed_stops:
        return None
    admission = state.pending_admission
    if (not admission or admission["call_id"] != call_id
            or admission["generation"] != state.growth_recovery_generation):
        return None
    args = payload.get("tool_input")
    if args != admission["tool_input"]:
        return None
    if admission.get("interruption"):
        return _additional_context_output("PostToolUseFailure", WORKFLOW_PAUSE_MARKER
            + " Failed-start phase remains unproven; retain pending state and end/resume for actual-state recovery."
            + _localai_v5141_authoritative_recovery_hint(state, identity.canonical_project_root))
    role = admission["role"]
    restored = payload.get("execution_status") == "not_started" and _localai_workflow_state.retire_not_started_admission(state)
    if not restored:
        admission["interruption"] = "START_PHASE_UNPROVEN"
        state.partial_side_effects_possible = True
        if role == "algorithm_agent":
            state.algorithm_completed = False
        else:
            state.final_test_completed = False
            state.verification_status = "pending"
    reason = _delegation_repair_reason(state, "Agent pre-start failure: " + str(payload.get("error", "Unknown failure"))[:700],
        category="agent_not_started_" + role if restored else "agent_start_unproven",
        project_root=identity.canonical_project_root)
    if not restored:
        reason = WORKFLOW_PAUSE_MARKER + " Execution phase is unproven; no safe retirement was inferred. End/resume for actual-state reread. " + reason
    return _additional_context_output("PostToolUseFailure", reason)


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

    _write_workflow_block(identity, state, reason)


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

    if state.delegation_blocked_reason:
        _write_workflow_block(identity, state, "Repair remains paused; await a genuine user submission or new valid evidence.")
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

        state.closure_outcome = "success" if state.verification_status not in {"fail", "blocked"} else "verification_" + state.verification_status
        mark_turn_closed(
            state
        )

        _write_json(
            {
                "continue": True,
            }
        )
        return

    _write_workflow_block(identity, state, reason)


def _handle_prompt_memory_pre_tool_use(
    payload: dict[str, Any],
    identity: ProjectIdentity,
) -> None:
    def write_output(output: dict[str, Any]) -> None:
        decision = output.get("hookSpecificOutput", {})
        if decision.get("permissionDecision") == "deny":
            state = _root_workflow_state(payload, identity)
            if state is None and not _is_explicit_child(payload):
                session_id = _get_required_string(payload, "session_id")
                if session_id and not _localai_workflow_state.has_registered_agents(session_id):
                    state = _ensure_active_state(payload, identity)
            if state is not None and state.project_id == identity.project_id:
                reason = decision.get("permissionDecisionReason", "Invalid delegation.")
                decision["permissionDecisionReason"] = _delegation_repair_reason(state, reason, project_root=identity.canonical_project_root)
        _write_json(output)

    # Enforce specialist routing, bounded deltas, PROMPT-memory transport,
    # and foreground execution at the Agent tool boundary.
    tool_name = str(
        payload.get("tool_name")
        or ""
    ).strip().lower()

    if tool_name not in {
        "agent",
        "task",
    }:
        write_output(
            {
                "continue": True,
            }
        )
        return

    tool_input = payload.get(
        "tool_input"
    )

    if not isinstance(
        tool_input,
        dict,
    ):
        write_output(
            {
                "continue": True,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        "Agent delegation requires an object tool_input."
                    ),
                },
            }
        )
        return

    prompt = tool_input.get(
        "prompt"
    )

    if not isinstance(
        prompt,
        str,
    ):
        write_output(
            {
                "continue": True,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        "Agent delegation requires a textual task delta."
                    ),
                },
            }
        )
        return

    agent_type = _normalize_agent_type(
        tool_input.get(
            "subagent_type"
        )
    )

    canonical_type_by_role = {
        "algorithm_agent": "algorithm-agent",
        "test_agent": "test-agent",
    }

    if agent_type not in canonical_type_by_role:
        write_output(
            {
                "continue": True,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        "Only the configured algorithm-agent and test-agent "
                        "may be delegated work. Specify subagent_type explicitly; "
                        "general-purpose, fork, omitted, and other agent types "
                        "are not part of this orchestration."
                    ),
                },
            }
        )
        return
    state = _ensure_active_state(payload, identity)
    call_id = _get_required_string(payload, "tool_call_id")
    if state is None or state.project_id != identity.project_id or not call_id or _is_explicit_child(payload):
        raise _localai_workflow_state.WorkflowStateError("Root Agent admission requires owned workflow state and an API tool call ID.")
    request_digest = hashlib.sha256(json.dumps(tool_input, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if state.active_agents:
        raise _localai_workflow_state.WorkflowStateError("A specialist execution is already active; its immutable scope cannot be replaced.")
    if state.pending_admission:
        admission = state.pending_admission
        if admission.get("interruption"):
            raise _localai_workflow_state.WorkflowStateError("Failed-start uncertainty remains unresolved; end/resume this workflow and re-read actual state.")
        if admission["call_id"] == call_id and admission["request_digest"] == request_digest:
            _write_json({"continue": True, "hookSpecificOutput": {"hookEventName": "PreToolUse",
                         "permissionDecision": "allow", "tool_input": admission["tool_input"]}})
            return
        raise _localai_workflow_state.WorkflowStateError("A different specialist admission is pending; resolve it before changing scope.")
    if call_id in state.processed_stops:
        raise _localai_workflow_state.WorkflowStateError("This Agent API call was already consumed.")
    if agent_type == "test_agent":
        session_id = _get_required_string(payload, "session_id")
        state = get_active_state(session_id) if session_id else None
        reason = _test_admission_error(state) if state else None
        if reason:
            write_output({"continue": True, "hookSpecificOutput": {
                "hookEventName": "PreToolUse", "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }})
            return

    workflow_marker_pattern = re.compile(
        r"<\s*/?\s*ORCHESTRATION_WORKFLOW\s*>",
        flags=re.IGNORECASE,
    )
    workflow_pattern = re.compile(
        r"<ORCHESTRATION_WORKFLOW>\s*"
        r"(ALGORITHM_ONLY|ALGORITHM_TEST)"
        r"\s*</ORCHESTRATION_WORKFLOW>",
        flags=re.IGNORECASE,
    )
    workflow_matches = list(
        workflow_pattern.finditer(
            prompt
        )
    )

    workflow_choice = None

    if workflow_marker_pattern.search(prompt) is not None:
        if len(workflow_matches) != 1:
            write_output(
                {
                    "continue": True,
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": (
                            "Malformed orchestration workflow carrier. "
                            "Use exactly one complete "
                            "<ORCHESTRATION_WORKFLOW>ALGORITHM_ONLY"
                            "</ORCHESTRATION_WORKFLOW> or "
                            "<ORCHESTRATION_WORKFLOW>ALGORITHM_TEST"
                            "</ORCHESTRATION_WORKFLOW> carrier."
                        ),
                    },
                }
            )
            return

        workflow_choice = (
            workflow_matches[0]
            .group(1)
            .upper()
        )

    if agent_type == "algorithm_agent":
        state = _ensure_active_state(
            payload,
            identity,
        )

        if state is None or state.project_id != identity.project_id:
            write_output(
                {
                    "continue": True,
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": (
                            "Implementation delegation requires active "
                            "workflow state for this project; retry the algorithm-agent "
                            "delegation after routing state is available."
                        ),
                    },
                }
            )
            return

        if state.delegation_blocked_reason or state.stop_blocked_reason:
            write_output({"continue": True, "hookSpecificOutput": {
                "hookEventName": "PreToolUse", "permissionDecision": "deny",
                "permissionDecisionReason": _workflow_context(state, identity.canonical_project_root)}})
            return

        scope_proposal: dict[str, Any] = {}
        prepared_prompt, scope_error = _localai_v514_prepare_algorithm(
            prompt,
            state,
            identity.canonical_project_root,
            proposal=scope_proposal,
        )
        if scope_error is not None:
            write_output(
                {
                    "continue": True,
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": scope_error,
                    },
                }
            )
            return
        assert prepared_prompt is not None
        prompt = prepared_prompt

    elif workflow_choice is not None:
        write_output(
            {
                "continue": True,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        "ORCHESTRATION_WORKFLOW metadata is valid only "
                        "on algorithm-agent implementation delegation."
                    ),
                },
            }
        )
        return

    prompt = workflow_pattern.sub(
        "",
        prompt,
    )

    suspicious_workflow = (
        workflow_marker_pattern.search(
            prompt
        )
    )

    if suspicious_workflow is not None:
        write_output(
            {
                "continue": True,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        "Malformed orchestration workflow metadata "
                        "must not reach a specialist."
                    ),
                },
            }
        )
        return

    carrier_marker_pattern = re.compile(
        r"<\s*/?\s*PROM[A-Z0-9_-]{0,24}MEMORY\s*>",
        flags=re.IGNORECASE,
    )

    carrier_pattern = re.compile(
        r"<PROMPT_MEMORY>\s*(.*?)\s*</PROMPT_MEMORY>",
        flags=(
            re.IGNORECASE
            | re.DOTALL
        ),
    )

    clean_prompt = prompt

    if carrier_marker_pattern.search(prompt) is not None:
        matches = list(
            carrier_pattern.finditer(
                prompt
            )
        )

        if len(matches) == 1:
            body = (
                matches[0]
                .group(1)
                .strip()
            )

            if body:
                session_id = _get_required_string(
                    payload,
                    "session_id",
                )

                state = (
                    get_active_state(
                        session_id
                    )
                    if session_id is not None
                    else None
                )

                write_allowed = (
                    state is not None
                    and has_prior_closed_turn(
                        state
                    )
                    and not state.prompt_memory_written
                )

                if write_allowed:
                    wrapped_memory_message = (
                        "<ORCHESTRATION_MEMORY>\n"
                        + body
                        + "\n</ORCHESTRATION_MEMORY>"
                    )

                    memory_before = read_memory(
                        identity,
                        "prompt_agent",
                    )

                    process_agent_memory_message(
                        identity,
                        "prompt_agent",
                        wrapped_memory_message,
                    )

                    memory_after = read_memory(
                        identity,
                        "prompt_agent",
                    )

                    if memory_after != memory_before:
                        mark_prompt_memory_written(
                            state
                        )

        clean_prompt = carrier_pattern.sub(
            "",
            prompt,
        )

        suspicious_tail = carrier_marker_pattern.search(
            clean_prompt
        )

        if suspicious_tail is not None:
            clean_prompt = clean_prompt[
                : suspicious_tail.start()
            ]

    clean_prompt = re.sub(
        r"\n{3,}",
        "\n\n",
        clean_prompt,
    ).strip()

    max_chars = (
        MAX_ALGORITHM_DELTA_CHARS
        if agent_type == "algorithm_agent"
        else MAX_TEST_DELTA_CHARS
    )

    if len(clean_prompt) > max_chars:
        write_output(
            {
                "continue": True,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        f"{canonical_type_by_role[agent_type]} task delta is "
                        f"{len(clean_prompt)} characters; hard limit is "
                        f"{max_chars}. Resynthesize only the task-specific delta "
                        "instead of restating the user prompt or conversation."
                    ),
                },
            }
        )
        return

    prior_state = _localai_workflow_state.capture_admission_state(state)
    if agent_type == "algorithm_agent":
        if state.implementation_verification_required is None or workflow_choice == "ALGORITHM_TEST":
            # Routing and scope are committed together with the immutable admission.
            state.algorithm_selected = True
            state.implementation_verification_required = bool(state.test_selected or workflow_choice != "ALGORITHM_ONLY")
            state.test_selected = state.implementation_verification_required
            state.verification_after_implementation = state.test_selected
        recovery_plan = scope_proposal.pop("recovery")
        if recovery_plan:
            _localai_workflow_state.set_growth_recovery_plan(state, **scope_proposal, persist=False)
        else:
            _localai_workflow_state.set_algorithm_scope(state, **scope_proposal, persist=False)
        _localai_workflow_state.reset_delegation_repairs(state, persist=False)
    updated_input = dict(
        tool_input
    )

    updated_input["prompt"] = (
        clean_prompt
    )
    updated_input["subagent_type"] = (
        canonical_type_by_role[
            agent_type
        ]
    )
    updated_input["run_in_background"] = False

    files = list(state.algorithm_scope_files)
    phase = "discover" if files == ["<discover>"] else "concrete"
    if any(item.endswith("/**") and not _localai_v514_scope_files([item], identity.canonical_project_root, require_coverage=False) for item in files):
        phase = "creation"
    state.pending_admission = dict(call_id=call_id, role=agent_type, files=files,
        objectives=list(state.algorithm_scope_objectives), generation=state.growth_recovery_generation,
        digest=_localai_workflow_state.scope_digest(files, state.algorithm_scope_objectives, state.growth_recovery_generation),
        request_digest=request_digest, tool_input=updated_input, phase=phase, prior_state=prior_state)
    if agent_type == "test_agent":
        state.test_selected = True
    _localai_workflow_state.save_state(state)

    write_output(
        {
            "continue": True,
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": (
                    "Configured specialist delegation accepted."
                ),
                "tool_input": updated_input,
            },
        }
    )

# LOCALAI_GROWTH_RECOVERY_POST_READ_EVIDENCE_V5_14_1
_LOCALAI_V5141_REREAD_LOCK_PATH = (
    ORCHESTRATION_ROOT
    / "state"
    / ".growth_recovery_reread_v5_14_1.lock"
)
_LOCALAI_V5141_REREAD_LOCK_TIMEOUT_SECONDS = 5.0


def _localai_v5141_is_valid_read_evidence(
    payload: dict[str, Any],
) -> bool:
    if str(payload.get("tool_name") or "").strip().lower() != "read_file":
        return False
    if _is_explicit_child(payload):
        return False
    tool_input = payload.get('tool_input')
    file_path = tool_input.get('file_path') if isinstance(tool_input, dict) else None
    if not isinstance(file_path, str) or not Path(file_path).is_absolute() or any(char in file_path for char in '*?[]'):
        return False
    try:
        identity = _project_identity(payload)
        path = _localai_v514_project_path(Path(identity.canonical_project_root), file_path)
        info = path.stat()
        missing = False
    except FileNotFoundError:
        missing = True
        info = None
    except (OSError, ValueError):
        return False

    event_name = str(
        payload.get("hook_event_name") or ""
    ).strip()

    if event_name == "PostToolUse":
        response = payload.get("tool_response")
        if isinstance(response, dict):
            # Pinned read_file reports skipped binary content as ordinary success.
            display = response.get("returnDisplay")
            if isinstance(display, str) and display.startswith("Skipped binary file:"):
                return False
        return info is not None and stat.S_ISREG(info.st_mode)

    if event_name != "PostToolUseFailure":
        return False
    if not missing:
        return False

    if payload.get("is_interrupt") is True:
        return False

    error_type_candidates: list[Any] = [
        payload.get("error_type"),
        payload.get("errorType"),
    ]

    tool_result = payload.get("tool_result")
    if isinstance(tool_result, dict):
        error_type_candidates.extend(
            (
                tool_result.get("error_type"),
                tool_result.get("errorType"),
            )
        )

    for candidate in error_type_candidates:
        if (
            isinstance(candidate, str)
            and candidate.strip().lower() == "file_not_found"
        ):
            return True

    error_value = payload.get("error")
    if isinstance(error_value, dict):
        nested_type = (
            error_value.get("error_type")
            or error_value.get("errorType")
            or error_value.get("type")
        )
        if (
            isinstance(nested_type, str)
            and nested_type.strip().lower() == "file_not_found"
        ):
            return True
        error_text = str(error_value.get("message") or "").casefold()
    else:
        error_text = str(error_value or "").casefold()

    # Error names in an echoed filename are not evidence of a missing-file error.
    return re.match(
        r"^\s*(?:error:\s*)?(?:file not found\s*:|enoent\b|"
        r"no such file or directory\b|cannot find the (?:file|path) specified\b|file_not_found\s*$)",
        error_text,
    ) is not None


def _localai_v5141_acquire_reread_lock():
    assert_local_path(_LOCALAI_V5141_REREAD_LOCK_PATH)
    _LOCALAI_V5141_REREAD_LOCK_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )
    handle = _LOCALAI_V5141_REREAD_LOCK_PATH.open(
        "a+b"
    )
    handle.seek(0, 2)
    if handle.tell() == 0:
        handle.write(b"\0")
        handle.flush()

    deadline = (
        time.monotonic()
        + _LOCALAI_V5141_REREAD_LOCK_TIMEOUT_SECONDS
    )
    while True:
        try:
            handle.seek(0)
            msvcrt.locking(
                handle.fileno(),
                msvcrt.LK_NBLCK,
                1,
            )
            return handle
        except OSError:
            if time.monotonic() >= deadline:
                handle.close()
                raise TimeoutError(
                    "Timed out acquiring growth-recovery reread state lock."
                )
            time.sleep(0.02)


def _localai_v5141_release_reread_lock(
    handle: Any,
) -> None:
    try:
        handle.seek(0)
        msvcrt.locking(
            handle.fileno(),
            msvcrt.LK_UNLCK,
            1,
        )
    finally:
        handle.close()


def _localai_v5141_record_read_evidence(
    payload: dict[str, Any],
) -> None:
    if not _localai_v5141_is_valid_read_evidence(payload):
        return

    lock_handle = _localai_v5141_acquire_reread_lock()
    try:
        _localai_v514_track_reread(
            payload
        )
    finally:
        _localai_v5141_release_reread_lock(
            lock_handle
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

    if event_name == "SessionDelete":
        _handle_session_delete(payload)
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

    if event_name == "PreToolUse":
        slice_output = _slice_tool_event(payload)
        if slice_output is not None:
            _write_json(slice_output)
            return
        _handle_prompt_memory_pre_tool_use(
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
        ).strip()

        lock_id = payload.get("deleted_session_id") if event_name == "SessionDelete" else payload.get("session_id")
        lock = _localai_workflow_state.session_transition_lock(lock_id) if isinstance(lock_id, str) and lock_id else nullcontext()
        with lock:
            _localai_v514_trace(
                payload
            )

            if event_name in {
                "PostToolUse",
                "PostToolUseFailure",
            }:
                if event_name == "PostToolUseFailure":
                    failure_output = _root_agent_failure(payload)
                    if failure_output is not None:
                        _write_json(failure_output)
                        return
                slice_output = _slice_tool_event(payload)
                if slice_output is not None:
                    _write_json(slice_output)
                    return
                error = payload.get("error")
                if (event_name == "PostToolUseFailure" and str(payload.get("tool_name", "")).lower() == "agent"
                        and isinstance(error, str) and error.startswith("LOCALAI_AGENT_PARAMETER_ERROR:")):
                    identity = _project_identity(payload)
                    state = _root_workflow_state(payload, identity)
                    if state is None and not _is_explicit_child(payload):
                        state = _ensure_active_state(payload, identity)
                    if (state and state.project_id == identity.project_id and not _is_explicit_child(payload)
                            and not _localai_workflow_state.has_registered_agents(state.session_id)):
                        reason = _delegation_repair_reason(state, error, category="tool_parameters", project_root=identity.canonical_project_root)
                        _write_json(_additional_context_output("PostToolUseFailure", reason))
                        return
                _localai_v5141_record_read_evidence(
                    payload
                )
                _write_json(
                    {"continue": True}
                )
                return

            _dispatch(
                payload
            )

    except (RuntimeError, OSError) as error:
        # Workflow and local-path safety failures must never authorize execution.
        try:
            _log_error(event_name, error)
        except Exception:
            pass
        reason = WORKFLOW_PAUSE_MARKER + " Workflow state is unresolved or unsafe; existing evidence was preserved. " + str(error)[:300]
        if event_name == "PreToolUse":
            _write_json({"continue": True, "hookSpecificOutput": {"hookEventName": event_name,
                         "permissionDecision": "deny", "permissionDecisionReason": reason}})
        else:
            _write_json({"continue": False, "decision": "block", "reason": reason, "systemMessage": reason})
    except Exception as error:
        try:
            _log_error(event_name, error)
        except Exception:
            pass

        if event_name == "PreToolUse":
            _write_json({"continue": True, "hookSpecificOutput": {"hookEventName": event_name,
                         "permissionDecision": "deny", "permissionDecisionReason": WORKFLOW_PAUSE_MARKER
                         + " Tool admission failed safely; no execution permission was granted."}})
            return

        if event_name in {
            "PostToolUse",
            "PostToolUseFailure",
        }:
            _write_json(
                {
                    "continue": True,
                }
            )

        elif event_name in {
            "SubagentStart",
            "SubagentStop",
            "Stop",
        }:
            _write_json(
                {
                    "continue": False,
                    "decision": "block",
                    "systemMessage": (
                        "LOCALAI_WORKFLOW_INCOMPLETE: Workflow transition failed; no completion was credited. Inspect "
                        f"{ERROR_LOG_PATH}."
                    ),
                }
            )


if __name__ == "__main__":
    main()

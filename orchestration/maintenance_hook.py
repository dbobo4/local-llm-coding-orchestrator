from __future__ import annotations

import json
import os
import shlex
import shutil
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from project_identity import (
    ORCHESTRATION_ROOT,
    PROJECT_MEMORY_ROOT,
)
from project_registry import (
    canonicalize_path,
    purge_project,
    rebind_project,
)
from workflow_state import (
    get_active_state,
    save_state,
)


REGISTRY_SCRIPT_PATH = (
    ORCHESTRATION_ROOT
    / "project_registry.py"
)

LOG_ROOT = (
    ORCHESTRATION_ROOT
    / "logs"
)

ERROR_LOG_PATH = (
    LOG_ROOT
    / "maintenance_hook_errors.log"
)


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
    error: BaseException,
) -> None:
    try:
        LOG_ROOT.mkdir(
            parents=True,
            exist_ok=True,
        )

        with ERROR_LOG_PATH.open(
            "a",
            encoding="utf-8",
            newline="\n",
        ) as handle:
            handle.write(
                f"\n## {_utc_timestamp()}\n"
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


def _strip_matching_quotes(
    value: str,
) -> str:
    value = value.strip()

    if len(value) < 2:
        return value

    if (
        value[0] == value[-1]
        and value[0] in {
            '"',
            "'",
        }
    ):
        return value[1:-1]

    return value


def _same_path(
    first: str | Path,
    second: str | Path,
) -> bool:
    return (
        canonicalize_path(first)
        == canonicalize_path(second)
    )


def _is_same_or_descendant(
    path: str | Path,
    root: str | Path,
) -> bool:
    canonical_path = canonicalize_path(
        path
    )

    canonical_root = canonicalize_path(
        root
    )

    try:
        common = os.path.commonpath(
            [
                canonical_path,
                canonical_root,
            ]
        )
    except ValueError:
        return False

    return _same_path(
        common,
        canonical_root,
    )


def _split_command(
    command: str,
) -> list[str]:
    try:
        tokens = shlex.split(
            command,
            posix=False,
        )
    except ValueError:
        return []

    return [
        _strip_matching_quotes(
            token
        )
        for token in tokens
    ]


def _registry_command_tokens(
    command: str,
) -> list[str] | None:
    tokens = _split_command(
        command
    )

    if not tokens:
        return None

    if tokens[0] == "&":
        tokens = tokens[1:]

    if len(tokens) < 3:
        return None

    executable = Path(
        tokens[0]
    ).name.lower()

    if executable not in {
        "python",
        "python.exe",
        "py",
        "py.exe",
    }:
        return None

    index = 1

    if (
        executable in {
            "py",
            "py.exe",
        }
        and index < len(tokens)
        and tokens[index].startswith("-")
    ):
        index += 1

    if index >= len(tokens):
        return None

    script_path = tokens[
        index
    ]

    if not _same_path(
        script_path,
        REGISTRY_SCRIPT_PATH,
    ):
        return None

    return tokens[
        index + 1:
    ]


def _parse_rebind_command(
    command: str,
) -> tuple[
    str,
    str,
    bool,
] | None:
    arguments = _registry_command_tokens(
        command
    )

    if arguments is None:
        return None

    if len(arguments) < 3:
        return None

    operation = arguments[0].lower()

    if operation != "rebind":
        return None

    reference = arguments[1]

    new_root = arguments[2]

    remaining = arguments[
        3:
    ]

    replace_existing = False

    for token in remaining:
        if token == "--replace-existing":
            replace_existing = True
            continue

        # Unknown arguments must never be intercepted.
        return None

    return (
        reference,
        new_root,
        replace_existing,
    )


def _parse_purge_command(
    command: str,
) -> str | None:
    arguments = _registry_command_tokens(
        command
    )

    if arguments is None:
        return None

    if len(arguments) != 2:
        return None

    operation = arguments[0].lower()

    if operation != "purge":
        return None

    reference = arguments[1].strip()

    return reference or None


def _get_shell_command(
    payload: dict[str, Any],
) -> str | None:
    if payload.get(
        "hook_event_name"
    ) != "PreToolUse":
        return None

    if payload.get(
        "tool_name"
    ) != "run_shell_command":
        return None

    tool_input = payload.get(
        "tool_input"
    )

    if not isinstance(
        tool_input,
        dict,
    ):
        return None

    command = tool_input.get(
        "command"
    )

    if not isinstance(
        command,
        str,
    ):
        return None

    command = command.strip()

    return command or None


def _cleanup_replaced_temporary_memory(
    replaced_project_id: str | None,
    preserved_project_id: str,
) -> None:
    if replaced_project_id is None:
        return

    if (
        replaced_project_id
        == preserved_project_id
    ):
        return

    temporary_memory_root = (
        PROJECT_MEMORY_ROOT
        / replaced_project_id
    )

    if not temporary_memory_root.exists():
        return

    shutil.rmtree(
        temporary_memory_root
    )


def _update_active_workflow_project_id(
    payload: dict[str, Any],
    new_root: str,
    project_id: str,
) -> None:
    session_id = payload.get(
        "session_id"
    )

    cwd = payload.get(
        "cwd"
    )

    if not isinstance(
        session_id,
        str,
    ):
        return

    if not isinstance(
        cwd,
        str,
    ):
        return

    if not _is_same_or_descendant(
        cwd,
        new_root,
    ):
        return

    state = get_active_state(
        session_id
    )

    if state is None:
        return

    state.project_id = project_id

    save_state(
        state
    )


def _allow_rewritten_rebind_success(
    project_id: str,
    root: str,
) -> None:
    # The actual global mutation has already completed inside this
    # trusted hook. Replace the intercepted command with a harmless
    # success message so PROMPT_AGENT does not execute it again.
    rewritten_command = (
        "python -c "
        "\"print('ORCHESTRATION_REBIND_OK')\""
    )

    _write_json(
        {
            "continue": True,
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "tool_input": {
                    "command": rewritten_command,
                },
                "additionalContext": (
                    "Global orchestration project rebind "
                    "completed successfully. "
                    f"Preserved project_id={project_id}; "
                    f"new root={root}. "
                    "The original registry command has already "
                    "been handled by the trusted maintenance "
                    "hook and must not be retried."
                ),
            }
        }
    )


def _allow_rewritten_purge_success(
    project_id: str,
    label: str,
    root: str,
    removed_memory: bool,
    removed_state_files: int,
    removed_state_directories: int,
) -> None:
    # The trusted hook already performed the destructive global
    # cleanup. Replace the intercepted command with a harmless
    # success marker so it cannot run a second time.
    rewritten_command = (
        "python -c "
        "\"print('ORCHESTRATION_PURGE_OK')\""
    )

    _write_json(
        {
            "continue": True,
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "tool_input": {
                    "command": rewritten_command,
                },
                "additionalContext": (
                    "Global orchestration project purge "
                    "completed successfully. "
                    f"Removed project_id={project_id}; "
                    f"label={label}; "
                    f"former root={root}; "
                    f"durable memory removed={removed_memory}; "
                    f"workflow state files removed="
                    f"{removed_state_files}; "
                    f"state directories removed="
                    f"{removed_state_directories}. "
                    "The registry entry has been removed. "
                    "The original purge command has already "
                    "been handled by the trusted maintenance "
                    "hook and must not be retried."
                ),
            }
        }
    )


def _deny_maintenance(
    operation: str,
    reason: str,
) -> None:
    _write_json(
        {
            "continue": True,
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "Global orchestration project "
                    f"{operation} failed inside the "
                    "maintenance hook: "
                    f"{reason}"
                ),
            }
        }
    )


def _handle_rebind(
    payload: dict[str, Any],
    reference: str,
    new_root: str,
    replace_existing: bool,
) -> None:
    (
        preserved_project,
        replaced_project,
    ) = rebind_project(
        reference,
        new_root,
        replace_existing=(
            replace_existing
        ),
    )

    # If this rebind occurred during an already active session that
    # initially received a temporary project identity, immediately
    # update that workflow state to the preserved stable identity.
    _update_active_workflow_project_id(
        payload,
        new_root=preserved_project.root,
        project_id=(
            preserved_project.project_id
        ),
    )

    # rebind_project() tells us exactly which conflicting temporary
    # registry entry was removed. Delete only that project's
    # orchestration memory; never infer deletion from folder names.
    replaced_project_id = (
        replaced_project.project_id
        if replaced_project is not None
        else None
    )

    _cleanup_replaced_temporary_memory(
        replaced_project_id=(
            replaced_project_id
        ),
        preserved_project_id=(
            preserved_project.project_id
        ),
    )

    _allow_rewritten_rebind_success(
        project_id=(
            preserved_project.project_id
        ),
        root=(
            preserved_project.root
        ),
    )


def _handle_purge(
    reference: str,
) -> None:
    result = purge_project(
        reference
    )

    _allow_rewritten_purge_success(
        project_id=(
            result.project.project_id
        ),
        label=(
            result.project.label
        ),
        root=(
            result.project.root
        ),
        removed_memory=(
            result.removed_memory
        ),
        removed_state_files=(
            result.removed_state_files
        ),
        removed_state_directories=(
            result.removed_state_directories
        ),
    )


def main() -> None:
    try:
        payload = _read_hook_input()

        command = _get_shell_command(
            payload
        )

        if command is None:
            _write_json(
                {
                    "continue": True,
                }
            )
            return

        parsed_rebind = _parse_rebind_command(
            command
        )

        if parsed_rebind is not None:
            (
                reference,
                new_root,
                replace_existing,
            ) = parsed_rebind

            try:
                _handle_rebind(
                    payload,
                    reference=reference,
                    new_root=new_root,
                    replace_existing=(
                        replace_existing
                    ),
                )

            except Exception as error:
                _log_error(
                    error
                )

                _deny_maintenance(
                    "rebind",
                    f"{type(error).__name__}: {error}",
                )

            return

        parsed_purge = _parse_purge_command(
            command
        )

        if parsed_purge is not None:
            try:
                _handle_purge(
                    parsed_purge
                )

            except Exception as error:
                _log_error(
                    error
                )

                _deny_maintenance(
                    "purge",
                    f"{type(error).__name__}: {error}",
                )

            return

        _write_json(
            {
                "continue": True,
            }
        )

    except Exception as error:
        _log_error(
            error
        )

        _write_json(
            {
                "continue": True,
            }
        )


if __name__ == "__main__":
    main()
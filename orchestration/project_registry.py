from __future__ import annotations

import json
import os
import re
import shutil
import sys
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


QWEN_HOME = Path(
    os.environ.get(
        "QWEN_HOME",
        str(Path.home() / ".qwen"),
    )
).expanduser()

ORCHESTRATION_ROOT = (
    QWEN_HOME
    / "orchestration"
)

REGISTRY_PATH = (
    ORCHESTRATION_ROOT
    / "project_registry.json"
)

PROJECT_MEMORY_ROOT = (
    ORCHESTRATION_ROOT
    / "memory"
    / "projects"
)

STATE_ROOT = (
    ORCHESTRATION_ROOT
    / "state"
)

REGISTRY_VERSION = 1


@dataclass
class RegisteredProject:
    project_id: str
    label: str
    root: str
    created_at: str
    updated_at: str
    previous_roots: list[str] = field(
        default_factory=list
    )


@dataclass
class PurgeResult:
    project: RegisteredProject
    removed_memory: bool
    removed_state_files: int
    removed_state_directories: int


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def canonicalize_path(
    path: str | Path,
) -> str:
    candidate = Path(path).expanduser()

    try:
        candidate = candidate.resolve(
            strict=False
        )
    except OSError:
        candidate = Path(
            os.path.abspath(
                str(candidate)
            )
        )

    normalized = os.path.normpath(
        str(candidate)
    )

    if os.name == "nt":
        normalized = os.path.normcase(
            normalized
        )

    return normalized


def _safe_label(
    value: str,
) -> str:
    value = value.strip()

    if not value:
        return "project"

    safe = re.sub(
        r"[^A-Za-z0-9._-]+",
        "_",
        value,
    ).strip("._-")

    return safe[:80] or "project"


def _default_label(
    root: str,
) -> str:
    name = Path(root).name.strip()

    return (
        name
        if name
        else "project"
    )


def _new_project_id(
    label: str,
) -> str:
    readable_label = _safe_label(
        label
    )

    random_part = uuid.uuid4().hex[:12]

    return (
        f"{readable_label}_{random_part}"
    )


def _empty_registry() -> dict[str, Any]:
    return {
        "version": REGISTRY_VERSION,
        "projects": [],
    }


def _project_from_dict(
    payload: dict[str, Any],
) -> RegisteredProject:
    previous_roots = payload.get(
        "previous_roots",
        [],
    )

    if not isinstance(
        previous_roots,
        list,
    ):
        previous_roots = []

    return RegisteredProject(
        project_id=str(
            payload["project_id"]
        ),
        label=str(
            payload["label"]
        ),
        root=canonicalize_path(
            str(payload["root"])
        ),
        created_at=str(
            payload["created_at"]
        ),
        updated_at=str(
            payload["updated_at"]
        ),
        previous_roots=[
            canonicalize_path(root)
            for root in previous_roots
            if isinstance(root, str)
            and root.strip()
        ],
    )


def _load_registry_document() -> dict[str, Any]:
    if not REGISTRY_PATH.exists():
        return _empty_registry()

    try:
        payload = json.loads(
            REGISTRY_PATH.read_text(
                encoding="utf-8"
            )
        )
    except (
        OSError,
        json.JSONDecodeError,
    ) as error:
        raise RuntimeError(
            f"Cannot read project registry: {REGISTRY_PATH}"
        ) from error

    if not isinstance(
        payload,
        dict,
    ):
        raise RuntimeError(
            "Project registry root must be a JSON object."
        )

    version = payload.get(
        "version"
    )

    if version != REGISTRY_VERSION:
        raise RuntimeError(
            "Unsupported project registry version: "
            f"{version!r}"
        )

    projects = payload.get(
        "projects"
    )

    if not isinstance(
        projects,
        list,
    ):
        raise RuntimeError(
            "Project registry 'projects' must be a list."
        )

    return payload


def _load_projects() -> list[RegisteredProject]:
    document = _load_registry_document()

    projects: list[RegisteredProject] = []

    for item in document["projects"]:
        if not isinstance(
            item,
            dict,
        ):
            raise RuntimeError(
                "Every project registry entry must be an object."
            )

        projects.append(
            _project_from_dict(
                item
            )
        )

    return projects


def _atomic_write_projects(
    projects: list[RegisteredProject],
) -> None:
    ORCHESTRATION_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    payload = {
        "version": REGISTRY_VERSION,
        "projects": [
            asdict(project)
            for project in projects
        ],
    }

    temporary_path = (
        REGISTRY_PATH.with_name(
            f".{REGISTRY_PATH.name}.{os.getpid()}.tmp"
        )
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
            REGISTRY_PATH,
        )

    finally:
        if temporary_path.exists():
            try:
                temporary_path.unlink()
            except OSError:
                pass


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


def list_projects() -> list[RegisteredProject]:
    return _load_projects()


def find_project_by_id(
    project_id: str,
) -> RegisteredProject | None:
    project_id = project_id.strip()

    if not project_id:
        return None

    for project in _load_projects():
        if project.project_id == project_id:
            return project

    return None


def find_project_by_exact_root(
    root: str | Path,
) -> RegisteredProject | None:
    canonical_root = canonicalize_path(
        root
    )

    for project in _load_projects():
        if _same_path(
            project.root,
            canonical_root,
        ):
            return project

    return None


def find_project_for_path(
    path: str | Path,
) -> RegisteredProject | None:
    canonical_path = canonicalize_path(
        path
    )

    matches: list[RegisteredProject] = []

    for project in _load_projects():
        if _is_same_or_descendant(
            canonical_path,
            project.root,
        ):
            matches.append(
                project
            )

    if not matches:
        return None

    # The most specific registered ancestor wins.
    return max(
        matches,
        key=lambda project: len(
            Path(project.root).parts
        ),
    )


def find_project_by_label(
    label: str,
) -> RegisteredProject | None:
    normalized = label.strip().casefold()

    if not normalized:
        return None

    matches = [
        project
        for project in _load_projects()
        if project.label.casefold()
        == normalized
    ]

    if len(matches) == 1:
        return matches[0]

    return None


def register_project(
    root: str | Path,
    *,
    label: str | None = None,
    force_new: bool = False,
) -> RegisteredProject:
    canonical_root = canonicalize_path(
        root
    )

    projects = _load_projects()

    for project in projects:
        if _same_path(
            project.root,
            canonical_root,
        ):
            return project

    if not force_new:
        ancestor_matches = [
            project
            for project in projects
            if _is_same_or_descendant(
                canonical_root,
                project.root,
            )
        ]

        if ancestor_matches:
            return max(
                ancestor_matches,
                key=lambda project: len(
                    Path(project.root).parts
                ),
            )

    resolved_label = (
        label.strip()
        if label is not None
        and label.strip()
        else _default_label(
            canonical_root
        )
    )

    now = _utc_timestamp()

    project = RegisteredProject(
        project_id=_new_project_id(
            resolved_label
        ),
        label=resolved_label,
        root=canonical_root,
        created_at=now,
        updated_at=now,
    )

    projects.append(
        project
    )

    _atomic_write_projects(
        projects
    )

    return project


def get_or_create_project(
    root: str | Path,
    *,
    label: str | None = None,
) -> RegisteredProject:
    existing = find_project_for_path(
        root
    )

    if existing is not None:
        return existing

    return register_project(
        root,
        label=label,
    )


def _resolve_project_reference(
    reference: str,
) -> RegisteredProject | None:
    reference = reference.strip()

    if not reference:
        return None

    by_id = find_project_by_id(
        reference
    )

    if by_id is not None:
        return by_id

    by_label = find_project_by_label(
        reference
    )

    if by_label is not None:
        return by_label

    try:
        by_root = find_project_by_exact_root(
            reference
        )
    except (
        OSError,
        ValueError,
    ):
        by_root = None

    return by_root


def rebind_project(
    reference: str,
    new_root: str | Path,
    *,
    new_label: str | None = None,
    replace_existing: bool = False,
) -> tuple[
    RegisteredProject,
    RegisteredProject | None,
]:
    project = _resolve_project_reference(
        reference
    )

    if project is None:
        raise ValueError(
            "Unknown project reference: "
            f"{reference!r}"
        )

    canonical_new_root = canonicalize_path(
        new_root
    )

    projects = _load_projects()

    target_index: int | None = None

    for index, candidate in enumerate(
        projects
    ):
        if (
            candidate.project_id
            == project.project_id
        ):
            target_index = index
            break

    if target_index is None:
        raise RuntimeError(
            "Project disappeared from registry during rebind."
        )

    conflicting_project: RegisteredProject | None = None

    for candidate in projects:
        if (
            candidate.project_id
            == project.project_id
        ):
            continue

        if _same_path(
            candidate.root,
            canonical_new_root,
        ):
            conflicting_project = candidate
            break

    if (
        conflicting_project is not None
        and not replace_existing
    ):
        raise ValueError(
            "The new root is already registered to another "
            f"project: {conflicting_project.project_id}"
        )

    if conflicting_project is not None:
        projects = [
            candidate
            for candidate in projects
            if candidate.project_id
            != conflicting_project.project_id
        ]

        # Re-find the target because the list may have changed.
        target_index = next(
            index
            for index, candidate in enumerate(
                projects
            )
            if candidate.project_id
            == project.project_id
        )

    target = projects[
        target_index
    ]

    old_root = target.root

    if (
        old_root
        and not _same_path(
            old_root,
            canonical_new_root,
        )
        and all(
            not _same_path(
                previous_root,
                old_root,
            )
            for previous_root
            in target.previous_roots
        )
    ):
        target.previous_roots.append(
            old_root
        )

    target.root = canonical_new_root

    if (
        new_label is not None
        and new_label.strip()
    ):
        target.label = (
            new_label.strip()
        )

    else:
        target.label = _default_label(
            canonical_new_root
        )

    target.updated_at = _utc_timestamp()

    projects[
        target_index
    ] = target

    _atomic_write_projects(
        projects
    )

    return (
        target,
        conflicting_project,
    )


def unregister_project(
    reference: str,
) -> RegisteredProject:
    project = _resolve_project_reference(
        reference
    )

    if project is None:
        raise ValueError(
            "Unknown project reference: "
            f"{reference!r}"
        )

    projects = [
        candidate
        for candidate in _load_projects()
        if candidate.project_id
        != project.project_id
    ]

    _atomic_write_projects(
        projects
    )

    return project


def _state_file_project_id(
    state_path: Path,
) -> str | None:
    try:
        payload = json.loads(
            state_path.read_text(
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

    project_id = payload.get(
        "project_id"
    )

    if not isinstance(
        project_id,
        str,
    ):
        return None

    project_id = project_id.strip()

    return project_id or None


def _cleanup_project_states(
    project_id: str,
) -> tuple[int, int]:
    if not STATE_ROOT.exists():
        return (
            0,
            0,
        )

    matching_state_files: list[Path] = []

    for state_path in STATE_ROOT.rglob(
        "*.json"
    ):
        if (
            _state_file_project_id(
                state_path
            )
            == project_id
        ):
            matching_state_files.append(
                state_path
            )

    touched_session_directories: set[Path] = set()

    for state_path in matching_state_files:
        touched_session_directories.add(
            state_path.parent
        )

        state_path.unlink()

    removed_directories = 0

    for session_directory in sorted(
        touched_session_directories,
        key=lambda path: len(
            path.parts
        ),
        reverse=True,
    ):
        if not session_directory.exists():
            continue

        remaining_state_files = list(
            session_directory.glob(
                "*.json"
            )
        )

        if remaining_state_files:
            # Another project's workflow state still lives in this
            # session directory. Leave routing metadata untouched.
            continue

        shutil.rmtree(
            session_directory
        )

        removed_directories += 1

    return (
        len(
            matching_state_files
        ),
        removed_directories,
    )


def purge_project(
    reference: str,
) -> PurgeResult:
    project = _resolve_project_reference(
        reference
    )

    if project is None:
        raise ValueError(
            "Unknown project reference: "
            f"{reference!r}"
        )

    project_root = Path(
        project.root
    )

    if project_root.exists():
        raise ValueError(
            "Refusing to purge orchestration data while the "
            "registered project root still exists: "
            f"{project.root}"
        )

    (
        removed_state_files,
        removed_state_directories,
    ) = _cleanup_project_states(
        project.project_id
    )

    memory_root = (
        PROJECT_MEMORY_ROOT
        / project.project_id
    )

    removed_memory = False

    if memory_root.exists():
        shutil.rmtree(
            memory_root
        )

        removed_memory = True

    removed_project = unregister_project(
        project.project_id
    )

    return PurgeResult(
        project=removed_project,
        removed_memory=removed_memory,
        removed_state_files=(
            removed_state_files
        ),
        removed_state_directories=(
            removed_state_directories
        ),
    )


def _print_json(
    payload: Any,
) -> None:
    print(
        json.dumps(
            payload,
            indent=2,
            ensure_ascii=False,
            sort_keys=True,
        )
    )


def main() -> None:
    arguments = sys.argv[1:]

    if not arguments:
        _print_json(
            {
                "registry_path": str(
                    REGISTRY_PATH
                ),
                "projects": [
                    asdict(project)
                    for project in list_projects()
                ],
            }
        )
        return

    command = arguments[0].strip().lower()

    if command == "list":
        _print_json(
            [
                asdict(project)
                for project in list_projects()
            ]
        )
        return

    if (
        command == "resolve"
        and len(arguments) == 2
    ):
        project = find_project_for_path(
            arguments[1]
        )

        _print_json(
            (
                asdict(project)
                if project is not None
                else None
            )
        )
        return

    if (
        command == "register"
        and len(arguments) == 2
    ):
        project = register_project(
            arguments[1],
            force_new=True,
        )

        _print_json(
            asdict(project)
        )
        return

    if (
        command == "rebind"
        and len(arguments) in {
            3,
            4,
        }
    ):
        replace_existing = (
            len(arguments) == 4
            and arguments[3]
            == "--replace-existing"
        )

        project, replaced = rebind_project(
            arguments[1],
            arguments[2],
            replace_existing=replace_existing,
        )

        _print_json(
            {
                "project": asdict(
                    project
                ),
                "replaced_project": (
                    asdict(replaced)
                    if replaced is not None
                    else None
                ),
            }
        )
        return

    if (
        command == "purge"
        and len(arguments) == 2
    ):
        result = purge_project(
            arguments[1]
        )

        _print_json(
            asdict(
                result
            )
        )
        return

    raise SystemExit(
        "Usage:\n"
        "  project_registry.py\n"
        "  project_registry.py list\n"
        "  project_registry.py resolve <path>\n"
        "  project_registry.py register <path>\n"
        "  project_registry.py rebind <project-id|label|old-root> "
        "<new-root> [--replace-existing]\n"
        "  project_registry.py purge <project-id|label|old-root>"
    )


if __name__ == "__main__":
    main()
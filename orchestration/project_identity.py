from __future__ import annotations

import json
import os
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path

from project_registry import (
    RegisteredProject,
    canonicalize_path,
    find_project_for_path,
    register_project,
)


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

MEMORY_ROOT = (
    ORCHESTRATION_ROOT
    / "memory"
)

PROJECT_MEMORY_ROOT = (
    MEMORY_ROOT
    / "projects"
)

CROSS_PROJECT_MEMORY_ROOT = (
    MEMORY_ROOT
    / "cross_project"
)

STATE_ROOT = (
    ORCHESTRATION_ROOT
    / "state"
)

PROJECT_SETTINGS_RELATIVE_PATH = (
    Path(".qwen")
    / "settings.json"
)


# Optional natural project indicators only.
# None of these files is required for Qwen orchestration.
PROJECT_ROOT_MARKERS = (
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "requirements.txt",
    "Pipfile",
    "environment.yml",
    "package.json",
    "Cargo.toml",
    "go.mod",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "CMakeLists.txt",
)


@dataclass(frozen=True)
class ProjectIdentity:
    cwd: str
    project_root: str
    canonical_project_root: str
    project_id: str
    project_root_source: str
    is_git_repository: bool


def _normalize_existing_or_future_path(
    path: str | Path,
) -> str:
    return canonicalize_path(
        path
    )


def _same_path(
    first: str | Path,
    second: str | Path,
) -> bool:
    return (
        _normalize_existing_or_future_path(first)
        == _normalize_existing_or_future_path(second)
    )


def _is_same_or_descendant(
    path: str | Path,
    root: str | Path,
) -> bool:
    canonical_path = (
        _normalize_existing_or_future_path(
            path
        )
    )

    canonical_root = (
        _normalize_existing_or_future_path(
            root
        )
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


def _run_git_command(
    cwd: str,
    *arguments: str,
) -> subprocess.CompletedProcess[str] | None:
    creationflags = 0

    if os.name == "nt":
        creationflags = getattr(
            subprocess,
            "CREATE_NO_WINDOW",
            0,
        )

    try:
        return subprocess.run(
            [
                "git",
                *arguments,
            ],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            creationflags=creationflags,
        )
    except (
        OSError,
        subprocess.SubprocessError,
    ):
        return None


def _find_git_root(
    cwd: str,
) -> str | None:
    result = _run_git_command(
        cwd,
        "rev-parse",
        "--show-toplevel",
    )

    if result is None:
        return None

    if result.returncode != 0:
        return None

    root = result.stdout.strip()

    if not root:
        return None

    return _normalize_existing_or_future_path(
        root
    )


def _find_configured_project_root(
    cwd: str,
) -> str | None:
    current = Path(
        _normalize_existing_or_future_path(
            cwd
        )
    )

    # These are user-level Qwen settings, not project markers.
    # QWEN_HOME may be overridden, so exclude both the configured
    # global location and the conventional ~/.qwen location.
    global_settings_paths = {
        canonicalize_path(
            QWEN_HOME
            / "settings.json"
        ),
        canonicalize_path(
            Path.home()
            / ".qwen"
            / "settings.json"
        ),
    }

    candidates = (
        current,
        *current.parents,
    )

    for candidate in candidates:
        try:
            settings_path = (
                candidate
                / PROJECT_SETTINGS_RELATIVE_PATH
            )

            if settings_path.is_file():
                if (
                    canonicalize_path(
                        settings_path
                    )
                    in global_settings_paths
                ):
                    continue

                return (
                    _normalize_existing_or_future_path(
                        candidate
                    )
                )

        except OSError:
            continue

    return None

def _find_marker_root(
    cwd: str,
) -> str | None:
    current = Path(
        _normalize_existing_or_future_path(
            cwd
        )
    )

    candidates = (
        current,
        *current.parents,
    )

    for candidate in candidates:
        try:
            if any(
                (
                    candidate
                    / marker
                ).exists()
                for marker in PROJECT_ROOT_MARKERS
            ):
                return (
                    _normalize_existing_or_future_path(
                        candidate
                    )
                )
        except OSError:
            continue

    return None


def _register_authoritative_root(
    root: str,
) -> RegisteredProject:
    # Git/Qwen-config/marker discovery explicitly identified a root.
    # force_new permits a genuinely independent nested project
    # when no existing registry project already owns the path.
    return register_project(
        root,
        force_new=True,
    )


def _register_launch_root(
    cwd: str,
) -> RegisteredProject:
    # Completely unknown, non-Git, marker-free directories are
    # automatically treated as project roots at first Qwen launch.
    return register_project(
        cwd,
        force_new=True,
    )


def _determine_project(
    cwd: str,
) -> tuple[
    RegisteredProject,
    str,
    bool,
]:
    canonical_cwd = (
        _normalize_existing_or_future_path(
            cwd
        )
    )

    # 1. A real Git root is authoritative. If the current directory
    # is inside a Git repository, that naturally identifies the
    # repository boundary.
    git_root = _find_git_root(
        canonical_cwd
    )

    if git_root is not None:
        project = (
            _register_authoritative_root(
                git_root
            )
        )

        return (
            project,
            "git",
            True,
        )

    # 2. An already registered project owns all of its descendants.
    #
    # This intentionally comes before Qwen config discovery.
    # A project-local Qwen settings file in an ordinary subdirectory
    # must not split an already known logical project or its durable
    # orchestration memory.
    registered_project = (
        find_project_for_path(
            canonical_cwd
        )
    )

    if registered_project is not None:
        return (
            registered_project,
            "registry",
            False,
        )

    # 3. An existing project-local .qwen/settings.json can identify
    # a project root only when the registry does not already know a
    # parent project for this path.
    configured_root = (
        _find_configured_project_root(
            canonical_cwd
        )
    )

    if configured_root is not None:
        project = (
            _register_authoritative_root(
                configured_root
            )
        )

        return (
            project,
            "qwen_config",
            False,
        )

    # 4. Naturally existing project files may identify a root for an
    # otherwise unknown path. They remain optional and are never
    # created by the orchestration system.
    marker_root = _find_marker_root(
        canonical_cwd
    )

    if marker_root is not None:
        project = (
            _register_authoritative_root(
                marker_root
            )
        )

        return (
            project,
            "natural_marker",
            False,
        )

    # 5. First launch in a completely unknown directory:
    # that launch directory becomes the project root.
    project = _register_launch_root(
        canonical_cwd
    )

    return (
        project,
        "launch_cwd",
        False,
    )


def identify_project(
    cwd: str | Path | None = None,
) -> ProjectIdentity:
    if cwd is None:
        cwd = Path.cwd()

    canonical_cwd = (
        _normalize_existing_or_future_path(
            cwd
        )
    )

    (
        registered_project,
        source,
        is_git_repository,
    ) = _determine_project(
        canonical_cwd
    )

    canonical_project_root = (
        _normalize_existing_or_future_path(
            registered_project.root
        )
    )

    return ProjectIdentity(
        cwd=canonical_cwd,
        project_root=(
            registered_project.root
        ),
        canonical_project_root=(
            canonical_project_root
        ),
        project_id=(
            registered_project.project_id
        ),
        project_root_source=source,
        is_git_repository=(
            is_git_repository
        ),
    )


def get_project_memory_root(
    identity: ProjectIdentity,
) -> Path:
    return (
        PROJECT_MEMORY_ROOT
        / identity.project_id
    )


def get_agent_memory_root(
    identity: ProjectIdentity,
    agent: str,
) -> Path:
    return (
        get_project_memory_root(
            identity
        )
        / agent
    )


# Compatibility helpers used by memory_store.py.
def get_prompt_agent_memory_root(
    identity: ProjectIdentity,
) -> Path:
    return get_agent_memory_root(
        identity,
        "prompt_agent",
    )


def get_algorithm_agent_memory_root(
    identity: ProjectIdentity,
) -> Path:
    return get_agent_memory_root(
        identity,
        "algorithm_agent",
    )


def get_test_agent_memory_root(
    identity: ProjectIdentity,
) -> Path:
    return get_agent_memory_root(
        identity,
        "test_agent",
    )


def get_memory_path(
    identity: ProjectIdentity,
    agent: str,
) -> Path:
    return (
        get_agent_memory_root(
            identity,
            agent,
        )
        / "memory.md"
    )


def get_journal_path(
    identity: ProjectIdentity,
    agent: str,
) -> Path:
    return (
        get_agent_memory_root(
            identity,
            agent,
        )
        / "journal.md"
    )


def get_misunderstandings_path(
    identity: ProjectIdentity,
) -> Path:
    return (
        get_prompt_agent_memory_root(
            identity
        )
        / "misunderstandings.md"
    )


def get_cross_project_memory_path() -> Path:
    return (
        CROSS_PROJECT_MEMORY_ROOT
        / "memory.md"
    )


def get_project_state_root(
    identity: ProjectIdentity,
) -> Path:
    return (
        STATE_ROOT
        / identity.project_id
    )


def main() -> None:
    identity = identify_project()

    payload = asdict(
        identity
    )

    payload[
        "project_memory_root"
    ] = str(
        get_project_memory_root(
            identity
        )
    )

    payload[
        "cross_project_memory_path"
    ] = str(
        get_cross_project_memory_path()
    )

    print(
        json.dumps(
            payload,
            indent=2,
            ensure_ascii=False,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
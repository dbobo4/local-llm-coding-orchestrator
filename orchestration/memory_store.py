from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

from project_identity import (
    CROSS_PROJECT_MEMORY_ROOT,
    ProjectIdentity,
    get_algorithm_agent_memory_root,
    get_project_memory_root,
    get_prompt_agent_memory_root,
    get_test_agent_memory_root,
)


AgentRole = Literal[
    "prompt_agent",
    "algorithm_agent",
    "test_agent",
]


MAX_MEMORY_CHARS = 24_000
MAX_JOURNAL_CHARS = 32_000
MAX_MISUNDERSTANDINGS_CHARS = 20_000
MAX_CROSS_PROJECT_MEMORY_CHARS = 20_000
JOURNAL_ROTATE_BYTES = 512 * 1024


INITIAL_MEMORY_CONTENT = """# Durable project memory

Store only compact, durable facts that materially help future work on this project.

Suitable content:
- project invariants,
- important architectural decisions,
- stable interfaces and contracts,
- important mathematical or algorithmic definitions,
- durable implementation constraints,
- repeatedly relevant technical facts.

Do not store:
- raw tool output,
- temporary execution state,
- long reasoning,
- routine edits,
- transient failures,
- information already obvious from the repository.
"""


INITIAL_JOURNAL_CONTENT = """# Project journal

Keep short chronological entries for meaningful completed actions, decisions, failures, or state changes.

Each entry should be concise and explain:
- what materially happened,
- why it mattered,
- any durable consequence.

Do not log every tool call or microscopic action.
"""


INITIAL_MISUNDERSTANDINGS_CONTENT = """# Misunderstandings

This file belongs only to PROMPT_AGENT.

Record compact reusable lessons from:
- user corrections,
- contract misunderstandings,
- scope mistakes,
- repeated implementation failures,
- repeated verification failures,
- incorrect assumptions that materially affected execution.

Do not load this file during normal successful execution unless a trigger requires it.
"""


INITIAL_CROSS_PROJECT_MEMORY_CONTENT = """# Cross-project memory

Store only rare, durable lessons that are genuinely useful across unrelated projects.

Suitable content:
- broadly reusable workflow lessons,
- recurring failure-prevention rules,
- important cross-project engineering principles.

Do not store project-specific facts here.
"""


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def _normalize_text(text: str) -> str:
    return (
        text.replace("\r\n", "\n")
        .replace("\r", "\n")
        .strip()
    )


def _ensure_file(
    path: Path,
    initial_content: str,
) -> None:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    if not path.exists():
        path.write_text(
            initial_content.rstrip() + "\n",
            encoding="utf-8",
        )


def _atomic_write(
    path: Path,
    content: str,
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
            content.rstrip() + "\n",
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


def _read_bounded(
    path: Path,
    max_chars: int,
    *,
    prefer_tail: bool = False,
) -> str:
    if not path.exists():
        return ""

    content = path.read_text(
        encoding="utf-8",
        errors="replace",
    )

    if len(content) <= max_chars:
        return content

    marker = (
        "\n\n"
        "[... older content omitted by bounded memory read ...]"
        "\n\n"
    )

    if prefer_tail:
        keep = max(
            0,
            max_chars - len(marker),
        )

        return (
            marker
            + content[-keep:]
        )

    keep = max(
        0,
        max_chars - len(marker),
    )

    return (
        content[:keep]
        + marker
    )


def _append_entry(
    path: Path,
    entry: str,
    *,
    timestamp: bool = True,
) -> None:
    normalized = _normalize_text(
        entry
    )

    if not normalized:
        return

    prefix = (
        f"\n## {_utc_timestamp()}\n"
        if timestamp
        else "\n"
    )

    payload = (
        prefix
        + normalized
        + "\n"
    )

    with path.open(
        "a",
        encoding="utf-8",
        newline="\n",
    ) as handle:
        handle.write(
            payload
        )


def _rotate_journal_if_needed(
    path: Path,
) -> None:
    if not path.exists():
        return

    try:
        size = path.stat().st_size
    except OSError:
        return

    if size <= JOURNAL_ROTATE_BYTES:
        return

    archive_root = (
        path.parent
        / "archive"
    )

    archive_root.mkdir(
        parents=True,
        exist_ok=True,
    )

    timestamp = datetime.now(
        timezone.utc
    ).strftime(
        "%Y%m%dT%H%M%SZ"
    )

    archive_path = (
        archive_root
        / f"{path.stem}_{timestamp}{path.suffix}"
    )

    counter = 1

    while archive_path.exists():
        archive_path = (
            archive_root
            / (
                f"{path.stem}_"
                f"{timestamp}_"
                f"{counter}"
                f"{path.suffix}"
            )
        )

        counter += 1

    os.replace(
        path,
        archive_path,
    )

    _ensure_file(
        path,
        INITIAL_JOURNAL_CONTENT,
    )


def _agent_root(
    identity: ProjectIdentity,
    agent: AgentRole,
) -> Path:
    if agent == "prompt_agent":
        return get_prompt_agent_memory_root(
            identity
        )

    if agent == "algorithm_agent":
        return get_algorithm_agent_memory_root(
            identity
        )

    if agent == "test_agent":
        return get_test_agent_memory_root(
            identity
        )

    raise ValueError(
        f"Unsupported agent role: {agent}"
    )


def get_memory_path(
    identity: ProjectIdentity,
    agent: AgentRole,
) -> Path:
    return (
        _agent_root(
            identity,
            agent,
        )
        / "memory.md"
    )


def get_journal_path(
    identity: ProjectIdentity,
    agent: AgentRole,
) -> Path:
    return (
        _agent_root(
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


def initialize_memory_structure(
    identity: ProjectIdentity,
) -> None:
    get_project_memory_root(
        identity
    ).mkdir(
        parents=True,
        exist_ok=True,
    )

    for agent in (
        "prompt_agent",
        "algorithm_agent",
        "test_agent",
    ):
        _ensure_file(
            get_memory_path(
                identity,
                agent,
            ),
            INITIAL_MEMORY_CONTENT,
        )

        _ensure_file(
            get_journal_path(
                identity,
                agent,
            ),
            INITIAL_JOURNAL_CONTENT,
        )

    _ensure_file(
        get_misunderstandings_path(
            identity
        ),
        INITIAL_MISUNDERSTANDINGS_CONTENT,
    )

    _ensure_file(
        get_cross_project_memory_path(),
        INITIAL_CROSS_PROJECT_MEMORY_CONTENT,
    )


def read_memory(
    identity: ProjectIdentity,
    agent: AgentRole,
) -> str:
    initialize_memory_structure(
        identity
    )

    return _read_bounded(
        get_memory_path(
            identity,
            agent,
        ),
        MAX_MEMORY_CHARS,
    )


def read_journal(
    identity: ProjectIdentity,
    agent: AgentRole,
) -> str:
    initialize_memory_structure(
        identity
    )

    return _read_bounded(
        get_journal_path(
            identity,
            agent,
        ),
        MAX_JOURNAL_CHARS,
        prefer_tail=True,
    )


def read_misunderstandings(
    identity: ProjectIdentity,
) -> str:
    initialize_memory_structure(
        identity
    )

    return _read_bounded(
        get_misunderstandings_path(
            identity
        ),
        MAX_MISUNDERSTANDINGS_CHARS,
        prefer_tail=True,
    )


def read_cross_project_memory() -> str:
    path = (
        get_cross_project_memory_path()
    )

    _ensure_file(
        path,
        INITIAL_CROSS_PROJECT_MEMORY_CONTENT,
    )

    return _read_bounded(
        path,
        MAX_CROSS_PROJECT_MEMORY_CHARS,
    )


def replace_memory(
    identity: ProjectIdentity,
    agent: AgentRole,
    content: str,
) -> None:
    initialize_memory_structure(
        identity
    )

    normalized = _normalize_text(
        content
    )

    if not normalized:
        normalized = (
            INITIAL_MEMORY_CONTENT.rstrip()
        )

    _atomic_write(
        get_memory_path(
            identity,
            agent,
        ),
        normalized,
    )


def replace_cross_project_memory(
    content: str,
) -> None:
    path = (
        get_cross_project_memory_path()
    )

    normalized = _normalize_text(
        content
    )

    if not normalized:
        normalized = (
            INITIAL_CROSS_PROJECT_MEMORY_CONTENT.rstrip()
        )

    _atomic_write(
        path,
        normalized,
    )


def append_journal(
    identity: ProjectIdentity,
    agent: AgentRole,
    entry: str,
) -> None:
    initialize_memory_structure(
        identity
    )

    path = get_journal_path(
        identity,
        agent,
    )

    _rotate_journal_if_needed(
        path
    )

    _append_entry(
        path,
        entry,
        timestamp=True,
    )


def append_misunderstanding(
    identity: ProjectIdentity,
    entry: str,
) -> None:
    initialize_memory_structure(
        identity
    )

    _append_entry(
        get_misunderstandings_path(
            identity
        ),
        entry,
        timestamp=True,
    )


def append_cross_project_entry(
    entry: str,
) -> None:
    path = (
        get_cross_project_memory_path()
    )

    _ensure_file(
        path,
        INITIAL_CROSS_PROJECT_MEMORY_CONTENT,
    )

    _append_entry(
        path,
        entry,
        timestamp=True,
    )
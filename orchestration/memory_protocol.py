from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Literal

from memory_store import (
    INITIAL_CROSS_PROJECT_MEMORY_CONTENT,
    INITIAL_MEMORY_CONTENT,
    append_misunderstanding,
    read_cross_project_memory,
    read_memory,
    read_misunderstandings,
    replace_cross_project_memory,
    replace_memory,
)
from project_identity import ProjectIdentity


AgentRole = Literal[
    "prompt_agent",
    "algorithm_agent",
    "test_agent",
]

MemoryOperation = Literal[
    "ADD",
    "REPLACE",
    "REMOVE",
]


MAX_PROJECT_MEMORY_FACTS = 12
MAX_AGENT_MEMORY_FACTS = 12
MAX_CROSS_PROJECT_MEMORY_FACTS = 8

MAX_DURABLE_UPDATE_CHARS = 650
MAX_DURABLE_UPDATE_SENTENCES = 3


ROLE_PREFIX = {
    "prompt_agent": "P",
    "algorithm_agent": "A",
    "test_agent": "T",
}


MEMORY_BLOCK_PATTERN = re.compile(
    r"<ORCHESTRATION_MEMORY>\s*(.*?)\s*</ORCHESTRATION_MEMORY>",
    flags=re.IGNORECASE | re.DOTALL,
)

SECTION_PATTERN = re.compile(
    r"^(ADD|REPLACE|REMOVE):$",
    flags=re.IGNORECASE,
)

ADD_PATTERN = re.compile(
    r"^[-*]\s+(.+)$",
)

REPLACE_PATTERN = re.compile(
    r"^[-*]\s+([A-Za-z]\d+)\s*:\s*(.+)$",
)

REMOVE_PATTERN = re.compile(
    r"^[-*]\s+([A-Za-z]\d+)\s*$",
)

MEMORY_ENTRY_PATTERN = re.compile(
    r"^[-*]\s+\[([A-Za-z])(\d+)\]\s+(.+)$",
)


@dataclass
class MemoryUpdate:
    operation: MemoryOperation | None = None
    target_id: str | None = None
    fact: str | None = None

    # Programmatic orchestration-only channels.
    project: list[str] = field(
        default_factory=list
    )
    agent: list[str] = field(
        default_factory=list
    )
    misunderstandings: list[str] = field(
        default_factory=list
    )
    cross_project: list[str] = field(
        default_factory=list
    )

    def is_empty(self) -> bool:
        return not (
            self.operation
            or self.project
            or self.agent
            or self.misunderstandings
            or self.cross_project
        )


@dataclass
class MemoryEntry:
    memory_id: str
    fact: str


def _normalize_fact(
    text: str,
) -> str:
    return " ".join(
        text.strip().split()
    )


def _fact_key(
    text: str,
) -> str:
    return _normalize_fact(
        text
    ).casefold()


def _sentence_count(
    text: str,
) -> int:
    normalized = _normalize_fact(
        text
    )

    if not normalized:
        return 0

    pieces = re.split(
        r"(?<=[.!?])\s+",
        normalized,
    )

    return sum(
        1
        for piece in pieces
        if piece.strip()
    )


def _valid_fact(
    fact: str | None,
) -> bool:
    if not fact:
        return False

    normalized = _normalize_fact(
        fact
    )

    if not normalized:
        return False

    if len(normalized) > MAX_DURABLE_UPDATE_CHARS:
        return False

    return (
        _sentence_count(normalized)
        <= MAX_DURABLE_UPDATE_SENTENCES
    )


def extract_memory_update(
    message: str | None,
) -> MemoryUpdate:
    update = MemoryUpdate()

    if not message:
        return update

    matches = MEMORY_BLOCK_PATTERN.findall(
        message
    )

    # Exactly one memory block is allowed.
    if len(matches) != 1:
        return update

    lines = [
        line.strip()
        for line in matches[0].splitlines()
        if line.strip()
    ]

    if len(lines) != 2:
        return update

    section_match = SECTION_PATTERN.match(
        lines[0]
    )

    if section_match is None:
        return update

    operation = section_match.group(
        1
    ).upper()

    if operation == "ADD":
        match = ADD_PATTERN.match(
            lines[1]
        )

        if match is None:
            return update

        fact = _normalize_fact(
            match.group(1)
        )

        # ADD must not supply its own stable ID.
        if re.match(
            r"^[A-Za-z]\d+\s*:",
            fact,
        ):
            return update

        if not _valid_fact(
            fact
        ):
            return update

        update.operation = "ADD"
        update.fact = fact
        return update

    if operation == "REPLACE":
        match = REPLACE_PATTERN.match(
            lines[1]
        )

        if match is None:
            return update

        memory_id = match.group(
            1
        ).upper()

        fact = _normalize_fact(
            match.group(2)
        )

        if not _valid_fact(
            fact
        ):
            return update

        update.operation = "REPLACE"
        update.target_id = memory_id
        update.fact = fact
        return update

    if operation == "REMOVE":
        match = REMOVE_PATTERN.match(
            lines[1]
        )

        if match is None:
            return update

        update.operation = "REMOVE"
        update.target_id = match.group(
            1
        ).upper()

    return update


def strip_memory_blocks(
    message: str | None,
) -> str:
    if not message:
        return ""

    cleaned = MEMORY_BLOCK_PATTERN.sub(
        "",
        message,
    )

    return cleaned.strip()


def _extract_bullet_fact(
    line: str,
) -> str | None:
    stripped = line.strip()

    match = re.match(
        r"^[-*]\s+(.+)$",
        stripped,
    )

    if match is None:
        return None

    fact = _normalize_fact(
        match.group(1)
    )

    return fact or None


def _extract_entries(
    content: str,
    prefix: str,
) -> list[MemoryEntry]:
    if not content:
        return []

    parsed_lines: list[
        tuple[str | None, str]
    ] = []

    max_number = 0

    for line in content.splitlines():
        match = MEMORY_ENTRY_PATTERN.match(
            line.strip()
        )

        if match is not None:
            entry_prefix = match.group(
                1
            ).upper()

            number = int(
                match.group(2)
            )

            fact = _normalize_fact(
                match.group(3)
            )

            if entry_prefix == prefix:
                parsed_lines.append(
                    (
                        f"{prefix}{number:03d}",
                        fact,
                    )
                )

                max_number = max(
                    max_number,
                    number,
                )
                continue

            parsed_lines.append(
                (
                    None,
                    fact,
                )
            )
            continue

        legacy_fact = _extract_bullet_fact(
            line
        )

        if legacy_fact is not None:
            parsed_lines.append(
                (
                    None,
                    legacy_fact,
                )
            )

    result: list[MemoryEntry] = []
    seen_ids: set[str] = set()
    seen_facts: set[str] = set()

    for memory_id, fact in parsed_lines:
        key = _fact_key(
            fact
        )

        if (
            not fact
            or key in seen_facts
        ):
            continue

        if memory_id is None:
            max_number += 1
            memory_id = (
                f"{prefix}{max_number:03d}"
            )

        if memory_id in seen_ids:
            continue

        seen_ids.add(
            memory_id
        )
        seen_facts.add(
            key
        )

        result.append(
            MemoryEntry(
                memory_id=memory_id,
                fact=fact,
            )
        )

    return result


def _next_memory_id(
    entries: list[MemoryEntry],
    prefix: str,
) -> str:
    highest = 0

    for entry in entries:
        match = re.fullmatch(
            rf"{re.escape(prefix)}(\d+)",
            entry.memory_id,
        )

        if match is not None:
            highest = max(
                highest,
                int(
                    match.group(1)
                ),
            )

    return (
        f"{prefix}{highest + 1:03d}"
    )


def _apply_operation_to_entries(
    entries: list[MemoryEntry],
    update: MemoryUpdate,
    prefix: str,
    max_facts: int,
) -> tuple[
    list[MemoryEntry],
    bool,
]:
    if update.operation is None:
        return entries, False

    if update.operation == "ADD":
        if (
            not _valid_fact(
                update.fact
            )
            or len(entries) >= max_facts
        ):
            return entries, False

        fact = _normalize_fact(
            update.fact or ""
        )

        key = _fact_key(
            fact
        )

        if any(
            _fact_key(entry.fact) == key
            for entry in entries
        ):
            return entries, False

        new_entry = MemoryEntry(
            memory_id=_next_memory_id(
                entries,
                prefix,
            ),
            fact=fact,
        )

        return (
            entries + [new_entry],
            True,
        )

    target_id = (
        update.target_id
        or ""
    ).upper()

    if not re.fullmatch(
        rf"{re.escape(prefix)}\d+",
        target_id,
    ):
        return entries, False

    target_index = next(
        (
            index
            for index, entry
            in enumerate(entries)
            if entry.memory_id == target_id
        ),
        None,
    )

    if target_index is None:
        return entries, False

    if update.operation == "REMOVE":
        return (
            entries[:target_index]
            + entries[
                target_index + 1:
            ],
            True,
        )

    if update.operation == "REPLACE":
        if not _valid_fact(
            update.fact
        ):
            return entries, False

        fact = _normalize_fact(
            update.fact or ""
        )

        replacement_key = _fact_key(
            fact
        )

        if any(
            index != target_index
            and _fact_key(entry.fact)
            == replacement_key
            for index, entry
            in enumerate(entries)
        ):
            return entries, False

        if (
            _fact_key(
                entries[
                    target_index
                ].fact
            )
            == replacement_key
        ):
            return entries, False

        result = list(
            entries
        )

        result[target_index] = (
            MemoryEntry(
                memory_id=target_id,
                fact=fact,
            )
        )

        return result, True

    return entries, False


def _render_memory(
    title: str,
    entries: list[MemoryEntry],
) -> str:
    lines = [
        title,
        "",
    ]

    for entry in entries:
        lines.append(
            f"- [{entry.memory_id}] "
            f"{entry.fact}"
        )

    return "\n".join(
        lines
    ).rstrip()


def _role_title(
    agent: AgentRole,
) -> str:
    if agent == "prompt_agent":
        return (
            "# Durable PROMPT/project memory"
        )

    if agent == "algorithm_agent":
        return (
            "# Durable ALGORITHM memory"
        )

    return "# Durable TEST memory"


def _update_role_memory(
    identity: ProjectIdentity,
    agent: AgentRole,
    update: MemoryUpdate,
) -> None:
    if update.operation is None:
        return

    prefix = ROLE_PREFIX[
        agent
    ]

    current = read_memory(
        identity,
        agent,
    )

    if (
        current.strip()
        == INITIAL_MEMORY_CONTENT.strip()
    ):
        entries: list[
            MemoryEntry
        ] = []
    else:
        entries = _extract_entries(
            current,
            prefix,
        )

    updated, changed = (
        _apply_operation_to_entries(
            entries,
            update,
            prefix,
            (
                MAX_PROJECT_MEMORY_FACTS
                if agent == "prompt_agent"
                else MAX_AGENT_MEMORY_FACTS
            ),
        )
    )

    if not changed:
        return

    if updated:
        replace_memory(
            identity,
            agent,
            _render_memory(
                _role_title(
                    agent
                ),
                updated,
            ),
        )
    else:
        replace_memory(
            identity,
            agent,
            "",
        )


def _add_programmatic_facts(
    identity: ProjectIdentity,
    agent: AgentRole,
    facts: list[str],
) -> None:
    for fact in facts:
        normalized = _normalize_fact(
            fact
        )

        if not _valid_fact(
            normalized
        ):
            continue

        _update_role_memory(
            identity,
            agent,
            MemoryUpdate(
                operation="ADD",
                fact=normalized,
            ),
        )


def _extract_cross_project_entries(
    content: str,
) -> list[MemoryEntry]:
    return _extract_entries(
        content,
        "C",
    )


def _add_cross_project_facts(
    facts: list[str],
) -> None:
    if not facts:
        return

    current = (
        read_cross_project_memory()
    )

    if (
        current.strip()
        == INITIAL_CROSS_PROJECT_MEMORY_CONTENT.strip()
    ):
        entries: list[
            MemoryEntry
        ] = []
    else:
        entries = (
            _extract_cross_project_entries(
                current
            )
        )

    changed = False

    for fact in facts:
        normalized = _normalize_fact(
            fact
        )

        if (
            not _valid_fact(
                normalized
            )
            or len(entries)
            >= MAX_CROSS_PROJECT_MEMORY_FACTS
        ):
            continue

        key = _fact_key(
            normalized
        )

        if any(
            _fact_key(entry.fact) == key
            for entry in entries
        ):
            continue

        entries.append(
            MemoryEntry(
                memory_id=_next_memory_id(
                    entries,
                    "C",
                ),
                fact=normalized,
            )
        )

        changed = True

    if not changed:
        return

    replace_cross_project_memory(
        _render_memory(
            "# Cross-project memory",
            entries,
        )
    )


def _existing_misunderstanding_keys(
    identity: ProjectIdentity,
) -> set[str]:
    current = (
        read_misunderstandings(
            identity
        )
    )

    keys: set[str] = set()

    for line in current.splitlines():
        fact = _extract_bullet_fact(
            line
        )

        if fact is not None:
            keys.add(
                _fact_key(
                    fact
                )
            )

    return keys


def _append_new_misunderstandings(
    identity: ProjectIdentity,
    facts: list[str],
) -> None:
    if not facts:
        return

    existing_keys = (
        _existing_misunderstanding_keys(
            identity
        )
    )

    for fact in facts:
        normalized = _normalize_fact(
            fact
        )

        if not normalized:
            continue

        key = _fact_key(
            normalized
        )

        if key in existing_keys:
            continue

        append_misunderstanding(
            identity,
            f"- {normalized}",
        )

        existing_keys.add(
            key
        )


def apply_memory_update(
    identity: ProjectIdentity,
    source_agent: AgentRole,
    update: MemoryUpdate,
) -> None:
    if update.is_empty():
        return

    # Model-originated ADD/REPLACE/REMOVE can modify only
    # the source agent's own persistent memory.
    if update.operation is not None:
        _update_role_memory(
            identity,
            source_agent,
            update,
        )

    # These channels remain available only for explicit
    # orchestration-side programmatic updates.
    if update.project:
        _add_programmatic_facts(
            identity,
            "prompt_agent",
            update.project,
        )

    if update.agent:
        _add_programmatic_facts(
            identity,
            source_agent,
            update.agent,
        )

    if update.misunderstandings:
        _append_new_misunderstandings(
            identity,
            update.misunderstandings,
        )

    if update.cross_project:
        _add_cross_project_facts(
            update.cross_project
        )


def process_agent_memory_message(
    identity: ProjectIdentity,
    source_agent: AgentRole,
    message: str | None,
) -> str:
    update = extract_memory_update(
        message
    )

    apply_memory_update(
        identity,
        source_agent,
        update,
    )

    return strip_memory_blocks(
        message
    )
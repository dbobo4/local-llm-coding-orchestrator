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


MAX_PROJECT_MEMORY_FACTS = 80
MAX_AGENT_MEMORY_FACTS = 80
MAX_CROSS_PROJECT_MEMORY_FACTS = 60

MEMORY_BLOCK_PATTERN = re.compile(
    r"<ORCHESTRATION_MEMORY>\s*(.*?)\s*</ORCHESTRATION_MEMORY>",
    flags=re.IGNORECASE | re.DOTALL,
)

VALID_SECTIONS = {
    "PROJECT",
    "AGENT",
    "MISUNDERSTANDING",
    "CROSS_PROJECT",
}


@dataclass
class MemoryUpdate:
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
            self.project
            or self.agent
            or self.misunderstandings
            or self.cross_project
        )


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


def _extract_bullet_fact(
    line: str,
) -> str | None:
    stripped = line.strip()

    if not stripped:
        return None

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


def extract_memory_update(
    message: str | None,
) -> MemoryUpdate:
    update = MemoryUpdate()

    if not message:
        return update

    matches = MEMORY_BLOCK_PATTERN.findall(
        message
    )

    for block in matches:
        current_section: str | None = None

        for raw_line in block.splitlines():
            line = raw_line.strip()

            if not line:
                continue

            section_candidate = (
                line.rstrip(":")
                .strip()
                .upper()
            )

            if section_candidate in VALID_SECTIONS:
                current_section = (
                    section_candidate
                )
                continue

            fact = _extract_bullet_fact(
                line
            )

            if (
                fact is None
                or current_section is None
            ):
                continue

            if current_section == "PROJECT":
                update.project.append(
                    fact
                )

            elif current_section == "AGENT":
                update.agent.append(
                    fact
                )

            elif (
                current_section
                == "MISUNDERSTANDING"
            ):
                update.misunderstandings.append(
                    fact
                )

            elif (
                current_section
                == "CROSS_PROJECT"
            ):
                update.cross_project.append(
                    fact
                )

    update.project = _deduplicate_facts(
        update.project
    )
    update.agent = _deduplicate_facts(
        update.agent
    )
    update.misunderstandings = (
        _deduplicate_facts(
            update.misunderstandings
        )
    )
    update.cross_project = (
        _deduplicate_facts(
            update.cross_project
        )
    )

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


def _deduplicate_facts(
    facts: list[str],
) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()

    for fact in facts:
        normalized = _normalize_fact(
            fact
        )

        if not normalized:
            continue

        key = _fact_key(
            normalized
        )

        if key in seen:
            continue

        seen.add(
            key
        )

        result.append(
            normalized
        )

    return result


def _extract_existing_bullets(
    content: str,
) -> list[str]:
    facts: list[str] = []

    for line in content.splitlines():
        fact = _extract_bullet_fact(
            line
        )

        if fact is not None:
            facts.append(
                fact
            )

    return _deduplicate_facts(
        facts
    )


def _merge_facts(
    existing: list[str],
    new: list[str],
    max_facts: int,
) -> list[str]:
    result: list[str] = []
    index_by_key: dict[str, int] = {}

    for fact in existing + new:
        normalized = _normalize_fact(
            fact
        )

        if not normalized:
            continue

        key = _fact_key(
            normalized
        )

        if key in index_by_key:
            old_index = (
                index_by_key[
                    key
                ]
            )

            result.pop(
                old_index
            )

            index_by_key = {
                _fact_key(item): index
                for index, item
                in enumerate(result)
            }

        result.append(
            normalized
        )

        index_by_key[
            key
        ] = len(result) - 1

    if len(result) > max_facts:
        result = result[
            -max_facts:
        ]

    return result


def _render_memory(
    title: str,
    facts: list[str],
) -> str:
    lines = [
        title,
        "",
    ]

    for fact in facts:
        lines.append(
            f"- {fact}"
        )

    return "\n".join(
        lines
    ).rstrip()


def _update_agent_memory(
    identity: ProjectIdentity,
    agent: AgentRole,
    new_facts: list[str],
    max_facts: int,
) -> None:
    if not new_facts:
        return

    current = read_memory(
        identity,
        agent,
    )

    if (
        current.strip()
        == INITIAL_MEMORY_CONTENT.strip()
    ):
        existing: list[str] = []
    else:
        existing = (
            _extract_existing_bullets(
                current
            )
        )

    merged = _merge_facts(
        existing,
        new_facts,
        max_facts,
    )

    replace_memory(
        identity,
        agent,
        _render_memory(
            "# Durable project memory",
            merged,
        ),
    )


def _update_cross_project_memory(
    new_facts: list[str],
) -> None:
    if not new_facts:
        return

    current = (
        read_cross_project_memory()
    )

    if (
        current.strip()
        == INITIAL_CROSS_PROJECT_MEMORY_CONTENT.strip()
    ):
        existing: list[str] = []
    else:
        existing = (
            _extract_existing_bullets(
                current
            )
        )

    merged = _merge_facts(
        existing,
        new_facts,
        MAX_CROSS_PROJECT_MEMORY_FACTS,
    )

    replace_cross_project_memory(
        _render_memory(
            "# Cross-project memory",
            merged,
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

    return {
        _fact_key(
            fact
        )
        for fact
        in _extract_existing_bullets(
            current
        )
    }


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
        key = _fact_key(
            fact
        )

        if key in existing_keys:
            continue

        append_misunderstanding(
            identity,
            f"- {fact}",
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

    if update.project:
        _update_agent_memory(
            identity,
            "prompt_agent",
            update.project,
            MAX_PROJECT_MEMORY_FACTS,
        )

    if update.agent:
        _update_agent_memory(
            identity,
            source_agent,
            update.agent,
            MAX_AGENT_MEMORY_FACTS,
        )

    if update.misunderstandings:
        _append_new_misunderstandings(
            identity,
            update.misunderstandings,
        )

    if update.cross_project:
        _update_cross_project_memory(
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
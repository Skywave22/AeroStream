#!/usr/bin/env python3
"""Turns a failed CI step's log into check-run annotations.

Why this exists: the run logs live behind a host the development sandbox cannot
reach, and issue comments can be rate-limited into silence, but check-run
annotations are plain API reads. GitHub allows ten error annotations per step,
so this picks the ten lines most likely to explain the failure rather than the
first ten lines of output.

Usage: annotate_log.py <log> <title>
"""

from __future__ import annotations

import re
import sys

LIMIT = 10
MAX_CHARS = 900

INTERESTING = re.compile(
    r"(error|Error|ERROR|FAIL|failed|Exception|Undefined|undefined|"
    r"isn't defined|not defined|Unknown|Expected:|Actual:|✗)"
)


def escape(message: str) -> str:
    """Escapes a message for the workflow-command syntax."""
    return (
        message.replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
        .replace("]", "%5D")
    )


def pick(lines: list[str]) -> list[str]:
    chosen: list[str] = []
    seen: set[str] = set()

    # Analyzer output is one finding per line and always worth reading first.
    for line in lines:
        stripped = line.strip()
        if " • " in stripped and stripped not in seen:
            seen.add(stripped)
            chosen.append(stripped)
        if len(chosen) >= LIMIT:
            return chosen

    for line in lines:
        stripped = line.strip()
        if stripped and INTERESTING.search(stripped) and stripped not in seen:
            seen.add(stripped)
            chosen.append(stripped)
        if len(chosen) >= LIMIT:
            return chosen

    # Nothing matched: the tail is still better than nothing.
    for line in lines[-3:]:
        stripped = line.strip()
        if stripped and stripped not in seen:
            seen.add(stripped)
            chosen.append(stripped)
    return chosen[:LIMIT]


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: annotate_log.py <log> <title>", file=sys.stderr)
        return 2

    path, title = sys.argv[1], sys.argv[2]
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        print(f"::error title={title}::could not read {path}: {error}")
        return 0

    if not any(line.strip() for line in lines):
        print(f"::error title={title}::the step produced no output")
        return 0

    for index, line in enumerate(pick(lines)):
        message = line[:MAX_CHARS]
        print(f"::error title={title} ({index + 1})::{escape(message)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

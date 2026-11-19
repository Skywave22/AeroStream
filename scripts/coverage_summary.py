#!/usr/bin/env python3
"""Prints line coverage from an lcov report, as a table.

Deliberately informational: the number goes into the CI report so a drop is
visible on the pull request, but it does not fail the build. A coverage floor
would be a number nobody chose carefully, and it would be gamed by tests that
exist to raise it rather than to check behaviour.

Usage: coverage_summary.py [coverage/lcov.info]
"""

from __future__ import annotations

import sys
from collections import defaultdict


def read_lcov(path: str) -> tuple[dict[str, tuple[int, int]], int, int]:
    """Returns per-file (hit, total) plus totals."""
    files: dict[str, tuple[int, int]] = {}
    current: str | None = None
    hit = total = 0
    file_hit = file_total = 0

    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("SF:"):
                current = line[3:]
                file_hit = file_total = 0
            elif line.startswith("DA:"):
                # DA:<line>,<hits>
                _, _, hits = line.partition(",")
                file_total += 1
                if hits.strip().isdigit() and int(hits.split(",")[0]) > 0:
                    file_hit += 1
            elif line == "end_of_record":
                if current is not None:
                    files[current] = (file_hit, file_total)
                    hit += file_hit
                    total += file_total
                current = None
    return files, hit, total


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "coverage/lcov.info"

    try:
        files, hit, total = read_lcov(path)
    except OSError:
        print("No coverage report was produced.")
        return 0

    if total == 0:
        print("The coverage report is empty.")
        return 0

    percent = 100.0 * hit / total
    print(f"**Line coverage: {percent:.1f}%** ({hit}/{total} lines in "
          f"{len(files)} files)")
    print()

    rows = sorted(
        ((name, h, t) for name, (h, t) in files.items() if t > 0),
        key=lambda row: (row[1] / row[2], -row[2]),
    )

    print("Lowest-covered files:")
    print()
    print("| File | Lines | Covered |")
    print("| --- | --- | --- |")
    for name, file_hit, file_total in rows[:10]:
        short = name.split("lib/", 1)[-1] if "lib/" in name else name
        print(f"| `{short}` | {file_total} | {100.0 * file_hit / file_total:.0f}% |")

    buckets: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for name, (file_hit, file_total) in files.items():
        rest = name.split("lib/", 1)[-1] if "lib/" in name else name
        area = rest.split("/")[0] if "/" in rest else rest
        buckets[area][0] += file_hit
        buckets[area][1] += file_total

    print()
    print("By area:")
    print()
    print("| Area | Lines | Covered |")
    print("| --- | --- | --- |")
    for area, (area_hit, area_total) in sorted(buckets.items()):
        if area_total == 0:
            continue
        print(f"| `{area}` | {area_total} | {100.0 * area_hit / area_total:.0f}% |")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

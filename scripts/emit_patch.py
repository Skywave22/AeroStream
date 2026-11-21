#!/usr/bin/env python3
"""Prints a patch as base64 chunks in workflow-command annotations.

Why: the run logs live behind a host the development sandbox cannot reach, and
issue comments can be rate-limited into silence, but check-run annotations are
plain API reads — and there is a hard limit of ten of them per step, each around
a kilobyte. A `dart format` patch is usually a few hundred bytes, so ten
annotations carry it comfortably.

Usage: emit_patch.py <patch> [title-prefix]

Read the chunks back with:

    gh api repos/<owner>/<repo>/check-runs/<id>/annotations \\
      --jq '.[] | select(.title | startswith("format-patch")) | .message' \\
      | sort | base64 -d > format.patch
"""

from __future__ import annotations

import base64
import sys

LIMIT = 10
CHUNK = 880


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: emit_patch.py <patch> [title]", file=sys.stderr)
        return 2

    prefix = sys.argv[2] if len(sys.argv) > 2 else "patch"
    try:
        with open(sys.argv[1], "rb") as handle:
            data = handle.read()
    except OSError as error:
        print(f"::error title={prefix}::could not read {sys.argv[1]}: {error}")
        return 0

    if not data:
        return 0

    encoded = base64.b64encode(data).decode("ascii")
    chunks = [encoded[i : i + CHUNK] for i in range(0, len(encoded), CHUNK)]
    total = len(chunks)
    if total > LIMIT:
        # Only the first chunks are worth sending: a truncated patch cannot be
        # applied, but it still shows what kind of change the formatter wants.
        chunks = chunks[:LIMIT]

    for index, chunk in enumerate(chunks, start=1):
        print(f"::error title={prefix}-{index}-of-{total}::{chunk}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

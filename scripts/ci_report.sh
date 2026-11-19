#!/usr/bin/env bash
# Collects the verifier's output into GitHub issue comments.
#
# Why comments and not the run log: the run logs live behind a host that the
# development sandbox cannot reach, so CI posts what it found where it can be
# read.
#
# The `dart format` patch is posted in *parts*, one comment per chunk of ≤50 KB,
# split on `diff --git` boundaries. A single comment is capped at 64 KB, and a
# truncated patch is useless — the parts are reassembled by concatenating them
# in order and applying the result with `git apply`.
set -uo pipefail

cd "$(dirname "$0")/.."

REPORT=/tmp/ci-report.md
PART_CHARS=48000

# GitHub rejects a comment body that is not valid UTF-8, which `tail -c` can
# produce by cutting a multi-byte character in half. Every snippet goes through
# this first, and a failure to post is what the caller must notice.
sanitize() {
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || cat
  else
    cat
  fi
}

post() {
  local file="$1"
  if [ -n "${CI_REPORT_ISSUE:-}" ]; then
    sanitize < "$file" > "$file.utf8"
    mv "$file.utf8" "$file"
    if [ "$(wc -c < "$file")" -gt 65000 ]; then
      head -c 60000 "$file" > "$file.cut"
      printf '\n\n_(truncated)_\n' >> "$file.cut"
      mv "$file.cut" "$file"
    fi
    local error
    if error=$(gh issue comment "$CI_REPORT_ISSUE" --body-file "$file" 2>&1); then
      printf '%s\n' "$error"
    else
      # The step log is unreadable from the development sandbox, but check-run
      # annotations are not: raise the failure reason as one so it can be read
      # back with `gh api .../check-runs/<id>/annotations`.
      local message
      message=$(printf '%s' "$error" | tr '\n' ' ' | cut -c1-900)
      message=${message//%/%25}
      message=${message//$'\r'/%0D}
      message=${message//$'\n'/%0A}
      echo "::error title=ci-report(${file##*/})::${message}"
      cat "$file"
    fi
  else
    cat "$file"
  fi
}

# ---- format patch, split into parts ---------------------------------------

if [ "${FORMAT_RESULT:-}" = "failure" ] && [ -s /tmp/format.patch ]; then
  rm -f /tmp/fmt-part-*.md
  # Split into per-file chunks first, then pack chunks into parts.
  awk -v dir=/tmp -v limit="$PART_CHARS" '
    BEGIN { part = 1; buf = "" }
    /^diff --git / {
      if (buf != "" && length(buf) + length($0) > limit) {
        printf "%s", buf > (dir "/fmt-part-" part ".patch");
        close(dir "/fmt-part-" part ".patch");
        part++;
        buf = "";
      }
    }
    { buf = buf $0 "\n" }
    END {
      if (buf != "") {
        printf "%s", buf > (dir "/fmt-part-" part ".patch");
        close(dir "/fmt-part-" part ".patch");
      }
      print part > (dir "/fmt-parts.count");
    }
  ' /tmp/format.patch

  parts=$(cat /tmp/fmt-parts.count 2>/dev/null || echo 1)
  for i in $(seq 1 "$parts"); do
    {
      echo "### Format patch — part $i/$parts"
      echo
      echo 'Apply every part in order: `cat part-*.patch | git apply`.'
      echo
      echo '```diff'
      cat "/tmp/fmt-part-$i.patch"
      echo '```'
    } > "/tmp/fmt-part-$i.md"
    post "/tmp/fmt-part-$i.md"
  done
fi

# ---- summary --------------------------------------------------------------

{
  echo "### CI report — \`${GITHUB_SHA:-local}\`"
  echo
  echo "| Step | Result |"
  echo "| --- | --- |"
  echo "| format | ${FORMAT_RESULT:-unknown} |"
  echo "| js-selftest | ${JS_RESULT:-unknown} |"
  echo "| analyze | ${ANALYZE_RESULT:-unknown} |"
  echo "| test | ${TEST_RESULT:-unknown} |"
  echo

  if [ "${FORMAT_RESULT:-}" = "failure" ]; then
    echo "Formatting needs the patch parts posted just above."
    echo
    if [ -s /tmp/format.log ]; then
      echo "<details><summary>dart format</summary>"
      echo
      echo '```'
      tail -c 8000 /tmp/format.log
      echo '```'
      echo "</details>"
      echo
    fi
  fi

  if [ "${JS_RESULT:-unknown}" != "success" ] && [ -s /tmp/js.log ]; then
    echo "<details><summary>node tool/js_selftest.mjs</summary>"
    echo
    echo '```'
    tail -c 12000 /tmp/js.log
    echo '```'
    echo "</details>"
    echo
  fi

  if [ "${ANALYZE_RESULT:-}" != "success" ]; then
    echo "<details><summary>flutter analyze</summary>"
    echo
    echo '```'
    tail -c 24000 /tmp/analyze.log 2>/dev/null || echo "(no log)"
    echo '```'
    echo "</details>"
    echo
  fi

  if [ -s /tmp/coverage.md ]; then
    echo "### Coverage"
    echo
    cat /tmp/coverage.md
    echo
  fi

  if [ "${TEST_RESULT:-}" != "success" ]; then
    echo "<details><summary>flutter test</summary>"
    echo
    echo '```'
    tail -c 24000 /tmp/test.log 2>/dev/null || echo "(no log)"
    echo '```'
    echo "</details>"
    echo
  fi
} > "$REPORT"

if [ "$(wc -c < "$REPORT")" -gt 65000 ]; then
  head -c 64000 "$REPORT" > /tmp/ci-report-trimmed.md
  printf '\n\n_(report truncated)_\n' >> /tmp/ci-report-trimmed.md
  mv /tmp/ci-report-trimmed.md "$REPORT"
fi

post "$REPORT"

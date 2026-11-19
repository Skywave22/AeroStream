#!/usr/bin/env bash
# Collects the verifier's output into a single GitHub issue comment.
#
# Why a comment and not the run log: the run logs live behind a host that the
# development sandbox cannot reach, so CI posts what it found where it can be
# read. The comment also carries the `dart format` patch, which is how style is
# applied without a local Dart SDK.
set -uo pipefail

cd "$(dirname "$0")/.."

REPORT=/tmp/ci-report.md
{
  echo "### CI report — \`${GITHUB_SHA:-local}\`"
  echo
  echo "| Step | Result |"
  echo "| --- | --- |"
  echo "| format | ${FORMAT_RESULT:-unknown} |"
  echo "| analyze | ${ANALYZE_RESULT:-unknown} |"
  echo "| test | ${TEST_RESULT:-unknown} |"
  echo

  if [ "${FORMAT_RESULT:-}" = "failure" ]; then
    echo "<details><summary>dart format patch (apply with git apply)</summary>"
    echo
    if [ -s /tmp/format.patch ]; then
      echo '```diff'
      head -c 30000 /tmp/format.patch
      echo
      echo '```'
      if [ "$(wc -c < /tmp/format.patch)" -gt 30000 ]; then
        echo
        echo "_Patch truncated. Files needing format:_"
        echo
        echo '```'
        git diff --stat | tail -40
        echo '```'
      fi
    else
      echo "_No patch produced._"
    fi
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

# Bound the payload: GitHub rejects comments over 65536 characters.
if [ "$(wc -c < "$REPORT")" -gt 65000 ]; then
  head -c 64000 "$REPORT" > /tmp/ci-report-trimmed.md
  printf '\n\n_(report truncated)_\n' >> /tmp/ci-report-trimmed.md
  mv /tmp/ci-report-trimmed.md "$REPORT"
fi

if [ -n "${CI_REPORT_ISSUE:-}" ]; then
  gh issue comment "$CI_REPORT_ISSUE" --body-file "$REPORT" || {
    echo "Could not post the CI report (non-fatal)";
  }
else
  cat "$REPORT"
fi

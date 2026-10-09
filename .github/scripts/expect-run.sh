#!/usr/bin/env bash
# Usage: expect-run.sh <run-log> <task> <ran|skipped|any>
# Reads the run log written by the buildfile to tell whether a task's action actually executed.
set -euo pipefail
log="$1"; task="$2"; expected="$3"
if [ -f "$log" ] && tr -d '\r' < "$log" | grep -qx "$task"; then actual=ran; else actual=skipped; fi
echo "$task: expected=$expected actual=$actual"
echo "| \`$task\` | $expected | $actual |" >> "$GITHUB_STEP_SUMMARY"
if [ "$expected" != any ] && [ "$expected" != "$actual" ]; then
    echo "::error title=Cache bash::$task expected '$expected' but was '$actual'"
    exit 1
fi

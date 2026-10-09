#!/usr/bin/env bash
# Drives the cache bash scenarios that need multiple runs, new commits, or branches.
# Pushes empty commits to main and a temporary branch, and deletes all Actions caches in the repo.
set -uo pipefail
export GH_HOST=github.com
REPO=${REPO:-mcafaro/output-cache-bash}
BRANCH=bash-feature
RESULTS=()

record() { RESULTS+=("$1 | $2"); echo ">>> $1: $2"; }

# Dispatches a workflow, waits for it, and sets RUN_ID and CONCLUSION.
dispatch() {
    local wf=$1 ref=$2; shift 2
    local before
    before=$(gh run list -R "$REPO" -w "$wf" -b "$ref" -L 1 --json databaseId -q '.[0].databaseId // 0')
    gh workflow run "$wf" -R "$REPO" --ref "$ref" "$@"
    RUN_ID=$before
    while [ "$RUN_ID" = "$before" ]; do
        sleep 5
        RUN_ID=$(gh run list -R "$REPO" -w "$wf" -b "$ref" -L 1 --json databaseId -q '.[0].databaseId // 0')
    done
    gh run watch "$RUN_ID" -R "$REPO" --interval 15 > /dev/null
    CONCLUSION=$(gh run view "$RUN_ID" -R "$REPO" --json conclusion -q .conclusion)
}

# Runs a workflow and records PASS if it concludes as expected.
scenario() {
    local name=$1 want=$2; shift 2
    dispatch "$@"
    if [ "$CONCLUSION" = "$want" ]; then record "$name" "PASS (run $RUN_ID)"
    else record "$name" "FAIL: expected $want, got $CONCLUSION (run $RUN_ID)"; fi
}

count_keys() { gh cache list -R "$REPO" -L 100 --key "$1" --json key -q 'length'; }

check_keys() {
    local name=$1 prefix=$2 want=$3 got
    got=$(count_keys "$prefix")
    if [ "$got" = "$want" ]; then record "$name" "PASS ($got keys with prefix $prefix)"
    else record "$name" "FAIL: expected $want keys with prefix $prefix, got $got"; fi
}

new_commit() { git commit -q --allow-empty -m "bash: $1" && git push -q origin HEAD; git rev-parse HEAD; }

[ -z "$(git status --porcelain)" ] || { echo "Working tree must be clean"; exit 1; }
git checkout -q main && git pull -q
read -r -p "This deletes all caches in $REPO and pushes commits to main. Continue? [y/N] " ok
[ "$ok" = y ] || exit 1
gh cache delete --all -R "$REPO" --succeed-on-no-caches

# 1. Cold cache: everything runs and each of the 6 matrix entries saves a key for this SHA.
scenario "cold cache runs tasks" success bash-cross-run.yml main -f expect=ran
check_keys "cold run saves 6 keys" "matlab-buildtool-" 6
check_keys "one key per Linux matrix entry" "matlab-buildtool-Linux-cross-run-" 2

# 2. Same SHA: exact key hit, tasks skipped, nothing new saved.
scenario "exact key hit skips tasks" success bash-cross-run.yml main -f expect=skipped
check_keys "exact hit does not save again" "matlab-buildtool-" 6

# 3. New commit, no source change: restore-key fallback, tasks skipped, new keys saved.
new_commit "no-op commit for restore-key fallback" > /dev/null
scenario "restore-key fallback skips tasks" success bash-cross-run.yml main -f expect=skipped
check_keys "new SHA saves new keys" "matlab-buildtool-" 12

# 4. Source change must invalidate: no stale outputs.
echo "% bash $(date +%s)" >> source/dayofyear.m
git commit -qam "bash: change source" && git push -q origin HEAD
scenario "source change reruns tasks" success bash-cross-run.yml main -f expect=ran

# 5. Revert the source change: with -outputCache, probe may reuse the earlier cached output. Report only.
git revert --no-edit HEAD > /dev/null && git push -q origin HEAD
scenario "revert source (report only, see summaries)" success bash-cross-run.yml main -f expect=any

# 6. Failed build must not save.
sha=$(new_commit "failing build")
scenario "failing build fails" failure bash-cross-run.yml main -f fail-build=true
n=$(gh cache list -R "$REPO" -L 100 --json key -q "[.[] | select(.key | endswith(\"$sha\"))] | length")
[ "$n" = 0 ] && record "no key for failed SHA" PASS || record "no key for failed SHA" "FAIL: $n keys saved"

# 7. Build passes but a later step fails. Docs say "saves only if the build succeeds"; post-if: success() checks the job.
sha=$(new_commit "fail after build")
dispatch bash-cross-run.yml main -f fail-after-build=true
n=$(gh cache list -R "$REPO" -L 100 --json key -q "[.[] | select(.key | endswith(\"$sha\"))] | length")
record "build ok + later step fails (report only)" "$n keys saved for $sha (docs imply 6)"

# 8. Non-default branch restores from main but never saves.
git checkout -q -B "$BRANCH" && sha=$(new_commit "feature branch")
scenario "branch restores main cache" success bash-cross-run.yml "$BRANCH" -f expect=skipped
n=$(gh cache list -R "$REPO" -L 100 --json key -q "[.[] | select(.key | endswith(\"$sha\"))] | length")
[ "$n" = 0 ] && record "branch does not save" PASS || record "branch does not save" "FAIL: $n keys saved"
git checkout -q main && git push -q origin --delete "$BRANCH" && git branch -qD "$BRANCH"

# 9. Two cached build steps in one job. First run seeds the cache; second run is the real test.
dispatch bash-multi-step.yml main
scenario "second cached step not clobbered by restore" success bash-multi-step.yml main
warns=$(gh run view "$RUN_ID" -R "$REPO" --log | grep -c "Failed to save the cache" || true)
record "multi-step save warnings (report only)" "$warns 'Failed to save the cache' lines"

# 10. -sd startup option.
dispatch bash-subfolder.yml main
check_keys "subfolder build saves cache" "matlab-buildtool-Linux-subfolder-" 1
scenario "subfolder build skips on rerun" success bash-subfolder.yml main -f expect=skipped

# 11. Cross-workflow isolation.
dispatch bash-collide-a.yml main
scenario "workflows with same job id are isolated" success bash-collide-b.yml main

# 12. Input validation and release compatibility.
scenario "inputs and releases behave as expected" success bash-inputs.yml main

echo
echo "Scenario | Result"
printf '%s\n' "${RESULTS[@]}"
echo
echo "Manual: wait for an hourly run of bash-schedule.yml, then check:"
echo "  GH_HOST=github.com gh cache list -R $REPO --key matlab-buildtool-Linux-scheduled-"
echo "Disable the schedule afterwards: gh workflow disable bash-schedule.yml -R $REPO"

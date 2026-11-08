#!/usr/bin/env bash
# Usage: skip-if-passed.sh WORKFLOW-FILE
#
# Writes skip=true to $GITHUB_OUTPUT when an earlier run of WORKFLOW-FILE,
# started by a push of the same commit $GITHUB_SHA, succeeded, and
# skip=false otherwise.  Earlier means a smaller run ID: a commit pushed to
# develop and then to main starts two runs, and the second waits here for
# the first to finish.  Two runs never wait for each other, because each
# waits only for runs with a smaller ID.  Needs GH_TOKEN with actions: read.
set -euo pipefail

workflow=$1

earlier_runs() {
  gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" \
     --commit "$GITHUB_SHA" --event push --limit 50 \
     --json databaseId,status,conclusion \
     --jq "[.[] | select(.databaseId < $GITHUB_RUN_ID)]"
}

while [ "$(earlier_runs | jq '[.[] | select(.status != "completed")] | length')" -gt 0 ]; do
  echo "An earlier run of $workflow for $GITHUB_SHA is not finished; checking again in 30 s"
  sleep 30
done

passed=$(earlier_runs | jq '[.[] | select(.conclusion == "success")] | length')
if [ "$passed" -gt 0 ]; then
  echo "An earlier run of $workflow for $GITHUB_SHA succeeded; the other jobs are skipped"
  echo "skip=true" >> "$GITHUB_OUTPUT"
else
  echo "No earlier run of $workflow for $GITHUB_SHA succeeded; the other jobs run"
  echo "skip=false" >> "$GITHUB_OUTPUT"
fi

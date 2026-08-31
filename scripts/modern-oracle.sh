#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: modern-oracle.sh BEFORE_GRAPH AFTER_GRAPH ORACLE_SPEC" >&2
  exit 64
fi

before=$1
after=$2
spec=$3

failures_for() {
  local graph=$1
  jq -r --slurpfile graph "$graph" '
    ($graph[0].nodes // []) as $nodes |
    [ .required_activities[] as $required |
      if any($nodes[]?; .kind=="Activity" and .name==$required) then empty
      else $required end ]
  ' "$spec"
}

before_missing=$(failures_for "$before")
after_missing=$(failures_for "$after")
before_count=$(jq 'length' <<<"$before_missing")
after_count=$(jq 'length' <<<"$after_missing")

jq -S -n \
  --arg schema "gooo/reflexive-loop/modern-cycle/oracle-verdict/v1" \
  --argjson before_failures "$before_count" \
  --argjson after_failures "$after_count" \
  --argjson before_missing "$(printf '%s\n' "$before_missing" | jq -R -s 'split("\n")|map(select(length>0))')" \
  --argjson after_missing "$(printf '%s\n' "$after_missing" | jq -R -s 'split("\n")|map(select(length>0))')" \
  '{schema:$schema,decision:(if $after_failures==0 then "CLOSED" else "REFUTED" end),equivalent:($before_failures>0 and $after_failures==0),oracle_failures:{before:$before_failures,after:$after_failures},missing_required_activities:{before:$before_missing,after:$after_missing},method:"independent_required_activity_oracle",counterexamples:(if $after_failures==0 then [] else ["REQUIRED_ACTIVITY_STILL_MISSING"] end)}'

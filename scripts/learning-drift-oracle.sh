#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: learning-drift-oracle.sh BEFORE_SOURCE AFTER_SOURCE ORACLE_SPEC" >&2
  exit 64
fi

before_source=$(realpath "$1")
after_source=$(realpath "$2")
oracle_spec=$(realpath "$3")

required_json=$(jq -c '.required_activities' "$oracle_spec")

observe() {
  local label=$1
  local source=$2
  local missing_file=$3
  local missing='[]'
  local activity
  while IFS= read -r activity; do
    if ! awk -v wanted="$activity" '$1 == "activity" && index($2, wanted "(") == 1 {found=1} END {exit(found ? 0 : 1)}' "$source"; then
      missing=$(jq -c --arg activity "$activity" '. + [$activity]' <<<"$missing")
    fi
  done < <(jq -r '.[]' <<<"$required_json")
  jq -S -n --arg label "$label" --arg source "$source" --argjson missing "$missing" \
    '{label:$label,source:$source,missing_required_activities:$missing,oracle_failures:($missing|length)}' > "$missing_file"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
observe before "$before_source" "$tmp/before.json"
observe after "$after_source" "$tmp/after.json"

jq -S -n --slurpfile before "$tmp/before.json" --slurpfile after "$tmp/after.json" \
  '{schema:"gooo/reflexive-loop/learning-drift-gated/oracle-verdict/v1",method:"independent_required_activity_oracle",decision:(if ($before[0].oracle_failures > 0 or $after[0].oracle_failures > 0) then "REFUTED" else "CLOSED" end),equivalent:($before[0].oracle_failures == $after[0].oracle_failures),oracle_failures:{before:$before[0].oracle_failures,after:$after[0].oracle_failures},missing_required_activities:{before:$before[0].missing_required_activities,after:$after[0].missing_required_activities},counterexamples:[]}'

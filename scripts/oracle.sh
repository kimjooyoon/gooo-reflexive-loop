#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: oracle.sh BEFORE_GRAPH AFTER_GRAPH OUTPUT" >&2
  exit 64
fi

before=$1
after=$2
output=$3
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

jq -S '
  {entities:[.nodes[]? | select(.kind=="Entity") | {kind,name,id}],
   activities:[.nodes[]? | select(.kind=="Activity") | {kind,name,id,inputs,input_types,result,result_type}]}
  | .entities |= sort_by(tojson)
  | .activities |= sort_by(tojson)
' "$before" > "$tmp/before.json"
jq -S '
  {entities:[.nodes[]? | select(.kind=="Entity") | {kind,name,id}],
   activities:[.nodes[]? | select(.kind=="Activity") | {kind,name,id,inputs,input_types,result,result_type}]}
  | .entities |= sort_by(tojson)
  | .activities |= sort_by(tojson)
' "$after" > "$tmp/after.json"

before_semantic=$(jq -r '.ir.semantic_digest // empty' "$before")
after_semantic=$(jq -r '.ir.semantic_digest // empty' "$after")
if cmp -s "$tmp/before.json" "$tmp/after.json" && [ -n "$before_semantic" ] && [ "$before_semantic" = "$after_semantic" ]; then
  jq -S -n --arg before "$before_semantic" --arg after "$after_semantic" \
    '{schema:"gooo/reflexive-loop/oracle-verdict/v1",decision:"CLOSED",equivalent:true,method:"independent_canonical_graph_and_semantic_digest",before_semantic_digest:$before,after_semantic_digest:$after,counterexamples:[]}' > "$output"
else
  jq -S -n --arg before "$before_semantic" --arg after "$after_semantic" \
    '{schema:"gooo/reflexive-loop/oracle-verdict/v1",decision:"REFUTED",equivalent:false,method:"independent_canonical_graph_and_semantic_digest",before_semantic_digest:$before,after_semantic_digest:$after,counterexamples:["CANONICAL_GRAPH_OR_SEMANTIC_DIGEST_DIFFERED"]}' > "$output"
fi

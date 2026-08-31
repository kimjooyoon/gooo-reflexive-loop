#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: emit-metrics.sh CATALOG REPORT OUTPUT_DIR SOURCE_DIGEST" >&2
  exit 64
fi

catalog=$1
report=$2
output_dir=$3
source_digest=$4
mkdir -p "$output_dir"

while IFS=$'\t' read -r id cell activity artifact evaluator; do
  state=$(jq -r --arg cell "$cell" '.cells[]|select(.id==$cell)|.state' "$report")
  numerator=0
  [ "$state" = "CLOSED" ] && numerator=1
  jq -S -n \
    --arg id "$id" --arg cell "$cell" --arg activity "$activity" \
    --arg artifact "$artifact" --arg evaluator "$evaluator" \
    --arg state "$state" --arg source_digest "$source_digest" \
    --argjson numerator "$numerator" \
    '{schema:"gooo/reflexive-loop/metric/v1",id:$id,cell:$cell,activity:$activity,source_file:"examples/reflexive-loop/main.gooo",source_digest:$source_digest,ir_node_kind:"Activity",generated_artifact:$artifact,evaluator:$evaluator,numerator:$numerator,denominator:1,state:$state}' \
    > "$output_dir/$(printf '%s' "$cell" | tr '[:upper:]' '[:lower:]' | tr '_' '-').json"
done < <(jq -r '.metrics[]|[.id,.cell,.activity,.generated_artifact,.evaluator]|@tsv' "$catalog")

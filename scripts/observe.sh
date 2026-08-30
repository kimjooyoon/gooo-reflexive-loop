#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: observe.sh GOOO REPOSITORY OUTPUT TOOL_DIGEST" >&2
  exit 64
fi

gooo=$1
repository=$(realpath "$2")
output=$(realpath -m "$3")
tool_digest=$4
source_file="$repository/examples/reflexive-loop/main.gooo"
workload_file="$repository/fixtures/use-case/workload.gooo"

test -x "$gooo"
test -d "$repository"
test -f "$source_file"
test -f "$workload_file"
mkdir -p "$output/observation/meta-resolutions"

contract_digest=$(sha256sum "$repository/contracts/allowed-transformations-v1.json" | awk '{print "sha256:" $1}')
source_digest=$(sha256sum "$source_file" | awk '{print "sha256:" $1}')
workload_digest=$(sha256sum "$workload_file" | awk '{print "sha256:" $1}')

"$gooo" check --json "$source_file" > "$output/observation/syntax.json"
"$gooo" check --semantic --json "$source_file" > "$output/observation/semantic.json"
"$gooo" graph dump "$source_file" > "$output/observation/meta-graph.json"

ordinal=0
while IFS=$'\t' read -r activity; do
  ordinal=$((ordinal + 1))
  receipt="$output/observation/meta-resolutions/$(printf '%02d' "$ordinal").json"
  if "$gooo" graph resolve-activity "$source_file" --name "$activity" > "$receipt"; then
    true
  else
    jq -S -n --arg activity "$activity" --arg source_file "$source_file" \
      '{schema:"gooo/reflexive-loop/meta-resolution/v1",decision:"REFUTED",activity:$activity,subject:{source_file:$source_file},reason:"META_ACTIVITY_RESOLUTION_FAILED"}' > "$receipt"
  fi
done < <(jq -r '.cells[].activity' "$repository/contracts/loop-denominator-v1.json")

jq -S -s '.' "$output"/observation/meta-resolutions/*.json > "$output/observation/resolutions.json"

physical_count() {
  find "$repository" -path "$repository/.git" -prune -o -type f ! -path "$repository/README.md" -print | wc -l | awk '{print $1 + 0}'
}

physical_lines() {
  find "$repository" -path "$repository/.git" -prune -o -type f ! -path "$repository/README.md" -print0 |
    xargs -0 -r wc -l | awk 'END {print $1 + 0}'
}

go_files=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.go' -print | wc -l | awk '{print $1 + 0}')
go_lines=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.go' -print0 | xargs -0 -r wc -l | awk 'END {print $1 + 0}')
gooo_files=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.gooo' -print | wc -l | awk '{print $1 + 0}')
gooo_lines=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.gooo' -print0 | xargs -0 -r wc -l | awk 'END {print $1 + 0}')

jq -S -n \
  --arg schema "gooo/reflexive-loop/observation/v1" \
  --arg repository "$repository" \
  --arg source_file "$source_file" \
  --arg source_digest "$source_digest" \
  --arg workload_file "$workload_file" \
  --arg workload_digest "$workload_digest" \
  --arg contract_digest "$contract_digest" \
  --arg tool_digest "$tool_digest" \
  --slurpfile graph "$output/observation/meta-graph.json" \
  --slurpfile syntax "$output/observation/syntax.json" \
  --slurpfile semantic "$output/observation/semantic.json" \
  --slurpfile resolutions "$output/observation/resolutions.json" \
  --argjson regular_files "$(physical_count)" \
  --argjson physical_lines "$(physical_lines)" \
  --argjson go_files "$go_files" \
  --argjson go_lines "$go_lines" \
  --argjson gooo_files "$gooo_files" \
  --argjson gooo_lines "$gooo_lines" '
  ($graph[0]) as $g |
  ($resolutions[0]) as $r |
  {
    schema:$schema,
    repository:$repository,
    source:{file:$source_file,digest:$source_digest,semantic_digest:($g.ir.semantic_digest // null)},
    workload:{file:$workload_file,digest:$workload_digest},
    contract_digest:$contract_digest,
    tool:{digest:$tool_digest},
    syntax:{status:($syntax[0].status // "unknown")},
    semantic:{status:($semantic[0].status // "unknown"),digest:($semantic[0].semantic_hash // $g.ir.semantic_digest // null)},
    meta_graph:{schema_version:($g.schema_version // null),activity_nodes:([$g.nodes[]? | select(.kind=="Activity")]|length),entity_nodes:([$g.nodes[]? | select(.kind=="Entity")]|length),graph_hash:($g.graph_hash // null)},
    resolutions:{expected:($r|length),closed:([$r[]?|select(.decision=="CLOSED")]|length),unknown:([$r[]?|select(.decision=="UNKNOWN")]|length),refuted:([$r[]?|select(.decision=="REFUTED")]|length),items:$r},
    inventory:{root_readme_excluded:true,regular_files:$regular_files,physical_lines:$physical_lines,go:{files:$go_files,lines:$go_lines},gooo:{files:$gooo_files,lines:$gooo_lines}}
  }
' > "$output/observation/observation.json"

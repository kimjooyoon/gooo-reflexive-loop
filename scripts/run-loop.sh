#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "usage: run-loop.sh GOOO REPOSITORY CLAIM RECEIPT OUTPUT SCENARIO" >&2
  exit 64
fi

gooo=$1
repository=$(realpath "$2")
claim_input=$(realpath "$3")
receipt_input=$(realpath "$4")
output=$(realpath -m "$5")
scenario=$6

case "$output" in
  "$repository"|"$repository"/*)
    echo "output must be outside the input repository" >&2
    exit 65
    ;;
esac
mkdir -p "$output"
if [ -n "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "output must be empty" >&2
  exit 66
fi

snapshot() {
  find "$repository" -path "$repository/.git" -prune -o -type f -print0 |
    sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print "sha256:" $1}'
}

input_before=$(snapshot)
tool_digest=$(sha256sum "$gooo" | awk '{print "sha256:" $1}')
mkdir -p "$output/input" "$output/clone/before" "$output/clone/after" "$output/metrics"
cp "$claim_input" "$output/input/claim.json"
cp "$receipt_input" "$output/input/receipt.json"

bash "$repository/scripts/observe.sh" "$gooo" "$repository" "$output" "$tool_digest"
bash "$repository/scripts/propose.sh" \
  "$output/input/claim.json" "$output/input/receipt.json" \
  "$output/observation/observation.json" "$repository/contracts/allowed-transformations-v1.json" \
  "$tool_digest" "$output/proposal.json"

jq -S -n '{schema:"gooo/reflexive-loop/oracle-verdict/v1",decision:"UNKNOWN",equivalent:false,counterexamples:[]}' > "$output/oracle.json"
jq -S -n '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"UNKNOWN"}' > "$output/workload-pair.json"
jq -S -n --arg before "$input_before" '{schema:"gooo/reflexive-loop/repository-effect/v1",before_digest:$before,after_digest:null,repository_writes:null}' > "$output/repository-effect.json"

proposal_state=$(jq -r '.state // "REFUTED"' "$output/proposal.json")
if [ "$proposal_state" = "CLOSED" ]; then
  workload_file=$(jq -r '.workload.file' "$output/observation/observation.json")
  cp "$workload_file" "$output/clone/before/workload.gooo"
  bash "$repository/scripts/apply.sh" "$workload_file" "$output/proposal.json" \
    "$output/clone/after/workload.gooo" "ApplyAllowedMetaActivity"

  run_workload() {
    local label=$1
    local source=$2
    local result="$output/clone/$label/check.json"
    local stderr="$output/clone/$label/check.stderr"
    local timing="$output/clone/$label/time.tsv"
    local status
    set +e
    /usr/bin/time -f '%e\t%M' -o "$timing" "$gooo" check --semantic --json "$source" > "$result" 2> "$stderr"
    status=$?
    set -e
    local seconds=0
    local rss=0
    if [ -s "$timing" ]; then read -r seconds rss < "$timing"; fi
    local wall_ms
    wall_ms=$(awk -v value="$seconds" 'BEGIN {printf "%d", (value * 1000) + 0.5}')
    jq -S -n --arg label "$label" --arg source "$source" --argjson status "$status" \
      --argjson wall_ms "$wall_ms" --argjson peak_rss_kib "${rss:-0}" \
      --arg source_digest "$(sha256sum "$source" | awk '{print "sha256:" $1}')" \
      --slurpfile result "$result" \
      '{label:$label,source:$source,source_digest:$source_digest,status:$status,wall_ms:$wall_ms,peak_rss_kib:$peak_rss_kib,semantic_digest:($result[0].semantic_hash // null),result:$result[0]}' \
      > "$output/clone/$label/measurement.json"
  }

  run_workload before "$output/clone/before/workload.gooo"
  run_workload after "$output/clone/after/workload.gooo"
  "$gooo" graph dump "$output/clone/before/workload.gooo" > "$output/clone/before/graph.json"
  "$gooo" graph dump "$output/clone/after/workload.gooo" > "$output/clone/after/graph.json"
  bash "$repository/scripts/oracle.sh" "$output/clone/before/graph.json" "$output/clone/after/graph.json" "$output/oracle.json"

  input_digest=$(jq -r '.workload.digest' "$output/observation/observation.json")
  contract_digest=$(jq -r '.contract_digest' "$output/observation/observation.json")
  before_semantic=$(jq -r '.ir.semantic_digest // empty' "$output/clone/before/graph.json")
  after_semantic=$(jq -r '.ir.semantic_digest // empty' "$output/clone/after/graph.json")
  jq -S -n \
    --arg input_digest "$input_digest" --arg contract_digest "$contract_digest" --arg tool_digest "$tool_digest" \
    --arg before_semantic "$before_semantic" --arg after_semantic "$after_semantic" \
    --slurpfile before "$output/clone/before/measurement.json" \
    --slurpfile after "$output/clone/after/measurement.json" \
    --slurpfile oracle "$output/oracle.json" \
    '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"CLOSED",exact_identity:true,input_digest:$input_digest,contract_digest:$contract_digest,tool_digest:$tool_digest,clone_created:true,applied:true,apply_activity:"ApplyAllowedMetaActivity",before:$before[0],after:$after[0],semantic_digest_pair:{before:$before_semantic,after:$after_semantic},oracle_decision:$oracle[0].decision,rollback:{mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}}' > "$output/workload-pair.json"
else
  jq -S -n --arg state "$proposal_state" --arg reason "$(jq -r '.reason // "PROPOSAL_NOT_CLOSED"' "$output/proposal.json")" \
    '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"UNKNOWN",exact_identity:false,reason:$reason,blocked_by:[],proposal_state:$state}' > "$output/workload-pair.json"
  jq -S -n --arg before "$input_before" --arg after "$input_before" \
    '{schema:"gooo/reflexive-loop/repository-effect/v1",before_digest:$before,after_digest:$after,repository_writes:0}' > "$output/repository-effect.json"
  jq -S -n '{schema:"gooo/reflexive-loop/rollback-receipt/v1",mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output",applied:false}' > "$output/rollback.json"
fi

jq -S -n '{manifest_ok:false,files:0,bytes:0}' > "$output/artifact-manifest.json"
bash "$repository/scripts/evaluate.sh" \
  "$repository/contracts/loop-denominator-v1.json" "$repository/contracts/metric-catalog-v1.json" \
  "$output/input/claim.json" "$output/input/receipt.json" "$output/observation/observation.json" \
  "$output/proposal.json" "$output/oracle.json" "$output/workload-pair.json" \
  "$output/repository-effect.json" "$output/artifact-manifest.json" "$output/report.pre.json"

bash "$repository/scripts/emit-metrics.sh" "$repository/contracts/metric-catalog-v1.json" \
  "$output/report.pre.json" "$output/metrics" "$(jq -r '.source.digest' "$output/observation/observation.json")"

artifact_files=$(find "$output" -type f ! -name 'ci-artifact.json' | wc -l | awk '{print $1 + 0}')
artifact_bytes=$(find "$output" -type f ! -name 'ci-artifact.json' -print0 | xargs -0 -r wc -c | awk 'END {print $1 + 0}')
jq -S -n --argjson files "$artifact_files" --argjson bytes "$artifact_bytes" \
  '{schema:"gooo/reflexive-loop/artifact-manifest/v1",manifest_ok:true,files:$files,bytes:$bytes,metric_files:18}' > "$output/artifact-manifest.json"

bash "$repository/scripts/evaluate.sh" \
  "$repository/contracts/loop-denominator-v1.json" "$repository/contracts/metric-catalog-v1.json" \
  "$output/input/claim.json" "$output/input/receipt.json" "$output/observation/observation.json" \
  "$output/proposal.json" "$output/oracle.json" "$output/workload-pair.json" \
  "$output/repository-effect.json" "$output/artifact-manifest.json" "$output/report.json"

input_after=$(snapshot)
jq -S -n --arg before "$input_before" --arg after "$input_after" \
  --arg scenario "$scenario" --arg report_digest "$(sha256sum "$output/report.json" | awk '{print "sha256:" $1}')" \
  --argjson artifact_files "$artifact_files" --argjson artifact_bytes "$artifact_bytes" \
  --slurpfile report "$output/report.json" \
  '{schema:"gooo/reflexive-loop/ci-artifact/v1",scenario:$scenario,report_digest:$report_digest,decision:$report[0].decision,summary:$report[0].summary,precedence:$report[0].precedence,unknown:[$report[0].cells[]|select(.state=="UNKNOWN")|{stage,step,reason,unknown_class,next_operation,blocked_by}],refuted:[$report[0].cells[]|select(.state=="REFUTED")|{stage,step,reason,next_operation,blocked_by}],inventory:$report[0].observed.inventory,performance:{build_wall_ms:($report[0].performance.before.wall_ms // 0),build_peak_rss_kib:($report[0].performance.before.peak_rss_kib // 0),test_wall_ms:(($report[0].performance.before.wall_ms // 0)+($report[0].performance.after.wall_ms // 0)),test_peak_rss_kib:([($report[0].performance.before.peak_rss_kib // 0),($report[0].performance.after.peak_rss_kib // 0)]|max),conformance_wall_ms:0,conformance_peak_rss_kib:0,before:$report[0].performance.before,after:$report[0].performance.after},artifact:{files:$artifact_files,bytes:$artifact_bytes},repository_writes:($report[0].authority.repository_writes // null),metrics:$report[0].metrics,bindings:$report[0].bindings,input_before:$before,input_after:$after,repository_unchanged:($before==$after)}' > "$output/ci-artifact.json"

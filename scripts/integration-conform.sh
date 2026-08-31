#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: integration-conform.sh GOOO REPOSITORY EXTERNAL_RELEASE_DIR ARTIFACT_DIR" >&2
  exit 64
fi

gooo=$1
repository=$(realpath "$2")
external=$(realpath "$3")
artifact_dir=$(realpath -m "$4")
mkdir -p "$artifact_dir/scenarios"

run_case() {
  local name=$1
  local expected=$2
  local expected_reason=$3
  local output="$artifact_dir/scenarios/$name"
  echo "running integrated scenario: $name"
  bash "$repository/scripts/integrated-loop.sh" "$gooo" "$repository" "$external" "$output" "$name"
  if ! jq -e --arg expected "$expected" --arg reason "$expected_reason" \
    '.decision==$expected and .summary=={total:8,closed:(if $expected=="CLOSED" then 8 else 0 end),unknown:0,refuted:(if $expected=="CLOSED" then 0 else 8 end)} and .precedence==["REFUTED","UNKNOWN","CLOSED"] and
     (if $expected=="CLOSED" then .bindings.external_inputs_affect_proposal==true and .bindings.execution_plan_affects_apply==true and .bindings.resolution_unknown_affects_utility_claim==true and .bindings.provenance_only==false and .resolution_unknown.state=="UNKNOWN" and .resolution_unknown.preserved_exactly==true and .lifecycle.promotion=="PROMOTED" and .lifecycle.rollback.repository_writes==0 and .authority.cross_project_required_gates==0 and .authority.input_repository_unchanged==true
      else (.validation_reason|contains($reason)) and .lifecycle.promotion=="NOT_PROMOTED" and .lifecycle.rollback.repository_writes==0
      end)' "$output/report.json" >/dev/null; then
    jq '{scenario,decision,summary,validation_reason,resolution_unknown,lifecycle,authority}' "$output/report.json" >&2
    return 1
  fi
  jq -e --arg expected "$expected" \
    '.schema=="gooo/reflexive-loop/integrated-ci-artifact/v1" and .decision==$expected and .artifact.files>0 and .artifact.bytes>0 and (.metrics|length)==8 and all(.metrics[]; .denominator==1 and (.numerator|type)=="number" and .activity != null and .source_file=="examples/reflexive-loop/main.gooo" and .ir_node_kind=="Activity" and .generated_artifact != null and .evaluator != null)' \
    "$output/integration-artifact.json" >/dev/null
}

run_case normal CLOSED ""
run_case tampered-budget-digest REFUTED "BUDGET_MANIFEST_DIGEST_MISMATCH"
run_case stale-resolution-target REFUTED "LATTICE_RELEASE_IMMUTABLE_OR_TARGET"
run_case missing-six-field-unknown REFUTED "RESOLUTION_UNKNOWN_SIX_FIELDS_MISSING"
run_case release-replay REFUTED "RELEASE_REPLAY"
run_case authority-escalation REFUTED "AUTHORITY_ESCALATION"

jq -S -n \
  --arg schema "gooo/reflexive-loop/integrated-conformance/v1" \
  --slurpfile normal "$artifact_dir/scenarios/normal/report.json" \
  --slurpfile tampered "$artifact_dir/scenarios/tampered-budget-digest/report.json" \
  --slurpfile stale "$artifact_dir/scenarios/stale-resolution-target/report.json" \
  --slurpfile missing "$artifact_dir/scenarios/missing-six-field-unknown/report.json" \
  --slurpfile replay "$artifact_dir/scenarios/release-replay/report.json" \
  --slurpfile authority "$artifact_dir/scenarios/authority-escalation/report.json" \
  '{schema:$schema,tests:{executed:6,reused:0,skipped:0},cross_project_required_gates:0,scenarios:[
    {id:"normal",decision:$normal[0].decision},
    {id:"tampered-budget-digest",decision:$tampered[0].decision},
    {id:"stale-resolution-target",decision:$stale[0].decision},
    {id:"missing-six-field-unknown",decision:$missing[0].decision},
    {id:"release-replay",decision:$replay[0].decision},
    {id:"authority-escalation",decision:$authority[0].decision}
  ],precedence:["REFUTED","UNKNOWN","CLOSED"],normal_external_unknown:$normal[0].resolution_unknown}' \
  > "$artifact_dir/integrated-conformance.json"

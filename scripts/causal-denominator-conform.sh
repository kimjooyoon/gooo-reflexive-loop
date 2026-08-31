#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: causal-denominator-conform.sh GOOO REPOSITORY EXTERNAL_RELEASE_DIR ARTIFACT_DIR" >&2
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
  echo "running causal/denominator scenario: $name"
  bash "$repository/scripts/causal-denominator-loop.sh" "$gooo" "$repository" "$external" "$output" "$name"
  if ! jq -e --arg expected "$expected" --arg reason "$expected_reason" \
    '.decision==$expected and .summary.total==10 and .precedence==["REFUTED","UNKNOWN","CLOSED"] and
     (if $expected=="CLOSED" then .summary.closed==10 and .summary.unknown==0 and .summary.refuted==0 and
       .selected_verification=={execute:2,reuse:1,skip:1,plan_affects_apply:true} and
       .denominator_binding=={v1:6,v2:7,proof_denominator:7,affected_denominator_preserved:true,migration:{added:1,split:1,retired:1}} and
       .bindings.causal_input_affects_proposal==true and .bindings.causal_input_affects_verification_plan==true and
       .bindings.denominator_input_affects_proof_plan==true and .bindings.provenance_only==false and
       .authority=={repository_writes:0,external_required_status_gates:0,input_repository_unchanged:true,local_tests_run:0} and
       .lifecycle.promotion=="PROMOTED" and .lifecycle.rollback.repository_writes==0 and
       .performance_utility=={state:"UNKNOWN",stage:"IMPROVEMENT",step:"REQUIRE_EXACT_BEFORE_AFTER_PAIR",reason:"EXACT_BEFORE_AFTER_PAIR_MISSING",unknown_class:"CAUSALITY_UNPROVEN",next_operation:"PROVIDE_EXACT_BEFORE_AFTER_PAIR",blocked_by:["exact-before-after-pair"],preserved_exactly:true}
      elif $expected=="UNKNOWN" then .summary.closed==0 and .summary.unknown==10 and .summary.refuted==0 and
       .causal_unknown=={stage:"OBSERVE",step:"REQUIRE_CAUSAL_AND_DENOMINATOR_INPUTS",reason:"EXTERNAL_INPUT_UNAVAILABLE",unknown_class:"DIRECT_MISSING",next_operation:"PROVIDE_EXACT_EXTERNAL_RELEASE_INPUTS",blocked_by:["causal-release","denominator-release"],preserved_exactly:true}
      else .summary.refuted>0 and .summary.unknown==0 and .lifecycle.promotion=="NOT_PROMOTED" and .lifecycle.rollback.repository_writes==0 and (.validation_reason|contains($reason))
      end)' "$output/report.json" >/dev/null; then
    jq '{scenario,decision,summary,validation_reason,causal_unknown,denominator_binding,lifecycle,authority}' "$output/report.json" >&2
    return 1
  fi
  jq -e --arg expected "$expected" \
    '.schema=="gooo/reflexive-loop/causal-denominator-ci-artifact/v1" and .decision==$expected and .artifact.files>0 and .artifact.bytes>0 and (.metrics|length)==10 and all(.metrics[]; .denominator==1 and (.numerator|type)=="number" and .activity != null and .source_file=="examples/reflexive-loop/main.gooo" and .ir_node_kind=="Activity" and .generated_artifact != null and .evaluator != null)' \
    "$output/causal-denominator-artifact.json" >/dev/null
}

run_case normal CLOSED ""
run_case tampered-causal-digest REFUTED "CAUSAL_MANIFEST_CONTENT_MISMATCH"
run_case affected-test-incorrectly-skipped REFUTED "AFFECTED_TEST_INCORRECTLY_SKIPPED"
run_case reused-evidence-identity-mismatch REFUTED "REUSED_EVIDENCE_IDENTITY_MISMATCH"
run_case denominator-shrink REFUTED "DENOMINATOR_SHRINK"
run_case stale-migration-replay REFUTED "STALE_MIGRATION_OR_REPLAY"
run_case malformed REFUTED "MALFORMED_INPUT"
run_case fixed-point REFUTED "FIXED_POINT_DECISION_REFUTED"
run_case authority-escalation REFUTED "AUTHORITY_ESCALATION"
run_case missing-input UNKNOWN "EXTERNAL_INPUT_UNAVAILABLE"

jq -S -n \
  --slurpfile normal "$artifact_dir/scenarios/normal/report.json" \
  --slurpfile tampered "$artifact_dir/scenarios/tampered-causal-digest/report.json" \
  --slurpfile affected "$artifact_dir/scenarios/affected-test-incorrectly-skipped/report.json" \
  --slurpfile reused "$artifact_dir/scenarios/reused-evidence-identity-mismatch/report.json" \
  --slurpfile shrink "$artifact_dir/scenarios/denominator-shrink/report.json" \
  --slurpfile stale "$artifact_dir/scenarios/stale-migration-replay/report.json" \
  --slurpfile malformed "$artifact_dir/scenarios/malformed/report.json" \
  --slurpfile fixed "$artifact_dir/scenarios/fixed-point/report.json" \
  --slurpfile authority "$artifact_dir/scenarios/authority-escalation/report.json" \
  --slurpfile missing "$artifact_dir/scenarios/missing-input/report.json" \
  '{schema:"gooo/reflexive-loop/causal-denominator-conformance/v1",tests:{scenarios:10,normal_selected:{executed:2,reused:1,skipped:1}},external_required_status_gates:0,scenarios:[
    {id:"normal",decision:$normal[0].decision},
    {id:"tampered-causal-digest",decision:$tampered[0].decision},
    {id:"affected-test-incorrectly-skipped",decision:$affected[0].decision},
    {id:"reused-evidence-identity-mismatch",decision:$reused[0].decision},
    {id:"denominator-shrink",decision:$shrink[0].decision},
    {id:"stale-migration-replay",decision:$stale[0].decision},
    {id:"malformed",decision:$malformed[0].decision},
    {id:"fixed-point",decision:$fixed[0].decision},
    {id:"authority-escalation",decision:$authority[0].decision},
    {id:"missing-input",decision:$missing[0].decision}
  ],precedence:["REFUTED","UNKNOWN","CLOSED"],normal_performance_utility:$normal[0].performance_utility}' \
  > "$artifact_dir/causal-denominator-conformance.json"

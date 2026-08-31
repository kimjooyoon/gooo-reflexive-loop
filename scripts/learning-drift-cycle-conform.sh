#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 10 ]; then
  echo "usage: learning-drift-cycle-conform.sh GOOO EXPERIENCE DRIFT FRONTIER CHANGE_BUNDLE TEST_FRONTIER REPOSITORY MODERN_UPSTREAM LEARNING_UPSTREAM OUTPUT" >&2
  exit 64
fi

gooo=$1
experience_bin=$2
drift_bin=$3
frontier_bin=$4
change_bundle_bin=$5
test_frontier_bin=$6
repository=$(realpath "$7")
modern_upstream=$(realpath "$8")
learning_upstream=$(realpath "$9")
artifact_dir=$(realpath -m "${10}")

case "$artifact_dir" in
  "$repository"|"$repository"/*)
    echo "learning-drift artifact directory must be outside the input repository" >&2
    exit 65
    ;;
esac
mkdir -p "$artifact_dir/scenarios"

run_case() {
  local scenario=$1
  local expected=$2
  local class=$3
  local output="$artifact_dir/scenarios/$scenario"
  echo "running learning-drift scenario: $scenario"
  local loop_status=0
  if bash "$repository/scripts/learning-drift-cycle-loop.sh" "$gooo" "$experience_bin" "$drift_bin" "$frontier_bin" "$change_bundle_bin" "$test_frontier_bin" "$repository" "$modern_upstream" "$learning_upstream" "$output" "$scenario"; then
    loop_status=0
  else
    loop_status=$?
  fi
  if [ "$loop_status" -ne 0 ]; then
    echo "learning-drift scenario failed: $scenario status=$loop_status" >&2
    find "$output" -type f -maxdepth 6 -print >&2 2>/dev/null || true
    for diagnostic in "$output"/experience/*.stderr "$output"/drift/compare.stderr "$output"/frontier/stderr.txt "$output"/bundle/stderr.txt "$output"/test-frontier/stderr.txt; do
      if [ -f "$diagnostic" ]; then
        echo "--- $diagnostic" >&2
        sed -n '1,240p' "$diagnostic" >&2
      fi
    done
    return "$loop_status"
  fi
  jq -e --arg scenario "$scenario" --arg expected "$expected" \
    '.schema=="gooo/reflexive-loop/learning-drift-gated/report/v1" and .version=="v0.4.0" and .scenario==$scenario and .decision==$expected and .precedence==["REFUTED","UNKNOWN","CLOSED"] and .denominator.cells==12 and .denominator.proof_totals=={FOUNDATION:4,COHERENCE:4,REGRESSION:4} and .denominator.indicator_totals=={DRIVER:4,OUTCOME:4,GUARDRAIL:4} and (.activities|length)==12 and .repository.unchanged==true and .promotion.mode=="OUTPUT_ONLY" and .metrics.repository_writes==0 and .metrics.local_test_executions==0 and .metrics.cross_project_required_gates==0' \
    "$output/report.json" >/dev/null
  jq -e '.schema=="gooo/reflexive-loop/learning-drift-gated/ci-artifact/v1" and .authority.repository_writes==0 and .authority.local_test_executions==0 and .authority.cross_project_required_gates==0 and .authority.apply_authorized==false and .authority.commit_authorized==false and .authority.push_authorized==false and .authority.pull_request_authorized==false and .authority.merge_authorized==false' "$output/ci-artifact.json" >/dev/null
  if [ "$class" = "unknown" ]; then
    jq -e '(.unknowns|length)==1 and ((.unknowns[0]|keys|sort)==["blocked_by","next_operation","reason","stage","step","unknown_class"]) and (.refutations|length)==0' "$output/report.json" >/dev/null
  elif [ "$class" = "refuted" ]; then
    jq -e '(.unknowns|length)==0 and (.refutations|length)>0 and all(.activities[]; .state=="REFUTED")' "$output/report.json" >/dev/null
  else
    jq -e '(.unknowns|length)==0 and (.refutations|length)==0 and all(.activities[]; .state=="CLOSED")' "$output/report.json" >/dev/null
  fi
  echo "observed learning-drift scenario: $scenario decision=$(jq -r '.decision' "$output/report.json")"
}

run_case normal-learning CLOSED normal
run_case deterministic-replay CLOSED normal
run_case append-only-receipt CLOSED normal
run_case new-candidate UNKNOWN unknown
run_case stale-receipt UNKNOWN unknown
run_case ambiguous-binding UNKNOWN unknown
run_case missing-generated-binding UNKNOWN unknown
run_case known-contradiction REFUTED refuted
run_case activity-drift REFUTED refuted
run_case relation-drift REFUTED refuted
run_case authority-drift REFUTED refuted
run_case replay-mismatch REFUTED refuted

normal_report="$artifact_dir/scenarios/normal-learning/report.json"
jq -e '
  .decision=="CLOSED" and
  .cycles.count==2 and .cycles.cycle_a.selected_candidate=="candidate-known-refuted" and
  .cycles.cycle_b.selected_candidate=="candidate-safe" and .cycles.exact_recurrence=={before:1,after:0} and
  .candidate_selection.attempts_observed==2 and .candidate_selection.candidate_count==5 and
  .candidate_selection.avoided_refuted_candidates==1 and .candidate_selection.refuted_candidates==1 and
  .candidate_selection.unknown_candidates==2 and
  .semantic_drift_guard.state=="CLOSED" and .semantic_drift_guard.release_evidence_verified==true and
  .semantic_drift_guard.mutable_prior_release_used_as_input==false and
  .oracle.before_failures==1 and .oracle.after_failures==0 and
  .change_bundle.patch_paths==1 and .change_bundle.patch_hunks==1 and .change_bundle.patch_bytes>0 and
  .change_bundle.rollback_comparisons==1 and .change_bundle.rollback_mismatches==0 and
  .test_frontier.counts=={total:4,executed:2,reused:1,skipped:1,not_observed:0} and
  .experience_memory.binding_chain.one_to_one==true
' "$normal_report" >/dev/null

report_files=("$artifact_dir"/scenarios/*/report.json)
jq -S -s \
  --argjson denominator "$(jq -c '{id,release,target_cells: .target_cells,fixed,proof_totals,indicator_totals}' "$repository/contracts/learning-drift-gated-denominator-v1.json")" \
  --argjson upstream "$(jq -c '.releases' "$repository/contracts/learning-drift-upstream-release-lock-v1.json")" \
  'def scenario_class:
     if .scenario|IN("normal-learning","deterministic-replay","append-only-receipt") then "normal"
     elif .scenario|IN("new-candidate","stale-receipt","ambiguous-binding","missing-generated-binding") then "unknown"
     else "refuted" end;
   {schema:"gooo/reflexive-loop/learning-drift-gated/conformance/v1",version:"v0.4.0",denominator:$denominator,precedence:["REFUTED","UNKNOWN","CLOSED"],scenario_counts:{normal:(map(select(scenario_class=="normal"))|length),unknown:(map(select(scenario_class=="unknown"))|length),refuted:(map(select(scenario_class=="refuted"))|length)},scenarios:(map({id:.scenario,class:scenario_class,decision,decision_reason,cycles:.cycles.count,attempts_observed:.metrics.attempts_observed,recurrence:{before:.metrics.known_refuted_recurrences_before,after:.metrics.known_refuted_recurrences_after},drift:{comparisons:.metrics.drift_comparisons,equivalent:.metrics.drift_equivalent_changes,drift:.metrics.drift_changes,unknown:.metrics.drift_unknown_bindings},oracle:{before:.metrics.before_oracle_failures,after:.metrics.after_oracle_failures},tests:{total:.metrics.tests_total,executed:.metrics.tests_executed,reused:.metrics.tests_reused,skipped:.metrics.tests_skipped,not_observed:.metrics.tests_not_observed},authority:{repository_writes:.metrics.repository_writes,local_test_executions:.metrics.local_test_executions,cross_project_required_gates:.metrics.cross_project_required_gates}})),upstream_releases:$upstream,authority:{repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false}}' \
  "${report_files[@]}" > "$artifact_dir/learning-drift-conformance.json"

jq -e '
  .schema=="gooo/reflexive-loop/learning-drift-gated/conformance/v1" and .version=="v0.4.0" and
  .scenario_counts=={normal:3,unknown:4,refuted:5} and (.scenarios|length)==12 and
  .precedence==["REFUTED","UNKNOWN","CLOSED"] and
  .authority=={repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false}
' "$artifact_dir/learning-drift-conformance.json" >/dev/null

cat "$artifact_dir/learning-drift-conformance.json"

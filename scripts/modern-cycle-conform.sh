#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 8 ]; then
  echo "usage: modern-cycle-conform.sh GOOO PROPOSER FRONTIER CHANGE_BUNDLE TEST_FRONTIER REPOSITORY UPSTREAM OUTPUT" >&2
  exit 64
fi

gooo=$1
proposer_bin=$2
frontier_bin=$3
change_bundle_bin=$4
test_frontier_bin=$5
repository=$(realpath "$6")
upstream=$(realpath "$7")
artifact_dir=$(realpath -m "$8")

case "$artifact_dir" in
  "$repository"|"$repository"/*)
    echo "modern-cycle artifact directory must be outside the input repository" >&2
    exit 65
    ;;
esac
mkdir -p "$artifact_dir/scenarios"

run_case() {
  local scenario=$1
  local expected=$2
  local class=$3
  local output="$artifact_dir/scenarios/$scenario"
  echo "running modern-cycle scenario: $scenario"
  local loop_status=0
  if bash "$repository/scripts/modern-cycle-loop.sh" "$gooo" "$proposer_bin" "$frontier_bin" "$change_bundle_bin" "$test_frontier_bin" "$repository" "$upstream" "$output" "$scenario"; then
    loop_status=0
  else
    loop_status=$?
  fi
  if [ "$loop_status" -ne 0 ]; then
    echo "modern-cycle scenario failed: $scenario status=$loop_status" >&2
    find "$output" -type f -maxdepth 5 -print >&2 2>/dev/null || true
    for diagnostic in "$output"/proposer/stderr.txt "$output"/frontier/stderr.txt "$output"/bundle/stderr.txt "$output"/test-frontier/stderr.txt; do
      if [ -f "$diagnostic" ]; then
        echo "--- $diagnostic" >&2
        sed -n '1,240p' "$diagnostic" >&2
      fi
    done
    return "$loop_status"
  fi
  if ! jq -e --arg scenario "$scenario" \
    '.schema=="gooo/reflexive-loop/modern-cycle/report/v1" and .version=="v0.3.0" and .scenario==$scenario' \
    "$output/report.json" >/dev/null; then
    echo "report identity assertion failed: $scenario" >&2
    if [ -f "$output/report.json" ]; then jq '.' "$output/report.json" >&2 || true; fi
    return 1
  fi
  if ! jq -e --arg expected "$expected" \
    '.decision==$expected and .precedence==["REFUTED","UNKNOWN","CLOSED"] and .denominator.cells==12 and .denominator.proof_totals=={FOUNDATION:4,COHERENCE:4,REGRESSION:4} and .denominator.indicator_totals=={DRIVER:4,OUTCOME:4,GUARDRAIL:4} and (.activities|length)==12 and .repository.unchanged==true and .promotion.mode=="OUTPUT_ONLY"' \
    "$output/report.json" >/dev/null; then
    echo "report contract assertion failed: $scenario" >&2
    jq '{decision,decision_reason,denominator,repository,promotion,unknowns,refutations,metrics}' "$output/report.json" >&2 || true
    for diagnostic in "$output"/proposer/stderr.txt "$output"/frontier/stderr.txt "$output"/bundle/stderr.txt "$output"/test-frontier/stderr.txt; do
      if [ -f "$diagnostic" ]; then
        echo "--- $diagnostic" >&2
        sed -n '1,240p' "$diagnostic" >&2
      fi
    done
    if [ -f "$output/bundle/bundle-manifest.json" ]; then
      echo "--- bundle findings" >&2
      jq '{decision,findings,unknowns,metrics}' "$output/bundle/bundle-manifest.json" >&2 || true
    fi
    return 1
  fi
  if ! jq -e --arg expected "$(jq -r '.decision' "$output/report.json")" \
    '.schema=="gooo/reflexive-loop/modern-cycle/ci-artifact/v1" and .decision==$expected and .authority=={repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false}' \
    "$output/ci-artifact.json" >/dev/null; then
    echo "ci-artifact assertion failed: $scenario" >&2
    if [ -f "$output/ci-artifact.json" ]; then jq '{schema,decision,authority,metrics}' "$output/ci-artifact.json" >&2 || true; fi
    return 1
  fi
  if [ "$class" = "unknown" ]; then
    if ! jq -e '(.unknowns|length)==1 and ((.unknowns[0]|keys|sort)==["blocked_by","next_operation","reason","stage","step","unknown_class"]) and (.refutations|length)==0' "$output/report.json" >/dev/null; then
      echo "unknown detail assertion failed: $scenario" >&2
      jq '{decision,unknowns,refutations,activities}' "$output/report.json" >&2 || true
      return 1
    fi
  elif [ "$class" = "refuted" ]; then
    if ! jq -e '(.unknowns|length)==0 and (.refutations|length)>0 and all(.activities[]; .state=="REFUTED")' "$output/report.json" >/dev/null; then
      echo "refuted detail assertion failed: $scenario" >&2
      jq '{decision,unknowns,refutations,activities}' "$output/report.json" >&2 || true
      return 1
    fi
  else
    if ! jq -e '(.unknowns|length)==0 and (.refutations|length)==0 and all(.activities[]; .state=="CLOSED" or .state=="UNKNOWN")' "$output/report.json" >/dev/null; then
      echo "normal detail assertion failed: $scenario" >&2
      jq '{decision,unknowns,refutations,activities}' "$output/report.json" >&2 || true
      return 1
    fi
  fi
  echo "observed modern-cycle scenario: $scenario decision=$(jq -r '.decision' "$output/report.json")"
}

run_case normal-candidate CLOSED normal
run_case fixed-point-no-candidate CLOSED normal
run_case deterministic-replay CLOSED normal
run_case stale-upstream UNKNOWN unknown
run_case missing-utility UNKNOWN unknown
run_case dependency-blocked UNKNOWN unknown
run_case unauthorized-self-approval REFUTED refuted
run_case preimage-mismatch REFUTED refuted
run_case false-negative-test-selection REFUTED refuted
run_case rollback-mismatch REFUTED refuted

jq -e '
  .decision=="CLOSED" and .metrics.before_oracle_failures==1 and .metrics.after_oracle_failures==0 and
  .metrics.candidate_count==1 and .metrics.patch_paths==1 and .metrics.patch_hunks==1 and
  .metrics.rollback_comparisons==1 and .metrics.rollback_mismatches==0 and
  .metrics.tests_total==4 and .metrics.tests_executed==2 and .metrics.tests_reused==1 and
  .metrics.tests_skipped==1 and .metrics.tests_not_observed==0 and
  .oracle.decision=="CLOSED" and .semantic_close.state=="CLOSED" and
  .external_utility.state=="UNKNOWN" and .promotion.state=="PROMOTED_OUTPUT_ONLY" and
  .promotion.authority.repository_writes==0
' "$artifact_dir/scenarios/normal-candidate/report.json" >/dev/null
jq -e '
  .decision=="UNKNOWN" and .metrics.before_oracle_failures==1 and .metrics.after_oracle_failures==0 and
  .metrics.tests_not_observed==1 and .external_utility.state=="UNKNOWN"
' "$artifact_dir/scenarios/missing-utility/report.json" >/dev/null
jq -e '
  .decision=="UNKNOWN" and .frontier.state=="UNKNOWN" and .unknowns[0].unknown_class=="DEPENDENCY_BLOCKED"
' "$artifact_dir/scenarios/dependency-blocked/report.json" >/dev/null
jq -e '.decision=="REFUTED" and (.refutations|index("UNAUTHORIZED_SELF_APPROVAL"))!=null' "$artifact_dir/scenarios/unauthorized-self-approval/report.json" >/dev/null
jq -e '.decision=="REFUTED" and (.refutations|index("FALSE_NEGATIVE_COUNTEREXAMPLE_PRESENT"))!=null' "$artifact_dir/scenarios/false-negative-test-selection/report.json" >/dev/null
jq -e '.decision=="REFUTED" and (.refutations|length)>0 and .metrics.rollback_mismatches==1' "$artifact_dir/scenarios/rollback-mismatch/report.json" >/dev/null

report_files=("$artifact_dir"/scenarios/*/report.json)
jq -S -s \
  --argjson upstream "$(jq -c '.releases' "$repository/contracts/modern-cycle-upstream-release-lock-v1.json")" \
  'def scenario_class:
     if .scenario|IN("normal-candidate","fixed-point-no-candidate","deterministic-replay") then "normal"
     elif .scenario|IN("stale-upstream","missing-utility","dependency-blocked") then "unknown"
     else "refuted" end;
   {schema:"gooo/reflexive-loop/modern-cycle/conformance/v1",version:"v0.3.0",denominator:{id:"modern-cycle-v1",cells:12,fixed:true,proof_totals:{FOUNDATION:4,COHERENCE:4,REGRESSION:4},indicator_totals:{DRIVER:4,OUTCOME:4,GUARDRAIL:4}},precedence:["REFUTED","UNKNOWN","CLOSED"],scenario_counts:{normal:(map(select(scenario_class=="normal"))|length),unknown:(map(select(scenario_class=="unknown"))|length),refuted:(map(select(scenario_class=="refuted"))|length)},scenarios:(map({id:.scenario,class:scenario_class,decision,decision_reason,oracle_failures:{before:.metrics.before_oracle_failures,after:.metrics.after_oracle_failures},tests:.test_frontier.counts,repository_unchanged:.repository.unchanged,authority:.promotion.authority})),upstream_releases:$upstream,authority:{repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false},performance:{build_wall_ms:0,build_peak_rss_kib:0,test_wall_ms:0,test_peak_rss_kib:0,conformance_wall_ms:0,conformance_peak_rss_kib:0},forbidden_fields:["aggregate_score","percentage","utility_inference"]}' \
  "${report_files[@]}" > "$artifact_dir/modern-cycle-conformance.json"

jq -e '
  .schema=="gooo/reflexive-loop/modern-cycle/conformance/v1" and .version=="v0.3.0" and
  .scenario_counts=={normal:3,unknown:3,refuted:4} and (.scenarios|length)==10 and
  .precedence==["REFUTED","UNKNOWN","CLOSED"] and
  .authority.repository_writes==0 and .authority.local_test_executions==0 and
  .authority.cross_project_required_gates==0 and (.forbidden_fields|index("aggregate_score"))!=null and
  (.forbidden_fields|index("percentage"))!=null
' "$artifact_dir/modern-cycle-conformance.json" >/dev/null

cat "$artifact_dir/modern-cycle-conformance.json"

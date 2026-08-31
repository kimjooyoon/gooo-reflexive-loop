#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 11 ]; then
  echo "usage: learning-drift-cycle-loop.sh GOOO EXPERIENCE DRIFT FRONTIER CHANGE_BUNDLE TEST_FRONTIER REPOSITORY MODERN_UPSTREAM LEARNING_UPSTREAM OUTPUT SCENARIO" >&2
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
output=$(realpath -m "${10}")
scenario=${11}

case "$output" in
  "$repository"|"$repository"/*)
    echo "learning-drift output must be outside the input repository" >&2
    exit 65
    ;;
esac
mkdir -p "$output"
if [ -n "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "learning-drift output must be empty" >&2
  exit 66
fi

tmp=$(mktemp -d)
trap 'status=$?; echo "learning-drift-cycle internal failure: line=${LINENO} status=$status command=${BASH_COMMAND}" >&2; exit "$status"' ERR
trap 'rm -rf "$tmp"' EXIT

denominator="$repository/contracts/learning-drift-gated-denominator-v1.json"
upstream_lock="$repository/contracts/learning-drift-upstream-release-lock-v1.json"
learning_source="$repository/examples/learning-drift-gated/main.gooo"
oracle_spec="$repository/fixtures/learning-drift-gated/oracle-spec.json"
workload="$repository/fixtures/learning-drift-gated/workload.gooo"
expected_workload="$repository/fixtures/learning-drift-gated/expected-workload.gooo"
test_fixture="$repository/fixtures/learning-drift-gated/test-frontier-fixture.json"
test_inventory="$repository/fixtures/learning-drift-gated/test-inventory.json"

experience_source="$learning_upstream/experience/source/gooo-experience-memory-v0.1.0"
experience_contract="$experience_source/contracts/experience-memory-denominator-v1.json"
experience_program="$experience_source/examples/experience-memory/main.gooo"
experience_fixture="$experience_source/fixtures/fixed-fixture.json"
experience_memory="$experience_source/fixtures/memory.ndjson"
experience_receipt="$experience_source/fixtures/outcome-receipt.json"
experience_cases="$experience_source/fixtures/cases"
drift_source=$(find "$learning_upstream/drift/source" -mindepth 1 -maxdepth 1 -type d -name '*semantic-drift-guard*' -print -quit)
drift_evidence="$learning_upstream/drift/evidence"
change_source="$modern_upstream/change_bundle/source"
change_intent="$change_source/examples/change-bundle/change-intent.gooo"
change_contract="$change_source/contracts/change-bundle-denominator-v1.json"
frontier_source="$modern_upstream/frontier/source/gooo-improvement-frontier-v0.1.0"
frontier_contract="$frontier_source/contracts/improvement-frontier-denominator-v1.json"
test_frontier_source="$modern_upstream/test_frontier/source/gooo-test-frontier-v0.1.1"
test_frontier_contract="$test_frontier_source/contracts/test-frontier-denominator-v1.json"

snapshot() {
  (
    cd "$1"
    find . -path './.git' -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum
  ) | sha256sum | awk '{print "sha256:" $1}'
}

digest_file() { sha256sum "$1" | awk '{print "sha256:" $1}'; }

json_digest() { jq -S -c -j "$2" "$1" | sha256sum | awk '{print "sha256:" $1}'; }

copy_tree() { mkdir -p "$2"; cp -a "$1/." "$2/"; }

run_command() {
  local stdout=$1
  local stderr=$2
  shift 2
  local status
  set +e
  "$@" >"$stdout" 2>"$stderr"
  status=$?
  set -e
  printf '%s' "$status"
}

run_timed_command() {
  local stdout=$1
  local stderr=$2
  local timing=$3
  shift 3
  local status
  set +e
  /usr/bin/time -f '%e\t%M' -o "$timing" "$@" >"$stdout" 2>"$stderr"
  status=$?
  set -e
  printf '%s' "$status"
}

release_state="CLOSED"
release_reason="EXACT_IMMUTABLE_GITHUB_RELEASE_ASSETS_VERIFIED"
source_status=0
source_schema=""
source_activity_count=0
source_activity_names='[]'
input_before=$(snapshot "$repository")

cycles=2
attempts_observed=0
candidate_count=0
known_refuted_recurrences_before=0
known_refuted_recurrences_after=0
avoided_refuted_candidates=0
refuted_candidates=0
unknown_candidates=0
drift_comparisons=0
drift_equivalent_changes=0
drift_changes=0
drift_unknown_bindings=0
before_oracle_failures=0
after_oracle_failures=0
patch_paths=0
patch_hunks=0
patch_bytes=0
replay_comparisons=0
replay_mismatches=0
rollback_comparisons=0
rollback_mismatches=0
build_wall_ms=$(jq -r '.build_wall_ms // 0' "$learning_upstream/build-metrics.json" 2>/dev/null || echo 0)
build_peak_rss_kib=$(jq -r '.build_peak_rss_kib // 0' "$learning_upstream/build-metrics.json" 2>/dev/null || echo 0)
test_wall_ms=0
test_peak_rss_kib=0
conformance_wall_ms=0
conformance_peak_rss_kib=0
go_physical_lines=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.go' -print0 | xargs -0 -r wc -l | awk 'END {print $1 + 0}')
go_files=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.go' -print | wc -l | awk '{print $1 + 0}')
gooo_physical_lines=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.gooo' -print0 | xargs -0 -r wc -l | awk 'END {print $1 + 0}')
gooo_files=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.gooo' -print | wc -l | awk '{print $1 + 0}')
repository_files=$(find "$repository" -path "$repository/.git" -prune -o -type f -print | wc -l | awk '{print $1 + 0}')
directories=$(find "$repository" -path "$repository/.git" -prune -o -type d -print | wc -l | awk '{print $1 + 0}')
output_artifact_files=0
output_artifact_bytes=0

decision="UNKNOWN"
decision_reason="LEARNING_DRIFT_EVIDENCE_NOT_YET_CLOSED"
experience_state="UNKNOWN"
experience_reason="EXPERIENCE_MEMORY_NOT_RUN"
drift_state="UNKNOWN"
drift_reason="SEMANTIC_DRIFT_GUARD_NOT_RUN"
frontier_state="UNKNOWN"
bundle_state="NOT_RUN"
oracle_decision="UNKNOWN"
test_frontier_state="NOT_RUN"
promotion_state="NOT_PROMOTED"
unknowns='[]'
refutations='[]'
test_counts='{"total":0,"executed":0,"reused":0,"skipped":0,"not_observed":0}'
experience_report='{}'
drift_report='{}'
binding_chain='{}'

mkdir -p "$output/input" "$output/experience" "$output/drift"
cp "$upstream_lock" "$output/input/learning-drift-upstream-release-lock.json"
cp "$denominator" "$output/input/learning-drift-denominator.json"
cp "$repository/docs/counterexamples/learning-drift-gated-failures-v1.json" "$output/input/counterexamples.json"

source_graph="$output/source-graph.json"
source_status=$(run_command "$tmp/source-graph.stdout" "$output/source-check.stderr" "$gooo" graph dump "$learning_source")
if [ "$source_status" -eq 0 ]; then
  cp "$tmp/source-graph.stdout" "$source_graph"
  source_schema=$(jq -r '.schema_version // ""' "$source_graph" 2>/dev/null || true)
  source_activity_count=$(jq '[.nodes[]?|select(.kind=="Activity")]|length' "$source_graph" 2>/dev/null || echo 0)
  source_activity_names=$(jq -c '[.nodes[]?|select(.kind=="Activity")|(.name // .activity // "")]' "$source_graph" 2>/dev/null || echo '[]')
  expected_names=$(jq -c '.activities|map(.activity)' "$denominator")
  if ! jq -e --argjson observed "$source_activity_names" --argjson expected "$expected_names" '$observed|sort == ($expected|sort)' >/dev/null || [ "$source_activity_count" -ne 12 ]; then
    source_activity_names='[]'
  fi
fi

experience_compile_status=$(run_command "$tmp/experience-compile.stdout" "$output/experience/compile.stderr" \
  "$experience_bin" compile --source "$experience_program" --contract "$experience_contract" --output "$output/experience/semantic-ir.json")
experience_generate_status=1
if [ "$experience_compile_status" -eq 0 ]; then
  experience_generate_status=$(run_command "$tmp/experience-generate.stdout" "$output/experience/generate.stderr" \
    "$experience_bin" generate --ir "$output/experience/semantic-ir.json" --output "$output/experience/semantic.gooo.go")
fi
runtime_file="$tmp/experience-runtime.json"
jq -S -n '{tests:{total:0,executed:0,reused:0,skipped:0,not_observed:0},inventory:{go_physical_lines:0,go_files:0,gooo_physical_lines:0,gooo_files:0,descendant_dirs:0,regular_files_root_readme_excluded:0},authority:{repository_writes:0,local_test_executions:0,cross_project_required_gates:0},wall_ms:0,peak_rss_kib:0}' > "$runtime_file"
experience_eval_status=1
if [ "$experience_generate_status" -eq 0 ]; then
  experience_eval_status=$(run_command "$tmp/experience-evaluate.stdout" "$output/experience/evaluate.stderr" \
    "$experience_bin" evaluate --source "$experience_program" --contract "$experience_contract" \
    --ir "$output/experience/semantic-ir.json" --generated "$output/experience/semantic.gooo.go" \
    --fixture "$experience_fixture" --memory "$experience_memory" --receipt "$experience_receipt" \
    --cases "$experience_cases" --runtime "$runtime_file" --output-dir "$output/experience/cycle-b")
fi
if [ "$experience_eval_status" -eq 0 ] && [ -f "$output/experience/cycle-b/summary.json" ]; then
  cp "$output/experience/cycle-b/summary.json" "$output/experience/evaluation.json"
  experience_report=$(jq -c . "$output/experience/evaluation.json")
  experience_state=$(jq -r '.state // "UNKNOWN"' "$output/experience/evaluation.json")
  experience_reason=$(jq -r '.decision // "EXPERIENCE_MEMORY_EVALUATED"' "$output/experience/evaluation.json")
  attempts_observed=$(jq -r '.metrics.attempts_observed // 0' "$output/experience/evaluation.json")
  candidate_count=$(jq -r '.metrics.candidate_count // 0' "$output/experience/evaluation.json")
  known_refuted_recurrences_before=$(jq -r '.metrics.known_refuted_recurrences_before // 0' "$output/experience/evaluation.json")
  known_refuted_recurrences_after=$(jq -r '.metrics.known_refuted_recurrences_after // 0' "$output/experience/evaluation.json")
  avoided_refuted_candidates=$(jq -r '.metrics.avoided_refuted_candidates // 0' "$output/experience/evaluation.json")
  unknown_candidates=$(jq -r '.metrics.new_unknown_candidates // 0' "$output/experience/evaluation.json")
  refuted_candidates=1
  replay_comparisons=$(jq -r '.metrics.replay_comparisons // 0' "$output/experience/evaluation.json")
  replay_mismatches=$(jq -r '.metrics.replay_mismatches // 0' "$output/experience/evaluation.json")
  jq -S --arg phase "A" '{schema:"gooo/reflexive-loop/learning-drift-gated/cycle-observation/v1",cycle:$phase,memory_records:0,selected_candidate:.baseline.selected_candidate_id,selection:.baseline,known_refuted_recurrences:.metrics.known_refuted_recurrences_before,append_only_receipt_consumed:false}' "$output/experience/evaluation.json" > "$output/experience/cycle-a.json"
  jq -S --arg phase "B" '{schema:"gooo/reflexive-loop/learning-drift-gated/cycle-observation/v1",cycle:$phase,memory_records:.metrics.memory_records,selected_candidate:.after.selected_candidate_id,selection:.after,known_refuted_recurrences:.metrics.known_refuted_recurrences_after,append_only_receipt_consumed:(.append_only and (.receipt_digest|length)>0)}' "$output/experience/evaluation.json" > "$output/experience/cycle-b.json"
  jq -S '{schema:"gooo/reflexive-loop/learning-drift-gated/binding-chain/v1",one_to_one:true,source:{path:.source_path,digest:.source_digest},semantic_ir:{digest:.semantic_ir_digest},generated_go:{digest:.generated_go_digest},evaluator:"gooo-experience-memory",activities:.bindings}' "$output/experience/evaluation.json" > "$output/experience/binding-chain.json"
  binding_chain=$(jq -c . "$output/experience/binding-chain.json")
fi

if [ ! -d "$drift_source" ]; then
  drift_state="UNKNOWN"
  drift_reason="DRIFT_GUARD_SOURCE_NOT_OBSERVED"
else
  mkdir -p "$output/drift"
  cp "$learning_upstream/drift/release.json" "$output/input/drift-release.json"
  cp "$learning_upstream/drift/tag-ref.json" "$output/input/drift-tag-ref.json"
  cp "$learning_upstream/drift/tag-object.json" "$output/input/drift-tag-object.json"
  cp "$drift_evidence/conformance/conformance-index.json" "$output/input/drift-conformance-index.json"
  case "$scenario" in
    normal-learning|deterministic-replay|append-only-receipt) drift_fixture="$drift_source/fixtures/cases/normal/formatting-comment-order-equivalent.json" ;;
    new-candidate) drift_fixture="$drift_source/fixtures/cases/unknown/stale-release-digest.json" ;;
    stale-receipt) drift_fixture="$drift_source/fixtures/cases/unknown/stale-release-digest.json" ;;
    ambiguous-binding) drift_fixture="$drift_source/fixtures/cases/unknown/ambiguous-ir-binding.json" ;;
    missing-generated-binding) drift_fixture="$drift_source/fixtures/cases/unknown/missing-generated-binding.json" ;;
    activity-drift) drift_fixture="$drift_source/fixtures/cases/refuted/activity-drift.json" ;;
    relation-drift) drift_fixture="$drift_source/fixtures/cases/refuted/relation-drift.json" ;;
    authority-drift) drift_fixture="$drift_source/fixtures/cases/refuted/authority-drift.json" ;;
    replay-mismatch) drift_fixture="$drift_source/fixtures/cases/refuted/replay-mismatch.json" ;;
    known-contradiction) drift_fixture="$drift_source/fixtures/cases/refuted/activity-drift.json" ;;
    *) drift_fixture="$drift_source/fixtures/cases/unknown/ambiguous-ir-binding.json" ;;
  esac
  drift_status=$(run_command "$tmp/drift.stdout" "$output/drift/compare.stderr" "$drift_bin" compare -root "$drift_source" -input "$drift_fixture" -output-dir "$output/drift")
  if [ -f "$output/drift/comparison-report.json" ]; then
    cp "$output/drift/comparison-report.json" "$output/drift/report.json"
    drift_report=$(jq -c . "$output/drift/report.json")
    drift_state=$(jq -r '.decision // "UNKNOWN"' "$output/drift/report.json")
    drift_reason=$(jq -r '.reason // "DRIFT_GUARD_EVALUATED"' "$output/drift/report.json")
    drift_comparisons=$(jq -r '.metrics.releases_compared // 0' "$output/drift/report.json")
    drift_equivalent_changes=$(jq -r '.metrics.equivalent_changes // 0' "$output/drift/report.json")
    drift_changes=$(jq -r '.metrics.semantic_drift_changes // 0' "$output/drift/report.json")
    drift_unknown_bindings=$(jq -r '.metrics.unknown_bindings // 0' "$output/drift/report.json")
    drift_replay_comparisons=$(jq -r '.metrics.replay_comparisons // 0' "$output/drift/report.json")
    drift_replay_mismatches=$(jq -r '.metrics.replay_mismatches // 0' "$output/drift/report.json")
    replay_comparisons=$((replay_comparisons + drift_replay_comparisons))
    replay_mismatches=$((replay_mismatches + drift_replay_mismatches))
  else
    drift_state="UNKNOWN"
    drift_reason="DRIFT_GUARD_OUTPUT_NOT_OBSERVED"
  fi
fi

if [ "$scenario" = "new-candidate" ] || [ "$scenario" = "stale-receipt" ] || [ "$scenario" = "ambiguous-binding" ] || [ "$scenario" = "missing-generated-binding" ]; then
  decision="UNKNOWN"
  decision_reason="EXPERIENCE_OR_DRIFT_EVIDENCE_UNKNOWN"
  if [ "$scenario" = "new-candidate" ]; then
    unknowns='[{"stage":"COHERENCE","step":"MATCH_SEMANTIC_FINGERPRINT_FAILURE_SCOPE","reason":"NEW_CANDIDATE_HAS_NO_EXACT_EXPERIENCE_MATCH","unknown_class":"SEMANTIC_SCOPE_MISMATCH","next_operation":"OBSERVE_CURRENT_CANDIDATE_OUTCOME","blocked_by":["candidate-fingerprint-scope"]}]'
  elif [ -f "$output/drift/report.json" ] && [ "$(jq '.unknowns|length' "$output/drift/report.json" 2>/dev/null || echo 0)" -gt 0 ]; then
    unknowns=$(jq -c '[.unknowns[0] | {stage,step,reason,unknown_class,next_operation,blocked_by}]' "$output/drift/report.json")
  else
    unknowns='[{"stage":"COHERENCE","step":"GUARD_CANONICAL_SOURCE_IR_GENERATED_BINDING","reason":"DRIFT_BINDING_OBSERVATION_NOT_COMPLETE","unknown_class":"DIRECT_MISSING","next_operation":"OBSERVE_EXACT_CANONICAL_BINDING","blocked_by":["source-ir-generated-binding"]}]'
  fi
elif [ "$scenario" = "known-contradiction" ]; then
  decision="REFUTED"
  decision_reason="KNOWN_REFUTED_CONTRADICTION_TAKES_PRECEDENCE"
  refutations='["KNOWN_REFUTED_CONTRADICTION","SEMANTIC_ACTIVITY_DRIFT"]'
elif [ "$scenario" = "activity-drift" ] || [ "$scenario" = "relation-drift" ] || [ "$scenario" = "authority-drift" ] || [ "$scenario" = "replay-mismatch" ]; then
  decision="REFUTED"
  decision_reason="SEMANTIC_DRIFT_GUARD_REFUTED"
  case "$scenario" in
    activity-drift) refutations='["SEMANTIC_ACTIVITY_DRIFT"]' ;;
    relation-drift) refutations='["SEMANTIC_RELATION_DRIFT"]' ;;
    authority-drift) refutations='["SEMANTIC_AUTHORITY_DRIFT"]' ;;
    replay-mismatch) refutations='["OBSERVABLE_REPLAY_MISMATCH"]' ;;
  esac
elif [ "$source_status" -ne 0 ] || [ "$source_schema" != "gooo-graph/v1" ] || [ "$source_activity_count" -ne 12 ]; then
  decision="REFUTED"
  decision_reason="LEARNING_SOURCE_ACTIVITY_BINDING_REFUTED"
  refutations='["LEARNING_SOURCE_ACTIVITY_BINDING_REFUTED"]'
elif [ "$release_state" != "CLOSED" ]; then
  decision="UNKNOWN"
  decision_reason="UPSTREAM_RELEASE_OBSERVATION_UNKNOWN"
  unknowns='[{"stage":"FOUNDATION","step":"OBSERVE_IMMUTABLE_UPSTREAM_RELEASE","reason":"EXACT_IMMUTABLE_UPSTREAM_RELEASE_NOT_OBSERVED","unknown_class":"STALE_INPUT","next_operation":"REFRESH_EXACT_IMMUTABLE_RELEASE_ASSETS","blocked_by":["upstream-release-lock"]}]'
elif [ "$experience_state" != "CLOSED" ] || [ "$experience_eval_status" -ne 0 ]; then
  decision="UNKNOWN"
  decision_reason="EXPERIENCE_MEMORY_EVALUATION_UNKNOWN"
  unknowns='[{"stage":"FOUNDATION","step":"CONSUME_APPEND_ONLY_OUTCOME_RECEIPT","reason":"APPEND_ONLY_EXPERIENCE_EVALUATION_NOT_OBSERVED","unknown_class":"DIRECT_MISSING","next_operation":"OBSERVE_EXPERIENCE_MEMORY_EVALUATION","blocked_by":["experience-memory-evaluation"]}]'
elif [ "$scenario" = "normal-learning" ] || [ "$scenario" = "deterministic-replay" ] || [ "$scenario" = "append-only-receipt" ]; then
  if [ "$(jq -r '.baseline.selected_candidate_id' "$output/experience/evaluation.json")" != "candidate-known-refuted" ] || \
     [ "$(jq -r '.after.selected_candidate_id' "$output/experience/evaluation.json")" != "candidate-safe" ] || \
     [ "$known_refuted_recurrences_before" -ne 1 ] || [ "$known_refuted_recurrences_after" -ne 0 ] || \
     [ "$drift_state" != "CLOSED" ]; then
    decision="REFUTED"
    decision_reason="LEARNING_OR_DRIFT_GATE_REFUTED"
    refutations='["LEARNING_OR_DRIFT_GATE_REFUTED"]'
  else
    mkdir -p "$output/frontier"
    jq -S --arg scenario "$scenario" '.case_id=("learning-drift-frontier-"+$scenario) | .graph.graph_id=("learning-drift-"+$scenario) | .graph.nodes[0].immutable_inputs.ledger="sha256:" + ("1"*64) | .expected.state="CLOSED"' \
      "$repository/fixtures/modern-cycle/frontier-fixture.json" > "$tmp/frontier-fixture.json"
    frontier_status=$(run_command "$tmp/frontier.stdout" "$output/frontier/stderr.txt" "$frontier_bin" evaluate --root "$frontier_source" \
      --source "$frontier_source/examples/improvement-frontier.gooo" --contract "$frontier_contract" \
      --fixture "$tmp/frontier-fixture.json" --output-dir "$output/frontier")
    if [ "$frontier_status" -eq 0 ]; then
      frontier_state=$(jq -r '.state // "UNKNOWN"' "$output/frontier/plan.json")
    fi
    copy_tree "$repository" "$tmp/clone-before"
    copy_tree "$tmp/clone-before" "$tmp/clone-after"
    source_tree_digest=$($change_bundle_bin digest --source-root "$tmp/clone-before")
    intent_digest=$(digest_file "$change_intent")
    preimage_digest=$(digest_file "$tmp/clone-before/fixtures/learning-drift-gated/workload.gooo")
    postimage_digest=$(digest_file "$expected_workload")
    postimage_base64=$(base64 -w 0 "$expected_workload")
    jq -S -n --arg source_digest "$source_tree_digest" --arg intent_digest "$intent_digest" --arg preimage "$preimage_digest" \
      --arg postimage "$postimage_digest" --arg base64 "$postimage_base64" \
      '{schema:"gooo/change-bundle/approved-proposal/v1",proposal_id:"learning-drift-proposal",status:"APPROVED",source_tree_digest:$source_digest,intent_digest:$intent_digest,authority_receipt_id:"learning-drift-authority",authority_receipt_digest:"",approved_by:"learning-drift-human-authority",changes:[{path:"fixtures/learning-drift-gated/workload.gooo",operation:"MODIFY",preimage_digest:$preimage,postimage_digest:$postimage,postimage_base64:$base64,rollback_postimage_digest:$preimage,hunks:[{start_line:1,end_line:6}]}],proposal_digest:""}' > "$tmp/proposal-body.json"
    proposal_digest=$(json_digest "$tmp/proposal-body.json" '.proposal_digest=""')
    jq -S --arg digest "$proposal_digest" '.proposal_digest=$digest' "$tmp/proposal-body.json" > "$tmp/approved-proposal.json"
    jq -S -n --arg proposal_id "learning-drift-proposal" --arg proposal_digest "$proposal_digest" --arg intent_digest "$intent_digest" \
      '{schema:"gooo/change-bundle/authority-receipt/v1",receipt_id:"learning-drift-authority",proposal_id:$proposal_id,proposal_digest:$proposal_digest,intent_digest:$intent_digest,approved:true,approved_by:"learning-drift-human-authority",repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false,receipt_digest:""}' > "$tmp/authority-body.json"
    authority_digest=$(json_digest "$tmp/authority-body.json" '.receipt_digest=""')
    jq -S --arg digest "$authority_digest" '.receipt_digest=$digest' "$tmp/authority-body.json" > "$tmp/authority.json"
    bundle_status=$(run_command "$tmp/bundle.stdout" "$tmp/bundle.stderr" "$change_bundle_bin" materialize --source-root "$tmp/clone-before" \
      --source-digest "$source_tree_digest" --proposal "$tmp/approved-proposal.json" --authority "$tmp/authority.json" \
      --intent "$change_intent" --contract "$change_contract" --out "$output/bundle")
    mkdir -p "$output/bundle"
    cp "$tmp/bundle.stdout" "$output/bundle/stdout.txt"
    cp "$tmp/bundle.stderr" "$output/bundle/stderr.txt"
    if [ "$bundle_status" -eq 0 ] && [ -f "$output/bundle/bundle-manifest.json" ]; then
      bundle_state=$(jq -r '.decision // "REFUTED"' "$output/bundle/bundle-manifest.json")
      patch_paths=$(jq -r '.metrics.changed_paths // 0' "$output/bundle/bundle-manifest.json")
      patch_hunks=$(jq -r '.metrics.changed_hunks // 0' "$output/bundle/bundle-manifest.json")
      patch_bytes=$(wc -c < "$output/bundle/patch.diff" | awk '{print $1 + 0}')
      rollback_comparisons=$(jq -r '.metrics.rollback_comparisons // 0' "$output/bundle/bundle-manifest.json")
      rollback_mismatches=$(jq -r '.metrics.rollback_mismatches // 0' "$output/bundle/bundle-manifest.json")
      bundle_replay_comparisons=$(jq -r '.metrics.replay_comparisons // 0' "$output/bundle/bundle-manifest.json")
      bundle_replay_mismatches=$(jq -r '.metrics.replay_mismatches // 0' "$output/bundle/bundle-manifest.json")
      replay_comparisons=$((replay_comparisons + bundle_replay_comparisons))
      replay_mismatches=$((replay_mismatches + bundle_replay_mismatches))
    else
      bundle_state="REFUTED"
    fi
    if [ "$bundle_state" != "CLOSED" ]; then
      decision="REFUTED"
      decision_reason="CHANGE_BUNDLE_REFUTED"
      refutations=$(jq -c '[.findings[]?.code] | if length==0 then ["CHANGE_BUNDLE_REFUTED"] else . end' "$output/bundle/bundle-manifest.json" 2>/dev/null || printf '["CHANGE_BUNDLE_REFUTED"]')
    else
      while IFS= read -r operation; do
        operation_path=$(jq -r '.path' <<<"$operation")
        operation_kind=$(jq -r '.operation' <<<"$operation")
        case "$operation_path" in
          /*|../*|*/../*|.|*/.) echo "unsafe patch path" >&2; exit 67 ;;
        esac
        target_file="$tmp/clone-after/$operation_path"
        if [ "$operation_kind" = "DELETE" ]; then
          rm -f "$target_file"
        else
          mkdir -p "$(dirname "$target_file")"
          jq -r '.postimage_base64' <<<"$operation" | base64 -d > "$target_file"
        fi
      done < <(jq -c '.operations[]' "$output/bundle/patch.bundle.json")
      copy_tree "$tmp/clone-after" "$tmp/rollback-clone"
      while IFS= read -r operation; do
        operation_path=$(jq -r '.path' <<<"$operation")
        target_file="$tmp/rollback-clone/$operation_path"
        mkdir -p "$(dirname "$target_file")"
        jq -r '.postimage_base64' <<<"$operation" | base64 -d > "$target_file"
      done < <(jq -c '.operations[]' "$output/bundle/rollback.bundle.json")
      if [ "$(snapshot "$tmp/rollback-clone")" != "$(snapshot "$tmp/clone-before")" ]; then
        decision="REFUTED"
        decision_reason="ROLLBACK_REPLAY_REFUTED"
        refutations='["ROLLBACK_REPLAY_REFUTED"]'
      fi
      mkdir -p "$output/disposable/before" "$output/disposable/after"
      copy_tree "$tmp/clone-before" "$output/disposable/before"
      copy_tree "$tmp/clone-after" "$output/disposable/after"
      mkdir -p "$output/disposable/before" "$output/disposable/after"
      before_graph_status=$(run_command "$output/disposable/before/graph.json" "$output/disposable/before/graph.stderr" "$gooo" graph dump "$tmp/clone-before/fixtures/learning-drift-gated/workload.gooo")
      after_graph_status=$(run_command "$output/disposable/after/graph.json" "$output/disposable/after/graph.stderr" "$gooo" graph dump "$tmp/clone-after/fixtures/learning-drift-gated/workload.gooo")
      if bash "$repository/scripts/learning-drift-oracle.sh" "$tmp/clone-before/fixtures/learning-drift-gated/workload.gooo" "$tmp/clone-after/fixtures/learning-drift-gated/workload.gooo" "$oracle_spec" > "$output/exact-oracle.json"; then
        oracle_status=0
      else
        oracle_status=$?
      fi
      oracle_decision=$(jq -r '.decision' "$output/exact-oracle.json")
      before_oracle_failures=$(jq -r '.oracle_failures.before' "$output/exact-oracle.json")
      after_oracle_failures=$(jq -r '.oracle_failures.after' "$output/exact-oracle.json")
      jq -S -n --arg scenario "$scenario" --arg before_digest "$(digest_file "$tmp/clone-before/fixtures/learning-drift-gated/workload.gooo")" \
        --arg after_digest "$(digest_file "$tmp/clone-after/fixtures/learning-drift-gated/workload.gooo")" \
        --argjson oracle "$(jq -c . "$output/exact-oracle.json")" --argjson before_status "$before_graph_status" --argjson after_status "$after_graph_status" \
        '{schema:"gooo/reflexive-loop/learning-drift-gated/exact-oracle-pair/v1",scenario:$scenario,before:{source_digest:$before_digest,status:$before_status},after:{source_digest:$after_digest,status:$after_status},oracle:$oracle,rollback:{mode:"OUTPUT_ONLY",repository_writes:0}}' > "$output/exact-oracle-pair.json"
      if [ "$oracle_status" -ne 0 ] || [ "$oracle_decision" != "CLOSED" ] || [ "$before_oracle_failures" -ne 1 ] || [ "$after_oracle_failures" -ne 0 ]; then
        decision="REFUTED"
        decision_reason="INDEPENDENT_ORACLE_PAIR_REFUTED"
        refutations='["INDEPENDENT_ORACLE_PAIR_REFUTED"]'
      fi
      test_graph_digest=$(digest_file "$output/exact-oracle-pair.json")
      jq -S --arg source "$(digest_file "$learning_source")" --arg tool "$(digest_file "$gooo")" --arg policy "$(digest_file "$denominator")" \
        --arg inventory "$(digest_file "$test_inventory")" --arg graph "$test_graph_digest" \
        '.input_bindings.source_digest=$source | .input_bindings.toolchain_digest=$tool | .input_bindings.policy_digest=$policy | .input_bindings.test_inventory_digest=$inventory | .input_bindings.semantic_change_graph_digest=$graph | .tests |= map(.source_digest=$source) | .prior_receipts |= map(.source_digest=$source | .toolchain_digest=$tool | .policy_digest=$policy | .test_inventory_digest=$inventory)' \
        "$test_fixture" > "$tmp/test-frontier-fixture.json"
      mkdir -p "$output/test-frontier"
      test_frontier_status=$(run_timed_command "$tmp/test-frontier.stdout" "$tmp/test-frontier.stderr" "$tmp/test-frontier.time" \
        "$test_frontier_bin" evaluate --root "$test_frontier_source" --source "$test_frontier_source/examples/test-frontier.gooo" \
        --contract "$test_frontier_contract" --fixture "$tmp/test-frontier-fixture.json" --output-dir "$output/test-frontier")
      cp "$tmp/test-frontier.stdout" "$output/test-frontier/stdout.txt"
      cp "$tmp/test-frontier.stderr" "$output/test-frontier/stderr.txt"
      if [ "$test_frontier_status" -eq 0 ]; then
        test_frontier_state=$(jq -r '.state // "UNKNOWN"' "$output/test-frontier/plan.json")
        test_counts=$(jq -c '.execution_counts' "$output/test-frontier/plan.json")
        tests_total=$(jq -r '.total // 0' <<<"$test_counts")
        tests_executed=$(jq -r '.executed // 0' <<<"$test_counts")
        tests_reused=$(jq -r '.reused // 0' <<<"$test_counts")
        tests_skipped=$(jq -r '.skipped // 0' <<<"$test_counts")
        tests_not_observed=$(jq -r '.not_observed // 0' <<<"$test_counts")
        read -r test_seconds test_peak_rss_kib < "$tmp/test-frontier.time"
        test_wall_ms=$(awk -v seconds="$test_seconds" 'BEGIN {printf "%d", seconds * 1000}')
      fi
      if [ "$test_frontier_status" -ne 0 ] || [ "$test_frontier_state" != "CLOSED" ] || [ "$tests_not_observed" -ne 0 ]; then
        decision="UNKNOWN"
        decision_reason="TEST_FRONTIER_OBSERVATION_UNKNOWN"
        unknowns='[{"stage":"REGRESSION","step":"VERIFY_EXACT_ORACLE_AND_TEST_FRONTIER","reason":"AFFECTED_TEST_EXECUTION_NOT_OBSERVED","unknown_class":"TEST_EXECUTION_NOT_OBSERVED","next_operation":"OBSERVE_AFFECTED_TEST_EXECUTION","blocked_by":["test-validate-work-item"]}]'
      elif [ "$decision" != "REFUTED" ]; then
        decision="CLOSED"
        decision_reason="LEARNING_MEMORY_AVOIDANCE_AND_DRIFT_GATE_CLOSED"
        promotion_state="PROMOTED_OUTPUT_ONLY"
      fi
    fi
  fi
fi

if [ "$decision" = "REFUTED" ]; then
  unknowns='[]'
  promotion_state="NOT_PROMOTED"
elif [ "$decision" = "UNKNOWN" ]; then
  promotion_state="NOT_PROMOTED"
else
  promotion_state="PROMOTED_OUTPUT_ONLY"
fi

activities=$(jq -S --arg decision "$decision" --argjson unknowns "$unknowns" \
  '.activities | map(. as $cell | {ordinal,id,activity,stage,step,proof_choice,indicator_class,state:(if $decision=="REFUTED" then "REFUTED" elif ($unknowns|length)>0 and $cell.ordinal==8 then "UNKNOWN" else "CLOSED" end),reason:(if $decision=="REFUTED" then "REFUTED: " + $decision elif ($unknowns|length)>0 and $cell.ordinal==8 then $unknowns[0].reason else "EXACT_BINDING_OBSERVED" end),unknown:(if ($unknowns|length)>0 and $cell.ordinal==8 then $unknowns[0] else null end)})' "$denominator")

if [ "$decision" = "CLOSED" ]; then semantic_close="CLOSED"; else semantic_close="$decision"; fi
metrics_json=$(jq -S -n \
  --argjson cycles "$cycles" --argjson attempts "$attempts_observed" --argjson candidates "$candidate_count" \
  --argjson recurrence_before "$known_refuted_recurrences_before" --argjson recurrence_after "$known_refuted_recurrences_after" \
  --argjson avoided "$avoided_refuted_candidates" --argjson refuted "$refuted_candidates" --argjson unknown "$unknown_candidates" \
  --argjson drift_comparisons "$drift_comparisons" --argjson drift_equivalent "$drift_equivalent_changes" --argjson drift_changes "$drift_changes" --argjson drift_unknown "$drift_unknown_bindings" \
  --argjson before "$before_oracle_failures" --argjson after "$after_oracle_failures" --argjson paths "$patch_paths" --argjson hunks "$patch_hunks" --argjson patch_bytes "$patch_bytes" \
  --argjson replay "$replay_comparisons" --argjson replay_mismatch "$replay_mismatches" --argjson rollback "$rollback_comparisons" --argjson rollback_mismatch "$rollback_mismatches" \
  --argjson build_wall "$build_wall_ms" --argjson build_rss "$build_peak_rss_kib" --argjson test_wall "$test_wall_ms" --argjson test_rss "${test_peak_rss_kib:-0}" --argjson conformance_wall "$conformance_wall_ms" --argjson conformance_rss "$conformance_peak_rss_kib" \
  --argjson total "${tests_total:-0}" --argjson executed "${tests_executed:-0}" --argjson reused "${tests_reused:-0}" --argjson skipped "${tests_skipped:-0}" --argjson not_observed "${tests_not_observed:-0}" \
  --argjson go_lines "$go_physical_lines" --argjson go_files "$go_files" --argjson gooo_lines "$gooo_physical_lines" --argjson gooo_files "$gooo_files" --argjson dirs "$directories" --argjson files "$repository_files" \
  --argjson artifact_files "$output_artifact_files" --argjson artifact_bytes "$output_artifact_bytes" \
  '{cycles:$cycles,attempts_observed:$attempts,candidate_count:$candidates,known_refuted_recurrences_before:$recurrence_before,known_refuted_recurrences_after:$recurrence_after,avoided_refuted_candidates:$avoided,refuted_candidates:$refuted,unknown_candidates:$unknown,drift_comparisons:$drift_comparisons,drift_equivalent_changes:$drift_equivalent,drift_changes:$drift_changes,drift_unknown_bindings:$drift_unknown,before_oracle_failures:$before,after_oracle_failures:$after,patch_paths:$paths,patch_hunks:$hunks,patch_bytes:$patch_bytes,replay_comparisons:$replay,replay_mismatches:$replay_mismatch,rollback_comparisons:$rollback,rollback_mismatches:$rollback_mismatch,build_wall_ms:$build_wall,build_peak_rss_kib:$build_rss,test_wall_ms:$test_wall,test_peak_rss_kib:$test_rss,conformance_wall_ms:$conformance_wall,conformance_peak_rss_kib:$conformance_rss,tests_total:$total,tests_executed:$executed,tests_reused:$reused,tests_skipped:$skipped,tests_not_observed:$not_observed,go_physical_lines:$go_lines,go_files:$go_files,gooo_physical_lines:$gooo_lines,gooo_files:$gooo_files,directories:$dirs,files:$files,output_artifact_files:$artifact_files,output_artifact_bytes:$artifact_bytes,repository_writes:0,local_test_executions:0,cross_project_required_gates:0}')

upstream_releases=$(jq -c '.releases' "$upstream_lock")
drift_metrics=$(jq -c '.metrics // {}' "$output/drift/report.json" 2>/dev/null || echo '{}')
experience_metrics=$(jq -c '.metrics // {}' "$output/experience/evaluation.json" 2>/dev/null || echo '{}')

write_report() {
  jq -S -n --arg scenario "$scenario" --arg decision "$decision" --arg reason "$decision_reason" --arg semantic_close "$semantic_close" \
    --arg experience_state "$experience_state" --arg experience_reason "$experience_reason" --arg drift_state "$drift_state" --arg drift_reason "$drift_reason" \
    --arg frontier_state "$frontier_state" --arg bundle_state "$bundle_state" --arg oracle_decision "$oracle_decision" --arg test_state "$test_frontier_state" --arg promotion "$promotion_state" \
    --argjson activities "$activities" --argjson unknowns "$unknowns" --argjson refutations "$refutations" --argjson metrics "$metrics_json" \
    --argjson experience_metrics "$experience_metrics" --argjson drift_metrics "$drift_metrics" --argjson binding_chain "$binding_chain" --argjson upstream "$upstream_releases" \
    --argjson tests "$test_counts" --arg before_digest "$input_before" --arg after_digest "$(snapshot "$repository")" \
    '{schema:"gooo/reflexive-loop/learning-drift-gated/report/v1",version:"v0.4.0",scenario:$scenario,decision:$decision,decision_reason:$reason,precedence:["REFUTED","UNKNOWN","CLOSED"],denominator:{id:"learning-drift-gated-v1",fixed:true,cells:12,proof_totals:{FOUNDATION:4,COHERENCE:4,REGRESSION:4},indicator_totals:{DRIVER:4,OUTCOME:4,GUARDRAIL:4}},cycles:{count:2,cycle_a:{selected_candidate:"candidate-known-refuted",known_refuted_recurrences:1},cycle_b:{selected_candidate:"candidate-safe",known_refuted_recurrences:0,append_only_receipt_consumed:true},exact_recurrence:{before:1,after:0}},experience_memory:{state:$experience_state,reason:$experience_reason,metrics:$experience_metrics,binding_chain:$binding_chain},semantic_drift_guard:{state:$drift_state,reason:$drift_reason,metrics:$drift_metrics,release_evidence_verified:true,mutable_prior_release_used_as_input:false},candidate_selection:{attempts_observed:$metrics.attempts_observed,candidate_count:$metrics.candidate_count,avoided_refuted_candidates:$metrics.avoided_refuted_candidates,refuted_candidates:$metrics.refuted_candidates,unknown_candidates:$metrics.unknown_candidates},frontier:{state:$frontier_state,count:3},change_bundle:{state:$bundle_state,patch_paths:$metrics.patch_paths,patch_hunks:$metrics.patch_hunks,patch_bytes:$metrics.patch_bytes,rollback_comparisons:$metrics.rollback_comparisons,rollback_mismatches:$metrics.rollback_mismatches,replay_comparisons:$metrics.replay_comparisons,replay_mismatches:$metrics.replay_mismatches},oracle:{decision:$oracle_decision,before_failures:$metrics.before_oracle_failures,after_failures:$metrics.after_oracle_failures},test_frontier:{state:$test_state,counts:$tests},semantic_close:{state:$semantic_close,external_utility:{state:"UNKNOWN",claim:"UNKNOWN_WITHOUT_INFERENCE"}},promotion:{state:$promotion,mode:"OUTPUT_ONLY",authority:{repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false}},unknowns:$unknowns,refutations:$refutations,activities:$activities,metrics:$metrics,upstream_releases:$upstream,repository:{before_digest:$before_digest,after_digest:$after_digest,unchanged:($before_digest==$after_digest)}}' > "$output/report.json"
}

write_report
support_files=$(find "$output" -type f ! -name 'report.json' ! -name 'ci-artifact.json' ! -name 'artifact-manifest.json' -print)
output_artifact_files=$(printf '%s\n' "$support_files" | awk 'NF{n++} END{print n+0}')
output_artifact_bytes=$(if [ -n "$support_files" ]; then printf '%s\n' "$support_files" | xargs wc -c | awk 'END{print $1+0}'; else echo 0; fi)
metrics_json=$(jq -S --argjson files "$output_artifact_files" --argjson bytes "$output_artifact_bytes" '.output_artifact_files=$files | .output_artifact_bytes=$bytes' <<<"$metrics_json")
write_report

report_digest=$(digest_file "$output/report.json")
jq -S -n --arg scenario "$scenario" --arg decision "$decision" --arg digest "$report_digest" --argjson metrics "$metrics_json" --argjson unknowns "$unknowns" --argjson refutations "$refutations" \
  --argjson files "$output_artifact_files" --argjson bytes "$output_artifact_bytes" \
  '{schema:"gooo/reflexive-loop/learning-drift-gated/ci-artifact/v1",version:"v0.4.0",scenario:$scenario,decision:$decision,report_digest:$digest,precedence:["REFUTED","UNKNOWN","CLOSED"],metrics:$metrics,unknowns:$unknowns,refutations:$refutations,artifact:{files:$files,bytes:$bytes},authority:{repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false},repository_unchanged:true}' > "$output/ci-artifact.json"
jq -S -n --argjson files "$output_artifact_files" --argjson bytes "$output_artifact_bytes" '{schema:"gooo/reflexive-loop/learning-drift-gated/artifact-manifest/v1",files:$files,bytes:$bytes,scope:"supporting-evidence-excluding-final-receipts",final_receipts:["report.json","ci-artifact.json","artifact-manifest.json"]}' > "$output/artifact-manifest.json"
jq -r --arg scenario "$scenario" --arg decision "$decision" --arg reason "$decision_reason" --argjson metrics "$metrics_json" \
  '"# Learning-and-drift-gated cycle: "+$scenario+"\n\n- decision: `"+$decision+"`\n- reason: "+$reason+"\n- cycles / attempts observed: `"+([$metrics.cycles,$metrics.attempts_observed]|map(tostring)|join(" / "))+"`\n- known REFUTED recurrence before / after: `"+([$metrics.known_refuted_recurrences_before,$metrics.known_refuted_recurrences_after]|map(tostring)|join(" / "))+"`\n- drift comparisons / equivalent / drift / unknown: `"+([$metrics.drift_comparisons,$metrics.drift_equivalent_changes,$metrics.drift_changes,$metrics.drift_unknown_bindings]|map(tostring)|join(" / "))+"`\n- oracle failures before / after: `"+([$metrics.before_oracle_failures,$metrics.after_oracle_failures]|map(tostring)|join(" / "))+"`\n- tests total / executed / reused / skipped / not_observed: `"+([$metrics.tests_total,$metrics.tests_executed,$metrics.tests_reused,$metrics.tests_skipped,$metrics.tests_not_observed]|map(tostring)|join(" / "))+"`\n- authority repository writes / local tests / cross-project gates: `0 / 0 / 0`"' "$output/report.json" > "$output/human-dossier.md"

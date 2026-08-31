#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: integrated-loop.sh GOOO REPOSITORY EXTERNAL_RELEASE_DIR OUTPUT SCENARIO" >&2
  exit 64
fi

gooo=$1
repository=$(realpath "$2")
external=$(realpath "$3")
output=$(realpath -m "$4")
scenario=$5
lock="$repository/contracts/external-release-locks-v1.json"

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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=()
fail() {
  local flag=$1
  local reason=$2
  eval "$flag=false"
  failures+=("$reason")
}

snapshot() {
  find "$repository" -path "$repository/.git" -prune -o -type f -print0 |
    sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print "sha256:" $1}'
}

digest() {
  sha256sum "$1" | awk '{print "sha256:" $1}'
}

copy_required() {
  local source=$1
  local destination=$2
  if [ ! -f "$source" ]; then
    echo "missing external input: $source" >&2
    exit 67
  fi
  cp "$source" "$destination"
}

budget_repository=$(jq -r '.releases.meta_budget.repository' "$lock")
budget_tag=$(jq -r '.releases.meta_budget.tag' "$lock")
budget_target=$(jq -r '.releases.meta_budget.target_commit_sha' "$lock")
budget_manifest_name=$(jq -r '.releases.meta_budget.manifest.asset_name' "$lock")
budget_manifest_digest=$(jq -r '.releases.meta_budget.manifest.sha256' "$lock")
budget_evidence_name=$(jq -r '.releases.meta_budget.evidence.asset_name' "$lock")
budget_evidence_size=$(jq -r '.releases.meta_budget.evidence.size_bytes' "$lock")
budget_evidence_digest=$(jq -r '.releases.meta_budget.evidence.sha256' "$lock")

lattice_repository=$(jq -r '.releases.resolution_lattice.repository' "$lock")
lattice_tag=$(jq -r '.releases.resolution_lattice.tag' "$lock")
lattice_target=$(jq -r '.releases.resolution_lattice.target_commit_sha' "$lock")
lattice_manifest_name=$(jq -r '.releases.resolution_lattice.manifest.asset_name' "$lock")
lattice_manifest_digest=$(jq -r '.releases.resolution_lattice.manifest.sha256' "$lock")
lattice_evidence_name=$(jq -r '.releases.resolution_lattice.evidence.asset_name' "$lock")
lattice_evidence_size=$(jq -r '.releases.resolution_lattice.evidence.size_bytes' "$lock")
lattice_evidence_digest=$(jq -r '.releases.resolution_lattice.evidence.sha256' "$lock")

budget_release="$tmp/budget-release.json"
budget_manifest="$tmp/budget-manifest.json"
budget_archive="$tmp/budget-evidence.tar.gz"
lattice_release="$tmp/lattice-release.json"
lattice_manifest="$tmp/lattice-manifest.json"
lattice_archive="$tmp/lattice-evidence.zip"
copy_required "$external/budget-release.json" "$budget_release"
copy_required "$external/budget-manifest.json" "$budget_manifest"
copy_required "$external/budget-evidence.tar.gz" "$budget_archive"
copy_required "$external/lattice-release.json" "$lattice_release"
copy_required "$external/lattice-manifest.json" "$lattice_manifest"
copy_required "$external/lattice-evidence.zip" "$lattice_archive"

case "$scenario" in
  normal)
    ;;
  tampered-budget-digest)
    jq -S '.evidence_bundle.sha256="sha256:tampered-budget-evidence"' "$budget_manifest" > "$tmp/budget-manifest.mutated.json"
    mv "$tmp/budget-manifest.mutated.json" "$budget_manifest"
    ;;
  stale-resolution-target)
    jq -S '.target_commitish="0000000000000000000000000000000000000000"' "$lattice_release" > "$tmp/lattice-release.mutated.json"
    mv "$tmp/lattice-release.mutated.json" "$lattice_release"
    ;;
  missing-six-field-unknown|release-replay|authority-escalation)
    ;;
  *)
    echo "unknown scenario: $scenario" >&2
    exit 68
    ;;
esac

budget_release_ok=true
budget_manifest_ok=true
lattice_release_ok=true
lattice_manifest_ok=true
budget_plan_ok=true
resolution_unknown_ok=true
apply_ok=false
oracle_ok=false
pair_ok=false
promotion_ok=false

if ! jq -e --arg repo "$budget_repository" --arg tag "$budget_tag" --arg target "$budget_target" \
  '.immutable==true and .tag_name==$tag and .target_commitish==$target' \
  "$budget_release" >/dev/null 2>&1; then
  fail budget_release_ok "BUDGET_RELEASE_IMMUTABLE_OR_TARGET"
fi
if ! jq -e --arg name "$budget_manifest_name" --arg digest "$budget_manifest_digest" --argjson size "$budget_evidence_size" \
  '.assets | any(.[]; .name==$name and .digest==$digest) and any(.[]; .name=="gooo-meta-budget-evidence-v0.1.0.tar.gz" and .size==$size)' \
  "$budget_release" >/dev/null 2>&1; then
  fail budget_release_ok "BUDGET_RELEASE_ASSET_IDENTITY"
fi
if [ "$(digest "$budget_manifest")" != "$budget_manifest_digest" ]; then
  fail budget_manifest_ok "BUDGET_MANIFEST_DIGEST_MISMATCH"
fi
if [ "$(digest "$budget_archive")" != "$budget_evidence_digest" ] || [ "$(wc -c < "$budget_archive" | awk '{print $1 + 0}')" -ne "$budget_evidence_size" ]; then
  fail budget_manifest_ok "BUDGET_EVIDENCE_DIGEST_MISMATCH"
fi
if ! jq -e --arg repo "$budget_repository" --arg tag "$budget_tag" --arg target "$budget_target" \
  --arg name "$budget_evidence_name" --arg evidence_digest "$budget_evidence_digest" --argjson evidence_size "$budget_evidence_size" \
  '.schema=="gooo/meta-budget/release-manifest/v1" and .repository==$repo and .release.tag==$tag and .release.target_commit_sha==$target and
   .evidence_bundle.name==$name and .evidence_bundle.sha256==$evidence_digest and .evidence_bundle.size_bytes==$evidence_size and
   .checksums.covers==["gooo-meta-budget-v0.1.0-manifest.json","gooo-meta-budget-evidence-v0.1.0.tar.gz"] and
   .verification.release_immutability.enabled==true' "$budget_manifest" >/dev/null 2>&1; then
  fail budget_manifest_ok "BUDGET_MANIFEST_CONTENT_MISMATCH"
fi

mkdir -p "$tmp/budget-extracted"
if ! tar -xzf "$budget_archive" -C "$tmp/budget-extracted"; then
  fail budget_plan_ok "BUDGET_EVIDENCE_UNREADABLE"
fi
if [ "$scenario" = "authority-escalation" ] && [ -f "$tmp/budget-extracted/paired-decision.json" ]; then
  jq -S '.requested_plan.privilege_level="repository-write"' "$tmp/budget-extracted/paired-decision.json" > "$tmp/budget-extracted/paired-decision.mutated.json"
  mv "$tmp/budget-extracted/paired-decision.mutated.json" "$tmp/budget-extracted/paired-decision.json"
fi
budget_decision="$tmp/budget-extracted/paired-decision.json"
budget_artifact_report="$tmp/budget-extracted/artifact-report.json"
if [ ! -f "$budget_decision" ] || [ ! -f "$budget_artifact_report" ]; then
  fail budget_plan_ok "BUDGET_CONSUMER_ENTRYPOINT_MISSING"
else
  if ! jq -e '
    .schema=="gooo/meta-budget/decision/v1" and .status=="CLOSED" and
    .requested_plan=={
      "id":"select-next-meta-operation",
      "kind":"STANDARD",
      "semantic_resolution":"full",
      "proof_denominator":6,
      "privilege_level":"read-only",
      "operations":["reuse-verified-evidence","defer-conformance-replay"],
      "allowed":true
    } and
    .pair.exact_baseline_pair==true and .pair.exact_candidate_pair==true and
    .pair.same_workload==true and .pair.same_input_tool_contract==true and
    .pair.improvement_proven==true and .pair.utility_inferred==false and
    .baseline_after.repository_writes==0 and .candidate_after.repository_writes==0 and
    ([.meta_metrics[].classification]|sort)==["COHERENCE","DRIVER","FOUNDATION","GUARDRAIL","OUTCOME","REGRESSION"] and
    (.meta_metrics|length)==6 and
    all(.meta_metrics[]; .numerator==6 and .denominator==6 and
      .binding.metric_id==.id and (.binding.meta_activity_id|type)=="string" and
      (.binding.source_id|type)=="string" and (.binding.ir_id|type)=="string" and
      (.binding.generated_artifact_id|type)=="string" and (.binding.evaluator_id|type)=="string")
  ' "$budget_decision" >/dev/null 2>&1; then
    if [ "$scenario" = "authority-escalation" ]; then
      fail budget_plan_ok "AUTHORITY_ESCALATION"
    else
      fail budget_plan_ok "BUDGET_EXECUTION_PLAN_NOT_ALLOWED"
    fi
  fi
  if ! jq -e --slurpfile pair "$budget_decision" \
    '.decision.schema=="gooo/meta-budget/decision/v1" and .decision.status=="CLOSED" and .decision.requested_plan==$pair[0].requested_plan and .decision.pair==$pair[0].pair' \
    "$budget_artifact_report" >/dev/null 2>&1; then
    fail budget_plan_ok "BUDGET_SCENARIO_BINDING_MISMATCH"
  fi
fi

if ! jq -e --arg repo "$lattice_repository" --arg tag "$lattice_tag" --arg target "$lattice_target" \
  '.immutable==true and .tag_name==$tag and .target_commitish==$target' \
  "$lattice_release" >/dev/null 2>&1; then
  fail lattice_release_ok "LATTICE_RELEASE_IMMUTABLE_OR_TARGET"
fi
if ! jq -e --arg name "$lattice_manifest_name" --arg digest "$lattice_manifest_digest" --argjson size "$lattice_evidence_size" \
  '.assets | any(.[]; .name==$name and .digest==$digest) and any(.[]; .name=="gooo-resolution-lattice-v0.1.0-evidence.zip" and .size==$size)' \
  "$lattice_release" >/dev/null 2>&1; then
  fail lattice_release_ok "LATTICE_RELEASE_ASSET_IDENTITY"
fi
if [ "$(digest "$lattice_manifest")" != "$lattice_manifest_digest" ]; then
  fail lattice_manifest_ok "LATTICE_MANIFEST_DIGEST_MISMATCH"
fi
if [ "$(digest "$lattice_archive")" != "$lattice_evidence_digest" ] || [ "$(wc -c < "$lattice_archive" | awk '{print $1 + 0}')" -ne "$lattice_evidence_size" ]; then
  fail lattice_manifest_ok "LATTICE_EVIDENCE_DIGEST_MISMATCH"
fi
if ! jq -e --arg repo "$lattice_repository" --arg tag "$lattice_tag" --arg target "$lattice_target" \
  --arg evidence_name "$lattice_evidence_name" --arg evidence_digest "${lattice_evidence_digest#sha256:}" --argjson evidence_size "$lattice_evidence_size" \
  '.schema=="gooo/resolution-lattice/release-manifest/v1" and
   .release.repository==$repo and .release.tag==$tag and .release.tag_target_sha==$target and
   .release.immutable_policy_enabled==true and .release.immutable_verified_after_publish==true and
   .provenance.artifact_size_bytes==$evidence_size and .provenance.artifact_digest==( "sha256:" + $evidence_digest ) and
   .consumer_entrypoints.evidence_bundle==$evidence_name and
   .consumer_entrypoints.normal_receipts=="receipts/normal.json" and
   .conformance.cells=={"numerator":12,"denominator":12} and .conformance.proof_choices.FOUNDATION=={"numerator":4,"denominator":4} and
   .conformance.proof_choices.COHERENCE=={"numerator":4,"denominator":4} and .conformance.proof_choices.REGRESSION=={"numerator":4,"denominator":4} and
   .conformance.indicator_classes.DRIVER=={"numerator":4,"denominator":4} and .conformance.indicator_classes.OUTCOME=={"numerator":4,"denominator":4} and
   .conformance.indicator_classes.GUARDRAIL=={"numerator":4,"denominator":4} and
   .conformance.repository_writes==0 and .conformance.local_tests_run==0' "$lattice_manifest" >/dev/null 2>&1; then
  fail lattice_manifest_ok "LATTICE_MANIFEST_CONTENT_MISMATCH"
fi

mkdir -p "$tmp/lattice-extracted"
if ! unzip -q "$lattice_archive" -d "$tmp/lattice-extracted"; then
  fail resolution_unknown_ok "LATTICE_EVIDENCE_UNREADABLE"
fi
if [ "$scenario" = "missing-six-field-unknown" ] && [ -f "$tmp/lattice-extracted/cases/improvement-unknown.json" ]; then
  jq -S 'del(.improvement.claim.blocked_by)' "$tmp/lattice-extracted/cases/improvement-unknown.json" > "$tmp/lattice-extracted/cases/improvement-unknown.mutated.json"
  mv "$tmp/lattice-extracted/cases/improvement-unknown.mutated.json" "$tmp/lattice-extracted/cases/improvement-unknown.json"
fi
if [ "$scenario" = "release-replay" ] && [ -f "$tmp/lattice-extracted/receipts/improvement-unknown.json" ]; then
  jq -S '.case_id="normal" | .receipts |= map(.case_id="normal")' "$tmp/lattice-extracted/receipts/improvement-unknown.json" > "$tmp/lattice-extracted/receipts/improvement-unknown.mutated.json"
  mv "$tmp/lattice-extracted/receipts/improvement-unknown.mutated.json" "$tmp/lattice-extracted/receipts/improvement-unknown.json"
fi
lattice_case="$tmp/lattice-extracted/cases/improvement-unknown.json"
lattice_receipt="$tmp/lattice-extracted/receipts/improvement-unknown.json"
if [ ! -f "$lattice_case" ] || [ ! -f "$lattice_receipt" ]; then
  fail resolution_unknown_ok "LATTICE_CONSUMER_ENTRYPOINT_MISSING"
else
  if ! jq -e '
    .schema=="gooo/resolution-lattice/v1" and .decision=="RESOLUTION_LATTICE_UNKNOWN" and .case_id=="improvement-unknown" and .state=="UNKNOWN" and
    .improvement.claim.state=="UNKNOWN" and .improvement.claim.stage=="IMPROVEMENT" and
    (.improvement.claim.blocked_by|type)=="array" and .authority.observation_mode=="READ_ONLY" and
    .authority.read_only==true and .authority.repository_writes==0 and .authority.input_repository_writes==0 and
    (.improvement.claim as $claim | ["stage","step","reason","unknown_class","next_operation","blocked_by"] | all(. as $field | $claim | has($field)))
  ' "$lattice_case" >/dev/null 2>&1; then
    fail resolution_unknown_ok "RESOLUTION_UNKNOWN_SIX_FIELDS_MISSING"
  fi
  if ! jq -e --slurpfile case "$lattice_case" '
    .schema=="gooo/resolution-lattice/receipts/v1" and .case_id=="improvement-unknown" and (.receipts|length)==2 and
    all(.receipts[]; . as $receipt |
      $receipt.schema=="gooo/resolution-lattice/receipt/v1" and $receipt.case_id=="improvement-unknown" and
      $receipt.input_digest==$case[0].input_digest and $receipt.tool_digest==$case[0].tool_digest and
      $receipt.contract_digest==$case[0].contract_digest and $receipt.source_digest==($case[0].edges[0].source_digest) and
      (any($case[0].edges[]; .receipt.id==$receipt.id)))
  ' "$lattice_receipt" >/dev/null 2>&1; then
    if [ "$scenario" = "release-replay" ]; then
      fail resolution_unknown_ok "RELEASE_REPLAY"
    else
      fail resolution_unknown_ok "RESOLUTION_RECEIPT_BINDING_MISMATCH"
    fi
  fi
fi

if [ "$(jq -r '.cross_project_required_gates' "$lock")" -ne 0 ]; then
  fail resolution_unknown_ok "CROSS_PROJECT_REQUIRED_GATE_NONZERO"
fi

input_before=$(snapshot)
source_file="$repository/examples/reflexive-loop/main.gooo"
workload_file="$repository/fixtures/use-case/workload.gooo"
source_digest=$(digest "$source_file")
workload_digest=$(digest "$workload_file")
contract_digest=$(digest "$repository/contracts/allowed-transformations-v1.json")
tool_digest=$(digest "$gooo")
mkdir -p "$output/input" "$output/clone/before" "$output/clone/after" "$output/metrics" "$output/external"
cp "$budget_manifest" "$output/external/meta-budget-manifest.json"
cp "$lattice_manifest" "$output/external/resolution-lattice-manifest.json"
cp "$budget_release" "$output/external/meta-budget-release.json"
cp "$lattice_release" "$output/external/resolution-lattice-release.json"

if [ -f "$budget_decision" ] && [ -f "$lattice_case" ] && [ -f "$lattice_receipt" ]; then
  jq -S -n --arg budget_release_id "$(jq -r '.id|tostring' "$budget_release")" \
    --arg lattice_release_id "$(jq -r '.id|tostring' "$lattice_release")" \
    --arg budget_manifest_digest "$budget_manifest_digest" --arg budget_evidence_digest "$budget_evidence_digest" \
    --arg lattice_manifest_digest "$lattice_manifest_digest" --arg lattice_evidence_digest "$lattice_evidence_digest" \
    --arg budget_target "$budget_target" --arg lattice_target "$lattice_target" \
    --slurpfile plan "$budget_decision" --slurpfile case "$lattice_case" --slurpfile receipt "$lattice_receipt" \
    '{schema:"gooo/reflexive-loop/external-input/v1",budget:{release_id:$budget_release_id,repository:"kimjooyoon/gooo-meta-budget",tag:"v0.1.0",target_commit_sha:$budget_target,manifest_digest:$budget_manifest_digest,evidence_digest:$budget_evidence_digest,requested_plan:$plan[0].requested_plan},resolution:{release_id:$lattice_release_id,repository:"kimjooyoon/gooo-resolution-lattice",tag:"v0.1.0",target_commit_sha:$lattice_target,manifest_digest:$lattice_manifest_digest,evidence_digest:$lattice_evidence_digest,case_id:$case[0].case_id,receipt_ids:[$receipt[0].receipts[].id],unknown:$case[0].improvement.claim}}' \
    > "$output/input/external-input.json"
else
  jq -S -n --arg reason "EXTERNAL_ENTRYPOINT_UNAVAILABLE" '{schema:"gooo/reflexive-loop/external-input/v1",state:"REFUTED",reason:$reason}' > "$output/input/external-input.json"
fi

if [ "${#failures[@]}" -eq 0 ]; then
  jq -S -n \
    --arg source_digest "$source_digest" --arg workload_digest "$workload_digest" --arg contract_digest "$contract_digest" --arg tool_digest "$tool_digest" \
    --arg budget_manifest_digest "$budget_manifest_digest" --arg budget_evidence_digest "$budget_evidence_digest" \
    --arg lattice_manifest_digest "$lattice_manifest_digest" --arg lattice_evidence_digest "$lattice_evidence_digest" \
    --arg resolution_case_id "$(jq -r '.case_id' "$lattice_case")" \
    --slurpfile plan "$budget_decision" --slurpfile unknown "$lattice_case" --slurpfile receipt "$lattice_receipt" \
    '{schema:"gooo/reflexive-loop/integrated-proposal/v1",state:"CLOSED",selector_activity:"SelectAllowedTransformation",apply_activity:"ApplyAllowedMetaActivity",transformation_id:"canonicalize-workload-source",source_digest:$source_digest,workload_digest:$workload_digest,contract_digest:$contract_digest,tool_digest:$tool_digest,external_inputs:{meta_budget_manifest_digest:$budget_manifest_digest,meta_budget_evidence_digest:$budget_evidence_digest,resolution_lattice_manifest_digest:$lattice_manifest_digest,resolution_lattice_evidence_digest:$lattice_evidence_digest},execution_plan:{id:$plan[0].requested_plan.id,kind:$plan[0].requested_plan.kind,semantic_resolution:$plan[0].requested_plan.semantic_resolution,proof_denominator:$plan[0].requested_plan.proof_denominator,privilege_level:$plan[0].requested_plan.privilege_level,selected_operation:$plan[0].requested_plan.operations[0],deferred_operation:$plan[0].requested_plan.operations[1],workload_pair:"same-input-tool-contract",apply_mode:"reuse-verified-evidence",utility_mode:"preserve-unknown-no-inference"},resolution_binding:{case_id:$resolution_case_id,state:$unknown[0].improvement.claim.state,metric:"performance/utility",unknown:$unknown[0].improvement.claim,receipt_ids:[$receipt[0].receipts[].id]},authority_scope:"temporary_output",proposal_replay_policy:"unique_proposal_digest",next_operation:"APPLY_ALLOWED_META_ACTIVITY"}' \
    > "$tmp/proposal-body.json"
  proposal_digest=$(digest "$tmp/proposal-body.json")
  jq -S --arg proposal_id "$proposal_digest" '. + {proposal_id:$proposal_id}' "$tmp/proposal-body.json" > "$output/proposal.json"
else
  validation_reason=$(IFS=,; echo "${failures[*]}")
  jq -S -n --arg reason "$validation_reason" --arg proposal_id "" \
    '{schema:"gooo/reflexive-loop/integrated-proposal/v1",state:"REFUTED",reason:$reason,proposal_id:$proposal_id,next_operation:"ROLLBACK_CANDIDATE",authority_scope:"temporary_output"}' \
    > "$output/proposal.json"
fi

jq -S -n '{schema:"gooo/reflexive-loop/oracle-verdict/v1",decision:"UNKNOWN",equivalent:false,counterexamples:[]}' > "$output/oracle.json"
jq -S -n '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"UNKNOWN"}' > "$output/workload-pair.json"
jq -S -n --arg before "$input_before" '{schema:"gooo/reflexive-loop/repository-effect/v1",before_digest:$before,after_digest:null,repository_writes:null}' > "$output/repository-effect.json"
jq -S -n --arg state "REFUTED" --arg reason "NOT_APPLIED" \
  '{schema:"gooo/reflexive-loop/rollback-receipt/v1",decision:$state,reason:$reason,mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}' > "$output/rollback.json"

if [ "${#failures[@]}" -eq 0 ]; then
  if bash "$repository/scripts/apply.sh" "$workload_file" "$output/proposal.json" "$output/clone/after/workload.gooo" "ApplyAllowedMetaActivity"; then
    apply_ok=true
    cp "$output/input/external-input.json" "$output/clone/after/external-input.json"
    jq -S '.execution_plan' "$output/proposal.json" > "$output/clone/after/execution-plan.json"
    cp "$workload_file" "$output/clone/before/workload.gooo"

    run_workload() {
      local label=$1
      local source=$2
      local result="$output/clone/$label/check.json"
      local stderr="$output/clone/$label/check.stderr"
      local timing="$output/clone/$label/time.tsv"
      local status
      mkdir -p "$output/clone/$label"
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
        --arg source_digest "$(digest "$source")" --slurpfile result "$result" \
        '{label:$label,source:$source,source_digest:$source_digest,status:$status,wall_ms:$wall_ms,peak_rss_kib:$peak_rss_kib,semantic_digest:($result[0].semantic_hash // null),result:$result[0]}' \
        > "$output/clone/$label/measurement.json"
    }

    run_workload before "$output/clone/before/workload.gooo"
    run_workload after "$output/clone/after/workload.gooo"
    "$gooo" graph dump "$output/clone/before/workload.gooo" > "$output/clone/before/graph.json"
    "$gooo" graph dump "$output/clone/after/workload.gooo" > "$output/clone/after/graph.json"
    if bash "$repository/scripts/oracle.sh" "$output/clone/before/graph.json" "$output/clone/after/graph.json" "$output/oracle.json"; then
      oracle_ok=$(jq -r '.decision=="CLOSED"' "$output/oracle.json")
    fi
    before_status=$(jq -r '.status' "$output/clone/before/measurement.json")
    after_status=$(jq -r '.status' "$output/clone/after/measurement.json")
    before_digest=$(jq -r '.source_digest' "$output/clone/before/measurement.json")
    after_digest=$(jq -r '.source_digest' "$output/clone/after/measurement.json")
    if [ "$before_status" -eq 0 ] && [ "$after_status" -eq 0 ] && [ "$oracle_ok" = true ]; then
      pair_ok=true
      jq -S -n --arg input_digest "$workload_digest" --arg contract_digest "$contract_digest" --arg tool_digest "$tool_digest" \
        --slurpfile before "$output/clone/before/measurement.json" --slurpfile after "$output/clone/after/measurement.json" \
        --slurpfile oracle "$output/oracle.json" \
        '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"CLOSED",exact_identity:true,input_digest:$input_digest,contract_digest:$contract_digest,tool_digest:$tool_digest,clone_created:true,applied:true,apply_activity:"ApplyAllowedMetaActivity",before:$before[0],after:$after[0],oracle_decision:$oracle[0].decision,rollback:{mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}}' > "$output/workload-pair.json"
    else
      jq -S -n --arg reason "WORKLOAD_PAIR_OR_ORACLE_REFUTED" \
        '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"REFUTED",exact_identity:false,reason:$reason}' > "$output/workload-pair.json"
    fi
  fi
fi

input_after=$(snapshot)
jq -S --arg after "$input_after" \
  '.after_digest=$after | .repository_writes=(if .before_digest==$after then 0 else 1 end)' \
  "$output/repository-effect.json" > "$tmp/repository-effect.json"
mv "$tmp/repository-effect.json" "$output/repository-effect.json"
if [ "$(jq -r '.repository_writes' "$output/repository-effect.json")" -ne 0 ]; then
  failures+=("INPUT_REPOSITORY_CHANGED")
fi

if [ "$apply_ok" = true ] && [ "$pair_ok" = true ] && [ "$oracle_ok" = true ] && [ "$(jq -r '.repository_writes' "$output/repository-effect.json")" -eq 0 ]; then
  promotion_ok=true
  jq -S -n '{schema:"gooo/reflexive-loop/rollback-receipt/v1",decision:"PROMOTED",mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output",boundary:"promotion-retains-recoverable-candidate"}' > "$output/rollback.json"
fi

if [ "$oracle_ok" != true ] && [ "$apply_ok" = true ]; then
  failures+=("INDEPENDENT_ORACLE_NOT_CLOSED")
fi
if [ "$pair_ok" != true ] && [ "$apply_ok" = true ]; then
  failures+=("EXACT_WORKLOAD_PAIR_NOT_CLOSED")
fi

validation_reason=""
if [ "${#failures[@]}" -gt 0 ]; then
  validation_reason=$(IFS=,; echo "${failures[*]}")
fi
report_decision="REFUTED"
[ "$promotion_ok" = true ] && report_decision="CLOSED"

jq -S -n \
  --arg scenario "$scenario" --arg decision "$report_decision" \
  --arg source_digest "$source_digest" --arg tool_digest "$tool_digest" \
  --arg proposal_id "$(jq -r '.proposal_id // ""' "$output/proposal.json")" \
  --arg validation_reason "$validation_reason" \
  --argjson budget_release_ok "$budget_release_ok" --argjson budget_manifest_ok "$budget_manifest_ok" \
  --argjson lattice_release_ok "$lattice_release_ok" --argjson lattice_manifest_ok "$lattice_manifest_ok" \
  --argjson budget_plan_ok "$budget_plan_ok" --argjson resolution_unknown_ok "$resolution_unknown_ok" \
  --argjson apply_ok "$apply_ok" --argjson oracle_ok "$oracle_ok" --argjson pair_ok "$pair_ok" --argjson promotion_ok "$promotion_ok" \
  --slurpfile unknown "$lattice_case" --slurpfile external_input "$output/input/external-input.json" \
  --slurpfile proposal "$output/proposal.json" --slurpfile oracle "$output/oracle.json" --slurpfile pair "$output/workload-pair.json" \
  'def state($ok): if $ok then "CLOSED" else "REFUTED" end;
   def reason($ok;$closed): if $ok then $closed else $validation_reason end;
   ($unknown[0].improvement.claim // {stage:null,step:null,reason:null,unknown_class:null,next_operation:null,blocked_by:null}) as $u |
   [
     {id:"BUDGET_RELEASE_IMMUTABLE",activity:"ConsumeImmutableMetaBudgetRelease",stage:"OBSERVE",step:"VERIFY_RELEASE_IMMUTABILITY_TARGET_AND_ASSET",state:state($budget_release_ok),reason:reason($budget_release_ok;"BUDGET_RELEASE_VERIFIED"),next_operation:(if $budget_release_ok then "NONE" else "REFETCH_EXACT_IMMUTABLE_RELEASE" end),blocked_by:[]},
     {id:"BUDGET_MANIFEST_EXACT",activity:"BindMetaBudgetManifest",stage:"OBSERVE",step:"VERIFY_MANIFEST_AND_EVIDENCE_DIGEST",state:state($budget_manifest_ok),reason:reason($budget_manifest_ok;"BUDGET_MANIFEST_EVIDENCE_BOUND"),next_operation:(if $budget_manifest_ok then "NONE" else "RESTORE_PINNED_BUDGET_ASSET" end),blocked_by:[]},
     {id:"LATTICE_RELEASE_IMMUTABLE",activity:"ConsumeImmutableResolutionRelease",stage:"OBSERVE",step:"VERIFY_RELEASE_IMMUTABILITY_TARGET_AND_ASSET",state:state($lattice_release_ok),reason:reason($lattice_release_ok;"LATTICE_RELEASE_VERIFIED"),next_operation:(if $lattice_release_ok then "NONE" else "REFETCH_EXACT_IMMUTABLE_RELEASE" end),blocked_by:[]},
     {id:"LATTICE_MANIFEST_EXACT",activity:"BindResolutionLatticeManifest",stage:"OBSERVE",step:"VERIFY_MANIFEST_AND_EVIDENCE_DIGEST",state:state($lattice_manifest_ok),reason:reason($lattice_manifest_ok;"LATTICE_MANIFEST_EVIDENCE_BOUND"),next_operation:(if $lattice_manifest_ok then "NONE" else "RESTORE_PINNED_LATTICE_ASSET" end),blocked_by:[]},
     {id:"BUDGET_PLAN_SELECTED",activity:"SelectBudgetAllowedExecutionPlan",stage:"PROPOSE",step:"SELECT_ALLOWED_EXECUTION_PLAN",state:state($budget_plan_ok),reason:reason($budget_plan_ok;"BUDGET_PLAN_SELECTED"),next_operation:(if $budget_plan_ok then "APPLY_ALLOWED_META_ACTIVITY" else "ROLLBACK_CANDIDATE" end),blocked_by:[]},
     {id:"RESOLUTION_UNKNOWN_PRESERVED",activity:"PreserveResolutionUnknown",stage:"PROPOSE",step:"PRESERVE_PERFORMANCE_UTILITY_UNKNOWN",state:state($resolution_unknown_ok),reason:reason($resolution_unknown_ok;"SIX_FIELD_UNKNOWN_PRESERVED"),next_operation:(if $resolution_unknown_ok then "NONE" else "RESTORE_COMPLETE_UNKNOWN_RECEIPT" end),blocked_by:[]},
     {id:"PROPOSAL_APPLY_BOUND",activity:"ApplyBudgetSelectedMetaActivity",stage:"APPLY",step:"APPLY_TO_TEMPORARY_OUTPUT",state:state($apply_ok),reason:reason($apply_ok;"TEMPORARY_APPLY_CLOSED"),next_operation:(if $apply_ok then "VERIFY_INDEPENDENT_ORACLE" else "ROLLBACK_CANDIDATE" end),blocked_by:[]},
     {id:"ORACLE_PROMOTE_ROLLBACK",activity:"VerifyPromoteOrRollback",stage:"PROMOTE",step:"VERIFY_ORACLE_THEN_PROMOTE_OR_ROLLBACK",state:state($promotion_ok),reason:reason($promotion_ok;"PROMOTED_WITH_UTILITY_UNKNOWN"),next_operation:(if $promotion_ok then "RETAIN_OUTPUT_ONLY_ROLLBACK_BOUNDARY" else "ROLLBACK_CANDIDATE" end),blocked_by:[]}
   ] as $cells |
   {schema:"gooo/reflexive-loop/integrated-conformance/v1",scenario:$scenario,decision:$decision,precedence:["REFUTED","UNKNOWN","CLOSED"],cells:$cells,summary:{total:($cells|length),closed:([$cells[]|select(.state=="CLOSED")]|length),unknown:([$cells[]|select(.state=="UNKNOWN")]|length),refuted:([$cells[]|select(.state=="REFUTED")]|length)},external_inputs:$external_input[0],proposal_digest:$proposal_id,proposal:$proposal[0],resolution_unknown:{metric:"performance/utility",state:"UNKNOWN",stage:$u.stage,step:$u.step,reason:$u.reason,unknown_class:$u.unknown_class,next_operation:$u.next_operation,blocked_by:$u.blocked_by,preserved_exactly:$resolution_unknown_ok},runtime:{oracle:$oracle[0],workload_pair:$pair[0]},lifecycle:{sequence:["PROPOSE","TEMP_APPLY","INDEPENDENT_ORACLE","PROMOTE","ROLLBACK_BOUNDARY"],promotion:(if $promotion_ok then "PROMOTED" else "NOT_PROMOTED" end),rollback:{mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}},authority:{repository_writes:0,cross_project_required_gates:0,input_repository_unchanged:true,local_tests_run:0},bindings:{external_inputs_affect_proposal:true,execution_plan_affects_apply:true,resolution_unknown_affects_utility_claim:true,provenance_only:false,source_file:"examples/reflexive-loop/main.gooo",source_digest:$source_digest,ir_node_kind:"Activity",evaluator:"scripts/integrated-loop.sh"},validation_reason:$validation_reason}' > "$output/report.json"

while IFS=$'\t' read -r cell state activity reason; do
  numerator=0
  [ "$state" = "CLOSED" ] && numerator=1
  jq -S -n --arg cell "$cell" --arg state "$state" --arg activity "$activity" --arg reason "$reason" \
    --arg source_digest "$source_digest" --argjson numerator "$numerator" \
    '{schema:"gooo/reflexive-loop/integrated-metric/v1",id:("gooo.metric.reflexive.integration." + ($cell|ascii_downcase|gsub("_";"-"))),cell:$cell,activity:$activity,source_file:"examples/reflexive-loop/main.gooo",source_digest:$source_digest,ir_node_kind:"Activity",generated_artifact:("integration/metrics/" + ($cell|ascii_downcase|gsub("_";"-")) + ".json"),evaluator:"scripts/integrated-loop.sh",numerator:$numerator,denominator:1,state:$state,reason:$reason}' \
    > "$output/metrics/$(printf '%s' "$cell" | tr '[:upper:]' '[:lower:]' | tr '_' '-').json"
done < <(jq -r '.cells[]|[.id,.state,.activity,.reason]|@tsv' "$output/report.json")

artifact_files=$(find "$output" -type f ! -name 'integration-artifact.json' | wc -l | awk '{print $1 + 0}')
artifact_bytes=$(find "$output" -type f ! -name 'integration-artifact.json' -print0 | xargs -0 -r wc -c | awk 'END {print $1 + 0}')
jq -S -n --arg scenario "$scenario" --arg report_digest "$(digest "$output/report.json")" \
  --argjson artifact_files "$artifact_files" --argjson artifact_bytes "$artifact_bytes" \
  --slurpfile report "$output/report.json" \
  '{schema:"gooo/reflexive-loop/integrated-ci-artifact/v1",scenario:$scenario,decision:$report[0].decision,summary:$report[0].summary,report_digest:$report_digest,external_inputs:$report[0].external_inputs,resolution_unknown:$report[0].resolution_unknown,execution_plan:$report[0].proposal.execution_plan,lifecycle:$report[0].lifecycle,authority:$report[0].authority,bindings:$report[0].bindings,metrics:[$report[0].cells[] | {id:("gooo.metric.reflexive.integration." + (.id|ascii_downcase|gsub("_";"-"))),cell:.id,activity:.activity,source_file:"examples/reflexive-loop/main.gooo",source_digest:$report[0].bindings.source_digest,ir_node_kind:"Activity",generated_artifact:("integration/metrics/" + (.id|ascii_downcase|gsub("_";"-")) + ".json"),evaluator:"scripts/integrated-loop.sh",numerator:(if .state=="CLOSED" then 1 else 0 end),denominator:1,state:.state,reason:.reason}],artifact:{files:$artifact_files,bytes:$artifact_bytes},repository_unchanged:$report[0].authority.input_repository_unchanged}' \
  > "$output/integration-artifact.json"

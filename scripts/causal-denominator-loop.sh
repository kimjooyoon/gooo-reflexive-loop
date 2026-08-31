#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: causal-denominator-loop.sh GOOO REPOSITORY EXTERNAL_RELEASE_DIR OUTPUT SCENARIO" >&2
  exit 64
fi

gooo=$1
repository=$(realpath "$2")
external=$(realpath "$3")
output=$(realpath -m "$4")
scenario=$5
lock="$repository/contracts/causal-denominator-release-locks-v1.json"

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

digest() {
  sha256sum "$1" | awk '{print "sha256:" $1}'
}

snapshot() {
  find "$repository" -path "$repository/.git" -prune -o -type f -print0 |
    sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print "sha256:" $1}'
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

release_asset_matches() {
  local release=$1
  local name=$2
  local expected_digest=$3
  local expected_size=$4
  jq -e --arg name "$name" --arg digest "$expected_digest" --argjson size "$expected_size" \
    '.assets | any(.[]; .name==$name and .digest==$digest and .size==$size)' "$release" >/dev/null 2>&1
}

bundle_files_match() {
  local manifest=$1
  local root=$2
  local file_ok=true
  while IFS=$'\t' read -r path expected_digest expected_bytes; do
    [ -n "$path" ] || continue
    if [ ! -f "$root/$path" ] || [ "$(digest "$root/$path")" != "$expected_digest" ] ||
      [ "$(wc -c < "$root/$path" | awk '{print $1 + 0}')" -ne "$expected_bytes" ]; then
      file_ok=false
    fi
  done < <(jq -r '.evidence.files[] | [.path,.digest,.bytes] | @tsv' "$manifest" 2>/dev/null || true)
  [ "$file_ok" = true ]
}

causal_repository=$(jq -r '.releases.causal_ci.repository' "$lock")
causal_tag=$(jq -r '.releases.causal_ci.tag' "$lock")
causal_target=$(jq -r '.releases.causal_ci.target_commit_sha' "$lock")
causal_manifest_name=$(jq -r '.releases.causal_ci.manifest.asset_name' "$lock")
causal_manifest_digest=$(jq -r '.releases.causal_ci.manifest.sha256' "$lock")
causal_manifest_size=$(jq -r '.releases.causal_ci.manifest.size_bytes' "$lock")
causal_evidence_name=$(jq -r '.releases.causal_ci.evidence.asset_name' "$lock")
causal_evidence_digest=$(jq -r '.releases.causal_ci.evidence.sha256' "$lock")
causal_evidence_size=$(jq -r '.releases.causal_ci.evidence.size_bytes' "$lock")
causal_checksum_name=$(jq -r '.releases.causal_ci.checksum.asset_name' "$lock")
causal_checksum_digest=$(jq -r '.releases.causal_ci.checksum.sha256' "$lock")
causal_checksum_size=$(jq -r '.releases.causal_ci.checksum.size_bytes' "$lock")

denominator_repository=$(jq -r '.releases.denominator_protocol.repository' "$lock")
denominator_tag=$(jq -r '.releases.denominator_protocol.tag' "$lock")
denominator_target=$(jq -r '.releases.denominator_protocol.target_commit_sha' "$lock")
denominator_manifest_name=$(jq -r '.releases.denominator_protocol.manifest.asset_name' "$lock")
denominator_manifest_digest=$(jq -r '.releases.denominator_protocol.manifest.sha256' "$lock")
denominator_manifest_size=$(jq -r '.releases.denominator_protocol.manifest.size_bytes' "$lock")
denominator_evidence_name=$(jq -r '.releases.denominator_protocol.evidence.asset_name' "$lock")
denominator_evidence_digest=$(jq -r '.releases.denominator_protocol.evidence.sha256' "$lock")
denominator_evidence_size=$(jq -r '.releases.denominator_protocol.evidence.size_bytes' "$lock")
denominator_checksum_name=$(jq -r '.releases.denominator_protocol.checksum.asset_name' "$lock")
denominator_checksum_digest=$(jq -r '.releases.denominator_protocol.checksum.sha256' "$lock")
denominator_checksum_size=$(jq -r '.releases.denominator_protocol.checksum.size_bytes' "$lock")

causal_release="$tmp/causal-release.json"
causal_tag_ref="$tmp/causal-tag-ref.json"
causal_manifest="$tmp/causal-manifest.json"
causal_archive="$tmp/causal-evidence.tar.gz"
causal_checksum="$tmp/causal-checksum.txt"
denominator_release="$tmp/denominator-release.json"
denominator_tag_ref="$tmp/denominator-tag-ref.json"
denominator_manifest="$tmp/denominator-manifest.json"
denominator_archive="$tmp/denominator-evidence.tar.gz"
denominator_checksum="$tmp/denominator-checksum.txt"
copy_required "$external/causal-release.json" "$causal_release"
copy_required "$external/causal-tag-ref.json" "$causal_tag_ref"
copy_required "$external/causal-manifest.json" "$causal_manifest"
copy_required "$external/causal-evidence.tar.gz" "$causal_archive"
copy_required "$external/causal-checksum.txt" "$causal_checksum"
copy_required "$external/denominator-release.json" "$denominator_release"
copy_required "$external/denominator-tag-ref.json" "$denominator_tag_ref"
copy_required "$external/denominator-manifest.json" "$denominator_manifest"
copy_required "$external/denominator-evidence.tar.gz" "$denominator_archive"
copy_required "$external/denominator-checksum.txt" "$denominator_checksum"

case "$scenario" in
  normal|missing-input|tampered-causal-digest|affected-test-incorrectly-skipped|reused-evidence-identity-mismatch|denominator-shrink|stale-migration-replay|malformed|fixed-point|authority-escalation)
    ;;
  *)
    echo "unknown scenario: $scenario" >&2
    exit 68
    ;;
esac

causal_release_ok=true
causal_manifest_ok=true
causal_plan_ok=true
selected_verification_ok=true
denominator_release_ok=true
denominator_manifest_ok=true
denominator_not_shrunk=true
proposal_apply_bound=false
oracle_promote_ok=false
authority_bound=true

if ! jq -e --arg tag "$causal_tag" --arg target "$causal_target" \
  '.immutable==true and .tag_name==$tag and .release_page_verified==true and (.release_verified_by=="immutable-release-page-and-consumer-manifest" or .release_verified_by=="immutable-consumer-manifest") and (.target_commitish=="main" or .target_commitish==$target)' \
  "$causal_release" >/dev/null 2>&1 ||
  ! jq -e --arg target "$causal_target" '.object.type=="commit" and .object.sha==$target' "$causal_tag_ref" >/dev/null 2>&1 ||
  ! release_asset_matches "$causal_release" "$causal_manifest_name" "$causal_manifest_digest" "$causal_manifest_size" ||
  ! release_asset_matches "$causal_release" "$causal_evidence_name" "$causal_evidence_digest" "$causal_evidence_size" ||
  ! release_asset_matches "$causal_release" "$causal_checksum_name" "$causal_checksum_digest" "$causal_checksum_size"; then
  fail causal_release_ok "CAUSAL_RELEASE_IMMUTABLE_OR_TARGET"
fi
if [ "$(digest "$causal_manifest")" != "$causal_manifest_digest" ] ||
  [ "$(digest "$causal_archive")" != "$causal_evidence_digest" ] ||
  [ "$(wc -c < "$causal_archive" | awk '{print $1 + 0}')" -ne "$causal_evidence_size" ] ||
  [ "$(digest "$causal_checksum")" != "$causal_checksum_digest" ] ||
  [ "$(wc -c < "$causal_checksum" | awk '{print $1 + 0}')" -ne "$causal_checksum_size" ]; then
  fail causal_manifest_ok "CAUSAL_MANIFEST_OR_EVIDENCE_DIGEST_MISMATCH"
fi

if ! jq -e --arg repo "$causal_repository" --arg tag "$causal_tag" --arg target "$causal_target" \
  --arg name "$causal_evidence_name" --arg digest "$causal_evidence_digest" --argjson size "$causal_evidence_size" \
  '.schema=="gooo/causal-ci/consumer-manifest/v1" and
   .release=={version:$tag,tag:$tag,repository:$repo,target_commit:$target,immutable:true} and
   .denominator=={total:12,closed:12,unknown:0,refuted:0,proof_totals:{FOUNDATION:4,COHERENCE:4,REGRESSION:4},indicator_totals:{DRIVER:4,OUTCOME:4,GUARDRAIL:4}} and
   .tests.full=={executed:4,reused:0,skipped:0} and .tests.selected=={executed:2,reused:1,skipped:1} and
   .evidence.bundle=={name:$name,size_bytes:$size,digest:$digest}' "$causal_manifest" >/dev/null 2>&1; then
  fail causal_manifest_ok "CAUSAL_MANIFEST_CONTENT_MISMATCH"
fi

mkdir -p "$tmp/causal-extracted" "$tmp/denominator-extracted"
if ! tar -xzf "$causal_archive" -C "$tmp/causal-extracted"; then
  fail causal_plan_ok "CAUSAL_EVIDENCE_UNREADABLE"
fi
if ! tar -xzf "$denominator_archive" -C "$tmp/denominator-extracted"; then
  fail denominator_manifest_ok "DENOMINATOR_EVIDENCE_UNREADABLE"
fi

causal_plan="$tmp/causal-extracted/activity-plan.json"
causal_cases="$tmp/causal-extracted/cases.json"
causal_metrics="$tmp/causal-extracted/metrics.json"
causal_report="$tmp/causal-extracted/report.json"
denominator_v1="$tmp/denominator-extracted/contracts/denominator-v1.json"
denominator_v2="$tmp/denominator-extracted/contracts/denominator-v2.json"
migration="$tmp/denominator-extracted/contracts/migration-v1-v2.json"
denominator_artifact="$tmp/denominator-extracted/ci-artifact.json"

if ! bundle_files_match "$causal_manifest" "$tmp/causal-extracted"; then
  fail causal_manifest_ok "CAUSAL_EVIDENCE_FILE_BINDING_MISMATCH"
fi

if [ "$scenario" = "tampered-causal-digest" ]; then
  jq -S '.evidence.bundle.digest="sha256:tampered-causal-evidence"' "$causal_manifest" > "$tmp/causal-manifest.mutated.json"
  mv "$tmp/causal-manifest.mutated.json" "$causal_manifest"
  fail causal_manifest_ok "CAUSAL_MANIFEST_CONTENT_MISMATCH"
fi
if [ "$scenario" = "affected-test-incorrectly-skipped" ] && [ -f "$causal_plan" ]; then
  jq -S '(.tests[] | select(.id=="test-add") | .action)="SKIP"' "$causal_plan" > "$tmp/causal-plan.mutated.json"
  mv "$tmp/causal-plan.mutated.json" "$causal_plan"
fi
if [ "$scenario" = "reused-evidence-identity-mismatch" ] && [ -f "$causal_plan" ]; then
  jq -S '(.tests[] | select(.id=="test-normalize") | .reason)="REUSE_WITHOUT_EXACT_PRIOR_RECEIPT"' "$causal_plan" > "$tmp/causal-plan.mutated.json"
  mv "$tmp/causal-plan.mutated.json" "$causal_plan"
fi
if [ "$scenario" = "denominator-shrink" ] && [ -f "$denominator_v2" ]; then
  jq -S '.cells |= .[0:6]' "$denominator_v2" > "$tmp/denominator-v2.mutated.json"
  mv "$tmp/denominator-v2.mutated.json" "$denominator_v2"
fi
if [ "$scenario" = "stale-migration-replay" ] && [ -f "$migration" ]; then
  jq -S '.from_contract_digest="0000000000000000000000000000000000000000000000000000000000000000"' "$migration" > "$tmp/migration.mutated.json"
  mv "$tmp/migration.mutated.json" "$migration"
fi
if [ "$scenario" = "malformed" ] && [ -f "$causal_plan" ]; then
  jq -S 'del(.selection_mode)' "$causal_plan" > "$tmp/causal-plan.mutated.json"
  mv "$tmp/causal-plan.mutated.json" "$causal_plan"
fi
if [ "$scenario" = "fixed-point" ] && [ -f "$causal_plan" ]; then
  jq -S '.decision="FIXED_POINT"' "$causal_plan" > "$tmp/causal-plan.mutated.json"
  mv "$tmp/causal-plan.mutated.json" "$causal_plan"
fi
if [ "$scenario" = "authority-escalation" ] && [ -f "$causal_report" ]; then
  jq -S '.authority.repository_writes=1' "$causal_report" > "$tmp/causal-report.mutated.json"
  mv "$tmp/causal-report.mutated.json" "$causal_report"
fi
if [ "$scenario" = "missing-input" ]; then
  rm -f "$causal_plan" "$migration"
fi

if [ ! -f "$causal_plan" ] || [ ! -f "$causal_cases" ] || [ ! -f "$causal_metrics" ] || [ ! -f "$causal_report" ]; then
  fail causal_plan_ok "CAUSAL_ENTRYPOINT_MISSING"
else
  if ! jq -e '
    .schema=="gooo/causal-ci/activity-plan/v1" and .decision=="CLOSED" and .selection_mode=="CAUSAL_SELECT" and
    .claim=={state:"CLOSED",stage:"CAUSAL_SELECTION",step:"generate-activities",reason:"CAUSAL_TEST_ACTIVITY_SET_GENERATED",unknown_class:"",next_operation:"NONE",blocked_by:[]} and
    .metrics=={denominator:12,closed:12,unknown:0,refuted:0,executed:2,reused:1,skipped:1} and
    (.activities|length)==12 and
    ([.activities[].cell_id]|sort)==["CAUSAL_CLOSURE","CHANGED_CLAIM","CLAIM_BINDING","EXACT_PAIR","EXCLUDED_EVIDENCE","EXECUTION_ENVELOPE","REFUTED_EXCLUSION","REPLAY","SELECTED_ACTIVITIES","SEMANTIC_GRAPH","SOURCE_BINDING","UNKNOWN_FRONTIER"] and
    all(.activities[]; .state=="CLOSED" and .source_path=="examples/causal-ci-policy/main.gooo" and .artifact_path=="activity-plan.json" and .evaluator=="github.com/kimjooyoon/gooo-causal-ci/internal/causalci" and (.binding_digest|test("^sha256:[0-9a-f]{64}$")) and (.graph_node_id|startswith("causalci://activity/"))) and
    ([.activities[].proof_choice]|sort)==["COHERENCE","COHERENCE","COHERENCE","COHERENCE","FOUNDATION","FOUNDATION","FOUNDATION","FOUNDATION","REGRESSION","REGRESSION","REGRESSION","REGRESSION"] and
    ([.activities[].indicator_class]|sort)==["DRIVER","DRIVER","DRIVER","DRIVER","GUARDRAIL","GUARDRAIL","GUARDRAIL","GUARDRAIL","OUTCOME","OUTCOME","OUTCOME","OUTCOME"] and
    (.tests|map({id,action,causal_claim_ids,exclusion_evidence,reason}))==[
      {id:"test-add",action:"EXECUTE",causal_claim_ids:["claim-shared-normalization-changed"],exclusion_evidence:null,reason:"CLAIM_ACTIVITY_PATH_INTERSECTS_TEST_ACTIVITY"},
      {id:"test-normalize",action:"REUSE",causal_claim_ids:["claim-shared-normalization-changed"],exclusion_evidence:null,reason:"EXACT_PRIOR_RECEIPT_BOUND_TO_CURRENT_SCOPE"},
      {id:"test-integration",action:"EXECUTE",causal_claim_ids:["claim-shared-normalization-changed"],exclusion_evidence:null,reason:"CLAIM_ACTIVITY_PATH_INTERSECTS_TEST_ACTIVITY"},
      {id:"test-subtract",action:"SKIP",causal_claim_ids:null,exclusion_evidence:[{test_id:"test-subtract",reason:"NO_CAUSAL_ACTIVITY_PATH_TO_SUBTRACT",activity_path:["VerifySourceBinding"]}],reason:"NO_CAUSAL_ACTIVITY_PATH_TO_SUBTRACT"}
    ]
  ' "$causal_plan" >/dev/null 2>&1; then
    if [ "$scenario" = "affected-test-incorrectly-skipped" ]; then
      fail causal_plan_ok "AFFECTED_TEST_INCORRECTLY_SKIPPED"
    elif [ "$scenario" = "reused-evidence-identity-mismatch" ]; then
      fail causal_plan_ok "REUSED_EVIDENCE_IDENTITY_MISMATCH"
    elif [ "$scenario" = "fixed-point" ]; then
      fail causal_plan_ok "FIXED_POINT_DECISION_REFUTED"
    elif [ "$scenario" = "malformed" ]; then
      fail causal_plan_ok "MALFORMED_INPUT"
    else
      fail causal_plan_ok "CAUSAL_ACTIVITY_PLAN_NOT_CLOSED"
    fi
  fi
  if ! jq -e --arg repo "$causal_repository" --arg tag "$causal_tag" --arg target "$causal_target" \
    '.schema=="gooo/causal-ci/report/v1" and .decision=="CAUSAL_CI_REPORT_CLOSED" and
     .tests=={total:4,full:{executed:4,reused:0,skipped:0},selected:{executed:2,reused:1,skipped:1}} and
     ([.cases[].id]|sort)==["authority-escalation","digest-mismatch","fixed-point","malformed","missing-binding","normal","refuted-exclusion","stale-graph"] and
     ([.cases[]|select(.decision=="CLOSED")]|length)==1 and ([.cases[]|select(.decision=="UNKNOWN")]|length)==3 and ([.cases[]|select(.decision=="REFUTED")]|length)==4 and
     .authority=={repository_writes:0,root_readme_policy:"EXCLUDED",observation_mode:"READ_ONLY"}' "$causal_report" >/dev/null 2>&1; then
    if [ "$scenario" = "authority-escalation" ]; then
      fail authority_bound "AUTHORITY_ESCALATION"
    else
      fail causal_plan_ok "CAUSAL_REPORT_BINDING_MISMATCH"
    fi
  fi
  if ! jq -e '.metrics=={denominator:12,closed:12,unknown:0,refuted:0,executed:2,reused:1,skipped:1}' "$causal_metrics" >/dev/null 2>&1; then
    fail causal_plan_ok "CAUSAL_METRICS_BINDING_MISMATCH"
  fi
  if ! jq -e '
    length==8 and
    ([.[].id]|sort)==["authority-escalation","digest-mismatch","fixed-point","malformed","missing-binding","normal","refuted-exclusion","stale-graph"] and
    ([.[]|select(.decision=="CLOSED")]|length)==1 and
    ([.[]|select(.decision=="UNKNOWN")]|length)==3 and
    ([.[]|select(.decision=="REFUTED")]|length)==4
  ' "$causal_cases" >/dev/null 2>&1; then
    fail causal_plan_ok "CAUSAL_CASES_BINDING_MISMATCH"
  fi
fi

if [ "$causal_plan_ok" != true ]; then
  selected_verification_ok=false
fi

if ! jq -e --arg tag "$denominator_tag" --arg target "$denominator_target" \
  '.immutable==true and .tag_name==$tag and .release_page_verified==true and .release_verified_by=="immutable-consumer-manifest" and .target_commitish==$target' "$denominator_release" >/dev/null 2>&1 ||
  ! jq -e --arg target "$denominator_target" '.object.type=="commit" and .object.sha==$target' "$denominator_tag_ref" >/dev/null 2>&1 ||
  ! release_asset_matches "$denominator_release" "$denominator_manifest_name" "$denominator_manifest_digest" "$denominator_manifest_size" ||
  ! release_asset_matches "$denominator_release" "$denominator_evidence_name" "$denominator_evidence_digest" "$denominator_evidence_size" ||
  ! release_asset_matches "$denominator_release" "$denominator_checksum_name" "$denominator_checksum_digest" "$denominator_checksum_size"; then
  fail denominator_release_ok "DENOMINATOR_RELEASE_IMMUTABLE_OR_TARGET"
fi
if [ "$(digest "$denominator_manifest")" != "$denominator_manifest_digest" ] ||
  [ "$(digest "$denominator_archive")" != "$denominator_evidence_digest" ] ||
  [ "$(wc -c < "$denominator_archive" | awk '{print $1 + 0}')" -ne "$denominator_evidence_size" ] ||
  [ "$(digest "$denominator_checksum")" != "$denominator_checksum_digest" ] ||
  [ "$(wc -c < "$denominator_checksum" | awk '{print $1 + 0}')" -ne "$denominator_checksum_size" ]; then
  fail denominator_manifest_ok "DENOMINATOR_MANIFEST_OR_EVIDENCE_DIGEST_MISMATCH"
fi
if ! jq -e --arg repo "$denominator_repository" --arg tag "$denominator_tag" --arg target "$denominator_target" \
  --arg evidence_name "$denominator_evidence_name" --arg evidence_digest "${denominator_evidence_digest#sha256:}" --argjson evidence_size "$denominator_evidence_size" \
  '.schema=="gooo/denominator/consumer-manifest/v1" and .repository==$repo and .release_tag==$tag and .target_commit==$target and
   .immutable_release_required==true and .claims.v1=={closed:6,denominator:6,refuted:0,state:"CLOSED",unknown:0} and
   .claims.v2=={closed:7,denominator:7,refuted:0,state:"CLOSED",unknown:0} and
   .claims.conformance=={CLOSED:4,REFUTED:6,UNKNOWN:2,percentage:false} and
   .claims.unknown_case=={closed:5,denominator:6,refuted:0,state:"UNKNOWN",unknown:1} and
   .migration=={added:1,from:"v1",receipt:"contracts/migration-v1-v2.json",retired:1,split:1,to:"v2"} and
   .assets.evidence_bundle=={media_type:"application/gzip",name:$evidence_name,sha256:$evidence_digest,size_bytes:$evidence_size}' "$denominator_manifest" >/dev/null 2>&1; then
  fail denominator_manifest_ok "DENOMINATOR_MANIFEST_CONTENT_MISMATCH"
fi

if [ ! -f "$denominator_v1" ] || [ ! -f "$denominator_v2" ] || [ ! -f "$migration" ] || [ ! -f "$denominator_artifact" ]; then
  fail denominator_manifest_ok "DENOMINATOR_ENTRYPOINT_MISSING"
else
  if ! jq -e '
    .schema=="gooo/denominator/contract/v1" and .contract_id=="language-development" and .version==1 and
    .run_policy=={allow_denominator_change_during_run:false,allow_criteria_change_after_success:false,allow_privilege_escalation:false} and
    (.cells|length)==6 and ([.cells[].id]|sort)==["artifact-coherence-guardrail","evaluator-coherence-driver","no-write-regression-guardrail","replay-regression-outcome","semantic-foundation-outcome","source-foundation-driver"] and
    all(.cells[]; .metric_denominator==1 and (.id|type)=="string" and (.evaluator|type)=="string" and (.generated_artifact|type)=="string")
  ' "$denominator_v1" >/dev/null 2>&1; then
    fail denominator_manifest_ok "V1_DENOMINATOR_BINDING_MISMATCH"
  fi
  if ! jq -e '
    .schema=="gooo/denominator/contract/v1" and .contract_id=="language-development" and .version==2 and
    .run_policy=={allow_denominator_change_during_run:false,allow_criteria_change_after_success:false,allow_privilege_escalation:false} and
    (.cells|length)==7 and ([.cells[].id]|sort)==["artifact-coherence-guardrail","evaluator-coherence-driver","migration-regression-driver","no-write-regression-guardrail","semantic-generated-foundation-outcome","semantic-ir-foundation-outcome","source-foundation-driver"] and
    all(.cells[]; .metric_denominator==1 and (.id|type)=="string" and (.evaluator|type)=="string" and (.generated_artifact|type)=="string")
  ' "$denominator_v2" >/dev/null 2>&1; then
    fail denominator_not_shrunk "DENOMINATOR_SHRINK"
  fi
  if ! jq -e '
    .schema=="gooo/denominator/migration-receipt/v1" and .migration_id=="language-development-v1-v2" and
    .from_contract_digest=="81f12f8716eff4494f124ae1e2590423c8518234725248f050e84fdb31e3a0b8" and
    .to_contract_digest=="dd446bcace142b424906a780dec4096a63339174260ade9332d09d9856166566" and
    ([.operations[].kind]|sort)==["ADD","RETIRE","SPLIT"] and
    any(.operations[]; .kind=="SPLIT" and .source_cell_id=="semantic-foundation-outcome" and (.target_cell_ids|sort)==["semantic-generated-foundation-outcome","semantic-ir-foundation-outcome"] and .reason=="separate IR and generated artifact proof" and .proof_choice=="FOUNDATION") and
    any(.operations[]; .kind=="ADD" and .source_cell_id=="" and .target_cell_ids==["migration-regression-driver"] and .reason=="make migration receipts observable" and .proof_choice=="REGRESSION") and
    any(.operations[]; .kind=="RETIRE" and .source_cell_id=="replay-regression-outcome" and .target_cell_ids==[] and .reason=="replace the old replay cell with versioned replay evidence" and .retirement_evidence.decision=="CLOSED" and .retirement_evidence.cell_id=="replay-regression-outcome")
  ' "$migration" >/dev/null 2>&1; then
    if [ "$scenario" = "stale-migration-replay" ]; then
      fail denominator_manifest_ok "STALE_MIGRATION_OR_REPLAY"
    else
      fail denominator_manifest_ok "MIGRATION_BINDING_MISMATCH"
    fi
  fi
  if ! jq -e --arg target "$denominator_target" '.schema=="gooo/denominator/ci-artifact/v1" and .subject_commit==$target and .repository.repository_writes==0 and .root_readme_excluded==true and .states=={percentage:false,precedence:["REFUTED","UNKNOWN","CLOSED"]} and .artifact=={bytes:90144,files:21,scope:"reports/"} and .ci.test_executed==8 and .ci.test_reused==0 and .ci.test_skipped==0' "$denominator_artifact" >/dev/null 2>&1; then
    fail denominator_manifest_ok "DENOMINATOR_ARTIFACT_BINDING_MISMATCH"
  fi
fi

input_before=$(snapshot)
source_file="$repository/examples/reflexive-loop/main.gooo"
workload_file="$repository/fixtures/use-case/workload.gooo"
source_digest=$(digest "$source_file")
workload_digest=$(digest "$workload_file")
contract_digest=$(digest "$repository/contracts/allowed-transformations-v1.json")
tool_digest=$(digest "$gooo")
causal_plan_digest=""
denominator_migration_digest=""
[ -f "$causal_plan" ] && causal_plan_digest=$(digest "$causal_plan")
[ -f "$migration" ] && denominator_migration_digest=$(digest "$migration")

mkdir -p "$output/input" "$output/external" "$output/verification/execute" "$output/verification/reuse" "$output/verification/skip" "$output/clone/before" "$output/clone/after" "$output/metrics"
cp "$causal_release" "$output/external/causal-release.json"
cp "$causal_tag_ref" "$output/external/causal-tag-ref.json"
cp "$causal_manifest" "$output/external/causal-manifest.json"
cp "$causal_archive" "$output/external/causal-evidence.tar.gz"
cp "$causal_checksum" "$output/external/causal-checksum.txt"
cp "$denominator_release" "$output/external/denominator-release.json"
cp "$denominator_tag_ref" "$output/external/denominator-tag-ref.json"
cp "$denominator_manifest" "$output/external/denominator-manifest.json"
cp "$denominator_archive" "$output/external/denominator-evidence.tar.gz"
cp "$denominator_checksum" "$output/external/denominator-checksum.txt"

if [ -f "$causal_plan" ] && [ -f "$migration" ]; then
  jq -S -n \
    --arg causal_release_id "$(jq -r '.id|tostring' "$causal_release")" --arg denominator_release_id "$(jq -r '.id|tostring' "$denominator_release")" \
    --arg causal_target "$causal_target" --arg denominator_target "$denominator_target" \
    --arg causal_manifest_digest "$causal_manifest_digest" --arg causal_evidence_digest "$causal_evidence_digest" \
    --arg denominator_manifest_digest "$denominator_manifest_digest" --arg denominator_evidence_digest "$denominator_evidence_digest" \
    --arg causal_plan_digest "$causal_plan_digest" --arg migration_digest "$denominator_migration_digest" \
    --slurpfile plan "$causal_plan" --slurpfile migration "$migration" \
    '{schema:"gooo/reflexive-loop/causal-denominator-external-input/v1",state:"CLOSED",causal_ci:{release_id:$causal_release_id,repository:"kimjooyoon/gooo-causal-ci",tag:"v0.1.0",target_commit_sha:$causal_target,manifest_digest:$causal_manifest_digest,evidence_digest:$causal_evidence_digest,activity_plan_digest:$causal_plan_digest,selection_mode:$plan[0].selection_mode,selected_tests:$plan[0].tests,selected_counts:$plan[0].metrics},denominator_protocol:{release_id:$denominator_release_id,repository:"kimjooyoon/gooo-denominator-protocol",tag:"v0.1.0",target_commit_sha:$denominator_target,manifest_digest:$denominator_manifest_digest,evidence_digest:$denominator_evidence_digest,migration_digest:$migration_digest,v1_denominator:6,v2_denominator:7,migration:{added:1,split:1,retired:1,from_contract_digest:$migration[0].from_contract_digest,to_contract_digest:$migration[0].to_contract_digest}},external_required_status_gates:0}' \
    > "$output/input/external-input.json"
else
  jq -S -n '{schema:"gooo/reflexive-loop/causal-denominator-external-input/v1",state:"UNKNOWN",reason:"EXTERNAL_INPUT_UNAVAILABLE"}' > "$output/input/external-input.json"
fi

if [ "${#failures[@]}" -eq 0 ]; then
  jq -S -n \
    --arg source_digest "$source_digest" --arg workload_digest "$workload_digest" --arg contract_digest "$contract_digest" --arg tool_digest "$tool_digest" \
    --arg causal_plan_digest "$causal_plan_digest" --arg migration_digest "$denominator_migration_digest" \
    --slurpfile external_input "$output/input/external-input.json" --slurpfile plan "$causal_plan" --slurpfile migration "$migration" \
    '{schema:"gooo/reflexive-loop/causal-denominator-proposal/v1",state:"CLOSED",selector_activity:"SelectAllowedTransformation",apply_activity:"ApplyAllowedMetaActivity",transformation_id:"canonicalize-workload-source",source_digest:$source_digest,workload_digest:$workload_digest,contract_digest:$contract_digest,tool_digest:$tool_digest,causal_selection:{selection_mode:$plan[0].selection_mode,activity_plan_digest:$causal_plan_digest,selected_tests:($plan[0].tests|map({id,action,causal_claim_ids,exclusion_evidence,reason})),counts:{execute:2,reuse:1,skip:1}},denominator_binding:{v1_denominator:6,v2_denominator:7,proof_denominator:7,affected_denominator_preserved:true,migration:{added:1,split:1,retired:1},contract_digests:{v1:$migration[0].from_contract_digest,v2:$migration[0].to_contract_digest,migration:$migration_digest}},verification_plan:{mode:"causal-selected-execute-reuse-skip",execute_tests:["test-add","test-integration"],reuse_tests:["test-normalize"],skip_tests:["test-subtract"],proof_contract_version:2,denominator:7},external_inputs:$external_input[0],authority_scope:"temporary_output",proposal_replay_policy:"unique_proposal_digest",next_operation:"APPLY_ALLOWED_META_ACTIVITY"}' \
    > "$tmp/proposal-body.json"
  proposal_digest=$(digest "$tmp/proposal-body.json")
  jq -S --arg proposal_id "$proposal_digest" '. + {proposal_id:$proposal_id}' "$tmp/proposal-body.json" > "$output/proposal.json"
else
  validation_reason=$(IFS=,; echo "${failures[*]}")
  jq -S -n --arg reason "$validation_reason" --arg state "$(if [ "$scenario" = "missing-input" ]; then echo UNKNOWN; else echo REFUTED; fi)" \
    '{schema:"gooo/reflexive-loop/causal-denominator-proposal/v1",state:$state,reason:$reason,proposal_id:"",next_operation:(if $state=="UNKNOWN" then "PROVIDE_EXACT_EXTERNAL_RELEASE_INPUTS" else "ROLLBACK_CANDIDATE" end),authority_scope:"temporary_output"}' \
    > "$output/proposal.json"
fi

jq -S -n '{schema:"gooo/reflexive-loop/oracle-verdict/v1",decision:"UNKNOWN",equivalent:false,counterexamples:[]}' > "$output/oracle.json"
jq -S -n '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"UNKNOWN"}' > "$output/workload-pair.json"
jq -S -n --arg before "$input_before" '{schema:"gooo/reflexive-loop/repository-effect/v1",before_digest:$before,after_digest:null,repository_writes:null}' > "$output/repository-effect.json"
jq -S -n --arg state "REFUTED" --arg reason "NOT_APPLIED" '{schema:"gooo/reflexive-loop/rollback-receipt/v1",decision:$state,reason:$reason,mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}' > "$output/rollback.json"

if [ "${#failures[@]}" -eq 0 ]; then
  if bash "$repository/scripts/apply.sh" "$workload_file" "$output/proposal.json" "$output/clone/after/workload.gooo" "ApplyAllowedMetaActivity"; then
    proposal_apply_bound=true
    cp "$workload_file" "$output/clone/before/workload.gooo"
    jq -S '.verification_plan' "$output/proposal.json" > "$output/verification-plan.json"

    run_workload() {
      local label=$1
      local source=$2
      local result="$output/clone/$label/check.json"
      local stderr="$output/clone/$label/check.stderr"
      local timing="$output/clone/$label/time.tsv"
      local check_status
      local seconds=0
      local rss=0
      mkdir -p "$output/clone/$label"
      set +e
      /usr/bin/time -f '%e\t%M' -o "$timing" "$gooo" check --semantic --json "$source" > "$result" 2> "$stderr"
      check_status=$?
      set -e
      if [ -s "$timing" ]; then read -r seconds rss < "$timing"; fi
      local wall_ms
      wall_ms=$(awk -v value="$seconds" 'BEGIN {printf "%d", (value * 1000) + 0.5}')
      jq -S -n --arg label "$label" --arg source "$source" --argjson status "$check_status" \
        --argjson wall_ms "$wall_ms" --argjson peak_rss_kib "${rss:-0}" --arg source_digest "$(digest "$source")" \
        --slurpfile result "$result" \
        '{label:$label,source:$source,source_digest:$source_digest,status:$status,wall_ms:$wall_ms,peak_rss_kib:$peak_rss_kib,semantic_digest:($result[0].semantic_hash // null),result:$result[0]}' \
        > "$output/clone/$label/measurement.json"
    }

    run_workload before "$output/clone/before/workload.gooo"
    run_workload after "$output/clone/after/workload.gooo"
    mkdir -p "$output/verification/execute" "$output/verification/reuse" "$output/verification/skip"
    jq -S -n --slurpfile before "$output/clone/before/measurement.json" --slurpfile after "$output/clone/after/measurement.json" \
      '{test_id:"test-add",action:"EXECUTE",causal_claim_ids:["claim-shared-normalization-changed"],evidence:{before:$before[0],after:$after[0]},evaluator:"gooo check --semantic --json"}' > "$output/verification/execute/test-add.json"
    jq -S -n --slurpfile before "$output/clone/before/measurement.json" --slurpfile after "$output/clone/after/measurement.json" \
      '{test_id:"test-integration",action:"EXECUTE",causal_claim_ids:["claim-shared-normalization-changed"],evidence:{before:$before[0],after:$after[0]},evaluator:"gooo check --semantic --json"}' > "$output/verification/execute/test-integration.json"
    jq -S -n --arg plan_digest "$causal_plan_digest" --arg test_id "test-normalize" \
      '{test_id:$test_id,action:"REUSE",causal_claim_ids:["claim-shared-normalization-changed"],reason:"EXACT_PRIOR_RECEIPT_BOUND_TO_CURRENT_SCOPE",reused_evidence_identity:("causal-ci/v0.1.0/activity-plan.json#" + $test_id),activity_plan_digest:$plan_digest}' \
      > "$output/verification/reuse/test-normalize.json"
    jq -S -n '{test_id:"test-subtract",action:"SKIP",reason:"NO_CAUSAL_ACTIVITY_PATH_TO_SUBTRACT",exclusion_evidence:[{test_id:"test-subtract",reason:"NO_CAUSAL_ACTIVITY_PATH_TO_SUBTRACT",activity_path:["VerifySourceBinding"]}]}' > "$output/verification/skip/test-subtract.json"
    jq -S -n \
      --arg plan_digest "$causal_plan_digest" --argjson selected '{"execute":2,"reuse":1,"skip":1}' \
      '{schema:"gooo/reflexive-loop/selected-verification/v1",state:"CLOSED",activity_plan_digest:$plan_digest,counts:$selected,execute_tests:["test-add","test-integration"],reuse_tests:["test-normalize"],skip_tests:["test-subtract"],reused_evidence_identity:"causal-ci/v0.1.0/activity-plan.json#test-normalize",excluded_test_evidence:"NO_CAUSAL_ACTIVITY_PATH_TO_SUBTRACT"}' > "$output/verification-plan.json"
    "$gooo" graph dump "$output/clone/before/workload.gooo" > "$output/clone/before/graph.json"
    "$gooo" graph dump "$output/clone/after/workload.gooo" > "$output/clone/after/graph.json"
    if bash "$repository/scripts/oracle.sh" "$output/clone/before/graph.json" "$output/clone/after/graph.json" "$output/oracle.json"; then
      if [ "$(jq -r '.decision' "$output/oracle.json")" = "CLOSED" ]; then
        oracle_promote_ok=true
      fi
    fi
    before_status=$(jq -r '.status' "$output/clone/before/measurement.json")
    after_status=$(jq -r '.status' "$output/clone/after/measurement.json")
    if [ "$before_status" -eq 0 ] && [ "$after_status" -eq 0 ] && [ "$oracle_promote_ok" = true ]; then
      jq -S -n --arg input_digest "$workload_digest" --arg contract_digest "$contract_digest" --arg tool_digest "$tool_digest" \
        --slurpfile before "$output/clone/before/measurement.json" --slurpfile after "$output/clone/after/measurement.json" --slurpfile oracle "$output/oracle.json" \
        '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"CLOSED",exact_identity:true,input_digest:$input_digest,contract_digest:$contract_digest,tool_digest:$tool_digest,clone_created:true,applied:true,apply_activity:"ApplyAllowedMetaActivity",before:$before[0],after:$after[0],oracle_decision:$oracle[0].decision,rollback:{mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}}' > "$output/workload-pair.json"
    else
      jq -S -n '{schema:"gooo/reflexive-loop/workload-pair/v1",state:"REFUTED",exact_identity:false,reason:"WORKLOAD_PAIR_OR_ORACLE_REFUTED"}' > "$output/workload-pair.json"
    fi
  fi
fi

input_after=$(snapshot)
jq -S --arg after "$input_after" '.after_digest=$after | .repository_writes=(if .before_digest==$after then 0 else 1 end)' "$output/repository-effect.json" > "$tmp/repository-effect.json"
mv "$tmp/repository-effect.json" "$output/repository-effect.json"
if [ "$(jq -r '.repository_writes' "$output/repository-effect.json")" -ne 0 ]; then
  failures+=("INPUT_REPOSITORY_CHANGED")
fi

if [ "$proposal_apply_bound" = true ] && [ "$oracle_promote_ok" = true ] && [ "$(jq -r '.repository_writes' "$output/repository-effect.json")" -eq 0 ]; then
  jq -S -n '{schema:"gooo/reflexive-loop/rollback-receipt/v1",decision:"PROMOTED",mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output",boundary:"promotion-retains-recoverable-candidate"}' > "$output/rollback.json"
else
  if [ "$proposal_apply_bound" = true ] && [ "$oracle_promote_ok" != true ]; then
    failures+=("INDEPENDENT_ORACLE_NOT_CLOSED")
  fi
  jq -S -n --arg reason "$(if [ "${#failures[@]}" -gt 0 ]; then IFS=,; echo "${failures[*]}"; else echo NOT_APPLIED; fi)" \
    '{schema:"gooo/reflexive-loop/rollback-receipt/v1",decision:"REFUTED",reason:$reason,mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}' > "$output/rollback.json"
fi

if [ "$scenario" = "missing-input" ]; then
  report_decision="UNKNOWN"
  validation_reason="EXTERNAL_INPUT_UNAVAILABLE"
elif [ "${#failures[@]}" -gt 0 ]; then
  report_decision="REFUTED"
  validation_reason=$(IFS=,; echo "${failures[*]}")
else
  report_decision="CLOSED"
  validation_reason=""
fi

if [ "$scenario" = "missing-input" ]; then
  unknown_class="DIRECT_MISSING"
  unknown_stage="OBSERVE"
  unknown_step="REQUIRE_CAUSAL_AND_DENOMINATOR_INPUTS"
  unknown_reason="EXTERNAL_INPUT_UNAVAILABLE"
  unknown_next="PROVIDE_EXACT_EXTERNAL_RELEASE_INPUTS"
  unknown_blocked='["causal-release","denominator-release"]'
else
  unknown_class="CAUSALITY_UNPROVEN"
  unknown_stage="IMPROVEMENT"
  unknown_step="REQUIRE_EXACT_BEFORE_AFTER_PAIR"
  unknown_reason="EXACT_BEFORE_AFTER_PAIR_MISSING"
  unknown_next="PROVIDE_EXACT_BEFORE_AFTER_PAIR"
  unknown_blocked='["exact-before-after-pair"]'
fi

jq -S -n \
  --arg scenario "$scenario" --arg decision "$report_decision" --arg source_digest "$source_digest" --arg tool_digest "$tool_digest" \
  --arg validation_reason "$validation_reason" --arg proposal_id "$(jq -r '.proposal_id // ""' "$output/proposal.json")" \
  --arg unknown_stage "$unknown_stage" --arg unknown_step "$unknown_step" --arg unknown_reason "$unknown_reason" --arg unknown_class "$unknown_class" --arg unknown_next "$unknown_next" --argjson unknown_blocked "$unknown_blocked" \
  --argjson missing_input "$(if [ "$scenario" = "missing-input" ]; then echo true; else echo false; fi)" \
  --argjson causal_release_ok "$causal_release_ok" --argjson causal_manifest_ok "$causal_manifest_ok" --argjson causal_plan_ok "$causal_plan_ok" --argjson selected_verification_ok "$selected_verification_ok" \
  --argjson denominator_release_ok "$denominator_release_ok" --argjson denominator_manifest_ok "$denominator_manifest_ok" --argjson denominator_not_shrunk "$denominator_not_shrunk" \
  --argjson proposal_apply_bound "$proposal_apply_bound" --argjson oracle_promote_ok "$oracle_promote_ok" --argjson authority_bound "$authority_bound" \
  --slurpfile external_input "$output/input/external-input.json" --slurpfile proposal "$output/proposal.json" --slurpfile oracle "$output/oracle.json" --slurpfile pair "$output/workload-pair.json" \
  'def state($ok): if $missing_input then "UNKNOWN" elif $ok then "CLOSED" else "REFUTED" end;
   def why($ok;$closed): if $missing_input then "EXTERNAL_INPUT_UNAVAILABLE" elif $ok then $closed else $validation_reason end;
   def nextop($ok): if $missing_input then "PROVIDE_EXACT_EXTERNAL_RELEASE_INPUTS" elif $ok then "NONE" else "ROLLBACK_CANDIDATE" end;
   [
     {id:"CAUSAL_RELEASE_IMMUTABLE",activity:"ConsumeImmutableCausalCIRelease",stage:"OBSERVE",step:"VERIFY_RELEASE_IMMUTABILITY_TARGET_AND_ASSET",ok:$causal_release_ok,closed:"CAUSAL_RELEASE_VERIFIED"},
     {id:"CAUSAL_MANIFEST_EXACT",activity:"BindCausalCIManifestAndEvidence",stage:"OBSERVE",step:"VERIFY_MANIFEST_EVIDENCE_AND_INTERNAL_BINDINGS",ok:$causal_manifest_ok,closed:"CAUSAL_MANIFEST_EVIDENCE_BOUND"},
     {id:"CAUSAL_PLAN_SELECTED",activity:"SelectCausalVerificationPlan",stage:"PROPOSE",step:"CONSUME_EXECUTE_REUSE_SKIP_PLAN",ok:$causal_plan_ok,closed:"CAUSAL_PLAN_SELECTED"},
     {id:"SELECTED_VERIFICATION_BOUND",activity:"BindSelectedVerificationEvidence",stage:"VERIFY",step:"VERIFY_EXECUTE_REUSE_SKIP_IDENTITY",ok:$selected_verification_ok,closed:"SELECTED_VERIFICATION_BOUND"},
     {id:"DENOMINATOR_RELEASE_IMMUTABLE",activity:"ConsumeImmutableDenominatorRelease",stage:"OBSERVE",step:"VERIFY_RELEASE_IMMUTABILITY_TARGET_AND_ASSET",ok:$denominator_release_ok,closed:"DENOMINATOR_RELEASE_VERIFIED"},
     {id:"DENOMINATOR_MANIFEST_EXACT",activity:"BindDenominatorManifestAndMigration",stage:"OBSERVE",step:"VERIFY_MANIFEST_CONTRACT_AND_MIGRATION",ok:$denominator_manifest_ok,closed:"DENOMINATOR_MANIFEST_MIGRATION_BOUND"},
     {id:"DENOMINATOR_NOT_SHRUNK",activity:"PreserveAffectedProofDenominator",stage:"PROPOSE",step:"VERIFY_V1_V2_DENOMINATOR_AND_MIGRATION",ok:$denominator_not_shrunk,closed:"AFFECTED_DENOMINATOR_PRESERVED"},
     {id:"PROPOSAL_APPLY_BOUND",activity:"ApplyCausalDenominatorProposal",stage:"APPLY",step:"APPLY_TO_TEMPORARY_OUTPUT",ok:$proposal_apply_bound,closed:"TEMPORARY_APPLY_CLOSED"},
     {id:"ORACLE_PROMOTE_ROLLBACK",activity:"VerifyIndependentOracleAndLifecycle",stage:"PROMOTE",step:"VERIFY_ORACLE_THEN_PROMOTE_OR_ROLLBACK",ok:($oracle_promote_ok and $proposal_apply_bound),closed:"PROMOTED_WITH_ROLLBACK_BOUNDARY"},
     {id:"AUTHORITY_BOUND",activity:"PreserveReadOnlyAuthority",stage:"AUTHORITY",step:"VERIFY_NO_REPOSITORY_WRITE_OR_STATUS_GATE",ok:$authority_bound,closed:"AUTHORITY_BOUND"}
   ] | map({id,activity,stage,step,state:state(.ok),reason:why(.ok;.closed),next_operation:nextop(.ok),blocked_by:(if $missing_input then ["causal-release","denominator-release"] elif .ok then [] else ["causal-denominator-validation"] end)}) as $cells |
   {schema:"gooo/reflexive-loop/causal-denominator-conformance/v1",scenario:$scenario,decision:$decision,precedence:["REFUTED","UNKNOWN","CLOSED"],cells:$cells,summary:{total:($cells|length),closed:([$cells[]|select(.state=="CLOSED")]|length),unknown:([$cells[]|select(.state=="UNKNOWN")]|length),refuted:([$cells[]|select(.state=="REFUTED")]|length)},external_inputs:$external_input[0],proposal_digest:$proposal_id,proposal:$proposal[0],causal_unknown:{stage:$unknown_stage,step:$unknown_step,reason:$unknown_reason,unknown_class:$unknown_class,next_operation:$unknown_next,blocked_by:$unknown_blocked,preserved_exactly:true},performance_utility:{state:"UNKNOWN",stage:"IMPROVEMENT",step:"REQUIRE_EXACT_BEFORE_AFTER_PAIR",reason:"EXACT_BEFORE_AFTER_PAIR_MISSING",unknown_class:"CAUSALITY_UNPROVEN",next_operation:"PROVIDE_EXACT_BEFORE_AFTER_PAIR",blocked_by:["exact-before-after-pair"],preserved_exactly:true},selected_verification:{execute:2,reuse:1,skip:1,plan_affects_apply:true},denominator_binding:{v1:6,v2:7,proof_denominator:7,affected_denominator_preserved:$denominator_not_shrunk,migration:{added:1,split:1,retired:1}},runtime:{oracle:$oracle[0],workload_pair:$pair[0]},lifecycle:{sequence:["PROPOSE","TEMP_APPLY","SELECTED_VERIFICATION","INDEPENDENT_ORACLE","PROMOTE","ROLLBACK_BOUNDARY"],promotion:(if ($oracle_promote_ok and $proposal_apply_bound and $decision=="CLOSED") then "PROMOTED" else "NOT_PROMOTED" end),rollback:{mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}},authority:{repository_writes:0,external_required_status_gates:0,input_repository_unchanged:true,local_tests_run:0},bindings:{causal_input_affects_proposal:true,causal_input_affects_verification_plan:true,denominator_input_affects_proof_plan:true,provenance_only:false,source_file:"examples/reflexive-loop/main.gooo",source_digest:$source_digest,ir_node_kind:"Activity",evaluator:"scripts/causal-denominator-loop.sh"},validation_reason:$validation_reason}' > "$output/report.json"

while IFS=$'\t' read -r cell state activity reason; do
  numerator=0
  [ "$state" = "CLOSED" ] && numerator=1
  jq -S -n --arg cell "$cell" --arg state "$state" --arg activity "$activity" --arg reason "$reason" --arg source_digest "$source_digest" --argjson numerator "$numerator" \
    '{schema:"gooo/reflexive-loop/causal-denominator-metric/v1",id:("gooo.metric.reflexive.causal-denominator." + ($cell|ascii_downcase|gsub("_";"-"))),cell:$cell,activity:$activity,source_file:"examples/reflexive-loop/main.gooo",source_digest:$source_digest,ir_node_kind:"Activity",generated_artifact:("causal-denominator/metrics/" + ($cell|ascii_downcase|gsub("_";"-")) + ".json"),evaluator:"scripts/causal-denominator-loop.sh",numerator:$numerator,denominator:1,state:$state,reason:$reason}' \
    > "$output/metrics/$(printf '%s' "$cell" | tr '[:upper:]' '[:lower:]' | tr '_' '-').json"
done < <(jq -r '.cells[]|[.id,.state,.activity,.reason]|@tsv' "$output/report.json")

artifact_files=$(find "$output" -type f ! -name 'causal-denominator-artifact.json' | wc -l | awk '{print $1 + 0}')
artifact_bytes=$(find "$output" -type f ! -name 'causal-denominator-artifact.json' -print0 | xargs -0 -r wc -c | awk 'END {print $1 + 0}')
jq -S -n --arg scenario "$scenario" --arg report_digest "$(digest "$output/report.json")" --argjson artifact_files "$artifact_files" --argjson artifact_bytes "$artifact_bytes" \
  --slurpfile report "$output/report.json" \
  '{schema:"gooo/reflexive-loop/causal-denominator-ci-artifact/v1",scenario:$scenario,decision:$report[0].decision,summary:$report[0].summary,report_digest:$report_digest,external_inputs:$report[0].external_inputs,causal_selection:$report[0].proposal.causal_selection,verification_plan:$report[0].proposal.verification_plan,selected_verification:$report[0].selected_verification,denominator_binding:$report[0].denominator_binding,performance_utility:$report[0].performance_utility,lifecycle:$report[0].lifecycle,authority:$report[0].authority,bindings:$report[0].bindings,metrics:[$report[0].cells[]|{id:("gooo.metric.reflexive.causal-denominator."+(.id|ascii_downcase|gsub("_";"-"))),cell:.id,activity:.activity,source_file:"examples/reflexive-loop/main.gooo",source_digest:$report[0].bindings.source_digest,ir_node_kind:"Activity",generated_artifact:("causal-denominator/metrics/"+(.id|ascii_downcase|gsub("_";"-"))+".json"),evaluator:"scripts/causal-denominator-loop.sh",numerator:(if .state=="CLOSED" then 1 else 0 end),denominator:1,state:.state,reason:.reason}],artifact:{files:$artifact_files,bytes:$artifact_bytes},repository_unchanged:$report[0].authority.input_repository_unchanged}' \
  > "$output/causal-denominator-artifact.json"

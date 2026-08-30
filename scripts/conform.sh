#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: conform.sh GOOO REPOSITORY ARTIFACT_DIR" >&2
  exit 64
fi

gooo=$1
repository=$(realpath "$2")
artifact_dir=$(realpath -m "$3")
mkdir -p "$artifact_dir/scenarios"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
contract_digest=$(sha256sum "$repository/contracts/allowed-transformations-v1.json" | awk '{print "sha256:" $1}')
source_digest=$(sha256sum "$repository/examples/reflexive-loop/main.gooo" | awk '{print "sha256:" $1}')
workload_digest=$(sha256sum "$repository/fixtures/use-case/workload.gooo" | awk '{print "sha256:" $1}')

jq -S --arg scenario "normal" --arg digest "$contract_digest" '. + {scenario:$scenario,contract_digest:$digest}' \
  "$repository/fixtures/claims/claim-normal.json" > "$tmp/claim-normal.json"
jq -S --arg claim_id "claim-normal-v1" --arg source "$source_digest" --arg workload "$workload_digest" --arg contract "$contract_digest" \
  '. + {claim_id:$claim_id,source_digest:$source,workload_digest:$workload,contract_digest:$contract}' \
  "$repository/fixtures/receipts/receipt-normal.json" > "$tmp/receipt-normal.json"

run_case() {
  local name=$1
  local claim=$2
  local receipt=$3
  local expected=$4
  local output="$artifact_dir/scenarios/$name"
  bash "$repository/scripts/run-loop.sh" "$gooo" "$repository" "$claim" "$receipt" "$output" "$name"
  jq -e --arg expected "$expected" '.decision==$expected and .summary.total==18 and .precedence==["REFUTED","UNKNOWN","CLOSED"]' "$output/report.json" >/dev/null
}

run_case normal "$tmp/claim-normal.json" "$tmp/receipt-normal.json" PROMOTED

jq -S --arg scenario "missing-receipt" --arg digest "$contract_digest" \
  '. + {scenario:$scenario,contract_digest:$digest}' "$tmp/claim-normal.json" > "$tmp/claim-unknown.json"
jq -S '. + {state:"UNKNOWN",reason:"OBSERVATION_RECEIPT_UNAVAILABLE",next_operation:"PROVIDE_OBSERVATION_RECEIPT"}' \
  "$tmp/receipt-normal.json" > "$tmp/receipt-unknown.json"
run_case unknown "$tmp/claim-unknown.json" "$tmp/receipt-unknown.json" UNKNOWN
jq -e '
  .claim.state=="UNKNOWN" and
  ([.cells[]|select(.state=="UNKNOWN")|has("stage") and has("step") and has("reason") and has("unknown_class") and has("next_operation") and has("blocked_by")]|all) and
  ([.cells[]|select(.state=="UNKNOWN")|.unknown_class]|index("DIRECT_MISSING")) != null
' "$artifact_dir/scenarios/unknown/report.json" >/dev/null

jq -S '.approver=.caller | .scenario="self-approval"' "$tmp/claim-normal.json" > "$tmp/claim-self.json"
run_case self-approval "$tmp/claim-self.json" "$tmp/receipt-normal.json" FAIL_CLOSED
jq -e '.adversarial.reason=="SELF_APPROVAL" and any(.cells[];.reason=="SELF_APPROVAL")' "$artifact_dir/scenarios/self-approval/report.json" >/dev/null

jq -S '.source_digest="sha256:stale-evidence"' "$tmp/receipt-normal.json" > "$tmp/receipt-stale.json"
run_case stale-evidence "$tmp/claim-normal.json" "$tmp/receipt-stale.json" FAIL_CLOSED
jq -e '.adversarial.reason=="STALE_EVIDENCE" and any(.cells[];.reason=="STALE_EVIDENCE")' "$artifact_dir/scenarios/stale-evidence/report.json" >/dev/null

jq -S '.proposal_reuse=true | .reused_proposal_id="sha256:already-used"' "$tmp/receipt-normal.json" > "$tmp/receipt-replay.json"
run_case proposal-replay "$tmp/claim-normal.json" "$tmp/receipt-replay.json" FAIL_CLOSED
jq -e '.adversarial.reason=="PROPOSAL_REPLAY" and any(.cells[];.reason=="PROPOSAL_REPLAY")' "$artifact_dir/scenarios/proposal-replay/report.json" >/dev/null

jq -S '.authority.requested_scope="repository_write" | .scenario="authority-escalation"' "$tmp/claim-normal.json" > "$tmp/claim-authority.json"
run_case authority-escalation "$tmp/claim-authority.json" "$tmp/receipt-normal.json" FAIL_CLOSED
jq -e '.adversarial.reason=="AUTHORITY_ESCALATION_ACCEPTED" and any(.cells[];.reason=="AUTHORITY_ESCALATION_ACCEPTED")' "$artifact_dir/scenarios/authority-escalation/report.json" >/dev/null

jq -S 'del(.target) | .scenario="malformed"' "$tmp/claim-normal.json" > "$tmp/claim-malformed.json"
run_case malformed "$tmp/claim-malformed.json" "$tmp/receipt-normal.json" FAIL_CLOSED
jq -e '.claim.reason=="MALFORMED_CLAIM" and any(.cells[];.reason=="MALFORMED_CLAIM")' "$artifact_dir/scenarios/malformed/report.json" >/dev/null

jq -S '.decision="FIXED_POINT"' "$tmp/receipt-normal.json" > "$tmp/receipt-fixed-point.json"
run_case fixed-point "$tmp/claim-normal.json" "$tmp/receipt-fixed-point.json" FAIL_CLOSED
jq -e '.adversarial.reason=="UNSUPPORTED_FIXED_POINT_DECISION" and any(.cells[];.reason=="UNSUPPORTED_FIXED_POINT_DECISION")' "$artifact_dir/scenarios/fixed-point/report.json" >/dev/null

jq -S '.authority.input_repository_writes=true | .scenario="permission-escalation"' "$tmp/claim-normal.json" > "$tmp/claim-permission.json"
run_case permission-escalation "$tmp/claim-permission.json" "$tmp/receipt-normal.json" FAIL_CLOSED
jq -e '.adversarial.reason=="AUTHORITY_ESCALATION_ACCEPTED" and .authority.repository_writes==0' "$artifact_dir/scenarios/permission-escalation/report.json" >/dev/null

jq -S -n \
  --arg schema "gooo/reflexive-loop/conformance/v1" \
  --argjson executed 9 --argjson reused 0 --argjson skipped 0 \
  --slurpfile normal "$artifact_dir/scenarios/normal/report.json" \
  --slurpfile unknown "$artifact_dir/scenarios/unknown/report.json" \
  --slurpfile self "$artifact_dir/scenarios/self-approval/report.json" \
  --slurpfile stale "$artifact_dir/scenarios/stale-evidence/report.json" \
  --slurpfile replay "$artifact_dir/scenarios/proposal-replay/report.json" \
  --slurpfile authority "$artifact_dir/scenarios/authority-escalation/report.json" \
  --slurpfile malformed "$artifact_dir/scenarios/malformed/report.json" \
  --slurpfile fixed "$artifact_dir/scenarios/fixed-point/report.json" \
  --slurpfile permission "$artifact_dir/scenarios/permission-escalation/report.json" \
  '{schema:$schema,tests:{executed:$executed,reused:$reused,skipped:$skipped},scenarios:[
    {id:"normal",decision:$normal[0].decision},
    {id:"unknown",decision:$unknown[0].decision},
    {id:"self-approval",decision:$self[0].decision},
    {id:"stale-evidence",decision:$stale[0].decision},
    {id:"proposal-replay",decision:$replay[0].decision},
    {id:"authority-escalation",decision:$authority[0].decision},
    {id:"malformed",decision:$malformed[0].decision},
    {id:"fixed-point",decision:$fixed[0].decision},
    {id:"permission-escalation",decision:$permission[0].decision}
  ]}' > "$artifact_dir/conformance.json"

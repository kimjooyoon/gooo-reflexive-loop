#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "usage: propose.sh CLAIM RECEIPT OBSERVATION POLICY TOOL_DIGEST OUTPUT" >&2
  exit 64
fi

claim=$1
receipt=$2
observation=$3
policy=$4
tool_digest=$5
output=$6
mkdir -p "$(dirname "$output")"

claim_valid=false
receipt_valid=false
jq -e '
  .schema=="gooo/reflexive-loop/claim/v1" and
  (.id|type)=="string" and (.state|type)=="string" and (.target|type)=="string" and
  (.requested_change|type)=="string" and (.contract_digest|type)=="string" and
  (.caller|type)=="string" and (.approver|type)=="string" and (.authority|type)=="object"
' "$claim" >/dev/null 2>&1 && claim_valid=true
jq -e '
  .schema=="gooo/reflexive-loop/observation-receipt/v1" and
  (.id|type)=="string" and (.claim_id|type)=="string" and (.state|type)=="string" and
  (.source_digest|type)=="string" and (.workload_digest|type)=="string" and (.contract_digest|type)=="string"
' "$receipt" >/dev/null 2>&1 && receipt_valid=true

if [ "$claim_valid" != true ] || [ "$receipt_valid" != true ]; then
  jq -S -n '{schema:"gooo/reflexive-loop/proposal/v1",state:"REFUTED",reason:"MALFORMED_INPUT",next_operation:"PROVIDE_VALID_CLAIM_AND_RECEIPT",unknown_class:null,blocked_by:[]}' > "$output"
  exit 0
fi

contract_digest=$(jq -r '.contract_digest' "$observation")
source_digest=$(jq -r '.source.digest' "$observation")
workload_digest=$(jq -r '.workload.digest' "$observation")
requested_change=$(jq -r '.requested_change' "$claim")
caller=$(jq -r '.caller' "$claim")
approver=$(jq -r '.approver' "$claim")
receipt_state=$(jq -r '.state' "$receipt")
claim_state=$(jq -r '.state' "$claim")

if [ "$receipt_state" = "UNKNOWN" ]; then
  jq -S -n --arg reason "$(jq -r '.reason // "OBSERVATION_UNKNOWN"' "$receipt")" \
    --arg next "$(jq -r '.next_operation // "PROVIDE_OBSERVATION_RECEIPT"' "$receipt")" \
    '{schema:"gooo/reflexive-loop/proposal/v1",state:"UNKNOWN",reason:$reason,unknown_class:"DIRECT_MISSING",next_operation:$next,blocked_by:[]}' > "$output"
  exit 0
fi

reason=""
if [ "$claim_state" != "CLOSED" ] || [ "$receipt_state" != "CLOSED" ]; then reason="INPUT_NOT_CLOSED"; fi
if [ "$caller" = "$approver" ]; then reason="SELF_APPROVAL"; fi
if [ "$(jq -r '.source_digest' "$receipt")" != "$source_digest" ] ||
   [ "$(jq -r '.workload_digest' "$receipt")" != "$workload_digest" ] ||
   [ "$(jq -r '.contract_digest' "$receipt")" != "$contract_digest" ]; then reason="STALE_EVIDENCE"; fi
if [ "$(jq -r '.contract_digest' "$claim")" != "$contract_digest" ]; then reason="CONTRACT_DIGEST_MISMATCH"; fi
if [ "$(jq -r '.proposal_reuse // false' "$receipt")" = "true" ] || [ "$(jq -r '.reused_proposal_id // empty' "$receipt")" != "" ]; then reason="PROPOSAL_REPLAY"; fi
if [ "$(jq -r '.decision // empty' "$receipt")" = "FIXED_POINT" ]; then reason="UNSUPPORTED_FIXED_POINT_DECISION"; fi
if [ "$(jq -r '.authority.requested_scope // empty' "$claim")" != "temporary_output" ] ||
   [ "$(jq -r '.authority.input_repository_writes // true' "$claim")" != "false" ] ||
   [ "$(jq -r '.authority.promotion_rights // true' "$claim")" != "false" ]; then reason="AUTHORITY_ESCALATION"; fi

if [ -n "$reason" ]; then
  jq -S -n --arg reason "$reason" \
    '{schema:"gooo/reflexive-loop/proposal/v1",state:"REFUTED",reason:$reason,unknown_class:null,next_operation:"ROLLBACK_CANDIDATE",blocked_by:[]}' > "$output"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
jq -S -n \
  --arg claim_id "$(jq -r '.id' "$claim")" \
  --arg receipt_id "$(jq -r '.id' "$receipt")" \
  --arg transformation_id "$(jq -r '.requested_change' "$claim")" \
  --arg selector_activity "$(jq -r '.authority' "$policy")" \
  --arg apply_activity "$(jq -r --arg id "$requested_change" '.transformations[]|select(.id==$id)|.apply_activity' "$policy")" \
  --arg source_digest "$source_digest" \
  --arg workload_digest "$workload_digest" \
  --arg contract_digest "$contract_digest" \
  --arg tool_digest "$tool_digest" \
  '{schema:"gooo/reflexive-loop/proposal/v1",state:"CLOSED",claim_id:$claim_id,receipt_id:$receipt_id,transformation_id:$transformation_id,selector_activity:$selector_activity,apply_activity:$apply_activity,source_digest:$source_digest,workload_digest:$workload_digest,contract_digest:$contract_digest,tool_digest:$tool_digest,deterministic:true,authority_scope:"temporary_output",next_operation:"APPLY_ALLOWED_META_ACTIVITY"}' > "$tmp/body.json"
proposal_digest=$(sha256sum "$tmp/body.json" | awk '{print $1}')
jq -S --arg proposal_id "sha256:$proposal_digest" '. + {proposal_id:$proposal_id}' "$tmp/body.json" > "$output"

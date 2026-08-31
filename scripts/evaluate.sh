#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 11 ]; then
  echo "usage: evaluate.sh DENOMINATOR CATALOG CLAIM RECEIPT OBSERVATION PROPOSAL ORACLE PAIR BOUNDARY ARTIFACT OUTPUT" >&2
  exit 64
fi

denominator=$1
catalog=$2
claim=$3
receipt=$4
observation=$5
proposal=$6
oracle=$7
pair=$8
boundary=$9
artifact=${10}
output=${11}

jq -S -n \
  --slurpfile d "$denominator" \
  --slurpfile c "$catalog" \
  --slurpfile cl "$claim" \
  --slurpfile rc "$receipt" \
  --slurpfile obs "$observation" \
  --slurpfile p "$proposal" \
  --slurpfile o "$oracle" \
  --slurpfile pair "$pair" \
  --slurpfile boundary "$boundary" \
  --slurpfile artifact "$artifact" '
  ($d[0]) as $den |
  ($c[0]) as $catalog |
  ($cl[0]) as $claim |
  ($rc[0]) as $receipt |
  ($obs[0]) as $observation |
  ($p[0]) as $proposal |
  ($o[0]) as $oracle |
  ($pair[0]) as $workload_pair |
  ($boundary[0]) as $effect |
  ($artifact[0]) as $artifact_manifest |
  def closed($cell;$reason): {cell_id:$cell.id,state:"CLOSED",stage:$cell.stage,step:$cell.step,reason:$reason,unknown_class:null,next_operation:"NONE",blocked_by:[]};
  def unknown($cell;$reason;$class;$next;$blocked): {cell_id:$cell.id,state:"UNKNOWN",stage:$cell.stage,step:$cell.step,reason:$reason,unknown_class:$class,next_operation:$next,blocked_by:$blocked};
  def refuted($cell;$reason;$next): {cell_id:$cell.id,state:"REFUTED",stage:$cell.stage,step:$cell.step,reason:$reason,unknown_class:null,next_operation:$next,blocked_by:[]};
  def malformed_claim: (($claim.schema // "") != "gooo/reflexive-loop/claim/v1" or (($claim.id // null)|type)!="string" or (($claim.target // null)|type)!="string" or (($claim.requested_change // null)|type)!="string" or (($claim.contract_digest // null)|type)!="string" or (($claim.caller // null)|type)!="string" or (($claim.approver // null)|type)!="string" or (($claim.authority // null)|type)!="object");
  def malformed_receipt: (($receipt.schema // "") != "gooo/reflexive-loop/observation-receipt/v1" or (($receipt.id // null)|type)!="string" or (($receipt.claim_id // null)|type)!="string" or (($receipt.state // null)|type)!="string" or (($receipt.source_digest // null)|type)!="string" or (($receipt.workload_digest // null)|type)!="string" or (($receipt.contract_digest // null)|type)!="string");
  def stale: ((malformed_receipt|not) and (($receipt.source_digest // "") != ($observation.source.digest // "") or ($receipt.workload_digest // "") != ($observation.workload.digest // "") or ($receipt.contract_digest // "") != ($observation.contract_digest // "")));
  def self_approval: ((malformed_claim|not) and $claim.caller == $claim.approver);
  def replay: ((malformed_receipt|not) and (($receipt.proposal_reuse // false) == true or (($receipt.reused_proposal_id // "")|length)>0));
  def authority_escalation: ((malformed_claim|not) and (($claim.authority.requested_scope // "") != "temporary_output" or ($claim.authority.input_repository_writes != false) or ($claim.authority.promotion_rights != false)));
  def fixed_point: ((malformed_receipt|not) and (($receipt.decision // "") == "FIXED_POINT"));
  def contract_ok: ((malformed_claim|not) and (malformed_receipt|not) and $claim.contract_digest == $observation.contract_digest and $receipt.contract_digest == $observation.contract_digest);
  def observation_ok: (($observation.schema // "") == "gooo/reflexive-loop/observation/v1" and $observation.meta_graph.schema_version == "gooo-graph/v1" and $observation.meta_graph.activity_nodes == $den.target_cells and $observation.resolutions.expected == $den.target_cells and $observation.resolutions.closed == $den.target_cells and $observation.resolutions.unknown == 0 and $observation.resolutions.refuted == 0);
  def candidate_ready: ($proposal.state == "CLOSED" and $proposal.deterministic == true and $proposal.authority_scope == "temporary_output");
  def pair_ready: ($workload_pair.state == "CLOSED" and $workload_pair.exact_identity == true and $workload_pair.before.status == 0 and $workload_pair.after.status == 0);
  def effect_ok: ($effect.repository_writes == 0 and $effect.before_digest == $effect.after_digest);
  (if malformed_claim then {cell:"CLAIM_OBSERVED",reason:"MALFORMED_CLAIM",next:"PROVIDE_VALID_CLAIM"}
   elif self_approval then {cell:"CLAIM_OBSERVED",reason:"SELF_APPROVAL",next:"REQUIRE_INDEPENDENT_APPROVER"}
   elif malformed_receipt then {cell:"RECEIPT_OBSERVED",reason:"MALFORMED_RECEIPT",next:"PROVIDE_VALID_RECEIPT"}
   elif fixed_point then {cell:"RECEIPT_OBSERVED",reason:"UNSUPPORTED_FIXED_POINT_DECISION",next:"PROVIDE_CLOSED_OR_EXPLICIT_REFUTED_RECEIPT"}
   elif stale then {cell:"RECEIPT_OBSERVED",reason:"STALE_EVIDENCE",next:"RECAPTURE_CURRENT_OBSERVATION"}
   elif replay then {cell:"PROPOSAL_DETERMINISTIC",reason:"PROPOSAL_REPLAY",next:"ISSUE_NEW_PROPOSAL_DIGEST"}
   elif authority_escalation then {cell:"ADVERSE_AUTHORITY_REJECTED",reason:"AUTHORITY_ESCALATION_ACCEPTED",next:"DROP_ESCALATED_AUTHORITY"}
   else null end) as $adverse |
  (if malformed_claim then refuted($den.cells[0];"MALFORMED_CLAIM";"PROVIDE_VALID_CLAIM")
   elif self_approval then refuted($den.cells[0];"SELF_APPROVAL";"REQUIRE_INDEPENDENT_APPROVER")
   else closed($den.cells[0];"CLAIM_OBSERVED") end) as $claim_fact |
  (if malformed_receipt then refuted($den.cells[1];"MALFORMED_RECEIPT";"PROVIDE_VALID_RECEIPT")
   elif fixed_point then refuted($den.cells[1];"UNSUPPORTED_FIXED_POINT_DECISION";"PROVIDE_CLOSED_OR_EXPLICIT_REFUTED_RECEIPT")
   elif stale then refuted($den.cells[1];"STALE_EVIDENCE";"RECAPTURE_CURRENT_OBSERVATION")
   elif ($receipt.state // "") == "UNKNOWN" then unknown($den.cells[1];($receipt.reason // "RECEIPT_UNAVAILABLE");"DIRECT_MISSING";($receipt.next_operation // "PROVIDE_OBSERVATION_RECEIPT");[])
   elif ($receipt.state // "") == "CLOSED" then closed($den.cells[1];"RECEIPT_OBSERVED")
   else refuted($den.cells[1];"UNRECOGNIZED_RECEIPT_STATE";"RESTORE_RECEIPT_STATE") end) as $receipt_fact |
  {
    CLAIM_OBSERVED:$claim_fact,
    RECEIPT_OBSERVED:$receipt_fact,
    CONTRACT_BOUND:(if contract_ok then closed($den.cells[2];"CONTRACT_DIGEST_MATCH") elif malformed_claim or malformed_receipt then unknown($den.cells[2];"CONTRACT_DIGEST_UNAVAILABLE";"DIRECT_MISSING";"PROVIDE_PINNED_CONTRACT_DIGEST";[]) elif ($receipt.state // "") == "UNKNOWN" then unknown($den.cells[2];"CONTRACT_DIGEST_BLOCKED_BY_RECEIPT";"DEPENDENCY_BLOCKED";"RESOLVE_UNKNOWN_PREDECESSORS";["RECEIPT_OBSERVED"]) else refuted($den.cells[2];"CONTRACT_DIGEST_MISMATCH";"RESTORE_PINNED_CONTRACT") end),
    META_GRAPH_OBSERVED:(if observation_ok then closed($den.cells[3];"META_GRAPH_OBSERVED") else refuted($den.cells[3];"META_GRAPH_ACTIVITY_SET_MISMATCH";"RESTORE_GOOO_META_SOURCE") end),
    META_ACTIVITIES_RESOLVED:(if observation_ok then closed($den.cells[4];"META_ACTIVITIES_UNIQUE") else unknown($den.cells[4];"META_ACTIVITY_RECEIPT_UNAVAILABLE";"DIRECT_MISSING";"RESTORE_EXACT_META_ACTIVITY_SET";[]) end),
    PROPOSAL_DETERMINISTIC:(if self_approval or replay or stale then refuted($den.cells[5];($adverse.reason // "PROPOSAL_REPLAY_MISMATCH");"REPLAY_SAME_CLAIM_RECEIPT") elif ($receipt.state // "") == "UNKNOWN" then unknown($den.cells[5];"PROPOSAL_BLOCKED_BY_RECEIPT";"DEPENDENCY_BLOCKED";"RESOLVE_UNKNOWN_PREDECESSORS";["RECEIPT_OBSERVED"]) elif candidate_ready then closed($den.cells[5];"PROPOSAL_REPLAY_MATCH") else unknown($den.cells[5];"PROPOSAL_UNAVAILABLE";"DIRECT_MISSING";"REPLAY_SAME_CLAIM_RECEIPT";[]) end),
    TRANSFORMATION_ALLOWED:(if candidate_ready and $proposal.transformation_id == "canonicalize-workload-source" and $proposal.apply_activity == "ApplyAllowedMetaActivity" then closed($den.cells[6];"TRANSFORMATION_ALLOWED") elif ($proposal.state // "") == "REFUTED" then refuted($den.cells[6];($proposal.reason // "TRANSFORMATION_NOT_ALLOWED");"RESTORE_ALLOWED_TRANSFORMATION_POLICY") else unknown($den.cells[6];"TRANSFORMATION_POLICY_UNAVAILABLE";"DIRECT_MISSING";"RESTORE_ALLOWED_TRANSFORMATION_POLICY";[]) end),
    TEMPORARY_CLONE_CREATED:(if ($workload_pair.clone_created // false) and $effect.repository_writes == 0 then closed($den.cells[7];"TEMPORARY_CLONE_CREATED") elif ($effect.repository_writes // null) == null then unknown($den.cells[7];"TEMPORARY_CLONE_UNAVAILABLE";"DIRECT_MISSING";"RECREATE_CALLER_OWNED_OUTPUT";[]) elif $effect.repository_writes != 0 then refuted($den.cells[7];"INPUT_REPOSITORY_WRITE_OBSERVED";"RECREATE_CALLER_OWNED_OUTPUT") else unknown($den.cells[7];"TEMPORARY_CLONE_UNAVAILABLE";"DIRECT_MISSING";"RECREATE_CALLER_OWNED_OUTPUT";[]) end),
    META_ACTIVITY_APPLIED:(if ($workload_pair.applied // false) and $workload_pair.apply_activity == "ApplyAllowedMetaActivity" then closed($den.cells[8];"META_ACTIVITY_APPLIED") elif ($workload_pair.state // "") == "REFUTED" then refuted($den.cells[8];"UNAUTHORIZED_SOURCE_EDIT";"REAPPLY_ALLOWED_ACTIVITY_TO_TEMPORARY_OUTPUT") else unknown($den.cells[8];"APPLICATION_UNAVAILABLE";"DIRECT_MISSING";"REAPPLY_ALLOWED_ACTIVITY_TO_TEMPORARY_OUTPUT";[]) end),
    BEFORE_MEASURED:(if ($workload_pair.before.status // null) == 0 then closed($den.cells[9];"BEFORE_WORKLOAD_MEASURED") elif ($workload_pair.before.status // null) == null then unknown($den.cells[9];"BEFORE_MEASUREMENT_UNAVAILABLE";"DIRECT_MISSING";"RESTORE_BEFORE_WORKLOAD";[]) else refuted($den.cells[9];"BEFORE_WORKLOAD_FAILED";"RESTORE_BEFORE_WORKLOAD") end),
    AFTER_MEASURED:(if ($workload_pair.after.status // null) == 0 then closed($den.cells[10];"AFTER_WORKLOAD_MEASURED") elif ($workload_pair.after.status // null) == null then unknown($den.cells[10];"AFTER_MEASUREMENT_UNAVAILABLE";"DIRECT_MISSING";"RESTORE_AFTER_WORKLOAD";[]) else refuted($den.cells[10];"AFTER_WORKLOAD_FAILED";"RESTORE_AFTER_WORKLOAD") end),
    ORACLE_EQUIVALENT:(if $oracle.decision == "CLOSED" and $oracle.equivalent == true then closed($den.cells[11];"SEMANTIC_EQUIVALENCE_VERIFIED") elif ($oracle.decision // "") == "UNKNOWN" or ($oracle|length)==0 then unknown($den.cells[11];"ORACLE_UNAVAILABLE";"DIRECT_MISSING";"RUN_INDEPENDENT_ORACLE";[]) else refuted($den.cells[11];"SEMANTIC_COUNTEREXAMPLE";"ROLLBACK_CANDIDATE") end),
    EXACT_PAIR_BOUND:(if pair_ready then closed($den.cells[12];"EXACT_PAIR_BOUND") elif ($workload_pair.state // "") == "UNKNOWN" or ($workload_pair|length)==0 then unknown($den.cells[12];"EXACT_BEFORE_AFTER_PAIR_UNAVAILABLE";"DIRECT_MISSING";"REPLAY_SAME_INPUT_TOOL_CONTRACT";[]) else refuted($den.cells[12];"WORKLOAD_PAIR_IDENTITY_MISMATCH";"REPLAY_SAME_INPUT_TOOL_CONTRACT") end),
    PROMOTION_GATED:(if pair_ready and $oracle.decision == "CLOSED" and candidate_ready then closed($den.cells[13];"ALL_EVIDENCE_CLOSED") else unknown($den.cells[13];"PROMOTION_EVIDENCE_INCOMPLETE";"DEPENDENCY_BLOCKED";"RESOLVE_ALL_PREDECESSORS";[]) end),
    ROLLBACK_BOUND:(if ($workload_pair.rollback.mode // "") == "OUTPUT_ONLY" and ($workload_pair.rollback.repository_writes // null) == 0 then closed($den.cells[14];"ROLLBACK_BOUNDARY_OBSERVED") else unknown($den.cells[14];"ROLLBACK_BOUNDARY_UNAVAILABLE";"DIRECT_MISSING";"RESTORE_OUTPUT_ONLY_ROLLBACK";[]) end),
    ADVERSE_AUTHORITY_REJECTED:(if authority_escalation then refuted($den.cells[15];"AUTHORITY_ESCALATION_ACCEPTED";"DROP_ESCALATED_AUTHORITY") elif malformed_claim then unknown($den.cells[15];"AUTHORITY_EVIDENCE_UNAVAILABLE";"DIRECT_MISSING";"PROVIDE_AUTHORITY_EVIDENCE";[]) else closed($den.cells[15];"ADVERSE_AUTHORITY_REJECTED") end),
    READ_ONLY_BOUND:(if effect_ok then closed($den.cells[16];"INPUT_REPOSITORY_UNCHANGED") elif ($effect|length)==0 then unknown($den.cells[16];"READ_ONLY_EVIDENCE_UNAVAILABLE";"DIRECT_MISSING";"COMPARE_REPOSITORY_SNAPSHOTS";[]) else refuted($den.cells[16];"INPUT_REPOSITORY_CHANGED";"RESTORE_INPUT_REPOSITORY") end),
    ARTIFACT_EMITTED:(if $artifact_manifest.manifest_ok == true then closed($den.cells[17];"EVIDENCE_ARTIFACT_EMITTED") else unknown($den.cells[17];"EVIDENCE_ARTIFACT_UNAVAILABLE";"DIRECT_MISSING";"REBUILD_EVIDENCE_ARTIFACT";[]) end)
  } as $facts |
  (reduce $den.cells[] as $cell ({cells:[],decisions:{}};
    . as $acc |
    ($facts[$cell.id]) as $fact |
    ([$cell.depends_on[]? | $acc.decisions[.]]) as $deps |
    (if $fact.state == "REFUTED" then $fact
     elif $fact.state == "UNKNOWN" then $fact
     elif any($deps[]?; .state == "REFUTED") then refuted($cell;"DEPENDENCY_REFUTED";"RESOLVE_REFUTED_PREDECESSORS") + {blocked_by:[$deps[]|select(.state=="REFUTED")|.cell_id]}
     elif any($deps[]?; .state == "UNKNOWN") then unknown($cell;"DEPENDENCY_BLOCKED";"DEPENDENCY_BLOCKED";"RESOLVE_UNKNOWN_PREDECESSORS";[$deps[]|select(.state=="UNKNOWN")|.cell_id])
     else $fact end) as $decision |
    .cells += [$cell + $decision] |
    .decisions[$cell.id] = ($cell + $decision)
  )) as $evaluation |
  ([$evaluation.cells[]|select(.state=="CLOSED")]|length) as $closed |
  ([$evaluation.cells[]|select(.state=="UNKNOWN")]|length) as $unknown |
  ([$evaluation.cells[]|select(.state=="REFUTED")]|length) as $refuted |
  ([$evaluation.cells[]|select(.unknown_class=="DIRECT_MISSING")]|length) as $direct_missing |
  ([$evaluation.cells[]|select(.unknown_class=="DEPENDENCY_BLOCKED")]|length) as $dependency_blocked |
  (if $refuted > 0 then "FAIL_CLOSED" elif $unknown > 0 then "UNKNOWN" elif $evaluation.decisions.PROMOTION_GATED.state == "CLOSED" then "PROMOTED" else "NOT_PROMOTED" end) as $decision |
  ([$catalog.metrics[] as $m | $evaluation.decisions[$m.cell] + {id:$m.id,activity:$m.activity,source_file:$catalog.source_file,ir_node_kind:$m.ir_node_kind,generated_artifact:$m.generated_artifact,evaluator:$m.evaluator,numerator:(if $evaluation.decisions[$m.cell].state=="CLOSED" then 1 else 0 end),denominator:$catalog.fixed_denominator}]) as $metrics |
  (if ($workload_pair.after.wall_ms // null) != null and ($workload_pair.after.wall_ms // 0) < ($workload_pair.before.wall_ms // 0) then
     {state:"CLOSED",stage:"VERIFY",step:"INTERPRET_PERFORMANCE",reason:"PERFORMANCE_IMPROVEMENT_MEASURED",unknown_class:null,next_operation:"NONE",blocked_by:[]}
   elif ($workload_pair.after.wall_ms // null) != null then
     {state:"UNKNOWN",stage:"VERIFY",step:"INTERPRET_PERFORMANCE",reason:"NO_PERFORMANCE_IMPROVEMENT_CLAIM",unknown_class:"DIRECT_MISSING",next_operation:"DO_NOT_INFER_UTILITY_FROM_GOOD_METRICS",blocked_by:[]}
   else {state:"UNKNOWN",stage:"VERIFY",step:"INTERPRET_PERFORMANCE",reason:"PERFORMANCE_MEASUREMENT_UNAVAILABLE",unknown_class:"DIRECT_MISSING",next_operation:"MEASURE_SAME_WORKLOAD_AGAIN",blocked_by:[]} end) as $utility |
  {
    schema:"gooo/reflexive-loop/evaluation/v1",
    scenario:($claim.scenario // null),
    decision:$decision,
    precedence:["REFUTED","UNKNOWN","CLOSED"],
    summary:{total:$den.target_cells,closed:$closed,unknown:$unknown,refuted:$refuted,direct_missing:$direct_missing,dependency_blocked:$dependency_blocked},
    claim:(if $refuted>0 then {state:"REFUTED",stage:"EVALUATE",step:"FAIL_CLOSED",reason:([$evaluation.cells[]|select(.state=="REFUTED")|.reason]|first),unknown_class:null,next_operation:([$evaluation.cells[]|select(.state=="REFUTED")|.next_operation]|first),blocked_by:[]} elif $unknown>0 then ([$evaluation.cells[]|select(.state=="UNKNOWN")]|first) else {state:"CLOSED",stage:"PROMOTE",step:"GATE_PROMOTION",reason:"ALL_EVIDENCE_CLOSED",unknown_class:null,next_operation:"NONE",blocked_by:[]} end),
    promotion:{state:(if $evaluation.decisions.PROMOTION_GATED.state=="CLOSED" and $refuted==0 and $unknown==0 then "PROMOTED" else "NOT_PROMOTED" end),candidate:(if $evaluation.decisions.PROMOTION_GATED.state=="CLOSED" and $refuted==0 and $unknown==0 then "temporary_output" else null end),utility:$utility},
    cells:$evaluation.cells,
    proofs:([$den.proof_totals[] as $proof | {proof_choice:$proof.proof_choice,closed:([$evaluation.cells[]|select(.proof_choice==$proof.proof_choice and .state=="CLOSED")]|length),total:$proof.total}]),
    indicators:([$den.indicator_totals[] as $indicator | {indicator_class:$indicator.indicator_class,closed:([$evaluation.cells[]|select(.indicator_class==$indicator.indicator_class and .state=="CLOSED")]|length),total:$indicator.total}]),
    metrics:$metrics,
    bindings:{source_file:$catalog.source_file,one_to_one:(([$metrics[]|select(.activity != null and .ir_node_kind=="Activity" and .generated_artifact != null and .evaluator != null)]|length)==$den.target_cells),entries:$metrics},
    observed:{source:$observation.source,meta_graph:$observation.meta_graph,inventory:$observation.inventory},
    performance:{before:($workload_pair.before // null),after:($workload_pair.after // null),exact_identity:($workload_pair.exact_identity // false),tool_digest:($workload_pair.tool_digest // null),contract_digest:($workload_pair.contract_digest // null),input_digest:($workload_pair.input_digest // null)},
    authority:{scope:($claim.authority.requested_scope // null),promotion_rights:$claim.authority.promotion_rights,repository_writes:$effect.repository_writes,root_readme_readiness:"EXCLUDED"},
    artifact:$artifact_manifest,
    adversarial:(if $adverse == null then {scenario:"none",state:"CLOSED"} else {scenario:$adverse.cell,state:"REFUTED",reason:$adverse.reason,next_operation:$adverse.next} end)
  }
' > "$output"

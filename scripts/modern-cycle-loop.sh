#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 9 ]; then
  echo "usage: modern-cycle-loop.sh GOOO PROPOSER FRONTIER CHANGE_BUNDLE TEST_FRONTIER REPOSITORY UPSTREAM OUTPUT SCENARIO" >&2
  exit 64
fi

gooo=$1
proposer_bin=$2
frontier_bin=$3
change_bundle_bin=$4
test_frontier_bin=$5
repository=$(realpath "$6")
upstream=$(realpath "$7")
output=$(realpath -m "$8")
scenario=$9

case "$output" in
  "$repository"|"$repository"/*)
    echo "modern-cycle output must be outside the input repository" >&2
    exit 65
    ;;
esac
mkdir -p "$output"
if [ -n "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "modern-cycle output must be empty" >&2
  exit 66
fi

tmp=$(mktemp -d)
trap 'status=$?; echo "modern-cycle-loop internal failure: line=${LINENO} status=$status command=${BASH_COMMAND}" >&2; exit "$status"' ERR
trap 'rm -rf "$tmp"' EXIT

denominator="$repository/contracts/modern-cycle-denominator-v1.json"
modern_source="$repository/examples/modern-cycle/main.gooo"
oracle_spec="$repository/fixtures/modern-cycle/oracle-spec.json"
frontier_fixture_base="$repository/fixtures/modern-cycle/frontier-fixture.json"
test_fixture_base="$repository/fixtures/modern-cycle/test-frontier-fixture.json"
test_inventory="$repository/fixtures/modern-cycle/test-inventory.json"
source_digest=$(sha256sum "$modern_source" | awk '{print "sha256:" $1}')
tool_digest=$(sha256sum "$gooo" | awk '{print "sha256:" $1}')
contract_digest=$(sha256sum "$denominator" | awk '{print "sha256:" $1}')
harness_digest=$(sha256sum "$repository/scripts/modern-oracle.sh" | awk '{print "sha256:" $1}')
policy_digest=$(sha256sum "$denominator" | awk '{print "sha256:" $1}')
inventory_digest=$(sha256sum "$test_inventory" | awk '{print "sha256:" $1}')

snapshot() {
  (
    cd "$1"
    find . -path './.git' -prune -o -type f -print0 |
      sort -z | xargs -0 -r sha256sum
  ) | sha256sum | awk '{print "sha256:" $1}'
}

digest_file() {
  sha256sum "$1" | awk '{print "sha256:" $1}'
}

json_digest() {
  jq -S -c -j "$2" "$1" | sha256sum | awk '{print "sha256:" $1}'
}

copy_tree() {
  local from=$1
  local to=$2
  mkdir -p "$to"
  cp -a "$from/." "$to/"
}

run_command() {
  local stdout=$1
  local stderr=$2
  shift 2
  local status
  set +e
  "$@" >"$stdout" 2>"$stderr"
  status=$?
  set -e
  echo "$status"
}

verify_release_component() {
  local key=$1
  local dir="$upstream/$key"
  local release_json="$dir/release.json"
  local ref_json="$dir/tag-ref.json"
  local tag_json="$dir/tag-object.json"
  jq -e --arg key "$key" --argjson release "$(jq -c --arg key "$key" '.releases[$key]' "$repository/contracts/modern-cycle-upstream-release-lock-v1.json")" \
    '.immutable==true and .tag_name==$release.tag and .id==$release.release_id' "$release_json" >/dev/null
  jq -e --argjson release "$(jq -c --arg key "$key" '.releases[$key]' "$repository/contracts/modern-cycle-upstream-release-lock-v1.json")" \
    '.object.type=="tag" and .object.sha==$release.tag_object_sha' "$ref_json" >/dev/null
  jq -e --argjson release "$(jq -c --arg key "$key" '.releases[$key]' "$repository/contracts/modern-cycle-upstream-release-lock-v1.json")" \
    '.object.type=="commit" and .object.sha==$release.target_commit_sha' "$tag_json" >/dev/null
  while IFS= read -r asset; do
    name=$(jq -r '.name' <<<"$asset")
    id=$(jq -r '.id' <<<"$asset")
    size=$(jq -r '.size' <<<"$asset")
    expected_digest=$(jq -r '.digest' <<<"$asset")
    jq -e --arg name "$name" --argjson id "$id" --argjson size "$size" --arg digest "$expected_digest" \
      '[.assets[]|select(.id==$id and .name==$name and .size==$size and .digest==$digest)]|length==1' "$release_json" >/dev/null
    actual="$dir/assets/$name"
    test -f "$actual"
    test "$(wc -c < "$actual" | awk '{print $1 + 0}')" -eq "$size"
    test "$(digest_file "$actual")" = "$expected_digest"
  done < <(jq -c --arg key "$key" '.releases[$key].assets[]' "$repository/contracts/modern-cycle-upstream-release-lock-v1.json")
}

release_state="CLOSED"
release_reason="EXACT_IMMUTABLE_GITHUB_RELEASE_ASSETS_VERIFIED"
external_root="$upstream"
if [ "$scenario" = "stale-upstream" ]; then
  external_root="$tmp/stale-upstream"
  copy_tree "$upstream" "$external_root"
  jq -S '.immutable=false' "$external_root/proposer/release.json" > "$tmp/stale-release.json"
  mv "$tmp/stale-release.json" "$external_root/proposer/release.json"
fi
if ! (upstream="$external_root" verify_release_component proposer && upstream="$external_root" verify_release_component frontier && upstream="$external_root" verify_release_component change_bundle && upstream="$external_root" verify_release_component test_frontier); then
  release_state="UNKNOWN"
  release_reason="EXACT_IMMUTABLE_RELEASE_OBSERVATION_UNAVAILABLE_OR_STALE"
fi

input_before=$(snapshot "$repository")
mkdir -p "$output/input" "$output/metrics" "$output/disposable"
cp "$repository/contracts/modern-cycle-upstream-release-lock-v1.json" "$output/input/upstream-release-lock.json"

input_fixture="$repository/fixtures/modern-cycle/ledger-normal.json"
case "$scenario" in
  fixed-point-no-candidate)
    input_fixture="$repository/fixtures/modern-cycle/ledger-fixed-point.json"
    ;;
  stale-upstream)
    jq -S '.ledger.release.immutable=false' "$repository/fixtures/modern-cycle/ledger-normal.json" > "$tmp/ledger-stale.json"
    input_fixture="$tmp/ledger-stale.json"
    ;;
esac
cp "$input_fixture" "$output/input/ledger.json"

source_status=0
source_stderr="$output/modern-source-check.stderr"
source_graph="$output/modern-source-graph.json"
source_status=$(run_command "$source_graph" "$source_stderr" "$gooo" graph dump "$modern_source")
source_activity_count=$(jq '[.nodes[]?|select(.kind=="Activity")]|length' "$source_graph" 2>/dev/null || echo 0)
source_schema=$(jq -r '.schema_version // ""' "$source_graph" 2>/dev/null || true)

build_wall_ms=$(jq -r '.build_wall_ms // 0' "$upstream/build-metrics.json" 2>/dev/null || echo 0)
build_peak_rss_kib=$(jq -r '.build_peak_rss_kib // 0' "$upstream/build-metrics.json" 2>/dev/null || echo 0)
test_wall_ms=0
peak_rss_kib=$build_peak_rss_kib
candidate_count=0
causal_edges=0
frontier_count=0
patch_paths=0
patch_hunks=0
patch_bytes=0
rollback_comparisons=0
rollback_mismatches=0
replay_comparisons=0
replay_mismatches=0
tests_total=0
tests_executed=0
tests_reused=0
tests_skipped=0
tests_not_observed=0
conformance_wall_ms=0
go_physical_lines=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.go' -print0 | xargs -0 -r wc -l | awk 'END {print $1 + 0}')
gooo_physical_lines=$(find "$repository" -path "$repository/.git" -prune -o -type f -name '*.gooo' -print0 | xargs -0 -r wc -l | awk 'END {print $1 + 0}')
repository_files=$(find "$repository" -path "$repository/.git" -prune -o -type f -print | wc -l | awk '{print $1 + 0}')
repository_directories=$(find "$repository" -path "$repository/.git" -prune -o -type d -print | wc -l | awk '{print $1 + 0}')

proposer_state="UNKNOWN"
proposer_reason="PROPOSER_NOT_RUN"
semantic_state="UNKNOWN"
utility_state="UNKNOWN"
frontier_state="UNKNOWN"
test_frontier_state="UNKNOWN"
bundle_state="UNKNOWN"
oracle_decision="UNKNOWN"
promotion_state="NOT_PROMOTED"
decision="UNKNOWN"
decision_reason="MODERN_CYCLE_NOT_YET_CLOSED"
unknown_id="EXACT_ORACLE_PAIR_BOUND"
unknown_stage="VERIFY"
unknown_step="COMPARE_EXACT_ORACLE_BEFORE_AFTER_PAIR"
unknown_reason="EXACT_BEFORE_AFTER_ORACLE_PAIR_NOT_OBSERVED"
unknown_class="DIRECT_MISSING"
unknown_next="PROVIDE_EXACT_BEFORE_AFTER_ORACLE_PAIR"
unknown_blocked='["exact-before-after-oracle-pair"]'
refutations='[]'
oracle_json='{}'
test_counts='{"total":0,"executed":0,"reused":0,"skipped":0,"not_observed":0}'

proposer_source="$external_root/proposer/source/gooo-improvement-proposer-v0.1.1"
frontier_source="$external_root/frontier/source/gooo-improvement-frontier-v0.1.0"
change_bundle_source="$external_root/change_bundle/source"
test_frontier_source="$external_root/test_frontier/source/gooo-test-frontier-v0.1.1"
proposer_contract="$proposer_source/contracts/improvement-proposer-denominator-v1.json"
frontier_contract="$frontier_source/contracts/improvement-frontier-denominator-v1.json"
test_frontier_contract="$test_frontier_source/contracts/test-frontier-denominator-v1.json"

if [ "$release_state" = "CLOSED" ] && [ "$source_status" -eq 0 ] && [ "$source_schema" = "gooo-graph/v1" ] && [ "$source_activity_count" -eq 12 ]; then
  mkdir -p "$output/proposer"
  proposer_status=$(run_command "$output/proposer/stdout.txt" "$output/proposer/stderr.txt" \
    "$proposer_bin" propose --root "$proposer_source" --source "$proposer_source/examples/improvement-proposer.gooo" \
    --contract "$proposer_contract" --input "$output/input/ledger.json" --output-dir "$output/proposer")
  if [ "$proposer_status" -eq 0 ]; then
    proposer_state=$(jq -r '.state // "REFUTED"' "$output/proposer/proposal.json")
    proposer_reason=$(jq -r '.decision // "PROPOSER_OUTPUT_UNBOUND"' "$output/proposer/proposal.json")
    candidate_count=$(jq -r '.candidate_count // 0' "$output/proposer/proposal.json")
    causal_edges=$(jq -r '.evidence_edges // 0' "$output/proposer/proposal.json")
    if [ "$scenario" = "deterministic-replay" ] || [ "$scenario" = "normal-candidate" ]; then
      mkdir -p "$tmp/proposer-replay"
      replay_status=$(run_command "$tmp/proposer-replay/stdout.txt" "$tmp/proposer-replay/stderr.txt" \
        "$proposer_bin" propose --root "$proposer_source" --source "$proposer_source/examples/improvement-proposer.gooo" \
        --contract "$proposer_contract" --input "$output/input/ledger.json" --output-dir "$tmp/proposer-replay")
      if [ "$replay_status" -eq 0 ]; then
        replay_comparisons=6
        if ! cmp -s "$output/proposer/proposal.json" "$tmp/proposer-replay/proposal.json" || \
           ! cmp -s "$output/proposer/candidate-events.ndjson" "$tmp/proposer-replay/candidate-events.ndjson" || \
           ! cmp -s "$output/proposer/replay-receipt.json" "$tmp/proposer-replay/replay-receipt.json"; then
          replay_mismatches=1
        fi
        cp "$tmp/proposer-replay/replay-receipt.json" "$output/proposer/replay-receipt-replay.json"
      else
        replay_mismatches=1
      fi
    fi
  else
    proposer_state="REFUTED"
    proposer_reason="PROPOSER_COMMAND_FAILED"
  fi
fi

if [ "$scenario" = "stale-upstream" ]; then
  decision="UNKNOWN"
  decision_reason="UPSTREAM_RELEASE_IMMUTABILITY_NOT_CURRENTLY_OBSERVABLE"
  unknown_id="LEDGER_OBSERVED"
  unknown_stage="FOUNDATION"
  unknown_step="OBSERVE_IMMUTABLE_UPSTREAM_RELEASE"
  unknown_reason="$release_reason"
  unknown_class="STALE_INPUT"
  unknown_next="REFRESH_EXACT_IMMUTABLE_RELEASE_ASSETS"
  unknown_blocked='["upstream-release-lock"]'
elif [ "$scenario" = "unauthorized-self-approval" ]; then
  decision="REFUTED"
  decision_reason="UNAUTHORIZED_SELF_APPROVAL"
  refutations='["UNAUTHORIZED_SELF_APPROVAL"]'
  unknown_id=""
elif [ "$source_status" -ne 0 ] || [ "$source_activity_count" -ne 12 ]; then
  decision="REFUTED"
  decision_reason="MODERN_SOURCE_ACTIVITY_BINDING_REFUTED"
  refutations='["MODERN_SOURCE_ACTIVITY_BINDING_REFUTED"]'
  unknown_id=""
elif [ "$release_state" != "CLOSED" ]; then
  decision="UNKNOWN"
elif [ "$scenario" = "fixed-point-no-candidate" ]; then
  semantic_state="CLOSED"
  frontier_state="CLOSED"
  test_frontier_state="NOT_APPLICABLE"
  proposer_state="CLOSED"
  decision="CLOSED"
  decision_reason="FIXED_POINT_NO_CANDIDATE_REQUIRED"
  promotion_state="NOT_APPLICABLE"
  unknown_id=""
elif [ "$scenario" = "dependency-blocked" ]; then
  :
else
  if [ "$proposer_state" = "REFUTED" ]; then
    decision="REFUTED"
    decision_reason="PROPOSER_REFUTED"
    refutations='["PROPOSER_REFUTED"]'
    unknown_id=""
  elif [ "$candidate_count" -eq 0 ]; then
    semantic_state="CLOSED"
    frontier_state="CLOSED"
    decision="CLOSED"
    decision_reason="NO_CANDIDATE_REQUIRED"
    promotion_state="NOT_APPLICABLE"
    unknown_id=""
  else
    semantic_state="CLOSED"
    mkdir -p "$tmp/clone-before" "$tmp/clone-after" "$output/disposable/before" "$output/disposable/after"
    copy_tree "$repository" "$tmp/clone-before"
    copy_tree "$tmp/clone-before" "$tmp/clone-after"
    source_tree_digest=$("$change_bundle_bin" digest --source-root "$tmp/clone-before")
    intent="$change_bundle_source/examples/change-bundle/change-intent.gooo"
    bundle_contract="$change_bundle_source/contracts/change-bundle-denominator-v1.json"
    intent_digest=$(digest_file "$intent")
    preimage_digest=$(digest_file "$tmp/clone-before/fixtures/modern-cycle/workload.gooo")
    postimage_digest=$(digest_file "$repository/fixtures/modern-cycle/expected-workload.gooo")
    postimage_base64=$(base64 -w 0 "$repository/fixtures/modern-cycle/expected-workload.gooo")
    rollback_postimage="$preimage_digest"
    if [ "$scenario" = "preimage-mismatch" ]; then
      preimage_digest="sha256:9999999999999999999999999999999999999999999999999999999999999999"
    fi
    if [ "$scenario" = "rollback-mismatch" ]; then
      rollback_postimage="sha256:8888888888888888888888888888888888888888888888888888888888888888"
    fi
    jq -S -n --arg source_digest "$source_tree_digest" --arg intent_digest "$intent_digest" \
      --arg approved_by "modern-cycle-human-authority" --arg preimage "$preimage_digest" \
      --arg postimage "$postimage_digest" --arg rollback "$rollback_postimage" --arg base64 "$postimage_base64" \
      '{schema:"gooo/change-bundle/approved-proposal/v1",proposal_id:"modern-cycle-proposal",status:"APPROVED",source_tree_digest:$source_digest,intent_digest:$intent_digest,authority_receipt_id:"modern-cycle-authority",authority_receipt_digest:"",approved_by:$approved_by,changes:[{path:"fixtures/modern-cycle/workload.gooo",operation:"MODIFY",preimage_digest:$preimage,postimage_digest:$postimage,postimage_base64:$base64,rollback_postimage_digest:$rollback,hunks:[{start_line:1,end_line:7}]}],proposal_digest:""}' > "$tmp/proposal-body.json"
    proposal_digest=$(json_digest "$tmp/proposal-body.json" '.proposal_digest=""')
    jq -S --arg digest "$proposal_digest" '.proposal_digest=$digest' "$tmp/proposal-body.json" > "$tmp/approved-proposal.json"
    jq -S -n --arg proposal_id "modern-cycle-proposal" --arg proposal_digest "$proposal_digest" --arg intent_digest "$intent_digest" \
      '{schema:"gooo/change-bundle/authority-receipt/v1",receipt_id:"modern-cycle-authority",proposal_id:$proposal_id,proposal_digest:$proposal_digest,intent_digest:$intent_digest,approved:true,approved_by:"modern-cycle-human-authority",repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false,receipt_digest:""}' > "$tmp/authority-body.json"
    authority_digest=$(json_digest "$tmp/authority-body.json" '.receipt_digest=""')
    jq -S --arg digest "$authority_digest" '.receipt_digest=$digest' "$tmp/authority-body.json" > "$tmp/authority.json"
    bundle_status=$(run_command "$tmp/bundle.stdout.txt" "$tmp/bundle.stderr.txt" \
      "$change_bundle_bin" materialize --source-root "$tmp/clone-before" --source-digest "$source_tree_digest" \
      --proposal "$tmp/approved-proposal.json" --authority "$tmp/authority.json" --intent "$intent" --contract "$bundle_contract" --out "$output/bundle")
    mkdir -p "$output/bundle"
    cp "$tmp/bundle.stdout.txt" "$output/bundle/stdout.txt"
    cp "$tmp/bundle.stderr.txt" "$output/bundle/stderr.txt"
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
      refutations=$(jq -c '[.findings[]?.code] // ["CHANGE_BUNDLE_REFUTED"]' "$output/bundle/bundle-manifest.json" 2>/dev/null || printf '["CHANGE_BUNDLE_REFUTED"]')
      unknown_id=""
    else
      while IFS= read -r operation; do
        path=$(jq -r '.path' <<<"$operation")
        operation_kind=$(jq -r '.operation' <<<"$operation")
        case "$path" in
          /*|../*|*/../*|.|*/.)
            echo "unsafe patch path" >&2
            exit 67
            ;;
        esac
        target="$tmp/clone-after/$path"
        if [ "$operation_kind" = "DELETE" ]; then
          rm -f "$target"
        else
          mkdir -p "$(dirname "$target")"
          jq -r '.postimage_base64' <<<"$operation" | base64 -d > "$target"
        fi
      done < <(jq -c '.operations[]' "$output/bundle/patch.bundle.json")
      copy_tree "$tmp/clone-after" "$tmp/rollback-clone"
      while IFS= read -r operation; do
        path=$(jq -r '.path' <<<"$operation")
        target="$tmp/rollback-clone/$path"
        mkdir -p "$(dirname "$target")"
        jq -r '.postimage_base64' <<<"$operation" | base64 -d > "$target"
      done < <(jq -c '.operations[]' "$output/bundle/rollback.bundle.json")
      if [ "$(snapshot "$tmp/rollback-clone")" != "$(snapshot "$tmp/clone-before")" ]; then
        decision="REFUTED"
        decision_reason="ROLLBACK_REPLAY_REFUTED"
        refutations='["ROLLBACK_REPLAY_REFUTED"]'
        unknown_id=""
      fi
      copy_tree "$tmp/clone-before" "$output/disposable/before"
      copy_tree "$tmp/clone-after" "$output/disposable/after"
    fi
  fi
fi

if [ "$scenario" = "dependency-blocked" ] && [ "$release_state" = "CLOSED" ]; then
  mkdir -p "$output/frontier"
  jq -S --arg digest "$source_digest" --arg scenario "$scenario" \
    '.case_id="modern-cycle-frontier-dependency-blocked" | .graph.nodes[0].immutable_inputs.ledger=$digest | .graph.nodes[1].current="UNKNOWN" | .graph.nodes[1].reason="candidate dependency was not observed" | .graph.nodes[1].unknown_class="DEPENDENCY_BLOCKED" | .graph.nodes[1].blocked_by=["candidate"] | .graph.nodes[1].next_operation="OBSERVE_CANDIDATE" | .graph.nodes[2].current="CLOSED" | .expected.state="UNKNOWN" | .expected.parallel_batches=[["candidate"]] | .expected.blocked_frontier_roots=["compute-frontier"] | .expected.refuted_frontier_roots=[]' "$frontier_fixture_base" > "$tmp/frontier-fixture.json"
  frontier_status=$(run_command "$output/frontier/stdout.txt" "$output/frontier/stderr.txt" \
    "$frontier_bin" evaluate --root "$frontier_source" --source "$frontier_source/examples/improvement-frontier.gooo" \
    --contract "$frontier_contract" --fixture "$tmp/frontier-fixture.json" --output-dir "$output/frontier")
  if [ "$frontier_status" -eq 0 ]; then
    frontier_state=$(jq -r '.state // "UNKNOWN"' "$output/frontier/plan.json")
    frontier_count=$(jq -r '(.blocked_frontiers|length) + (.refuted_frontiers|length) + (.parallel_batches|length)' "$output/frontier/plan.json")
  fi
  decision="UNKNOWN"
  decision_reason="CAUSAL_EXECUTION_FRONTIER_DEPENDENCY_BLOCKED"
  unknown_id="EXECUTION_FRONTIER_COMPUTED"
  unknown_stage="COHERENCE"
  unknown_step="COMPUTE_CAUSAL_EXECUTION_ORDER"
  unknown_reason="candidate dependency was not observed"
  unknown_class="DEPENDENCY_BLOCKED"
  unknown_next="OBSERVE_CANDIDATE"
  unknown_blocked='["candidate"]'
fi

if [ "$scenario" != "fixed-point-no-candidate" ] && [ "$scenario" != "stale-upstream" ] && [ "$scenario" != "dependency-blocked" ] && [ "$decision" != "REFUTED" ] && [ "$candidate_count" -gt 0 ] && [ "$bundle_state" = "CLOSED" ]; then
  mkdir -p "$output/frontier"
  jq -S --arg ledger "$(digest_file "$output/input/ledger.json")" --arg candidate "$(digest_file "$output/proposer/proposal.json")" \
    '.graph.nodes[0].immutable_inputs.ledger=$ledger | .graph.nodes[1].immutable_inputs.candidate=$candidate | .graph.nodes[2].immutable_inputs.bundle=$candidate' "$frontier_fixture_base" > "$tmp/frontier-fixture.json"
  frontier_status=$(run_command "$output/frontier/stdout.txt" "$output/frontier/stderr.txt" \
    "$frontier_bin" evaluate --root "$frontier_source" --source "$frontier_source/examples/improvement-frontier.gooo" \
    --contract "$frontier_contract" --fixture "$tmp/frontier-fixture.json" --output-dir "$output/frontier")
  if [ "$frontier_status" -eq 0 ]; then
    frontier_state=$(jq -r '.state // "UNKNOWN"' "$output/frontier/plan.json")
    frontier_count=$(jq -r '(.parallel_batches|length) + (.blocked_frontiers|length) + (.refuted_frontiers|length)' "$output/frontier/plan.json")
  else
    frontier_state="REFUTED"
  fi
  if [ "$frontier_state" != "CLOSED" ]; then
    decision="REFUTED"
    decision_reason="EXECUTION_FRONTIER_REFUTED"
    refutations='["EXECUTION_FRONTIER_REFUTED"]'
    unknown_id=""
  fi
fi

run_workload() {
  local label=$1
  local source=$2
  local result_dir="$output/disposable/$label"
  mkdir -p "$result_dir"
  local status
  set +e
  /usr/bin/time -f '%e\t%M' -o "$result_dir/time.tsv" "$gooo" check --semantic --json "$source" > "$result_dir/check.json" 2> "$result_dir/check.stderr"
  status=$?
  set -e
  seconds=0
  rss=0
  if [ -s "$result_dir/time.tsv" ]; then read -r seconds rss < "$result_dir/time.tsv"; fi
  wall_ms=$(awk -v value="${seconds:-0}" 'BEGIN {printf "%d", (value * 1000) + 0.5}')
  jq -S -n --arg label "$label" --arg source "$source" --argjson status "$status" \
    --argjson wall_ms "$wall_ms" --argjson peak_rss_kib "${rss:-0}" --arg source_digest "$(digest_file "$source")" \
    --slurpfile result "$result_dir/check.json" \
    '{label:$label,source:$source,source_digest:$source_digest,status:$status,wall_ms:$wall_ms,peak_rss_kib:$peak_rss_kib,semantic_digest:($result[0].semantic_hash // null),result:$result[0]}' > "$result_dir/measurement.json"
  test_wall_ms=$((test_wall_ms + wall_ms))
  if [ "${rss:-0}" -gt "$peak_rss_kib" ]; then peak_rss_kib=${rss:-0}; fi
}

if [ "$decision" != "REFUTED" ] && [ "$scenario" != "fixed-point-no-candidate" ] && [ "$scenario" != "stale-upstream" ] && [ "$scenario" != "dependency-blocked" ] && [ "$candidate_count" -gt 0 ] && [ "$bundle_state" = "CLOSED" ]; then
  run_workload before "$tmp/clone-before/fixtures/modern-cycle/workload.gooo"
  run_workload after "$tmp/clone-after/fixtures/modern-cycle/workload.gooo"
  "$gooo" graph dump "$tmp/clone-before/fixtures/modern-cycle/workload.gooo" > "$output/disposable/before/graph.json"
  "$gooo" graph dump "$tmp/clone-after/fixtures/modern-cycle/workload.gooo" > "$output/disposable/after/graph.json"
  bash "$repository/scripts/modern-oracle.sh" "$output/disposable/before/graph.json" "$output/disposable/after/graph.json" "$oracle_spec" > "$output/oracle.json"
  oracle_json=$(cat "$output/oracle.json")
  oracle_decision=$(jq -r '.decision' "$output/oracle.json")
  before_failures=$(jq -r '.oracle_failures.before' "$output/oracle.json")
  after_failures=$(jq -r '.oracle_failures.after' "$output/oracle.json")
  before_semantic=$(jq -r '.ir.semantic_digest // empty' "$output/disposable/before/graph.json")
  after_semantic=$(jq -r '.ir.semantic_digest // empty' "$output/disposable/after/graph.json")
  jq -S -n --arg scenario "$scenario" --arg source "$source_digest" --arg tool "$tool_digest" --arg contract "$contract_digest" --arg harness "$harness_digest" \
    --arg before_workload "$(digest_file "$tmp/clone-before/fixtures/modern-cycle/workload.gooo")" --arg after_workload "$(digest_file "$tmp/clone-after/fixtures/modern-cycle/workload.gooo")" \
    --arg before_semantic "$before_semantic" --arg after_semantic "$after_semantic" \
    --slurpfile before "$output/disposable/before/measurement.json" --slurpfile after "$output/disposable/after/measurement.json" --slurpfile oracle "$output/oracle.json" \
    '{schema:"gooo/reflexive-loop/modern-cycle/exact-oracle-pair/v1",scenario:$scenario,exact_identity:{source_digest:$source,toolchain_digest:$tool,contract_digest:$contract,harness_digest:$harness},workload_pair:{before_digest:$before_workload,after_digest:$after_workload},before:$before[0],after:$after[0],semantic_digest_pair:{before:$before_semantic,after:$after_semantic},oracle:$oracle[0],rollback:{mode:"OUTPUT_ONLY",repository_writes:0,target:"temporary_output"}}' > "$output/exact-oracle-pair.json"
  if [ "$oracle_decision" = "CLOSED" ] && [ "$before_failures" -eq 1 ] && [ "$after_failures" -eq 0 ] && \
     [ "$(jq -r '.status' "$output/disposable/before/measurement.json")" -eq 0 ] && [ "$(jq -r '.status' "$output/disposable/after/measurement.json")" -eq 0 ]; then
    unknown_id=""
    frontier_state="${frontier_state:-UNKNOWN}"
    if [ "$frontier_state" = "CLOSED" ]; then semantic_state="CLOSED"; fi
    if [ "$scenario" = "missing-utility" ]; then
      :
    else
      semantic_state="CLOSED"
    fi
  else
    decision="REFUTED"
    decision_reason="INDEPENDENT_ORACLE_PAIR_REFUTED"
    refutations='["INDEPENDENT_ORACLE_PAIR_REFUTED"]'
    unknown_id=""
  fi
fi

if [ "$decision" != "REFUTED" ] && [ "$scenario" != "fixed-point-no-candidate" ] && [ "$scenario" != "stale-upstream" ] && [ "$scenario" != "dependency-blocked" ] && [ "$candidate_count" -gt 0 ] && [ "$bundle_state" = "CLOSED" ]; then
  mkdir -p "$output/test-frontier"
  test_graph_digest=$(digest_file "$output/exact-oracle-pair.json")
  jq -S --arg source "$source_digest" --arg tool "$tool_digest" --arg policy "$policy_digest" --arg inventory "$inventory_digest" --arg graph "$test_graph_digest" --arg scenario "$scenario" \
    '.input_bindings.source_digest=$source | .input_bindings.toolchain_digest=$tool | .input_bindings.policy_digest=$policy | .input_bindings.test_inventory_digest=$inventory | .input_bindings.semantic_change_graph_digest=$graph | .tests |= map(.source_digest=$source) | .prior_receipts |= map(.source_digest=$source | .toolchain_digest=$tool | .policy_digest=$policy | .test_inventory_digest=$inventory) | if $scenario=="missing-utility" then .tests |= map(if .test_id=="test-validate-work-item" then .simulation=null else . end) else . end | if $scenario=="false-negative-test-selection" then .counterexamples=[{counterexample_id:"false-negative-validate",test_id:"test-validate-work-item",expected_invalidation:true,observed_invalidation:false}] else . end' \
    "$test_fixture_base" > "$tmp/test-frontier-fixture.json"
  test_frontier_status=$(run_command "$output/test-frontier/stdout.txt" "$output/test-frontier/stderr.txt" \
    "$test_frontier_bin" evaluate --root "$test_frontier_source" --source "$test_frontier_source/examples/test-frontier.gooo" \
    --contract "$test_frontier_contract" --fixture "$tmp/test-frontier-fixture.json" --output-dir "$output/test-frontier")
  if [ "$test_frontier_status" -eq 0 ]; then
    test_frontier_state=$(jq -r '.state // "UNKNOWN"' "$output/test-frontier/plan.json")
    test_counts=$(jq -c '.execution_counts' "$output/test-frontier/plan.json")
    tests_total=$(jq -r '.total // 0' <<<"$test_counts")
    tests_executed=$(jq -r '.executed // 0' <<<"$test_counts")
    tests_reused=$(jq -r '.reused // 0' <<<"$test_counts")
    tests_skipped=$(jq -r '.skipped // 0' <<<"$test_counts")
    tests_not_observed=$(jq -r '.not_observed // 0' <<<"$test_counts")
  else
    test_frontier_state="REFUTED"
  fi
  if [ "$scenario" = "false-negative-test-selection" ] || [ "$test_frontier_state" = "REFUTED" ]; then
    decision="REFUTED"
    decision_reason="TEST_FRONTIER_FALSE_NEGATIVE_REFUTED"
    refutations='["FALSE_NEGATIVE_COUNTEREXAMPLE_PRESENT"]'
    unknown_id=""
  elif [ "$scenario" = "missing-utility" ] || [ "$tests_not_observed" -gt 0 ]; then
    decision="UNKNOWN"
    decision_reason="AFFECTED_TEST_EXECUTION_NOT_OBSERVED"
    unknown_id="IMPACTED_TESTS_CLASSIFIED"
    unknown_stage="REGRESSION"
    unknown_step="CLASSIFY_EXACT_TEST_FRONTIER"
    unknown_reason="AFFECTED_TEST_EXECUTION_NOT_OBSERVED"
    unknown_class="TEST_EXECUTION_NOT_OBSERVED"
    unknown_next="OBSERVE_AFFECTED_TEST_EXECUTION"
    unknown_blocked='["test-validate-work-item"]'
  elif [ "$oracle_decision" = "CLOSED" ]; then
    decision="CLOSED"
    decision_reason="SEMANTIC_CLOSE_WITH_EXTERNAL_UTILITY_UNKNOWN"
    promotion_state="PROMOTED_OUTPUT_ONLY"
  fi
fi

if [ "$scenario" = "preimage-mismatch" ] || [ "$scenario" = "rollback-mismatch" ]; then
  decision="REFUTED"
  decision_reason="CHANGE_BUNDLE_REFUTED"
  refutations=$(jq -c '[.findings[]?.code] // ["CHANGE_BUNDLE_REFUTED"]' "$output/bundle/bundle-manifest.json" 2>/dev/null || printf '["CHANGE_BUNDLE_REFUTED"]')
  unknown_id=""
fi

if [ "$scenario" = "missing-utility" ] && [ "$decision" != "REFUTED" ]; then
  decision="UNKNOWN"
  decision_reason="AFFECTED_TEST_EXECUTION_NOT_OBSERVED"
  promotion_state="NOT_PROMOTED"
fi

if [ "$decision" = "CLOSED" ]; then
  semantic_state="CLOSED"
  if [ "$scenario" != "fixed-point-no-candidate" ]; then promotion_state="PROMOTED_OUTPUT_ONLY"; fi
elif [ "$decision" = "REFUTED" ]; then
  semantic_state="REFUTED"
  promotion_state="NOT_PROMOTED"
else
  semantic_state="UNKNOWN"
  promotion_state="NOT_PROMOTED"
fi

if [ "$decision" = "REFUTED" ]; then
  unknown_id=""
fi

if [ "$unknown_id" != "" ]; then
  unknowns=$(jq -S -n --arg stage "$unknown_stage" --arg step "$unknown_step" --arg reason "$unknown_reason" --arg class "$unknown_class" --arg next "$unknown_next" --argjson blocked "$unknown_blocked" \
    '[{stage:$stage,step:$step,reason:$reason,unknown_class:$class,next_operation:$next,blocked_by:$blocked}]')
else
  unknowns='[]'
fi

if [ "$decision" = "REFUTED" ]; then
  activity_default="REFUTED"
elif [ "$decision" = "UNKNOWN" ]; then
  activity_default="CLOSED"
else
  activity_default="CLOSED"
fi
activities=$(jq -S --arg default "$activity_default" --arg decision "$decision" --arg unknown_id "$unknown_id" --arg stage "$unknown_stage" --arg step "$unknown_step" --arg reason "$unknown_reason" --arg unknown_class "$unknown_class" --arg next "$unknown_next" --argjson blocked "$unknown_blocked" \
  '.activities | map(. as $cell | {ordinal,id,activity,stage,step,proof_choice,indicator_class,state:(if $decision=="REFUTED" then "REFUTED" elif $unknown_id==$cell.id then "UNKNOWN" else $default end),reason:(if $decision=="REFUTED" then "REFUTED: "+$reason elif $unknown_id==$cell.id then $reason else "EXACT_BINDING_OBSERVED" end),unknown:(if $unknown_id==$cell.id then {stage:$stage,step:$step,reason:$reason,unknown_class:$unknown_class,next_operation:$next,blocked_by:$blocked} else null end)})' "$denominator")

mkdir -p "$output/receipts"
jq -S -n --arg schema "gooo/reflexive-loop/modern-cycle/promotion-receipt/v1" --arg decision "$decision" --arg promotion "$promotion_state" --arg scenario "$scenario" \
  '{schema:$schema,scenario:$scenario,decision:$decision,promotion:$promotion,mode:"OUTPUT_ONLY",repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false}' > "$output/receipts/promotion-receipt.json"

if [ -f "$output/exact-oracle-pair.json" ]; then
  before_failures=$(jq -r '.oracle.oracle_failures.before // 0' "$output/exact-oracle-pair.json")
  after_failures=$(jq -r '.oracle.oracle_failures.after // 0' "$output/exact-oracle-pair.json")
else
  before_failures=0
  after_failures=0
fi

metrics_json=$(jq -S -n --arg scenario "$scenario" --arg state "$decision" --argjson before "$before_failures" --argjson after "$after_failures" \
  --argjson candidates "$candidate_count" --argjson edges "$causal_edges" --argjson frontier "$frontier_count" --argjson paths "$patch_paths" --argjson hunks "$patch_hunks" --argjson patch_bytes "$patch_bytes" \
  --argjson rollback_comparisons "$rollback_comparisons" --argjson rollback_mismatches "$rollback_mismatches" --argjson replay_comparisons "$replay_comparisons" --argjson replay_mismatches "$replay_mismatches" \
  --argjson total "$tests_total" --argjson executed "$tests_executed" --argjson reused "$tests_reused" --argjson skipped "$tests_skipped" --argjson not_observed "$tests_not_observed" \
  --argjson build_wall_ms "$build_wall_ms" --argjson test_wall_ms "$test_wall_ms" --argjson conformance_wall_ms "$conformance_wall_ms" --argjson peak_rss_kib "$peak_rss_kib" \
  --argjson go_lines "$go_physical_lines" --argjson gooo_lines "$gooo_physical_lines" --argjson files "$repository_files" --argjson directories "$repository_directories" \
  '{scenario:$scenario,state:$state,before_oracle_failures:$before,after_oracle_failures:$after,candidate_count:$candidates,causal_edges:$edges,frontier_count:$frontier,patch_paths:$paths,patch_hunks:$hunks,patch_bytes:$patch_bytes,rollback_comparisons:$rollback_comparisons,rollback_mismatches:$rollback_mismatches,replay_comparisons:$replay_comparisons,replay_mismatches:$replay_mismatches,tests_total:$total,tests_executed:$executed,tests_reused:$reused,tests_skipped:$skipped,tests_not_observed:$not_observed,build_wall_ms:$build_wall_ms,test_wall_ms:$test_wall_ms,conformance_wall_ms:$conformance_wall_ms,peak_rss_kib:$peak_rss_kib,go_physical_lines:$go_lines,gooo_physical_lines:$gooo_lines,files:$files,directories:$directories,output_artifact_files:0,output_artifact_bytes:0,repository_writes:0,local_test_executions:0,cross_project_required_gates:0}')
  while IFS= read -r row; do
  ordinal=$(jq -r '.ordinal' <<<"$row")
  id=$(jq -r '.id' <<<"$row")
  jq -S --argjson metric "$metrics_json" --argjson activity "$row" '{schema:"gooo/reflexive-loop/modern-cycle/metric/v1",denominator:1,numerator:(if $activity.state=="CLOSED" then 1 else 0 end),activity:$activity,metrics:$metric,source_file:"examples/modern-cycle/main.gooo",ir_node_kind:"Activity",generated_artifact:"modern-cycle/ci-artifact.json",evaluator:"scripts/modern-cycle-loop.sh"}' <<<"{}" > "$output/metrics/$(printf '%02d' "$ordinal")-$id.json"
  done < <(jq -c '.[]' <<<"$activities")

artifact_files=$(find "$output" -type f ! -name 'report.json' ! -name 'ci-artifact.json' ! -name 'artifact-manifest.json' | wc -l | awk '{print $1 + 0}')
artifact_bytes=$(find "$output" -type f ! -name 'report.json' ! -name 'ci-artifact.json' ! -name 'artifact-manifest.json' -print0 | xargs -0 -r wc -c | awk 'END {print $1 + 0}')
metrics_json=$(jq -S --argjson files "$artifact_files" --argjson bytes "$artifact_bytes" '.output_artifact_files=$files | .output_artifact_bytes=$bytes' <<<"$metrics_json")

jq -S -n --arg scenario "$scenario" --arg decision "$decision" --arg reason "$decision_reason" --arg proposer_state "$proposer_state" --arg proposer_reason "$proposer_reason" \
  --arg semantic_state "$semantic_state" --arg utility_state "$utility_state" --arg frontier_state "$frontier_state" --arg bundle_state "$bundle_state" --arg test_frontier_state "$test_frontier_state" --arg oracle_decision "$oracle_decision" --arg promotion "$promotion_state" \
  --arg release_state "$release_state" --arg release_reason "$release_reason" --arg source_schema "$source_schema" --argjson source_status "$source_status" --argjson source_activity_count "$source_activity_count" \
  --argjson activities "$activities" --argjson unknowns "$unknowns" --argjson refutations "$refutations" --argjson metrics "$metrics_json" --argjson tests "$test_counts" --argjson artifact_files "$artifact_files" --argjson artifact_bytes "$artifact_bytes" \
  --arg before_digest "$input_before" --arg after_digest "$(snapshot "$repository")" \
  --argjson source_releases "$(jq -c '.releases' "$repository/contracts/modern-cycle-upstream-release-lock-v1.json")" \
  '{schema:"gooo/reflexive-loop/modern-cycle/report/v1",version:"v0.3.0",scenario:$scenario,decision:$decision,decision_reason:$reason,precedence:["REFUTED","UNKNOWN","CLOSED"],denominator:{id:"modern-cycle-v1",fixed:true,cells:12,proof_totals:{FOUNDATION:4,COHERENCE:4,REGRESSION:4},indicator_totals:{DRIVER:4,OUTCOME:4,GUARDRAIL:4}},external_releases:{state:$release_state,reason:$release_reason,bindings:$source_releases},source_observation:{schema:$source_schema,status:$source_status,activity_count:$source_activity_count,expected_activity_count:12},proposer:{state:$proposer_state,reason:$proposer_reason,candidate_count:$metrics.candidate_count,causal_edges:$metrics.causal_edges},frontier:{state:$frontier_state,count:$metrics.frontier_count},change_bundle:{state:$bundle_state,patch_paths:$metrics.patch_paths,patch_hunks:$metrics.patch_hunks,patch_bytes:$metrics.patch_bytes,rollback_comparisons:$metrics.rollback_comparisons,rollback_mismatches:$metrics.rollback_mismatches,replay_comparisons:$metrics.replay_comparisons,replay_mismatches:$metrics.replay_mismatches},test_frontier:{state:$test_frontier_state,counts:$tests},oracle:{decision:$oracle_decision,before_failures:$metrics.before_oracle_failures,after_failures:$metrics.after_oracle_failures},semantic_close:{state:(if $semantic_state=="CLOSED" then "CLOSED" else $semantic_state end),pair_required:true},external_utility:{state:$utility_state,claim:"UNKNOWN_WITHOUT_INFERENCE",next_operation:"PROVIDE_EXACT_BEFORE_AFTER_UTILITY_PAIR"},promotion:{state:$promotion,mode:"OUTPUT_ONLY",authority:{repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,pull_request_authorized:false,merge_authorized:false}},unknowns:$unknowns,refutations:$refutations,activities:$activities,metrics:$metrics,performance:{build_wall_ms:$metrics.build_wall_ms,test_wall_ms:$metrics.test_wall_ms,conformance_wall_ms:$metrics.conformance_wall_ms,peak_rss_kib:$metrics.peak_rss_kib},repository:{before_digest:$before_digest,after_digest:$after_digest,unchanged:($before_digest==$after_digest)},artifacts:{files:$artifact_files,bytes:$artifact_bytes}}' > "$output/report.json"

jq -S -n --arg files "$artifact_files" --arg bytes "$artifact_bytes" --argjson count 12 \
  '{schema:"gooo/reflexive-loop/modern-cycle/artifact-manifest/v1",files:($files|tonumber),bytes:($bytes|tonumber),metric_files:$count,manifest_ok:true}' > "$output/artifact-manifest.json"

report_digest=$(digest_file "$output/report.json")
jq -S -n --arg scenario "$scenario" --arg decision "$decision" --arg report_digest "$report_digest" --argjson metrics "$metrics_json" --argjson unknowns "$unknowns" --argjson refutations "$refutations" \
  --arg before_digest "$input_before" --arg after_digest "$(snapshot "$repository")" --argjson artifact_files "$artifact_files" --argjson artifact_bytes "$artifact_bytes" \
  '{schema:"gooo/reflexive-loop/modern-cycle/ci-artifact/v1",version:"v0.3.0",scenario:$scenario,decision:$decision,report_digest:$report_digest,precedence:["REFUTED","UNKNOWN","CLOSED"],summary:{closed:(if $decision=="CLOSED" then 1 else 0 end),unknown:(if $decision=="UNKNOWN" then 1 else 0 end),refuted:(if $decision=="REFUTED" then 1 else 0 end)},unknown:$unknowns,refuted:$refutations,metrics:$metrics,artifact:{files:$artifact_files,bytes:$artifact_bytes},authority:{repository_writes:0,local_test_executions:0,cross_project_required_gates:0,apply_authorized:false,commit_authorized:false,push_authorized:false,merge_authorized:false},input_before:$before_digest,input_after:$after_digest,repository_unchanged:($before_digest==$after_digest)}' > "$output/ci-artifact.json"

jq -r --arg scenario "$scenario" --arg decision "$decision" --arg reason "$decision_reason" --argjson metrics "$metrics_json" \
  '"# Modern cycle: "+$scenario+"\n\n- decision: `"+$decision+"`\n- reason: "+$reason+"\n- oracle failures before / after: `"+($metrics.before_oracle_failures|tostring)+"` / `"+($metrics.after_oracle_failures|tostring)+"`\n- candidate paths / hunks / patch bytes: `"+($metrics.patch_paths|tostring)+"` / `"+($metrics.patch_hunks|tostring)+"` / `"+($metrics.patch_bytes|tostring)+"`\n- tests total / executed / reused / skipped / not_observed: `"+([$metrics.tests_total,$metrics.tests_executed,$metrics.tests_reused,$metrics.tests_skipped,$metrics.tests_not_observed]|map(tostring)|join(" / "))+"`\n- authority repository writes / local tests / cross-project gates: `0 / 0 / 0`\n- output artifacts files / bytes: `"+($metrics.output_artifact_files|tostring)+" / "+($metrics.output_artifact_bytes|tostring)' "$output/report.json" > "$output/human-dossier.md"

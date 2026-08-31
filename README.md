# Gooo reflexive loop

This repository is a small, read-only proof harness for a Gooo-only reflexive
loop:

```text
observe -> propose -> apply -> verify -> promote / rollback
```

The loop consumes a claim and an observation receipt, selects one permitted
Gooo meta activity, and materializes a candidate in a caller-owned temporary
directory. It never edits the input repository. An independent oracle checks
the before/after semantic pair. Promotion is possible only after every fixed
denominator cell is `CLOSED`.

The authoritative activity set is
[`examples/reflexive-loop/main.gooo`](examples/reflexive-loop/main.gooo).
Its 18 activities are bound one-to-one to the fixed denominator,
source/semantic-IR observations, generated metric records, and evaluator
entries. `FOUNDATION`, `COHERENCE`, and `REGRESSION` as well as `DRIVER`,
`OUTCOME`, and `GUARDRAIL` are each represented six times.

## Evidence contract

The evaluator gives `REFUTED` precedence over `UNKNOWN`, and `UNKNOWN`
precedence over `CLOSED`. Every unknown preserves exactly these fields:
`stage`, `step`, `reason`, `unknown_class`, `next_operation`, and `blocked_by`.
Self-approval, stale evidence, proposal replay, authority escalation,
malformed input, unsupported `FIXED_POINT`, and permission escalation are
fail-closed refutations.

The normal fixture runs the same workload before and after a permitted
`CanonicalizeWorkloadSource` activity. Its measured wall time and peak RSS are
reported verbatim; a slower after-run is recorded and never converted into a
positive utility claim.

## Exact external release integration

The integration path consumes the immutable `v0.1.0` releases pinned in
[`contracts/external-release-locks-v1.json`](contracts/external-release-locks-v1.json):
[`gooo-meta-budget`](https://github.com/kimjooyoon/gooo-meta-budget/releases/tag/v0.1.0)
selects the allowed execution plan, and
[`gooo-resolution-lattice`](https://github.com/kimjooyoon/gooo-resolution-lattice/releases/tag/v0.1.0)
supplies the performance/utility `UNKNOWN` receipt. CI checks release
immutability, target SHA, manifest digest, evidence digest/size, and the
internal scenario and metric bindings before writing the selected plan into
the proposal. The plan controls temporary apply and the UNKNOWN receipt keeps
the six fields (`stage`, `step`, `reason`, `unknown_class`, `next_operation`,
`blocked_by`) without inferring utility.

This is an additional eight-cell integration report; the original v0.1.0
18-cell denominator and its meanings are unchanged. The same Actions job also
proves `cross_project_required_gates=0`, records the independent oracle and
promote/rollback boundary, and exercises tampered digest, stale target,
missing-UNKNOWN-field, release replay, and authority-escalation cases as
`REFUTED`.

## v0.3 modern self-improvement cycle

The v0.3 cycle is a separate, fixed 12-cell denominator in
[`contracts/modern-cycle-denominator-v1.json`](contracts/modern-cycle-denominator-v1.json).
It is balanced four-by-four across `FOUNDATION`, `COHERENCE`, and
`REGRESSION`, and independently four-by-four across `DRIVER`, `OUTCOME`, and
`GUARDRAIL`. It does not combine evidence into an aggregate score or
percentage. Its precedence remains `REFUTED > UNKNOWN > CLOSED`, and every
UNKNOWN keeps exactly `stage`, `step`, `reason`, `unknown_class`,
`next_operation`, and `blocked_by`.

The Actions-only modern cycle consumes the exact immutable releases pinned in
[`contracts/modern-cycle-upstream-release-lock-v1.json`](contracts/modern-cycle-upstream-release-lock-v1.json):
`gooo-improvement-proposer@v0.1.1`, `gooo-improvement-frontier@v0.1.0`,
`gooo-change-bundle@v0.1.1`, and `gooo-test-frontier@v0.1.1`. It proposes a
candidate from the ledger, computes a causal frontier, materializes a
deterministic patch and rollback bundle, applies the patch only to a
caller-owned disposable clone, classifies exact test statuses, and compares
the same small Gooo workload before and after with the independent oracle in
[`scripts/modern-oracle.sh`](scripts/modern-oracle.sh). Semantic close and
external utility evidence stay separate: without an exact utility pair the
utility claim remains `UNKNOWN` and is never inferred from runtime numbers.

The modern conformance corpus has three normal, three UNKNOWN, and four
REFUTED scenarios. All repository writes, local test executions, pull-request
authority, merge authority, and required cross-project gates remain zero.

## v0.4 learning-and-drift-gated cycle

The v0.4 cycle is a separate fixed 12-cell denominator in
[`contracts/learning-drift-gated-denominator-v1.json`](contracts/learning-drift-gated-denominator-v1.json).
It preserves the v0.3.1 denominator and all legacy and modern denominators;
the new cells cover append-only experience memory, exact semantic source-to-IR-
to-generated binding, immutable semantic-drift evidence, precedence, a
temporary-clone patch, an independent oracle, and the affected test frontier.
No aggregate score, percentage, utility inference, or denominator substitution
is permitted.

Actions verifies the exact immutable upstream releases locked in
[`contracts/learning-drift-upstream-release-lock-v1.json`](contracts/learning-drift-upstream-release-lock-v1.json):
`gooo-experience-memory@v0.1.0` and
`gooo-semantic-drift-guard@v0.1.1`. The mutable drift `v0.1.0` is retained only
as a process counterexample and is never consumed as an input. The cycle emits
three CLOSED replay/receipt cases, four UNKNOWN cases, and five REFUTED cases;
every UNKNOWN preserves exactly the six-field tuple used by the earlier
contracts. Build, test, conformance, line-count, artifact, digest, and
authority values are recorded as integer evidence, while external utility
remains UNKNOWN without an exact utility pair.

## Running in CI

The checked-in workflow downloads the pinned Gooo release, performs all
observations and conformance cases on GitHub Actions, and uploads one human-
readable evidence artifact. Local build, test, format, and vet commands are
intentionally not part of this workflow contract.

See [the RFC](docs/rfcs/reflexive-loop-v1.md) for the state machine and
[the CI workflow](.github/workflows/reflexive-loop.yml) for the exact evidence
production path.

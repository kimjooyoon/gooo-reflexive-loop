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

## Running in CI

The checked-in workflow downloads the pinned Gooo release, performs all
observations and conformance cases on GitHub Actions, and uploads one human-
readable evidence artifact. Local build, test, format, and vet commands are
intentionally not part of this workflow contract.

See [the RFC](docs/rfcs/reflexive-loop-v1.md) for the state machine and
[the CI workflow](.github/workflows/reflexive-loop.yml) for the exact evidence
production path.

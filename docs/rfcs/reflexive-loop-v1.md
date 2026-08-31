# Reflexive loop v1

## Scope

The loop is an evidence-producing Gooo activity graph. It is not an agent
that edits a checkout and then asks the edited checkout to approve itself.
`examples/reflexive-loop/main.gooo` is the authority for the 18 activities.
The shell entry points only materialize receipts for those activities.

```text
claim + observation receipt
        |
        v
Gooo graph observation -> deterministic proposal -> temporary output
        |                                      |
        +---------------- independent oracle <-+
                               |
                     exact pair + read-only effect
                               |
                         promotion / rollback
```

## Identity

The claim, receipt, proposal, and workload pair carry the digest of the
allowed-transformation contract. They also carry source/workload identity and
the downloaded Gooo binary digest. A before/after pair is exact only when the
same input, tool, and contract identities are present. No performance number
is treated as utility without that exact pair.

## State algebra

The evaluator uses the strict order `REFUTED > UNKNOWN > CLOSED`. A missing
receipt is `UNKNOWN`, not a successful observation. A malformed input,
unsupported `FIXED_POINT`, stale receipt, replayed proposal, self-approval,
or authority that requests repository writes is `REFUTED` and prevents
promotion. UNKNOWN records always contain `stage`, `step`, `reason`,
`unknown_class`, `next_operation`, and `blocked_by`.

Promotion is a property of the evidence gate, not a claim that a benchmark
improved. The normal fixture records before/after wall time and peak RSS. If
the after-run is slower or tied, the artifact records
`NO_PERFORMANCE_IMPROVEMENT_CLAIM` and does not infer utility from the other
closed cells.

## Boundary

The input repository is read-only. The only writes made by the runner are to
the caller-owned output directory. Rollback is represented as an output-only
receipt; it never writes a branch, tag, or source checkout. The workflow does
not bypass required checks or modify the protected source repository.

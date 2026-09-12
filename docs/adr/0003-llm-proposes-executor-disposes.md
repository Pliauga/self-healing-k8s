# ADR-0003: LLM Proposes, Deterministic Executor Disposes

**Date:** 2026-09-28
**Status:** Accepted

## Context

The project's differentiating feature is an LLM agent that diagnoses cluster
faults and proposes remediations. The core risk is that a language model will
hallucinate a destructive action, misread a log, or apply a fix that makes an
outage worse — and it will do so probabilistically, without warning.

At the same time, constraining the agent so tightly that it can only report
findings would make it useless: a self-healing system that never heals is not
self-healing.

## Decision

Split responsibilities across a hard process boundary:

1. The **LLM agent** has read-only cluster access. Its only output is a
  structured JSON diagnosis: `{ root_cause, action, target, confidence }`.
2. A separate **deterministic executor** — a Python service, not the model —
  receives that JSON, validates it against an allowlist of known remediations,
   runs `kubectl --dry-run=server` first, and only then applies the change.

The LLM never calls a write API. The executor never calls an LLM.

## Rationale

- **Least privilege.** The agent's ServiceAccount can `get`, `list`, and `watch`
pods, events, deployments, replicasets, and read pod logs. It cannot `delete`,
`patch`, or `create` anything. Compromise of the metrics pipeline yields a
read-only vantage, not cluster control.
- **Auditability.** Every mutation is a fixed code path with a single log line.
Post-mortems ask "what did the executor run?" and get a deterministic answer,
not "the model may have chosen...".
- **Testability.** The executor's decision function is unit-testable. We can
simulate 10,000 malformed diagnoses and assert none of them cause a mutation.
- **Approval gates fit naturally.** The executor already sits between proposal
and effect, so inserting "human approves" for destructive actions is a
branch, not a redesign.
- **Bounded blast radius.** The executor's action allowlist (`restart-pod`,
`scale-up`) is a code artifact. Adding a new remediation is a code review,
not a prompt change.

## Consequences

**Positive:**

- A hallucinated `delete ns` cannot reach the API server.
- Failures are reproducible and reviewable.
- The design survives model upgrades — swapping the LLM doesn't change the
safety envelope.

**Negative:**

- The allowlist must be maintained. Novel failures the agent correctly
diagnoses may be rejected by the executor until the list is updated.
- Slightly more moving parts: two services, one API contract, one test surface.
- The agent is slower than direct tool use — the extra hop costs ~1–2 s per
remediation.

**Mitigation:**

- The executor emits structured "rejected: unknown action" events so gaps in
the allowlist are visible in dashboards.
- The agent's diagnosis endpoint is synchronous; the extra hop is well inside
the `for: 1m` alert-window budget.
- For the local demo, run both in the same pod with a Unix socket; for EKS,
split them and use IRSA to give the executor a separate, narrower Role.

## Alternatives Considered

- **Direct LLM tool use.** Give the agent `dsh-kubectl` with write permissions.
Rejected: a single hallucination becomes a cluster-wide incident. This is the
pattern most "AIops" demos use, and it is the pattern that produces
cautionary conference talks.
- **Two-model consensus.** Require two LLMs to agree before acting. Rejected:
correlated failure modes. Two instances of the same model agree on the same
hallucination.
- **Human-in-the-loop for every action.** Rejected: defeats automation; the
latency (minutes) exceeds the fault-recovery window (seconds). Reserved for
destructive actions only.

## References

- `docs/design.md` §6 — Agent design and control loop
- `docs/design.md` §6.3 — RBAC table (granted vs. withheld)

 
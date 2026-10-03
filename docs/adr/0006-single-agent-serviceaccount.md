# ADR-0006: One ServiceAccount for the Agent, Because the RBAC Boundary Is the Process Boundary

**Date:** 2026-10-15
**Status:** Accepted

## Context

ADR-0003 splits the Tier 2 agent across a *hard process boundary*: the component
that decides (the LLM) holds read-only credentials, and the component that acts
(the deterministic executor) holds the eviction grant. `k8s/optional/agent/rbac.yaml`
expressed that boundary in RBAC as two ServiceAccounts —
`remediation-diagnosis` (read-only) and `remediation-executor` (`create` on
`policy/pods/eviction` only) — with the deliberate property that *the two grants
do not overlap*, so neither identity can both learn and act.

Two facts make that shape unimplementable as the Tier 2 handoff specifies it:

1. **The handoff commits to a single container.** Both responsibilities run in
   one Flask process: `diagnosis.py` receives the webhook, `executor.py` acts
   in-process. ADR-0003's own text says the split is "across a hard process
   boundary" — and in-process function separation is not a process boundary.

2. **A pod presents exactly one ServiceAccount token.** There is no supported
   way for one container to hold two identities. Kubernetes mounts one token at
   `/var/run/secrets/kubernetes.io/serviceaccount`. Even if both files were
   applied, the running pod would authenticate as exactly one of the two SAs.

The second point is the decisive one, and it is not a wiring detail: with one
token, the two-ServiceAccount design does not merely degrade, it is vacuous. The
"non-overlapping grants" property belongs to *two identities*; one process has
one identity, so the property has nothing to attach to.

There is also a live defect motivating the change: the executor's guards perform
two reads — `get pods` for the mandatory target re-check (docs/design.md §6.2)
and `get poddisruptionbudgets` for the budget gate — and the executor Role grants
no read verbs at all. Under the split, `get pods` returns 403, which the executor
would have been unable to distinguish from a genuine 404, reporting "already
healed" for a pod it was never authorized to look at.

## Decision

The agent runs as **one ServiceAccount, `remediation-agent`**, bound by one Role
and one RoleBinding. It is granted exactly what the code needs, and no more:

```
- apiGroups: [""]
  resources: ["pods", "events"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["get"]
- apiGroups: ["policy"]
  resources: ["pods/eviction"]
  verbs: ["create"]
```

Deliberately still **not** granted: `delete` on pods (bypasses the PDB and races
the ReplicaSet — ADR-0005), `patch` on deployments (not in the closed vocabulary;
the vocabulary is the safety property, and a permission wider than the vocabulary
dissolves it), anything cluster-scoped, and `secrets`.

This supersedes the *two-identity mechanism* of ADR-0003. ADR-0003's substantive
decision — the LLM never calls a write API, the deterministic executor is the only
writer, the LLM's entire output is validated JSON, and an unparseable response
becomes an escalation — is retained in full and is unaffected.

## Rationale

The RBAC boundary in ADR-0003 was always meant to be enforced somewhere the model
cannot reach. In the single-container shape, that "somewhere" is the code: the
executor validates the closed action set and the confidence gate before any
mutating call, and it never consults the LLM. The safety property that survives
is the one the ADR actually cares about — *the LLM cannot express an action
outside the vocabulary* — because `executor.py` reads `ACTIONS` from the schema
Literal and rejects anything else.

What is genuinely lost is defense in depth, and it should be stated plainly
rather than rationalized: with the split, a fully compromised diagnosis workload
could do no more than read the namespace. With one identity, a compromised agent
pod can read *and* evict. The blast radius is bounded by the PDB — the worst case
is one budget-checked eviction, refused with `429 TooManyRequests` when the budget
is exhausted — but it is larger than the two-identity design's worst case.

Two supporting changes belong to this decision:

- **Three-state reads.** `executor.py` performs no read that answers with two
  states. `lookup_pod` and `lookup_disruption_budget` return `FOUND`, `ABSENT`, or
  `INDETERMINATE`, and `INDETERMINATE` escalates. This is the same failure shape
  as finding 2 in docs/design.md §14 — a check reporting a confident answer to a
  question it did not actually ask — and it must remain even though the merged
  Role makes a 403 unlikely, because a future narrowing would reintroduce it.
- **The RBAC file is applied.** `scripts/setup.sh` applied only
  `optional/agent/load-generator.yaml`, so `rbac.yaml` was never installed by the
  bring-up path; it was reachable only via `scripts/apply.sh --optional`. The
  handoff recorded the RBAC as already applied. It was not.

## Consequences

**Positive.** The permission set matches the code, so the executor's guards
actually run instead of silently escalating on a 403. One identity is one thing to
audit, one thing to rotate, and one thing to bind. The closed vocabulary remains
the enforced safety property, and it is enforced in code where it is testable.

**Negative.** A compromised agent pod can evict, where the split would have
confined it to reading. Defense in depth is reduced, and the reduction is a direct
consequence of the single-container decision rather than something a narrower Role
can recover.

**Negative.** The RBAC no longer *by itself* demonstrates the ADR-0003 property to
a reader; the demonstration now lives in `executor.py` and its tests. The comment
block in `rbac.yaml` has to say this explicitly, or a future reviewer will read
the file, see one identity with an eviction grant, and conclude the safety model
was abandoned.

**Neutral.** `docs/design.md` §6.3 still lists `patch apps/deployments` as granted.
That is stale — the grant was removed before this ADR, and it is not restored here.
The doc fix is tracked as follow-up work.

## Alternatives Considered

- **Two ServiceAccounts, one container.** Rejected: a pod presents one token, so
  one of the two identities would be unused and the "non-overlapping grants"
  property would not hold at runtime. The RBAC would describe a boundary the
  process does not have.
- **Two pods, one identity each.** This is the architecture that actually
  preserves ADR-0003, and it remains the correct answer if the agent is ever split
  for real. Rejected for v1 because the handoff commits to one container, and the
  cost — a second Deployment, a second Service or an in-cluster RPC, two image
  rollouts, and a network hop inside the `for: 1m` alert budget — is not justified
  by the threat model at this stage.
- **Keep the executor Role eviction-only and drop the two read guards.**
  Rejected: the PDB gate and the mandatory re-check are correctness requirements
  (docs/design.md §6.2), not conveniences. Removing a guard so that a Role does not
  have to change inverts the dependency — the permission would be shaping the
  behaviour instead of the reverse.
- **Grant the executor the two reads, keep both identities, run two pods later.**
  Rejected as a half-measure: it still cannot be instantiated in one container,
  so it would ship an RBAC file that both overstates the boundary and fails at
  runtime.

## References

- `docs/adr/0003-llm-proposes-executor-disposes.md` — the decide/act separation
  this ADR preserves, and the two-identity mechanism it supersedes
- `docs/adr/0005-use-eviction-api-not-delete.md` — why eviction, never deletion
- `docs/design.md` §6.2 — the mandatory re-check before acting
- `docs/design.md` §6.3 — RBAC table (stale; lists `patch apps/deployments`)
- `docs/design.md` §6.4 — diagnosis separated from execution
- `docs/design.md` §14 — findings 2 and 5, the failure shapes this ADR guards against
- `k8s/optional/agent/rbac.yaml` — the applied truth

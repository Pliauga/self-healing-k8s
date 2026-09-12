# ADR-0005: Use the Eviction API, Never Pod Deletion, for Remediation

**Date:** 2026-09-28
**Status:** Accepted

## Context

To replace a misbehaving pod there are two candidate operations:

- `DELETE /api/v1/namespaces/{ns}/pods/{name}` — removes the pod directly.
- `POST /api/v1/namespaces/{ns}/pods/{name}/eviction` — asks the API server to
evict the pod, subject to the namespace's PodDisruptionBudgets.

Deletion is simpler and always succeeds. That "always succeeds" property is the
problem: a `DELETE` bypasses the disruption budget entirely, so an automated
agent evicting pods in a loop can drain a workload's *entire* replica set — and
it will do so precisely when the workload is already degraded and the budget is
most needed. A remediation action must not be able to cause the outage it exists
to prevent.

`DELETE` is also racy with respect to the ReplicaSet controller: the controller
may create a replacement while the deletion is still propagating.

## Decision

All programmatic pod replacement uses the **eviction subresource**, and the agent
is granted `create` on `policy/pods/eviction` — and deliberately **not** granted
`delete` on `pods`.

```
- apiGroups: ["policy"]
  resources: ["pods/eviction"]
  verbs: ["create"]
```

This holds for the remediation agent and for `scripts/inject-failure.sh pod-evict`. The `pod-kill` scenario exists only to demonstrate that a plain
deletion is *not* budget-protected, and the script says so at the point of use.

## Consequences

**Positive.** Automated remediation cannot breach the disruption budget. When a
budget is exhausted the API server returns `429 TooManyRequests` and the agent
backs off and escalates, which is the correct behaviour: `minAvailable: 2` means
two replicas must stay up, whatever the agent wants. The RBAC gap makes the
unsafe operation unavailable rather than merely discouraged.

**Negative.** Eviction can be *refused*, so the agent needs a
policy-violation path (back off, escalate) that a `DELETE` would not require.
Observing a refusal is also the clearest demonstration that the budget is
working, which the `pod-evict` scenario relies on.

**Negative.** The eviction subresource has no top-level `kind`. A manifest-based
caller cannot submit it with `kubectl create -f`, because the API server's
discovery documents expose `pods/eviction` only as a subresource — there is no
`Eviction` entry in `kubectl api-resources`:

```
$ kubectl create -f - <<'YAML'
apiVersion: policy/v1
kind: Eviction
...
YAML
error: no matches for kind "Eviction" in version "policy/v1"
```

This is a **permanent property of the API**, not version skew, and it was
verified as such: the failure is byte-identical on kubectl v1.31.14 and
v1.36.1, and discovery on the v1.37.0 server advertises only
`['poddisruptionbudgets', 'poddisruptionbudgets/status']` under `/apis/policy/v1`
while `pods/eviction` carries the single verb `create`. **Do not attempt to
"fix" this by upgrading kubectl, and do not treat a future recurrence as an
environment problem.** The subresource must be addressed by its raw path:

```bash
kubectl create --raw "/api/v1/namespaces/${NS}/pods/${POD}/eviction" -f -
```

Two consequences follow from the raw-path requirement:

- The raw path has no `--dry-run` support (see below), so the PDB — not a
  dry-run — is what actually protects the workload here.
- The raw path hardcodes `/api/v1/`, which is the correct group for the *pod*
  resource (eviction posts against the pod, even though the object it carries is
  `policy/v1`). This is a real coupling to the pod API version and should be
  revisited if pods ever move off `v1`.

## `--raw` silently drops the dry-run flag

`kubectl create --raw` does **not** forward `--dry-run=server` to the API server,
and it does not error. Verified by wire capture: the raw request URL contained no
`?dryRun=All`, whereas an equivalent non-raw `create` produced
`?dryRun=All&fieldManager=kubectl-create&fieldValidation=Strict`.

The practical hazard is that a "dry-run" raw eviction is a **real eviction**. Any
remediation path using `--raw` for the eviction subresource must perform its own
dry-run gate by other means, or skip the dry-run and rely on the PDB (which is
what actually protects the workload). This is why the smoke-test mutation
classifier in `scripts/smoke-test.sh` checks `--raw` for mutation **before** it
checks for `--dry-run`: flag order matters, and getting it backwards would
classify a real eviction as a safe probe.

## Verifying eviction permission: `can-i` asks the wrong API group

The executor's `create` on `pods/eviction` lives in the **`policy`** group, but
`kubectl auth can-i` has no way to express a group together with a subresource.
Its `<resource>/<subresource>` slash form defaults that resource to the **core**
group, so the command asks about `""/pods/eviction` — a rule nobody holds — and
answers `no` for a Role that is entirely correct:

```console
$ kubectl auth can-i create pods/eviction \
    --as=system:serviceaccount:selfhealing:remediation-executor -n selfhealing
no                                     # WRONG - wrong group, not a wrong Role
```

This is reproducible on kubectl **v1.31.14** and **v1.36.1**, so it is a property
of the client command rather than version skew, and it should not be "fixed" by
adding a core-group grant — that would grant a permission the design explicitly
withholds.

The authoritative checks are `can-i --list`, which annotates the grant with its
real group (`pods.policy/eviction  [create]`), and a `SubjectAccessReview` that
names `"group": "policy"` explicitly, which returns `allowed: true` with a reason
naming the RoleBinding. Use a `SubjectAccessReview` when the answer matters.

Recorded here because the failure mode is dangerous in the specific direction that
matters: a false `no` invites someone to widen the Role until the *tool* is
satisfied, which is the exact move this ADR exists to prevent. See also
`docs/runbook.md` for the full verification procedure, including the two adjacent
traps (the client cannot map `kind: Eviction` at all, and `--dry-run=server`
trips CRD schema validation before authorization is consulted).

## Alternatives Considered

- **Direct `delete pod`.** Rejected: it bypasses the disruption budget, so an
agent evicting in a loop can drain the entire replica set — precisely when the
budget is most needed. Retained in `scripts/inject-failure.sh` only as the
`pod-kill` negative control, which exists to demonstrate this failure.
- `**delete pod` plus a pre-flight PDB check in the agent.** Rejected: the check
is advisory and racy. Two concurrent agent actions can each observe budget
headroom and together breach it. The API server's own admission path has no
such race, and using it costs nothing.
- **Cordon the node instead of evicting the pod.** Rejected for pod-level
faults: far heavier blast radius, and it removes capacity the workload may
still need.

## References

- Kubernetes, *Disruptions*: [https://kubernetes.io/docs/concepts/workloads/pods/disruptions/](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- Kubernetes, *Eviction API*: [https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/](https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/)

 
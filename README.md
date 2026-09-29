# Self-Healing Kubernetes Cluster
A reference implementation of a Kubernetes cluster that detects and repairs its
own failures, built to run locally on minikube and designed to migrate to AWS EKS
with Terraform.

The design is deliberately layered: **most self-healing needs no agent at all.**

Probes and controllers handle the common cases in seconds; an optional
metrics-driven agent handles only what they cannot express. See
[docs/design.md](docs/design.md) for the reasoning.

```
docs/design.md      why the architecture is shaped this way
docs/runbook.md     how to run, verify and troubleshoot it
docs/adr/           decision records - why, and what was rejected
k8s/                Kubernetes manifests
app/                the demo workload (Flask + gunicorn)
scripts/            setup, teardown, status, failure injection
tests/chaos/        chaos test scenarios
```

---

## Quick start
Requires Docker running, plus `minikube` and `kubectl`.

```bash
scripts/setup.sh              # cluster + workload      (~2-4 min)
scripts/status.sh             # verify
scripts/inject-failure.sh --list
```
Then break something on purpose:

```bash
scripts/inject-failure.sh pod-evict    # PDB-gated eviction - sanctioned   ~7-15s
scripts/inject-failure.sh app-fail     # readiness sheds, liveness restarts
scripts/inject-failure.sh cpu-load     # HPA scales 3 -> 7 -> 10

scripts/inject-failure.sh recover-all  # reset
```
With the full observability stack (adds ~1.5 CPU / ~3 GiB):

```bash
scripts/setup.sh --monitoring --load-generator
```

---

## The demo workload
`app/app.py` is a Flask service with deliberate failure-injection endpoints:

- `GET /healthz` — liveness; returns 500 when faulted

- `GET /readyz` — readiness; returns 503 when faulted

- `GET /fail` — inject a fault (readiness sheds, then liveness restarts)

- `GET /recover` — clear the fault

- `GET /burn?seconds=N` — consume CPU for HPA testing

- `GET /metrics` — Prometheus exposition format

- `GET /echo` — echo the request back (load-target endpoint)
Fault state is persisted to a file, not process memory, because gunicorn runs
multiple workers and a module-level dict would only be set in one of them.

---

## What is in `k8s/`

- `00-namespace.yaml` — `selfhealing` namespace, `restricted` Pod Security

- `10-deployment.yaml` — `demo-api` ×3, startup/readiness/liveness probes, topology spread

- `20-service.yaml` — ClusterIP Service

- `30-hpa.yaml` — HPA 3→10 on CPU 70% / memory 80%, asymmetric stabilisation

- `40-pdb.yaml` — `minAvailable: 2` — bounds voluntary disruption

- `optional/agent/rbac.yaml` — least-privilege ServiceAccount, Role, RoleBinding

- `optional/agent/load-generator.yaml` — CPU load for HPA testing

- `optional/observability/` — ServiceMonitor + PrometheusRule (need Prometheus Operator CRDs)

- `optional/observability/*.helm` — Helm values for kube-prometheus-stack (chart config, not a manifest)
`optional/` is excluded from the default apply because its manifests depend on
CRDs that are not present in a bare cluster.

Run `make validate` for offline structural checks: selectors that match nothing,
probes aimed at undeclared ports, an HPA whose target lacks the CPU request it
needs. These are cross-manifest errors that schema validation cannot catch, and
they are checked without needing a cluster.

---

## The three tiers

**Tier 0 — kubelet.** Detects a failed probe and restarts the container.

Latency: ~7-14s for readiness, ~25-40s for liveness. Needs neither the control
plane nor the network.

**Tier 1 — controllers.** Detects desired ≠ actual and creates or evicts pods.

Latency: ~7-15s. Requires the control plane to be up.

**Tier 2 — external agent.** Detects an alert condition and evicts or patches.

Latency: ~75s. Requires the API server, Prometheus, and network access to an
LLM provider. It is itself a thing that can fail.

A fault is handled at the lowest tier capable of resolving it. Tier 2 is
reserved for conditions that cannot be expressed as a probe or a reconciliation
rule — SLO breaches, queue-depth anomalies, certificate expiry. Reaching for the
agent before exhausting Tiers 0 and 1 is the most common architectural mistake
in this space.

---

## Failure scenarios

**pod-evict** — eviction API + PDB (sanctioned). Replaced, or refused if it
would breach the budget. This is the only sanctioned pod-replacement path.

**pod-kill** — direct delete (negative control). Replacement in ~7-15s, but
bypasses the PDB. Exists to demonstrate that direct deletion ignores the
budget, which is why ADR-0005 mandates the eviction API for remediation.

**app-fail** — readiness → liveness. Traffic shed in ~7-14s, container restart
in ~25-40s. Exercises two independent healing paths at once.

**cpu-load** — HPA. Scales out in ~60-120s (3→7→10; see design.md §5 for why
the intermediate 7 is significant).

**bad-image** — rollout stall. Stays available throughout; requires manual
rollback. Not healing itself is intentional: a system that automatically fixes
every failed rollout is one that rolls back legitimate changes.

**node-drain** — scheduler. Reschedules pods (needs ≥2 nodes; with 1 node the
scenario exercises its refusal guard instead).

**Safety policy.** Pod replacement always goes through the eviction API, never a
direct `delete`, so the PodDisruptionBudget is enforced by the API server rather
than by convention ([ADR-0005](docs/adr/0005-use-eviction-api-not-delete.md)).

Manifests are validated with `kubectl --dry-run=server` before every apply and
delete (enforced in `scripts/lib/common.sh`). See [docs/adr/](docs/adr/README.md)
for the reasoning behind each decision.

---

## Roadmap

- [ ] **Floci integration** — AWS emulation for the Terraform/ECR path
  `floci start`; verify coverage with `floci services`)

- [ ] **Terraform** — EKS cluster, managed node group, IRSA roles

- [ ] **Remediation agent** — the Tier 2 controller described in
  `docs/design.md` §6; RBAC is already in place, the controller is not

- [ ] **Node elasticity** — Cluster Autoscaler or Karpenter; today nothing scales
  nodes, so an HPA blocked on capacity is unrecoverable `design.md` §11)

- [ ] **Remediation budget** — rate-limit agent actions per namespace
Known gaps are tracked as open questions in
[docs/design.md](docs/design.md#13-open-questions) rather than omitted.

---

## Requirements
Docker (Desktop or colima), minikube ≥ 1.30, kubectl within ±1 minor of the
cluster (tested with kubectl v1.31.14 against minikube's v1.37.0; behaviour
outside that window is best-effort), and optionally helm ≥ 3.12 for
`--monitoring` and Floci ≥ 0.2 for the AWS path.

The cluster is created with 4 CPU / 8 GiB. Below ~4 CPU the HPA behaviour becomes
unrepresentative — see `docs/design.md` §10.1. Override with
`MINIKUBE_CPUS` / `MINIKUBE_MEMORY`. All scripts honour `CLUSTER_NAME`,
`K8S_NAMESPACE`, `MONITORING_NAMESPACE`, `APP_IMAGE`, `ASSUME_YES` and
`NO_COLOR`.

---

## Teardown
```bash
scripts/teardown.sh --app-only       # namespace only
scripts/teardown.sh --keep-cluster   # app + monitoring
scripts/teardown.sh --all            # delete the minikube profile
```

---

## Known issues
One gap is documented rather than fixed, so that the state of the repository is
honest about what has been verified and what has not.

*`shellcheck` is not installed, so `make lint` skips it.** The `validate` target
syntax-checks every script with `bash -n` (which catches parse errors), but
`bash -n` does not catch the class of bug `shellcheck` catches: unquoted
expansions, `local` outside a function, `$(...)` in a condition that always
succeeds. The `local: can only be used in a function` bug in `smoke-test.sh` was
exactly that class, and it was found only by running the suite — not by linting
it, which would have caught it before it ever ran. `make shellcheck` prints
`shellcheck not installed; skipping` and exits 0, so the gap is silent unless you
read the output. Install it `brew install shellcheck`) to close this, and note
that `make validate` is a *necessary but insufficient* gate until then.

### Resolved during development, recorded for the pattern
These were live defects, and they are listed because the way each was found is
the useful part. All are fixed; none is outstanding.

**A latency figure that was the measuring loop's floor.** The `app-fail` scenario
reported a liveness restart at ~43s for every run. The stability of that number
made it look like a measurement; it was the readiness loop's 45s period, because
the loop had no break-on-success and `restartCount` was read only after it
exited. With the break added, the first live run reported 26s — inside the
25-40s band derived from the probe arithmetic. See `docs/design.md` §4.2.

**Assertions that restated a baseline instead of reading it.** `pod-evict`
waited for `readyReplicas == "3"` and `app-fail` for `endpoints == "2"`, both
assuming the deployment sits at `minReplicas`. It cannot: the HPA's memory-bound
fixed point holds at 5/6/7, so at the natural steady state those predicates were
unreachable, and `pod-evict` returned failure after a successful eviction. Both
now sample the live baseline and assert relative to it.

**A smoke-test guard that was unsound.** An added "the evicted pod is gone"
check asserted a stronger claim than its wait established — terminating pods are
excluded from `readyReplicas`, so the replacement is created immediately and
whether the old pod is gone is a race, not a contract. It was removed rather
than loosened, which also cleared a false failure in the `pod-evict` consent
control.

The common thread, and the reason they are recorded: in each case **the check
kept passing**, or failed, for a reason unrelated to the system it was testing.

`docs/design.md` §14 names this as the project's dominant failure mode and lists
all nine instances.
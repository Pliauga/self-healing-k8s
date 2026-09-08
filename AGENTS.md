# Agent Instructions — Self-Healing Kubernetes Cluster

Every agent and subagent working in this repository reads this file at startup.

It is the short, always-injected rule sheet. Long-form context lives in `docs/`.

## Project Goal

Build a production-grade self-healing Kubernetes cluster locally (Minikube +
Floci), designed for direct migration to AWS EKS via Terraform. Three tiers of
healing: kubelet probes, controller reconciliation, external LLM agent.

**Source of truth:** `docs/design.md` (architecture) and `docs/runbook.md`
(operational procedures). Read them before making structural changes.

## Tech Stack

- **Local K8s:** Minikube (driver: docker, profile: `selfhealing`)
- **Local AWS:** Floci (endpoint `http://localhost:4566`)
- **IaC (target):** Terraform → AWS EKS
- **Monitoring:** kube-prometheus-stack (Prometheus, Alertmanager, Grafana)
- **App:** Python 3.12 + Flask + gunicorn
- **Agent Runtime:** DeepSeek Harness with `dsh-kubectl`, `dsh-docker`, `dsh-terraform`
- **Primary Model:** `deepseek-v4.1-flash`
- **Escalation Model:** `gpt-6-luna`

## Directory Structure

```
.

├── AGENTS.md                    # this file
├── README.md
├── app/                         # demo-api Flask application
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── docs/
│   ├── design.md                # architecture (owned by you)
│   ├── runbook.md               # operational procedures
│   └── adr/                     # architecture decision records
├── k8s/                         # Kubernetes manifests
│   ├── 00-namespace.yaml
│   ├── 10-deployment.yaml
│   ├── 20-service.yaml
│   ├── 30-hpa.yaml
│   ├── 40-pdb.yaml
│   └── optional/
│       ├── agent/               # RBAC for the remediation agent
│       └── observability/       # PrometheusRule, ServiceMonitor
├── scripts/                     # bash automation
│   ├── setup.sh
│   ├── status.sh
│   ├── inject-failure.sh
│   └── teardown.sh
└── tests/chaos/                 # chaos test scenarios
```

## Naming Conventions

- **K8s resources:** `kebab-case` (e.g. `demo-api`, `self-healing-agent`)
- **K8s namespace:** `selfhealing` (no hyphen — matches design.md)
- **Terraform:** `snake_case`
- **Bash scripts:** `kebab-case.sh`
- **Python:** `snake_case` for functions/vars, `PascalCase` for classes
- **Environment variables in scripts:** `UPPER_SNAKE_CASE`
- Never mix conventions across directories.

## Safety Rules (MANDATORY)

1. **Always `--dry-run=server` before `kubectl apply` or `kubectl delete`.**
2. **Never run destructive kubectl commands without explicit user approval.**
  Destructive: `delete`, `drain`, `cordon`, `scale --replicas=0`, `delete ns`.
3. **Never bypass PodDisruptionBudgets.** Use the eviction API, never `kubectl delete pod` for "remediation."
4. **Never modify `terraform/` state files directly.**
5. **Never `git commit` or `git push` without user confirmation.**
6. **Never write credentials, API keys, or tokens into any tracked file.**
7. **If a change touches more than 3 resources, present a plan first.**
8. **Read existing files before writing new ones.** Modify, don't duplicate.
9. **Verify the mutation guard is active in the SAME shell invocation as the
  mutating call.** Check the guard's existence and behaviour immediately before
  the call, not in a separate step. A guard checked in one command and used in
  another is not a guard. For example:

  ```bash
  type -t my_stub >/dev/null && my_stub --dry-run || die "stub not loaded"
  ```

  In practice this means a stub harness must be built and asserted in the same
  script that runs the target, never assembled by hand in a prior command.

10. **After any script invocation that could mutate, check the event log:**
  `kubectl get events -n selfhealing --sort-by=.lastTimestamp | tail -5`.
  Report any unintended mutation, even when the impact appears to be zero. The
  purpose is to detect the mutations you did *not* intend, which are exactly the
  ones a success message will not mention.

## Agent Behavior

- **Ask before creating new top-level directories.** Match the structure above.
- **Prefer editing existing manifests over creating variant manifests.**
If you need a different config, parameterize — don't fork.
- **When unsure about cluster state, run `kubectl_status` or `kubectl_get` first.**
Never assume a cluster is empty or a deployment exists.
- **For self-healing logic, keep the LLM in the diagnosis role, not the
execution role.** See ADR-0003.
- **Reference `docs/runbook.md` when diagnosing failures** — do not improvise
new remediation strategies without adding them to the runbook first.
- **Log every action.** If you patch a resource, say which resource and why.

## Testing

- Every script in `scripts/` must run cleanly from a fresh `minikube delete`.
- Every manifest in `k8s/` must pass `kubectl apply --dry-run=server -f <file>`.
- Chaos scenarios in `tests/chaos/` must produce the "Expected time" from
`docs/design.md` §7.

## When in Doubt

Ask the user. A 30-second clarification beats a 3-hour rollback.
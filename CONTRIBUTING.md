# # Contributing

Notes for anyone (including me, three weeks from now) picking this up. The

architecture lives in `docs/design.md`; this file is the short version of how

to work on the code without breaking it.

## What this project is

A three-tier self-healing Kubernetes cluster: kubelet probes handle the

cheap cases, controllers handle reconciliation, and a metrics-driven agent

handles what the first two cannot express. Runs locally on Minikube with

Floci standing in for AWS. The production target is EKS via Terraform.

## Setup

```bash

scripts/[setup.sh](http://setup.sh) --monitoring --load-generator

scripts/[status.sh](http://status.sh)

```

Cluster state is stored project-locally at `.minikube-home/` and `.kube/`

rather than in `$HOME`. This keeps the project self-contained — `rm -rf` is

a clean uninstall.

## Naming

- Kubernetes resources: `kebab-case` `demo-api`, `self-healing-agent`)
- Namespace: `selfhealing` (no hyphen — matches `design.md`)
- Terraform: `snake_case`
- Bash scripts: `kebab-case.sh`
- Python: `snake_case` for functions and variables, `PascalCase` for classes
- Environment variables in scripts: `UPPER_SNAKE_CASE`

## Safety rules

These exist because breaking them has already caused incidents in this

project's history. See `docs/design.md` §14.

1. **Always `--dry-run=server` before `kubectl apply` or `kubectl delete`.**
  The wrapper in `scripts/lib/common.sh` enforces this. Don't bypass it.
2. **Never run destructive kubectl commands without explicit approval.**
  That includes `delete`, `drain`, `cordon`, `scale --replicas=0`, and
   `delete ns`.
3. **Pod replacement goes through the eviction API, never direct `delete`.**
  Direct delete bypasses the PodDisruptionBudget. See ADR-0005.
4. **Never modify Terraform state files directly.**
5. **Never commit credentials, API keys, or tokens.** `make hygiene` scans
  for this; it should stay clean.
6. **If a change touches more than three resources, present a plan first.**

## Working style

- Read existing files before writing new ones. Modify, don't duplicate.
- Prefer parameterizing an existing manifest over creating a variant.
- When unsure about cluster state, query it — don't assume. `kubectl get
  pods -n selfhealing` before reasoning about what's there.
- Log every action. If you patch a resource, say which resource and why.
- Diagnostics belong in `docs/runbook.md` before they belong in code.

## Testing

- Every script must run cleanly from a fresh `minikube delete`.
- Every manifest must pass `kubectl apply --dry-run=server -f <file>`.
- Chaos scenarios in `tests/chaos/` must match the expected times in
  `docs/design.md` §7. If a measured time disagrees with the doc, fix the
  doc, not the assertion.
- `make validate` runs the offline gate. It is necessary but not sufficient
  — see `README.md` "Known issues".

## When in doubt

Ask. A 30-second clarification is cheaper than a 3-hour rollback.
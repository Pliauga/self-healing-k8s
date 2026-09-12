# ADR-0001: Use Minikube Instead of Kind for Local Kubernetes

**Date:** 2026-09-28
**Status:** Accepted

## Context

We need a local Kubernetes cluster to develop and demonstrate self-healing
behavior. The two leading candidates are Minikube and Kind. The cluster must
support metrics-server, HPA, PodDisruptionBudgets, and topology spread
constraints out of the box, since these are load-bearing for the design.

## Decision

Use **Minikube** with the Docker driver, under a named profile `selfhealing`.

## Rationale

- **Addons are first-class.** `minikube addons enable metrics-server` installs
and wires metrics-server in one command. Kind requires installing the full
kube-prometheus-stack or a hand-rolled manifest, and getting the API service
registration right is a known friction point.
- **Named profiles isolate this project.** `minikube -p selfhealing` keeps state
(cluster, images, volumes) independent from any other local cluster. Deletion
is `minikube delete -p selfhealing` — no Docker state leaks.
- **Image build path is short.** `minikube image build -p selfhealing` builds
directly into the node's container runtime. No registry, no `kind load`,
no imagePullPolicy gymnastics.
- **Tunnel and ingress are built in.** `minikube tunnel` and the ingress addon
are one-liners when we need them later.
- **Floci interop is simpler.** Minikube's Docker driver puts the node in a
predictable network where `host.docker.internal:4566` reaches Floci on the
host. Kind's nested containers complicate this.

## Consequences

**Positive:**

- Faster bootstrap; fewer manual steps to reach a working HPA demonstration.
- Consistent, reproducible dev environment across machines.

**Negative:**

- Minikube is heavier than Kind: ~2 GiB baseline for the node alone.
- Docker driver exposes node ports on the host, which can surprise.
- The cluster is single-node by default; multi-node requires `--nodes=N`.

**Mitigation:**

- Document required resources in the runbook: `--cpus=4 --memory=8192`.
- Use `minikube tunnel` explicitly in scripts rather than relying on NodePorts.

## Alternatives Considered

- **Kind** — Rejected on addon friction and Floci interop. Would reconsider if
the project needed multi-node clusters with rapid recreate cycles.
- **k3s** — Rejected as production-oriented; overkill for local dev.
- **Docker Desktop Kubernetes** — Rejected on licensing grounds for commercial use.
- **Talos in Docker** — Rejected as too far from the EKS target architecture.

 
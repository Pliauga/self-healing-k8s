# ADR-0004: Three-Tier Healing Model

**Date:** 2026-09-28
**Status:** Accepted

## Context

"Self-healing Kubernetes" is an overloaded term. In practice it describes
capabilities that range from "kubelet restarts a wedged container" to "an
external system detects an SLO breach and reshapes the cluster." These
capabilities have radically different latencies, failure modes, and trust
requirements, and conflating them produces systems that are simultaneously
over-engineered and fragile.

The specific failure mode we want to avoid: reaching for the LLM agent to
remediate faults that a liveness probe or a ReplicaSet already handles. This is
slow (agent path is ~5× the kubelet path), fragile (the agent needs network and
credentials), and dangerous (the agent is itself a thing that can fail).

## Decision

Model self-healing as three independent, layered tiers, and adopt the rule:
**a fault must be handled at the lowest tier capable of resolving it.**


| Tier | Mechanism                                                   | Detection latency | Survives control-plane outage | Authority                   |
| ---- | ----------------------------------------------------------- | ----------------- | ----------------------------- | --------------------------- |
| 0    | kubelet probes (liveness, readiness, startup)               | 10–45 s           | Yes                           | Per-node, autonomous        |
| 1    | Controller reconciliation (ReplicaSet, HPA, PDB, scheduler) | 1–15 s            | No                            | Declarative, threshold-free |
| 2    | External LLM agent (alert-driven)                           | 60–120 s          | No                            | Narrow, audited, gated      |


Tier 2 is reserved for conditions that **cannot be expressed as a probe or a
reconciliation rule**: p99 latency SLO breaches, queue-depth anomalies,
certificate expiry, cross-service correlated failures, drift from declared
topology.

## Rationale

- **Latency budget.** A liveness restart completes in ~25-40 s end-to-end
(measured 26 s; see design.md section 7). The
alert path (`for: 1m` + webhook + diagnosis + executor + apply) completes in
~75 s or more. For a fault the kubelet can already handle, Tier 2 doubles
recovery time for no added capability.
- **Blast radius.** Tier 0 acts on one container on one node. Tier 1 acts on
a resource set defined by a selector. Tier 2 acts on whatever the executor's
allowlist permits. The trust required scales with the tier, so the tier
should scale with the fault's severity.
- **Failure independence.** Tier 0 works when the API server is unreachable.
Tier 1 works when Prometheus is down. Tier 2 requires both. Layering means
a failure in one tier does not silently remove protection from the others.
- **Cognitive fit.** Engineers already reason in these tiers (probes,
controllers, controllers+operators). Encoding the tiers makes reviews
tractable: "why is this a Tier 2 remediation?" has an answerable form.
- **Cost.** Tiers 0 and 1 are free. Tier 2 consumes LLM tokens, network hops,
and human attention on escalations. Charging Tier 2 for what Tier 0 handles
is the most expensive way to solve the problem.

## Consequences

**Positive:**

- Clear placement rules for new remediations: probes → controllers → agent.
- Latency budgets become a design constraint, not a post-hoc metric.
- The system degrades gracefully: if the agent is down, Tier 0/1 still work.
- The tier structure directly supports the demo narrative (design.md §7),
because each row maps to a specific tier.

**Negative:**

- More upfront design: every remediation must justify its tier.
- Some faults genuinely straddle tiers (e.g. node failure involves Tier 0
removal from service, Tier 1 rescheduling, and sometimes Tier 2 escalation).
- Testing must cover inter-tier interactions, not just each tier alone.

**Mitigation:**

- `docs/design.md` §7 lists each known failure with its assigned tier, making
placement auditable.
- Inter-tier behavior is exercised by the `node-drain` chaos scenario, which
crosses all three tiers.
- The `remediation` label on alerts carries tier intent explicitly, so an
alert written for Tier 2 cannot accidentally be picked up by Tier 0 logic
(they don't share a bus).

## Alternatives Considered

- **Single-tier: agent does everything.** Rejected: slowest, most fragile, and
requires the agent to run before the system is minimally self-healing. Fails
during any control-plane incident — the exact time you most need healing.
- **Two-tier: probes + agent (no controllers).** Rejected: controllers
reconcile continuously and for free. Skipping them means the agent must
re-implement ReplicaSet semantics, badly and slowly.
- **Four+ tiers (splitting controllers by type).** Rejected as over-modeled.
Kubelet vs. controllers vs. agent is the natural boundary; further division
adds vocabulary without adding capability.
- **No formal tiering — case-by-case decisions.** Rejected: this is the status
quo that produces systems where the agent restarts pods the kubelet would
have restarted in a third of the time.

## References

- `docs/design.md` §3 — Architecture overview and tier table
- `docs/design.md` §3.1 — Tier definitions and design rule
- `docs/design.md` §8 — End-to-end latency budget by tier
- Burns et al. (2016). Borg, Omega, and Kubernetes. *CACM 59*(5).

 
# Architecture Decision Records

Short, immutable records of decisions that shaped this system. Each states the
context, the decision, and what it costs — including what was rejected and why.

| ADR | Decision |
|---|---|
| [0001](0001-use-minikube-over-kind.md) | Use Minikube instead of Kind for the local cluster |
| [0002](0002-use-floci-over-localstack.md) | Use Floci instead of LocalStack for local AWS emulation |
| [0003](0003-llm-proposes-executor-disposes.md) | The LLM proposes; a deterministic executor disposes |
| [0004](0004-three-tier-healing-model.md) | Three-tier healing, handled at the lowest capable tier |
| [0005](0005-use-eviction-api-not-delete.md) | Use the eviction API, never pod deletion, for remediation |

## Conventions

- One decision per file, named `NNNN-short-title.md`, numbered sequentially.
- Each record opens with `# ADR-NNNN: Title`, then **Date** and **Status**, then
  the sections **Context**, **Decision**, **Rationale**, **Consequences**,
  **Alternatives Considered** and **References**.
- **Status** is `Accepted`, `Proposed`, `Superseded by ADR-NNNN`, or
  `Deprecated`. An accepted ADR is not edited; it is superseded by a new one.
- Each ADR records the negative consequences, not only the benefits. A decision
  without a stated cost has not been thought through.
- Decisions must be reflected in `docs/design.md`. If the two disagree, the ADR
  is authoritative for *why* and `design.md` for *what*.
- Reference the relevant section of `docs/design.md` under **References** so the
  decision can be traced to the architecture it shapes.

## Relationship to `design.md`

`design.md` describes what the system is. These records describe why it is that
way, and what else was considered. ADR-0004 (mirrored in `design.md` §3) is the
one to read first: it establishes the tiering that the other decisions slot into.
ADR-0005 is the concrete safety consequence of that tiering, and pairs with the
`pod-evict` / `pod-kill` scenarios in `scripts/inject-failure.sh`.
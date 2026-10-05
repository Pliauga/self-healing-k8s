"""The structured diagnosis contract between the LLM and the deterministic
executor.

This module is a safety boundary, not a convenience. ADR-0003 splits the agent
into a component that *decides* (the LLM, which holds no write credential) and a
component that *acts* (deterministic code). Everything crossing that boundary
crosses it as a ``Diagnosis``, and a response that does not validate never
becomes an action: it becomes an escalation.

Two properties here carry the safety story:

1. ``action`` is a closed set. A diagnosis outside it is escalated to a human,
   never improvised upon (docs/design.md §6.4).
2. ``ACTIONS`` is *derived* from the ``Action`` literal, not written out beside
   it. docs/design.md §14 names "a check that restates a fact instead of reading
   it" as this project's dominant failure mode; a second hand-maintained copy of
   the vocabulary would be exactly that, and it would drift silently in the
   safe-looking direction.
"""

from __future__ import annotations

from typing import Literal, get_args

from pydantic import BaseModel, ConfigDict, Field, field_validator

# The closed remediation vocabulary (ADR-0003, docs/design.md §6.1):
#   restart-pod  evict one pod; the ReplicaSet replaces it
#   scale-up     let the HPA raise replicas; the agent does not write replicas
#   investigate  deliberate no-op; a human looks at why
#   escalate     hand off to a human; the fail-closed default
Action = Literal["restart-pod", "scale-up", "investigate", "escalate"]

# Derived, never restated. Change the literal above and this follows.
ACTIONS: frozenset[str] = frozenset(get_args(Action))


class Diagnosis(BaseModel):
    """What the LLM is allowed to say, and all it is allowed to say."""

    # Unknown keys from the model are ignored rather than rejected: an extra
    # field is not a safety problem, and failing on one would turn a usable
    # diagnosis into an escalation for no safety gain. The four fields below
    # are validated strictly.
    model_config = ConfigDict(extra="ignore")

    root_cause: str = Field(
        min_length=1,
        description="Why the cluster is in this state, in one or two sentences.",
    )
    action: Action = Field(
        description="One of the closed vocabulary. Anything else is escalated.",
    )
    target: str = Field(
        min_length=1,
        description="The resource the action names, e.g. affected pod or Deployment.",
    )
    confidence: float = Field(
        ge=0.0,
        le=1.0,
        description="Self-reported confidence, 0..1. The executor gates on this.",
    )

    @field_validator("action", mode="before")
    @classmethod
    def _strip_action(cls, value: object) -> object:
        """Trim surrounding whitespace, and nothing else.

        Deliberately NOT a normaliser: mapping "restart_pod" onto "restart-pod",
        or lower-casing an arbitrary token, would invent vocabulary the rules
        file never defined. Anything not already one of the four categories
        fails validation and becomes an escalation.
        """
        if isinstance(value, str):
            return value.strip()
        return value

    @classmethod
    def escalate(cls, root_cause: str, target: str) -> "Diagnosis":
        """The fail-closed default, used whenever a diagnosis is unusable.

        A malformed response, a validation failure, or an unparseable body must
        never default *towards* an action (HANDOFF §5). Confidence is 0.0 so the
        executor's gate cannot pass it even if the caller checked nothing.
        """
        return cls(
            root_cause=root_cause,
            action="escalate",
            target=target,
            confidence=0.0,
        )

"""Deterministic execution of a validated diagnosis.

ADR-0003: "The LLM never calls a write API. The executor never calls an LLM."
This module is the second half of that sentence. It receives a Diagnosis and
performs at most ONE mutation, chosen from a closed set by code rather than by
a model. There is no inference here, no retry-until-it-works, and no path that
constructs a verb the allowlist does not name.

THREE-STATE READS
Every read this module performs answers with three states, never two: found,
absent, or INDETERMINATE. The distinction is load-bearing. A 403 from a Role
that lacks a verb looks identical to a healthy "no such object" if both collapse
to None, and the executor would then report "already healed" for a pod it was
never authorized to look at - a false success, which is the exact divergence
class catalogued in docs/design.md §14 (finding 2, and the emptyDir crash loop:
a check that reports a confident answer to a question it did not actually ask).
Indeterminate always escalates. There is no path where an unverifiable read is
read as permission to act.

Guards are ordered so a failure returns an escalation rather than proceeding:

  unknown action   validated against ACTIONS, derived from schema.py's Action
                   literal - never a second literal here. Out of vocabulary
                   means a human, not a best guess.
  low confidence   below CONFIDENCE_THRESHOLD the agent does not act at all.
                   The threshold is a property of the executor, not of the
                   model's self-report, so it cannot be talked past.
  target gone      the cluster may have healed between the alert firing and
                   this call (docs/design.md §6.2). Blind actuation on a stale
                   alert is how an agent causes an outage - and "I could not
                   tell whether the target is still there" escalates; it is
                   never read as "the target is gone".
  PDB exhausted    checked explicitly BEFORE evicting. The API server would
                   refuse anyway (429), but a refusal we can see coming is a
                   back-off, not an error rate.

WHY THE EVICTION USES kubectl create --raw
ADR-0005: pods/eviction has no top-level kind, so the client cannot map it and
kubectl create -f eviction.json fails with: no matches for kind "Eviction" in
version "policy/v1" - a property of the API, not version skew.

CRITICAL: --raw silently drops --dry-run=server (docs/design.md §14, finding 1 -
no ?dryRun=All on the wire, and no error). A "dry-run" raw eviction is a REAL
eviction; one pod was evicted before this was found. The dry-run gate for this
path therefore cannot be the flag. Its substitutes are the explicit PDB check,
the mandatory GET on the target, and the fact that the PDB - not a dry run - is
what actually protects the workload here.
"""

from __future__ import annotations

import enum
import json
import logging
import subprocess
from typing import Any

from pydantic import BaseModel, ConfigDict

from .schema import ACTIONS, Diagnosis

log = logging.getLogger(__name__)

# The confidence gate. A property of the executor, not of the model's
# self-report: it cannot be talked past by a confident-sounding diagnosis.
CONFIDENCE_THRESHOLD = 0.85

# ADR-0005: the version the eviction object is spelled against. The raw path
# posts to /api/v1 (the pod resource), even though the object it carries is
# policy/v1 - a real coupling to revisit if pods ever move off v1.
EVICTION_VERSION = "policy/v1"

KUBECTL_TIMEOUT_S = 20


class ReadState(str, enum.Enum):
    """The three-state result of any cluster read.

    FOUND / ABSENT are answers. INDETERMINATE is the absence of an answer -
    permission denied, timeout, unparseable body, transport error - and callers
    must treat it as a refusal to proceed, never as ABSENT.
    """

    FOUND = "found"
    ABSENT = "absent"
    INDETERMINATE = "indeterminate"


class PodLookup(BaseModel):
    """Outcome of the mandatory target re-check."""

    model_config = ConfigDict(extra="forbid")

    state: ReadState
    pod: dict[str, Any] | None = None
    detail: str = ""


class BudgetLookup(BaseModel):
    """Outcome of the PDB budget gate.

    ``allowed`` is meaningful only when ``state`` is FOUND. It is None in that
    case when no PDB applies at all: the gate is absent, not blocking, which is
    permission - and the log says so rather than inventing a count.
    """

    model_config = ConfigDict(extra="forbid")

    state: ReadState
    allowed: int | None = None
    detail: str = ""


class ExecutionResult(BaseModel):
    """What the executor did, and why. Returned to the caller verbatim."""

    model_config = ConfigDict(extra="forbid")

    applied: bool
    action_taken: str
    reason: str
    # The API server's eviction response body, when an eviction was issued.
    # None for every path that did not mutate anything.
    eviction_response: dict[str, Any] | None = None


def _run(args: list[str], stdin: str | None = None) -> tuple[int, str, str]:
    """Run kubectl; return (returncode, stdout, stderr).

    Never raises. A refusal from the API server (403 from a missing grant, 429
    from an exhausted PDB, 404 for a pod that has gone) is information the
    caller must classify, not an exception to swallow - and a timeout is
    reported as exit code 124 rather than propagating, so a wedged API server
    cannot take the webhook down.
    """
    try:
        proc = subprocess.run(
            ["kubectl", *args],
            input=stdin,
            capture_output=True,
            text=True,
            timeout=KUBECTL_TIMEOUT_S,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"kubectl timed out after {KUBECTL_TIMEOUT_S}s: {' '.join(args)}"
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def lookup_pod(namespace: str, pod: str) -> PodLookup:
    """Fetch the target pod. FOUND, ABSENT, or INDETERMINATE.

    The mandatory re-check from docs/design.md §6.2: it answers "is the
    condition still true?". ABSENT is decisive - the pod is already gone, which
    is a healed cluster, not a failure. INDETERMINATE is not: a Role that lacks
    `get pods` produces the same stderr shape as a genuine 404 for anyone who
    only looks at the exit code, so the two are separated here by message, and
    anything unrecognised falls to INDETERMINATE.
    """
    code, out, err = _run(["get", "pod", pod, "-n", namespace, "-o", "json"])
    if code == 0:
        if not out:
            return PodLookup(state=ReadState.INDETERMINATE,
                             detail="kubectl succeeded but returned no body")
        try:
            parsed = json.loads(out)
        except json.JSONDecodeError as exc:
            return PodLookup(state=ReadState.INDETERMINATE,
                             detail=f"unparseable pod JSON: {exc}")
        if not isinstance(parsed, dict) or "metadata" not in parsed:
            return PodLookup(state=ReadState.INDETERMINATE,
                             detail="pod JSON did not look like a pod")
        return PodLookup(state=ReadState.FOUND, pod=parsed)

    lowered = err.lower()
    if "not found" in lowered or "notfound" in lowered:
        return PodLookup(state=ReadState.ABSENT, detail=err)
    # A 403 lands here, and so does anything else we do not recognise. Both
    # mean "you cannot conclude the pod is gone", so both escalate.
    return PodLookup(state=ReadState.INDETERMINATE,
                     detail=err or f"kubectl exited {code} with no stderr")


def lookup_disruption_budget(namespace: str) -> BudgetLookup:
    """Smallest `disruptionsAllowed` across the namespace's PodDisruptionBudgets.

    INDETERMINATE means the budget could not be established - and the caller
    treats that as a refusal. A guard that fails open is not a guard.
    FOUND with allowed=None means no PDB applies at all: eviction is permitted
    because the gate is absent, not because it reported headroom.

    Reads the whole PDB list rather than one named budget: the pod's owner may
    be covered by any budget in the namespace, and naming one would silently
    check the wrong object if it were ever renamed.
    """
    code, out, err = _run(["get", "poddisruptionbudgets", "-n", namespace,
                           "-o", "jsonpath={.items[*].status.disruptionsAllowed}"])
    if code != 0:
        return BudgetLookup(state=ReadState.INDETERMINATE, detail=err)
    if not out.strip():
        return BudgetLookup(state=ReadState.FOUND, allowed=None,
                            detail="no PodDisruptionBudget applies to this namespace")
    values = [int(v) for v in out.split() if v.lstrip("-").isdigit()]
    if not values:
        return BudgetLookup(state=ReadState.INDETERMINATE,
                            detail=f"could not parse disruptionsAllowed from {out!r}")
    return BudgetLookup(state=ReadState.FOUND, allowed=min(values))


def _evict(namespace: str, pod: str) -> tuple[bool, dict[str, Any] | None, str]:
    """Issue the eviction via the raw subresource path. Returns (ok, body, err).

    The pod name is passed as a positional subprocess argument, never through a
    shell, so it cannot be interpreted as anything other than a path component.
    """
    body = {
        "apiVersion": EVICTION_VERSION,
        "kind": "Eviction",
        "metadata": {"name": pod, "namespace": namespace},
    }
    path = f"/api/v1/namespaces/{namespace}/pods/{pod}/eviction"
    code, out, err = _run(["create", "--raw", path, "-f", "-"], stdin=json.dumps(body))
    if code != 0:
        return False, None, err or out
    try:
        return True, json.loads(out), ""
    except json.JSONDecodeError:
        # A 2xx with an unparseable body still means the API server accepted the
        # eviction; report success with the raw text rather than a failure.
        return True, {"raw": out}, ""


def execute(
    diagnosis: Diagnosis,
    namespace: str = "selfhealing",
) -> ExecutionResult:
    """Validate a diagnosis and perform at most one mutation.

    Returns an ExecutionResult; never raises. Guards run in the order below
    because each is cheaper and more fundamental than the next.
    """
    # 1. The closed set. ACTIONS is derived from the Action literal, so this is
    #    the same vocabulary the schema validated against, not a copy of it.
    if diagnosis.action not in ACTIONS:
        # Unreachable through Pydantic, and deliberately kept: it is the guard
        # for a caller that built a Diagnosis with model_construct(), and for
        # the case where the vocabulary is narrowed without the schema.
        reason = f"rejected: unknown action {diagnosis.action!r}"
        log.warning(reason)
        return ExecutionResult(applied=False, action_taken="escalate", reason=reason)

    # 2. The confidence gate. Below threshold the agent does not act at all -
    #    not "acts more carefully".
    if diagnosis.confidence < CONFIDENCE_THRESHOLD:
        reason = (f"escalated: confidence {diagnosis.confidence:.2f} < "
                  f"threshold {CONFIDENCE_THRESHOLD}")
        log.warning("%s | root_cause=%s", reason, diagnosis.root_cause)
        return ExecutionResult(applied=False, action_taken="escalate", reason=reason)

    # 3. Non-mutating actions. scale-up is a no-op by design: the HPA owns
    #    spec.replicas and the executor holds no deployment write (rbac.yaml).
    #    KNOWN GAP (roadmap: remediation budget): if the HPA never scales - for
    #    instance the memory-bound fixed point where the descent halts at 5-7 -
    #    the alert re-fires and we return scale-up again with no actuation. That
    #    is a load-limiter problem, not a v1 correctness problem.
    if diagnosis.action in ("scale-up", "investigate", "escalate"):
        reason = (f"no-op: {diagnosis.action} requires no cluster mutation "
                  f"(target={diagnosis.target})")
        log.info("%s | root_cause=%s", reason, diagnosis.root_cause)
        return ExecutionResult(applied=False, action_taken=diagnosis.action, reason=reason)

    # 4. restart-pod. Everything below can mutate.
    pod = diagnosis.target
    lookup = lookup_pod(namespace, pod)
    if lookup.state is ReadState.INDETERMINATE:
        reason = (f"escalated: could not determine whether pod {pod} exists - "
                  f"refusing to act on an unverifiable target ({lookup.detail})")
        log.warning(reason)
        return ExecutionResult(applied=False, action_taken="escalate", reason=reason)
    if lookup.state is ReadState.ABSENT:
        reason = f"already healed: pod {pod} no longer exists"
        log.info(reason)
        return ExecutionResult(applied=False, action_taken="restart-pod", reason=reason)

    budget = lookup_disruption_budget(namespace)
    if budget.state is ReadState.INDETERMINATE:
        reason = ("escalated: could not determine PDB disruptionsAllowed - "
                  f"refusing to evict on an unverifiable budget ({budget.detail})")
        log.warning(reason)
        return ExecutionResult(applied=False, action_taken="escalate", reason=reason)
    if budget.allowed is not None and budget.allowed < 1:
        reason = ("escalated: PDB would block - disruptionsAllowed=0 "
                  "(back off rather than reaching for a stronger verb)")
        log.warning(reason)
        return ExecutionResult(applied=False, action_taken="escalate", reason=reason)

    ok, body, err = _evict(namespace, pod)
    if not ok:
        reason = f"escalated: eviction refused: {err}"
        log.warning(reason)
        return ExecutionResult(applied=False, action_taken="escalate", reason=reason)

    headroom = ("no PDB applies" if budget.allowed is None
                else f"disruptionsAllowed was {budget.allowed}")
    reason = (f"applied: evicted {pod} via policy/pods/eviction ({headroom}); "
              f"the ReplicaSet will replace it")
    log.info(reason)
    return ExecutionResult(applied=True, action_taken="restart-pod", reason=reason,
                           eviction_response=body)

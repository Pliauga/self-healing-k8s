"""Executor tests: the five guards and the single mutation path.

Run with:  pytest app/agent/tests/

Every kubectl call - the two guard reads and the eviction - lands in the stub
from conftest.py. No cluster, no network, no API key.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent.executor import (ReadState, execute, lookup_disruption_budget,
                            lookup_pod)
from agent.schema import Diagnosis

EXECUTOR_SOURCE = Path(__file__).resolve().parents[1] / "executor.py"

POD = "demo-api-797748cc79-csfxl"
NS = "selfhealing"

POD_JSON = json.dumps({
    "apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": POD, "namespace": NS},
})

EVICTION = {"kind": "Status", "apiVersion": "v1", "status": "Success",
            "details": {"name": POD, "kind": "pods"}, "code": 201}
EVICTION_JSON = json.dumps(EVICTION)

GET_POD = f"get pod {POD} -n {NS} -o json"
GET_PDB = (f"get poddisruptionbudgets -n {NS} -o "
           f"jsonpath={{.items[*].status.disruptionsAllowed}}")
EVICT = f"create --raw /api/v1/namespaces/{NS}/pods/{POD}/eviction -f -"

NOT_FOUND = f'Error from server (NotFound): pods "{POD}" not found'
FORBIDDEN = (f'Error from server (Forbidden): pods "{POD}" is forbidden: '
             f'User "system:serviceaccount:{NS}:remediation-agent" cannot get '
             f'resource "pods" in API group "" in the namespace "{NS}"')


def diagnosis(action="restart-pod", confidence=0.95, target=POD):
    return Diagnosis(root_cause="the container is wedged", action=action,
                     target=target, confidence=confidence)


def happy_plan(stub, disruptions="1", eviction_code=0,
               eviction_stdout=EVICTION_JSON, pod_code=0, pod_stdout=POD_JSON,
               pod_stderr=""):
    stub.plan({
        GET_POD: {"code": pod_code, "stdout": pod_stdout, "stderr": pod_stderr},
        GET_PDB: {"code": 0, "stdout": disruptions},
        EVICT: {"code": eviction_code, "stdout": eviction_stdout},
    })


# --- the happy path ----------------------------------------------------------

def test_restart_pod_evicts_via_the_raw_subresource_when_guards_pass(kubectl):
    happy_plan(kubectl)

    result = execute(diagnosis())

    assert result.applied is True
    assert result.action_taken == "restart-pod"
    assert result.eviction_response == EVICTION
    assert "evicted" in result.reason

    calls = kubectl.commands()
    assert GET_POD in calls           # the mandatory re-check ran
    assert GET_PDB in calls           # the budget gate ran
    assert EVICT in calls             # exactly one mutation, via the raw path
    assert "delete" not in " ".join(calls)


def test_eviction_uses_the_eviction_subresource_not_a_delete(kubectl):
    happy_plan(kubectl)
    execute(diagnosis())

    assert [c for c in kubectl.mutations()] == [EVICT.split()]


# --- guard order: cheapest and most fundamental first ------------------------

def test_low_confidence_escalates_without_touching_the_cluster(kubectl):
    # No plan installed: any cluster call would exit 99 and fail the test.
    result = execute(diagnosis(confidence=0.50))

    assert result.applied is False
    assert result.action_taken == "escalate"
    assert "confidence" in result.reason
    assert kubectl.calls() == []


def test_action_outside_the_closed_set_is_rejected_without_a_cluster_call(kubectl):
    # model_construct skips validation on purpose: this exercises the guard for
    # a caller that bypassed Pydantic, which is the only way the guard is
    # reachable. The executor re-validates against ACTIONS rather than trusting
    # that the schema already did.
    rogue = Diagnosis.model_construct(root_cause="free-form",
                                      action="delete-pod", target=POD,
                                      confidence=0.99)

    result = execute(rogue)

    assert result.applied is False
    assert result.action_taken == "escalate"
    assert "unknown action" in result.reason
    assert kubectl.calls() == []


@pytest.mark.parametrize("action", ["scale-up", "investigate", "escalate"])
def test_non_mutating_actions_never_call_the_cluster(kubectl, action):
    result = execute(diagnosis(action=action, confidence=0.99))

    assert result.applied is False
    assert result.action_taken == action
    assert "no-op" in result.reason
    assert kubectl.mutations() == []
    assert kubectl.calls() == []


# --- the three-state reads, which are the reason this suite exists ------------

def test_missing_pod_reports_already_healed_and_does_not_evict(kubectl):
    happy_plan(kubectl, pod_code=1, pod_stdout="", pod_stderr=NOT_FOUND)

    result = execute(diagnosis())

    assert result.applied is False
    assert result.action_taken == "restart-pod"
    assert "already healed" in result.reason
    assert kubectl.mutations() == []


def test_forbidden_read_is_indeterminate_not_absent(kubectl):
    # The whole point of the three-state read: a 403 means "cannot say", and a
    # two-state read would report it as "already healed" - a false success.
    happy_plan(kubectl, pod_code=1, pod_stdout="", pod_stderr=FORBIDDEN)

    result = execute(diagnosis())

    assert result.applied is False
    assert result.action_taken == "escalate"
    assert "could not determine" in result.reason
    assert "already healed" not in result.reason
    assert kubectl.mutations() == []


def test_exhausted_pdb_escalates_and_does_not_evict(kubectl):
    happy_plan(kubectl, disruptions="0")

    result = execute(diagnosis())

    assert result.applied is False
    assert result.action_taken == "escalate"
    assert "PDB would block" in result.reason
    assert kubectl.mutations() == []


def test_unreadable_pdb_escalates_rather_than_failing_open(kubectl):
    # The budget read itself fails: a guard that fails open is not a guard.
    kubectl.plan({
        GET_POD: {"code": 0, "stdout": POD_JSON},
        GET_PDB: {"code": 1, "stderr": "Forbidden"},
        EVICT: {"code": 0, "stdout": EVICTION_JSON},
    })

    result = execute(diagnosis())

    assert result.action_taken == "escalate"
    assert "disruptionsAllowed" in result.reason
    assert kubectl.mutations() == []


def test_a_refused_eviction_escalates(kubectl):
    kubectl.plan({
        GET_POD: {"code": 0, "stdout": POD_JSON},
        GET_PDB: {"code": 0, "stdout": "1"},
        EVICT: {"code": 1, "stderr": "TooManyRequests: cannot evict pod"},
    })

    result = execute(diagnosis())

    assert result.applied is False
    assert result.action_taken == "escalate"
    assert "eviction refused" in result.reason


# --- the reader helpers, directly --------------------------------------------

def test_lookup_pod_distinguishes_found_absent_and_indeterminate(kubectl):
    kubectl.plan({GET_POD: {"code": 0, "stdout": POD_JSON}})
    assert lookup_pod(NS, POD).state is ReadState.FOUND

    kubectl.plan({GET_POD: {"code": 1, "stderr": NOT_FOUND}})
    assert lookup_pod(NS, POD).state is ReadState.ABSENT

    kubectl.plan({GET_POD: {"code": 1, "stderr": FORBIDDEN}})
    assert lookup_pod(NS, POD).state is ReadState.INDETERMINATE

    kubectl.plan({GET_POD: {"code": 0, "stdout": "not json"}})
    assert lookup_pod(NS, POD).state is ReadState.INDETERMINATE


def test_lookup_disruption_budget_takes_the_minimum(kubectl):
    kubectl.plan({GET_PDB: {"code": 0, "stdout": "3 1 2"}})
    found = lookup_disruption_budget(NS)
    assert found.state is ReadState.FOUND
    assert found.allowed == 1


def test_a_namespace_with_no_pdb_permits_eviction(kubectl):
    kubectl.plan({GET_PDB: {"code": 0, "stdout": ""}})
    found = lookup_disruption_budget(NS)
    assert found.state is ReadState.FOUND
    assert found.allowed is None


# --- the invariant the whole design rests on ---------------------------------

def test_executor_source_contains_no_delete_verb():
    """ADR-0005, asserted rather than assumed.

    A future edit that reaches for kubectl delete would bypass the
    PodDisruptionBudget entirely; this fails the build instead of the cluster.
    """
    source = EXECUTOR_SOURCE.read_text(encoding="utf-8")
    assert "delete" not in source
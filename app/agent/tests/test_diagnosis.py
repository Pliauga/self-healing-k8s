"""Webhook-handler tests: routing, the envelope, and fail-closed escalation.

The LLM and the executor are replaced by recording fakes (conftest's `pipeline`
fixture), so these tests assert the SEAM - what diagnosis.py passes across it -
without exercising either decision module. Evidence reads go to the kubectl
stub.
"""

from __future__ import annotations

import json
import subprocess
import sys

from agent import diagnosis as diagnosis_module

POD = "demo-api-797748cc79-csfxl"
NS = "selfhealing"

EVIDENCE_PLAN = {
    f"describe pod {POD} -n {NS}": {"code": 0, "stdout": "Name: " + POD + "\n"},
    f"logs {POD} -n {NS} --tail=200": {"code": 0, "stdout": "starting up\n"},
    f"get events -n {NS}": {"code": 0, "stdout": "no events\n"},
}


def one_alert(alertname="DemoApiUnhealthy", **labels):
    base = {"alertname": alertname, "pod": POD, "remediation": "restart-pod"}
    base.update(labels)
    return {"status": "firing", "labels": base}


def firing(payload_alerts, **extra):
    body = {"status": "firing", "alerts": payload_alerts}
    body.update(extra)
    return body


# --- request handling --------------------------------------------------------

def test_malformed_json_body_returns_400(client):
    response = client.post("/alert", data="{ not json",
                           content_type="application/json")
    assert response.status_code == 400
    assert "not a JSON object" in response.get_json()["error"]


def test_a_json_array_body_returns_400(client, pipeline):
    """Alertmanager sends an object. An array is a different client's mistake,
    and redelivery cannot fix it - so it is permanent, not a 500."""
    response = client.post("/alert", json=[one_alert()])
    assert response.status_code == 400
    assert pipeline.diagnose_calls == []


def test_healthz_does_not_touch_kubectl_or_the_llm(client, pipeline):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_data(as_text=True).strip() == "ok"
    assert pipeline.diagnose_calls == []


# --- notifications that are not faults ---------------------------------------

def test_resolved_notification_is_ignored(client, pipeline):
    response = client.post("/alert", json=firing([one_alert()],
                                                 status="resolved"))
    assert response.status_code == 200
    assert response.get_json()["status"] == "ignored"
    assert pipeline.diagnose_calls == []
    assert pipeline.execute_calls == []


def test_payload_with_no_alerts_is_ignored(client, pipeline):
    response = client.post("/alert", json={"status": "firing", "alerts": []})
    assert response.status_code == 200
    assert response.get_json()["status"] == "ignored"
    assert pipeline.diagnose_calls == []


# --- the pipeline ------------------------------------------------------------

def test_valid_alert_runs_diagnose_then_execute_once(client, kubectl, pipeline):
    kubectl.plan(EVIDENCE_PLAN)

    response = client.post("/alert", json=firing([one_alert()]))

    assert response.status_code == 200
    body = response.get_json()
    assert body["status"] == "handled"
    assert body["count"] == 1

    assert len(pipeline.diagnose_calls) == 1
    assert len(pipeline.execute_calls) == 1

    # The envelope contract: dsh_client reads alert["alerts"][0], so a bare
    # alert would make every escalation report target="unknown".
    handed_over = pipeline.diagnose_calls[0]["alert"]
    assert list(handed_over) == ["alerts"]
    assert handed_over["alerts"][0]["labels"]["alertname"] == "DemoApiUnhealthy"

    assert pipeline.execute_calls[0]["diagnosis"].action == "restart-pod"
    assert pipeline.execute_calls[0]["namespace"] == NS


def test_evidence_is_gathered_for_the_resolved_target(client, kubectl, pipeline):
    kubectl.plan(EVIDENCE_PLAN)

    client.post("/alert", json=firing([one_alert()]))

    evidence = pipeline.diagnose_calls[0]["evidence"]
    assert set(evidence) == {"pod_describe", "events", "logs"}
    assert evidence["pod_describe"]
    assert evidence["logs"]
    assert "describe pod " + POD in " ".join(kubectl.commands())


def test_target_resolved_from_a_deployment_label(client, kubectl, pipeline):
    """A deployment label has no pod name, so it is resolved through the pod
    list - and handing the deployment name to `kubectl describe pod` would just
    produce a confusing 404."""
    kubectl.plan({
        f"get pods -n {NS} -o json": {"code": 0, "stdout": json.dumps(
            {"items": [{"metadata": {
                "name": POD,
                "ownerReferences": [{"name": "demo-api"}]}}]})},
        f"describe pod {POD} -n {NS}": {"code": 0, "stdout": "Name: " + POD},
        f"logs {POD} -n {NS} --tail=200": {"code": 0, "stdout": "ok"},
        f"get events -n {NS}": {"code": 0, "stdout": "none"},
    })
    alert = one_alert()
    del alert["labels"]["pod"]
    alert["labels"]["deployment"] = "demo-api"

    client.post("/alert", json=firing([alert]))

    assert pipeline.execute_calls[0]["diagnosis"].target == POD


def test_a_failed_evidence_read_yields_empty_not_the_error_text(client, kubectl,
                                                                pipeline):
    """Empty means empty: smuggling kubectl's error into a field would count as
    a non-empty source and SUPPRESS dsh_client's incomplete-evidence warning."""
    kubectl.plan({
        f"describe pod {POD} -n {NS}": {"code": 1, "stderr": "boom"},
        f"logs {POD} -n {NS} --tail=200": {"code": 1, "stderr": "boom"},
        f"get events -n {NS}": {"code": 1, "stderr": "boom"},
    })

    client.post("/alert", json=firing([one_alert()]))

    evidence = pipeline.diagnose_calls[0]["evidence"]
    assert evidence == {"pod_describe": "", "events": "", "logs": ""}


def test_missing_pod_label_still_produces_a_diagnosis(client, kubectl, pipeline):
    kubectl.plan({f"get events -n {NS}": {"code": 0, "stdout": "none"}})
    alert = one_alert()
    del alert["labels"]["pod"]

    response = client.post("/alert", json=firing([alert]))

    assert response.status_code == 200
    assert len(pipeline.diagnose_calls) == 1


# --- failure paths stay 2xx, because a 5xx asks for redelivery ----------------

def test_diagnosis_stage_raising_escalates_and_still_returns_200(client, kubectl,
                                                                 pipeline):
    kubectl.plan(EVIDENCE_PLAN)
    pipeline.diagnose_raises = RuntimeError("provider exploded")

    response = client.post("/alert", json=firing([one_alert()]))

    assert response.status_code == 200
    handed_to_executor = pipeline.execute_calls[0]["diagnosis"]
    assert handed_to_executor.action == "escalate"
    assert handed_to_executor.confidence == 0.0


def test_executor_raising_is_reported_as_not_applied(client, kubectl, pipeline):
    kubectl.plan(EVIDENCE_PLAN)
    pipeline.execute_raises = RuntimeError("executor exploded")

    response = client.post("/alert", json=firing([one_alert()]))

    assert response.status_code == 200
    execution = response.get_json()["results"][0]["execution"]
    assert execution["applied"] is False
    assert execution["action_taken"] == "escalate"


# --- the anomalous group -----------------------------------------------------

def test_more_than_max_alerts_handles_one_and_logs_the_rest(client, kubectl,
                                                            pipeline, caplog):
    kubectl.plan(EVIDENCE_PLAN)
    alerts = [one_alert(alertname="DemoApiUnhealthy-" + str(i))
              for i in range(5)]

    with caplog.at_level("WARNING"):
        response = client.post("/alert", json=firing(alerts))

    assert response.status_code == 200
    body = response.get_json()
    assert body["count"] == 1
    assert len(pipeline.diagnose_calls) == 1
    assert "skipping the rest" in caplog.text
    assert "DemoApiUnhealthy-1" in caplog.text   # the skipped ones are named


def test_the_max_alerts_boundary_is_read_from_the_module(client, kubectl,
                                                         pipeline):
    """MAX_ALERTS is a module constant, not a copy. Three alerts (the replica
    count) is handled whole; the fourth would trip the guard."""
    kubectl.plan(EVIDENCE_PLAN)
    three = [one_alert(alertname="A" + str(i))
             for i in range(diagnosis_module.MAX_ALERTS)]

    response = client.post("/alert", json=firing(three))

    assert response.status_code == 200
    assert len(pipeline.diagnose_calls) == 1


# --- the fixture must not be able to pass vacuously ---------------------------

def test_the_stub_fails_loudly_on_an_unplanned_command(tmp_path, monkeypatch,
                                                       stub_path):
    monkeypatch.setenv("KUBECTL_STUB_PLAN", "{}")
    monkeypatch.setenv("KUBECTL_STUB_LOG", str(tmp_path / "calls.log"))

    proc = subprocess.run([sys.executable, str(stub_path), "get", "pods"],
                          capture_output=True, text=True)

    assert proc.returncode == 99
    assert "no plan for" in proc.stderr
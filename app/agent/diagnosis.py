"""Alertmanager webhook handler: the seam between an alert and the executor.

This module is a seam, not a policy. It parses the webhook, resolves the target
resource, gathers read-only evidence, and calls the two modules that hold the
decisions:

    dsh_client.diagnose(alert, evidence) -> Diagnosis
    executor.execute(diagnosis)          -> ExecutionResult

The closed action set, the confidence gate and the eviction path all live in
executor.py, where they are reviewed as one artifact (ADR-0003). Reinventing any
of them here would put the safety property in two places and make it assertable
in neither.

Two contracts this module owes the modules it calls:

The envelope. dsh_client reads ``alert["alerts"][0]`` for both the prompt and the
escalation target, because that is the shape Alertmanager actually sends. Each
webhook alert is therefore wrapped in a one-element envelope before being handed
over; passing the bare alert would make every escalation report ``target:
unknown`` and show the model no alert at all.

Empty means empty. A failed evidence read yields ``""``, never the kubectl error
text. dsh_client counts non-empty evidence fields to decide whether to warn the
model that the evidence is incomplete, so smuggling a kubectl error into a field
would turn "I could not read anything" into "I read something" and suppress that
warning - the same divergence between a tool's report and its behaviour that
docs/design.md 14 catalogues.

Response codes carry meaning for the sender. Alertmanager redelivers any
non-2xx, so:

    400  the body is not a JSON object. Permanent: redelivery cannot help.
    200  resolved notification, or handled - including an escalation.
         An escalation is a successful handling, not a server error.
    500  an exception in this process. Presumed transient, so redelivery is
         the correct response from the sender.

Timing, and the sender's retry loop. Alertmanager's default webhook timeout is
10 seconds, while the worst case here is ~123 seconds (three 30-second LLM
attempts, 3 seconds of backoff, plus three kubectl evidence reads at 10 seconds
each). A slow diagnosis is
therefore timed out and redelivered by Alertmanager, and the duplicate arrives
while the first request is still running. With gunicorn running a single sync
worker the duplicate queues behind the first; when it runs, the pod has already
been evicted, so executor.execute() finds it absent and reports "already
healed". Correct by design - the executor's re-check, not the timing, is what
makes it safe - but worth knowing, because it doubles LLM cost on slow
diagnoses and shows up in the logs as a duplicate "already healed". Fix
candidates, deliberately not v1: raise Alertmanager's webhook timeout, or
dedupe in flight on the alert fingerprint. Noted in the Dockerfile's CMD comment
too, because the single sync worker is what makes the queueing deterministic.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from typing import Any

from flask import Flask, Response, jsonify, request

from . import dsh_client, executor
from .schema import Diagnosis

log = logging.getLogger(__name__)

app = Flask(__name__)

NAMESPACE = os.environ.get("NAMESPACE", "selfhealing")
PORT = int(os.environ.get("PORT", "8080"))
EVIDENCE_TIMEOUT_S = 10

# A per-pod rule can legitimately group the alerts of a three-replica workload,
# and the workload runs three replicas. A larger group is anomalous - stale
# alerts from an earlier rollout, a mis-grouped payload, or a mass fault - and
# the safe answer to an anomalous group is to handle one alert properly rather
# than fan out N mutations. The rest are logged, not acted on.
MAX_ALERTS = 3

app.logger.setLevel(logging.INFO)


# --- evidence gathering ------------------------------------------------------

def _run(args: list[str], timeout: int = EVIDENCE_TIMEOUT_S) -> tuple[int, str]:
    """Run one read-only kubectl command; return (returncode, stdout).

    Read-only by construction: every caller below uses get/describe/logs, and no
    caller in this module passes a mutating verb. Mutation is executor.py's job.
    """
    try:
        proc = subprocess.run(
            ["kubectl", *args],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired:
        return 124, ""
    except OSError as exc:
        log.warning("could not run kubectl: %s", exc)
        return 127, ""
    return proc.returncode, proc.stdout.strip()


def _read(argv: list[str], label: str) -> str:
    """Read one evidence block. Returns "" on any failure, by contract.

    The failure is logged with its command and exit code so it is discoverable
    in the agent's own logs; it is deliberately NOT returned as text.
    """
    code, out = _run(argv)
    if code != 0 or not out:
        log.info("evidence %s unavailable: exit=%s cmd=kubectl %s",
                 label, code, " ".join(argv))
        return ""
    return out


def _pods(selector: str | None = None) -> list[dict[str, Any]]:
    argv = ["get", "pods", "-n", NAMESPACE, "-o", "json"]
    if selector:
        argv += ["-l", selector]
    code, out = _run(argv)
    if code != 0 or not out:
        return []
    try:
        return json.loads(out).get("items", [])
    except json.JSONDecodeError:
        return []


def _resolve_target(labels: dict[str, Any]) -> str:
    """Work out which resource the alert is about.

    Preference order matches what the alert rules can actually label. The live
    series carries ``pod`` (verified against Prometheus), so that is the common
    path. ``instance`` is an IP:port, so it is resolved through the pod's own
    status.podIP rather than being handed to kubectl as a name - passing
    "10.244.0.6:8080" to `kubectl describe pod` would just be a confusing 404.
    """
    pod = labels.get("pod") or labels.get("pod_name")
    if isinstance(pod, str) and pod:
        return pod

    deployment = labels.get("deployment") or labels.get("deployment_name")
    if isinstance(deployment, str) and deployment:
        # The action names a pod, so a deployment label is resolved to one of its
        # pods. Prefer a pod that is not already terminating: evicting a pod that
        # is going away anyway would spend a disruption for nothing.
        for item in _pods():
            owner = (item.get("metadata", {}).get("ownerReferences") or [{}])[0]
            if owner.get("name") != deployment:
                continue
            if not item.get("metadata", {}).get("deletionTimestamp"):
                return item["metadata"]["name"]
        return deployment

    instance = labels.get("instance")
    if isinstance(instance, str) and instance:
        ip = instance.rsplit(":", 1)[0]
        for item in _pods():
            if item.get("status", {}).get("podIP") == ip:
                return item["metadata"]["name"]
        return instance

    return ""


def _gather(target: str) -> dict[str, str]:
    """Collect the three evidence blocks dsh_client renders.

    Always returns all three keys, each possibly empty. Events are gathered
    namespace-wide rather than filtered by involvedObject, because the events
    that explain a pod's failure frequently name its ReplicaSet or the node
    rather than the pod itself.
    """
    evidence: dict[str, str] = {"pod_describe": "", "events": "", "logs": ""}
    if target:
        evidence["pod_describe"] = _read(
            ["describe", "pod", target, "-n", NAMESPACE], "pod_describe")
        evidence["logs"] = _read(
            ["logs", target, "-n", NAMESPACE, "--tail=200"], "logs")
    evidence["events"] = _read(
        ["get", "events", "-n", NAMESPACE], "events")
    sizes = ", ".join(f"{k}={len(v)}" for k, v in sorted(evidence.items()))
    log.info("evidence gathered for target=%r: %s", target, sizes)
    return evidence


# --- pipeline ----------------------------------------------------------------

def _guarded_diagnosis(alert: dict[str, Any],
                       evidence: dict[str, str]) -> Diagnosis:
    """Call dsh_client, converting an unexpected raise into an escalation.

    dsh_client already escalates on every failure it anticipates; this wrapper
    covers the failures it does not, so that "the diagnosis stage threw" can
    never reach the executor as anything other than escalate.
    """
    try:
        return dsh_client.diagnose(alert, evidence)
    except Exception as exc:
        log.exception("diagnosis stage raised unexpectedly")
        return Diagnosis.escalate(
            "diagnosis stage raised " + type(exc).__name__ + ": " + str(exc)[:200],
            _target_of(alert),
        )


def _target_of(alert: dict[str, Any]) -> str:
    """Target for an escalation, read from the envelope."""
    alerts = alert.get("alerts")
    if isinstance(alerts, list) and alerts and isinstance(alerts[0], dict):
        labels = alerts[0].get("labels") or {}
        if isinstance(labels, dict):
            return str(labels.get("pod") or labels.get("instance") or "")
    return ""


def _run_pipeline(one_alert: dict[str, Any]) -> dict[str, Any]:
    """Diagnose and execute a single alert. Never raises."""
    envelope = {"alerts": [one_alert]}
    labels = one_alert.get("labels") or {}
    if not isinstance(labels, dict):
        labels = {}

    target = _resolve_target(labels)
    log.info("alert resolved: alertname=%s target=%r remediation=%r",
             labels.get("alertname"), target, labels.get("remediation"))

    evidence = _gather(target)
    diagnosis = _guarded_diagnosis(envelope, evidence)
    log.info("diagnosis: action=%s confidence=%.2f target=%r root_cause=%s",
             diagnosis.action, diagnosis.confidence, diagnosis.target,
             diagnosis.root_cause)

    try:
        result = executor.execute(diagnosis, namespace=NAMESPACE)
    except Exception as exc:
        # execute() is documented never to raise. If it does, the escalation is
        # synthetic and the mutating path is reported as not applied, because a
        # raise means we cannot say what happened - and "cannot say" must never
        # be reported as success.
        log.exception("executor raised unexpectedly")
        result = executor.ExecutionResult(
            applied=False, action_taken="escalate",
            reason="executor raised " + type(exc).__name__ + ": " + str(exc)[:200],
        )

    log.info("execution: applied=%s action_taken=%s reason=%s",
             result.applied, result.action_taken, result.reason)
    return {
        "alert": labels.get("alertname"),
        "target": diagnosis.target,
        "resolved_target": target,
        "diagnosis": diagnosis.model_dump(),
        "execution": result.model_dump(),
    }


def _handle(payload: dict[str, Any]) -> tuple[dict[str, Any], int]:
    alerts = payload.get("alerts")
    if not isinstance(alerts, list) or not alerts:
        log.warning("payload carried no alerts: keys=%s", sorted(payload))
        return {"status": "ignored", "reason": "payload carried no alerts"}, 200

    if payload.get("status") == "resolved":
        # A resolution notification tells us the condition has cleared. Reporting
        # that as a no-op keeps the sender's retry loop quiet; acting on it would
        # be acting on the absence of a fault.
        log.info("resolved notification for %d alert(s); no action", len(alerts))
        return {"status": "ignored",
                "reason": "notification is a resolution, not a fault"}, 200

    usable = [a for a in alerts if isinstance(a, dict)]
    if not usable:
        return {"status": "ignored", "reason": "alerts were not objects"}, 200

    if len(usable) > MAX_ALERTS:
        # Deliberate: one alert handled properly beats N mutations issued from a
        # group whose size we do not trust. The skipped alerts are logged so the
        # loss is visible rather than silent.
        log.warning("payload grouped %d alerts (> %d); handling the first and "
                    "skipping the rest: skipped=%s", len(usable), MAX_ALERTS,
                    [a.get("labels", {}).get("alertname") for a in usable[1:]])

    results = [_run_pipeline(usable[0])]
    return {"status": "handled", "count": len(results), "results": results}, 200


# --- routes ------------------------------------------------------------------

@app.route("/alert", methods=["POST"])
def alert() -> Response:
    payload = request.get_json(force=True, silent=True)
    if not isinstance(payload, dict):
        log.warning("rejected alert webhook: body was not a JSON object")
        return jsonify({"error": "body is not a JSON object"}), 400

    try:
        body, status = _handle(payload)
    except Exception as exc:
        # The pipeline escalates internally on its own failures; reaching here
        # means the failure was outside it. A 500 asks the sender to redeliver,
        # and the body still carries the fail-closed decision so that the mistake
        # is recorded rather than merely retried.
        log.exception("alert handler failed outside the pipeline")
        return jsonify({
            "error": "internal error",
            "detail": type(exc).__name__ + ": " + str(exc)[:300],
            "diagnosis": Diagnosis.escalate(
                "webhook handler failed before a diagnosis was produced",
                _target_of(payload),
            ).model_dump(),
        }), 500

    return jsonify(body), status


@app.route("/healthz", methods=["GET"])
def healthz() -> Response:
    """Liveness only. Deliberately independent of kubectl and the LLM.

    The process is what this probe answers for. A liveness probe that fails when
    a dependency is slow would restart the agent during the very incident it
    exists to handle, so this checks nothing but the process itself - the same
    rule app/app.py follows for demo-api's /healthz.
    """
    return Response("ok\n", mimetype="text/plain")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    app.run(host="0.0.0.0", port=PORT)

"""LLM client for the Tier 2 agent: structured evidence in, a Diagnosis out.

ADR-0003 draws the boundary this module sits on: the LLM decides and holds no
write credential. Everything it says crosses back as a Diagnosis, and anything
that does not validate crosses back as an escalation.

This module is standalone by design. It imports schema.py (the contract) and
nothing else from the package - not executor.py, not diagnosis.py. It takes
plain dicts in and returns a Diagnosis out, so it is testable without a cluster
and without Flask.

Every failure path is fail-closed: a missing API key, a transport error that
survives the retries, a 4xx, a body that is not JSON, JSON that is not a valid
Diagnosis - all of them return Diagnosis.escalate(). No branch turns a failure
into an action, and diagnose() does not raise.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

from .schema import ACTIONS, Diagnosis

log = logging.getLogger(__name__)

# --- configuration -----------------------------------------------------------

# In-cluster this is filled from the Secret by the Deployment (valueFrom
# secretKeyRef). It is read from the environment at call time, never at import
# time and never written down: CONTRIBUTING.md rule 5.
API_KEY_ENV = "TOKEN_HARBOR_API_KEY"
BASE_URL = "https://tokenharbor.ai/v1"

PRIMARY_MODEL = "deepseek-v4.1-flash"
# gpt-6-luna is deliberately NOT wired. It is reserved for a future
# "low-confidence re-ask": if the primary model returns a VALID Diagnosis whose
# confidence sits below the executor's 0.85 gate, a stronger model could be asked
# once more before escalating. Wiring it now would add a second call path that no
# test and no gate covers, so it stays a comment until that pattern is specified.
# Note that a re-ask is only meaningful for a *valid* low-confidence answer: at
# temperature 0.0, repeating the same prompt against the same model reproduces
# the same response, so a parse failure is not a candidate for re-asking.

REQUEST_TIMEOUT_S = 30.0
MAX_ATTEMPTS = 3        # the initial call plus two retries
BACKOFF_BASE_S = 1.0    # waits 1s, then 2s
BACKOFF_FACTOR = 2.0
TEMPERATURE = 0.0       # this is a classification, not a composition
MAX_OUTPUT_TOKENS = 512

# response_format={"type": "json_object"} is deliberately NOT sent. If Token
# Harbor rejects the parameter then every call fails, every call escalates, and
# the agent is silently useless - a whole-tier failure caused by an unverified
# optimisation. The parser below already copes with a model that ignores the
# "no fence" instruction (fence strip, brace slice). Revisit in v2, once a real
# key has confirmed the endpoint accepts it.

# Truncation is a scope decision, not a nicety: what the model is shown is what
# it can diagnose, so quietly dropping the tail of a crash log is the same
# defect class as a check whose scope does not match reality (design.md §14).
# Both ends are kept, because a crash loop's FIRST startup error and its MOST
# RECENT traceback are the two most informative regions of the log, and a plain
# head-truncation would throw away the fresher one. When the marker fires it is
# logged with the field name and the dropped count: if a diagnosis is later
# found to be wrong and the answer was in the dropped region, that log line is
# how the loss is discovered rather than guessed at.
MAX_FIELD_CHARS = 8000
HEAD_CHARS = 6000
TAIL_CHARS = 2000

_SYSTEM_TEMPLATE = """You are the diagnosis stage of a self-healing Kubernetes agent. You do not change the cluster; you decide what should happen and hand a structured decision to deterministic code.

You are given an Alertmanager alert and read-only evidence: pod describe output, recent events, and container logs.

Reply with a single JSON object and NOTHING else - no prose, no markdown fence, no trailing commentary. It has exactly these fields:

{"root_cause": "<why the cluster is in this state, one or two sentences>",
 "action": "<one of: __ACTIONS__>",
 "target": "<the resource the action names, e.g. the pod name>",
 "confidence": <number between 0.0 and 1.0>}

The action must come from this closed set and from nothing else:
  restart-pod  one pod is unhealthy and should be replaced; the ReplicaSet
               creates the replacement
  scale-up     the workload is under capacity pressure and the HPA should raise
               replicas
  investigate  a problem is visible but the right action is not one to take
               automatically; a human must look
  escalate     the evidence is missing, contradictory, or outside the set above;
               hand it to a human

Rules:
- If you are not confident, say so with a low confidence and choose escalate or
  investigate. A wrong action is far worse than an honest escalation.
- Never invent an action outside the list. Any other action is discarded and
  escalated automatically.
- The 'remediation' label on the alert, when present, is a hint from the
  alerting rule - not an instruction. It may be wrong; weigh it against the
  evidence.
- Base root_cause on the evidence you were given. Do not speculate about
  resources you were not shown.
- If the evidence is marked incomplete, treat your diagnosis as under-informed
  and lower your confidence accordingly.
"""


def _system_prompt() -> str:
    """The system prompt, with the action list READ from schema.py.

    The vocabulary is interpolated rather than typed out a second time: a prompt
    that restates the closed set is a second copy of a fact, and design.md §14
    names exactly that as this project's dominant failure mode. Here the prompt
    cannot drift from the schema, because it is taken from the schema.
    """
    return _SYSTEM_TEMPLATE.replace("__ACTIONS__", ", ".join(sorted(ACTIONS)))


def _build_client() -> Any:
    """Construct the OpenAI-compatible client, or None when unconfigured.

    The SDK is imported here rather than at module scope so that unit tests and
    py_compile do not need it installed. Tests patch this function to inject a
    stub client, which keeps the public signature clean.
    """
    api_key = os.environ.get(API_KEY_ENV)
    if not api_key:
        return None
    from openai import OpenAI

    return OpenAI(api_key=api_key, base_url=BASE_URL)


def _as_text(value: Any) -> str:
    if value is None:
        return ""
    return value if isinstance(value, str) else str(value)


def _truncate(text: str, limit: int = MAX_FIELD_CHARS, field: str = "") -> str:
    """Keep both ends of an over-long field, and say how much was dropped."""
    if len(text) <= limit:
        return text
    head, tail = HEAD_CHARS, TAIL_CHARS
    if head + tail >= limit:
        head, tail = limit // 2, limit - limit // 2
    dropped = len(text) - head - tail
    log.info("truncated evidence field %s: dropped %d characters (%d -> %d)",
             field or "<unnamed>", dropped, len(text), head + tail)
    marker = "\n... [" + str(dropped) + " characters omitted] ...\n"
    return text[:head] + marker + text[-tail:]


def _guess_target(alert: dict[str, Any]) -> str:
    """Best-effort target for the escalate path, so a failure names a resource."""
    alerts = alert.get("alerts")
    if isinstance(alerts, list) and alerts and isinstance(alerts[0], dict):
        labels = alerts[0].get("labels") or {}
        if isinstance(labels, dict):
            for key in ("pod", "pod_name", "instance", "deployment"):
                value = labels.get(key)
                if isinstance(value, str) and value:
                    return value
    return "unknown"


def _render_alert(alert: dict[str, Any]) -> str:
    lines: list[str] = []
    if alert.get("status"):
        lines.append("status: " + str(alert["status"]))
    alerts = alert.get("alerts")
    if not isinstance(alerts, list):
        return "no alert list in payload"
    for index, item in enumerate(alerts):
        if not isinstance(item, dict):
            continue
        lines.append("alert[" + str(index) + "]")
        for name in ("labels", "annotations"):
            section = item.get(name)
            if not isinstance(section, dict):
                continue
            for key in sorted(section):
                lines.append("  " + name[:-1] + "." + str(key) + ": " + str(section[key]))
    return "\n".join(lines)


def _render_evidence(evidence: dict[str, Any]) -> tuple[str, int]:
    """Render the evidence blocks; return (text, sources_present).

    ``sources_present`` counts how many of the three expected sources carried
    non-empty content. The count is returned rather than recomputed so that the
    warning in _render_prompt is derived from what was actually rendered, not
    from a second guess at the same dict.
    """
    blocks: list[str] = []
    present = 0
    for name in ("pod_describe", "events", "logs"):
        body = _truncate(_as_text(evidence.get(name)), field=name)
        if not body.strip():
            continue
        present += 1
        blocks.append("### " + name + "\n" + body)
    if not blocks:
        return "no evidence gathered", present
    return "\n\n".join(blocks), present


def _render_prompt(alert: dict[str, Any], evidence: dict[str, Any]) -> str:
    body, present = _render_evidence(evidence)
    warning = ""
    if present < 2:
        # The gatherer cannot always find its target. Passing empty evidence
        # leaves the model guessing at what it was not shown, so the shortfall is
        # stated outright: "you are missing sources" is information the model can
        # weigh into its confidence, whereas silence is not.
        warning = ("WARNING: evidence is incomplete - only "
                   + str(present) + "/3 sources available\n\n")
    return ("Alert\n-----\n" + _render_alert(alert)
            + "\n\nEvidence\n--------\n" + warning + body)


def _strip_code_fence(text: str) -> str:
    """Remove a markdown fence, if the model wrapped its JSON in one."""
    body = text.strip()
    if not body.startswith("```"):
        return body
    body = body[3:]
    newline = body.find("\n")
    if newline == -1:
        return body.strip().strip("`").strip()
    language = body[:newline].strip().lower()
    if language in ("", "json", "javascript", "js"):
        body = body[newline + 1:]
    end = body.rfind("```")
    if end != -1:
        body = body[:end]
    return body.strip()


def _parse_diagnosis(content: str) -> Diagnosis:
    """Turn the model's text into a Diagnosis, or raise.

    It raises on every failure shape so that diagnose() has exactly one
    escalation path rather than several. Note that valid JSON naming an action
    outside the closed set does NOT raise here - it raises at the Pydantic layer
    below, which is where the closed-set check belongs.
    """
    text = _strip_code_fence(content)
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start == -1 or end <= start:
            raise
        payload = json.loads(text[start:end + 1])
    return Diagnosis.model_validate(payload)


def _first_content(response: Any) -> str:
    choices = getattr(response, "choices", None) or []
    if not choices:
        raise ValueError("response contained no choices")
    content = getattr(getattr(choices[0], "message", None), "content", None)
    if not isinstance(content, str) or not content.strip():
        raise ValueError("response message had no text content")
    return content


def _status_code(exc: BaseException) -> int | None:
    """Find an HTTP status on an exception, whoever put it there.

    The OpenAI SDK's APIStatusError exposes ``status_code`` directly, but it can
    also surface an httpx.HTTPStatusError, which carries the status on
    ``exc.response.status_code`` instead. Both are checked so that a 429 is
    recognised as retryable regardless of which layer raised.
    """
    status = getattr(exc, "status_code", None)
    if isinstance(status, int):
        return status
    response = getattr(exc, "response", None)
    status = getattr(response, "status_code", None)
    if isinstance(status, int):
        return status
    return None


def _is_retryable(exc: BaseException) -> bool:
    """Retry transport-shaped failures only, and default to NOT retrying.

    A 4xx that is not 429 is a malformed request: repeating it three times only
    delays the escalation to the same answer. An unknown exception type is also
    not retried - the fail-closed direction is to escalate sooner, not to keep
    trying.
    """
    status = _status_code(exc)
    if status is not None:
        return status == 429 or status >= 500
    return type(exc).__name__ in (
        "APITimeoutError", "APIConnectionError", "InternalServerError",
        "Timeout", "ReadTimeout", "ConnectError",
    )


def diagnose(alert: dict[str, Any], evidence: dict[str, Any]) -> Diagnosis:
    """Ask the primary model for a Diagnosis. Never raises; never acts.

    Every failure returns Diagnosis.escalate(...), so the caller has one success
    shape and one failure shape and no third path to handle.
    """
    target = _guess_target(alert)
    client = _build_client()
    if client is None:
        log.error("%s is not set; escalating instead of calling the model",
                  API_KEY_ENV)
        return Diagnosis.escalate(
            API_KEY_ENV + " is not configured; the agent cannot reach " + BASE_URL,
            target,
        )

    messages = [
        {"role": "system", "content": _system_prompt()},
        {"role": "user", "content": _render_prompt(alert, evidence)},
    ]

    for attempt in range(1, MAX_ATTEMPTS + 1):
        started = time.monotonic()
        try:
            response = client.chat.completions.create(
                model=PRIMARY_MODEL,
                messages=messages,
                temperature=TEMPERATURE,
                max_tokens=MAX_OUTPUT_TOKENS,
                timeout=REQUEST_TIMEOUT_S,
            )
        except Exception as exc:  # any client failure becomes an escalation
            if attempt < MAX_ATTEMPTS and _is_retryable(exc):
                delay = BACKOFF_BASE_S * (BACKOFF_FACTOR ** (attempt - 1))
                log.warning("%s on attempt %d/%d; retrying in %.1fs",
                            type(exc).__name__, attempt, MAX_ATTEMPTS, delay)
                time.sleep(delay)
                continue
            log.error("model call failed: %s", exc)
            return Diagnosis.escalate(
                "LLM call failed after " + str(attempt) + " attempt(s): "
                + type(exc).__name__ + ": " + str(exc)[:300],
                target,
            )

        content = ""
        try:
            content = _first_content(response)
            diagnosis = _parse_diagnosis(content)
        except Exception as exc:  # no retry: the re-ask is the reserved pattern
            log.error("model response was not a usable Diagnosis: %s", exc)
            return Diagnosis.escalate(
                "LLM response unusable (" + type(exc).__name__ + "): "
                + _truncate(content, 300, field="response"),
                target,
            )

        log.info("diagnosis in %.2fs: action=%s confidence=%.2f target=%s",
                 time.monotonic() - started,
                 diagnosis.action, diagnosis.confidence, diagnosis.target)
        return diagnosis

    # Unreachable: every iteration returns. Kept so that a future edit adding a
    # `break` cannot fall out of this function without a Diagnosis.
    return Diagnosis.escalate("model call loop exited without a result", target)

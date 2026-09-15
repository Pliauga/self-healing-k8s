"""demo-api: the failure-injection target for the self-healing cluster.

Endpoints
---------
``GET /``           JSON description of the pod
``GET /healthz``    liveness  - 200 while healthy, 500 after ``/fail``
``GET /readyz``     readiness - 200 while ready, 503 after ``/fail``
``GET /fail``       inject a fault: mark the pod unready and unhealthy
``GET /recover``    clear an injected fault
``GET /burn``       busy-loop N CPU seconds (default 15) on a background thread
``GET /metrics``    Prometheus text exposition format
``GET /echo``       echo the request back (arbitrary load target)

``/healthz`` and ``/readyz`` are what the kubelet probes. ``/fail`` makes both
fail, which exercises two independent self-healing paths at once: the kubelet
restarts the container, and the endpoint controller removes the pod from the
Service.

Fault state is deliberately stored in a **file**, not in process memory
-----------------------------------------------------------------------
gunicorn serves this application from multiple worker processes. If the fault
flag lived in a module-level dict, ``/fail`` would set it in exactly one worker
and the kubelet's next probe - which may land on any worker - would likely
return 200. The same applies to a Prometheus scrape of ``/metrics``, which would
report the pod as healthy while it is faulted, silently breaking the
``DemoApiUnhealthy`` alert.

The flag is therefore written to ``FAULT_STATE_FILE`` and read on every probe
and scrape, so behaviour is identical regardless of worker count. Writes are
atomic (write to a temp file, then ``os.replace``) so a concurrent reader never
observes a partially written file.
"""

from __future__ import annotations

import atexit
import json
import os
import socket
import tempfile
import threading
import time

from flask import Flask, Response, jsonify, request

START_TIME = time.time()
POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
NODE_NAME = os.environ.get("NODE_NAME", "unknown")
FAULT_STATE_FILE = os.environ.get("FAULT_STATE_FILE", "/tmp/demo-api-fault.json")

app = Flask(__name__)

# Guards reads and writes within a single process. Cross-process safety comes
# from the atomic replace in _write_fault.
_state_lock = threading.Lock()

# Request counters are per worker and therefore approximate under gunicorn.
# They are adequate for demonstrating metrics-driven remediation; the fault
# flags - the values the alert rules actually depend on - are exact.
_request_counts: dict[tuple[str, str, int], int] = {}


# --- fault state -------------------------------------------------------------


def _read_fault() -> dict:
    """Return the current fault state, tolerating a missing or corrupt file."""
    try:
        with open(FAULT_STATE_FILE, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        return {
            "alive": bool(state.get("alive", True)),
            "ready": bool(state.get("ready", True)),
            "fail_injections": int(state.get("fail_injections", 0)),
            "recoveries": int(state.get("recoveries", 0)),
        }
    except (FileNotFoundError, ValueError, OSError):
        # No file yet, or unreadable: the pod is healthy by default.
        return {"alive": True, "ready": True, "fail_injections": 0, "recoveries": 0}


def _write_fault(state: dict) -> None:
    """Atomically persist fault state so all workers observe it consistently."""
    directory = os.path.dirname(FAULT_STATE_FILE) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".fault-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle)
            handle.flush()
            os.fsync(handle.fileno())
        # Atomic on POSIX: readers see either the old or the new file, never a
        # partial write.
        os.replace(tmp_path, FAULT_STATE_FILE)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _bump(path: str, method: str, status: int) -> None:
    with _state_lock:
        key = (path, method, status)
        _request_counts[key] = _request_counts.get(key, 0) + 1


# --- fault-state lifetime ----------------------------------------------------
#
# A fault flag must NOT survive a container restart, or liveness remediation
# cannot work: the kubelet restarts the container, the fresh process reads the
# persisted flag, fails its probes immediately, and is killed again - an
# infinite restart loop with a permanently unreachable pod.
#
# emptyDir is ephemeral per *pod*, not per *container*. A container restart
# keeps the pod (and its emptyDir), so the file on disk outlives the process
# that wrote it. That is why clearing on shutdown alone is not enough: an OOM
# kill, or a SIGKILL after terminationGracePeriodSeconds, runs no handler.
#
# Clearing at startup is the reliable half - it covers every restart path,
# including SIGKILL and OOM. The shutdown hook is belt-and-braces and keeps the
# common case tidy. FAULT_STATE_PERSIST=1 disables both, for an experiment that
# deliberately wants a fault to outlive a container restart.

def _clear_fault_on_start() -> None:
    """Start every container from a clean, healthy state."""
    if os.environ.get("FAULT_STATE_PERSIST") == "1":
        return
    try:
        os.unlink(FAULT_STATE_FILE)
    except FileNotFoundError:
        pass
    except OSError:
        # A read-only or absent volume is not fatal: the pod keeps whatever
        # state it had, which is the pre-fix behaviour.
        pass


def _clear_fault_on_exit(*_args) -> None:
    """Best-effort cleanup on graceful termination."""
    if os.environ.get("FAULT_STATE_PERSIST") == "1":
        return
    try:
        _write_fault({"alive": True, "ready": True,
                      "fail_injections": 0, "recoveries": 0})
    except OSError:
        pass


_clear_fault_on_start()

# Registered with atexit rather than a SIGTERM handler on purpose: gunicorn
# installs its own signal handlers to manage worker shutdown, and overriding
# them here would interfere with graceful process management. atexit runs on
# the normal interpreter exit that gunicorn's handler ultimately produces.
atexit.register(_clear_fault_on_exit)


# --- CPU burn ----------------------------------------------------------------

_burn_lock = threading.Lock()
_burn_seconds_total = 0.0


def _burn(seconds: float) -> None:
    """Consume CPU for the requested duration on a background thread."""
    global _burn_seconds_total
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        # A tight arithmetic loop: the point is CPU time, not a useful result.
        sum(i * i for i in range(10_000))
    with _burn_lock:
        _burn_seconds_total += seconds


# --- metrics -----------------------------------------------------------------


def _prometheus_text() -> str:
    """Render current state in Prometheus text exposition format (v0.0.4)."""
    fault = _read_fault()
    with _state_lock:
        counts = dict(_request_counts)
    with _burn_lock:
        burn_total = _burn_seconds_total

    lines = [
        "# HELP demo_api_up 1 if the process is serving, 0 otherwise.",
        "# TYPE demo_api_up gauge",
        "demo_api_up 1",
        "# HELP demo_api_healthy 1 if /healthz would return 200.",
        "# TYPE demo_api_healthy gauge",
        f"demo_api_healthy {1 if fault['alive'] else 0}",
        "# HELP demo_api_ready 1 if /readyz would return 200.",
        "# TYPE demo_api_ready gauge",
        f"demo_api_ready {1 if fault['ready'] else 0}",
        "# HELP demo_api_uptime_seconds Seconds since process start.",
        "# TYPE demo_api_uptime_seconds gauge",
        f"demo_api_uptime_seconds {time.time() - START_TIME:.3f}",
        "# HELP demo_api_fail_injections_total Faults injected via /fail.",
        "# TYPE demo_api_fail_injections_total counter",
        f"demo_api_fail_injections_total {fault['fail_injections']}",
        "# HELP demo_api_recoveries_total Faults cleared via /recover.",
        "# TYPE demo_api_recoveries_total counter",
        f"demo_api_recoveries_total {fault['recoveries']}",
        "# HELP demo_api_cpu_burn_seconds_total CPU seconds consumed by /burn.",
        "# TYPE demo_api_cpu_burn_seconds_total counter",
        f"demo_api_cpu_burn_seconds_total {burn_total:.3f}",
        "# HELP demo_api_requests_total HTTP requests by path, method, status.",
        "# TYPE demo_api_requests_total counter",
    ]
    for (path, method, status), count in sorted(counts.items()):
        lines.append(
            f'demo_api_requests_total{{path="{path}",method="{method}",'
            f'status="{status}"}} {count}'
        )
    return "\n".join(lines) + "\n"


# --- routes ------------------------------------------------------------------


@app.route("/healthz")
def healthz():
    """Liveness. Fails only when the process itself has been faulted.

    Deliberately independent of any downstream dependency: a liveness probe
    that can fail because a dependency is slow turns a downstream outage into a
    cluster-wide restart storm.
    """
    if _read_fault()["alive"]:
        return Response("ok\n", mimetype="text/plain")
    return Response("injected failure\n", status=500, mimetype="text/plain")


@app.route("/readyz")
def readyz():
    """Readiness. Failing this removes the pod from the Service endpoints."""
    if _read_fault()["ready"]:
        return Response("ready\n", mimetype="text/plain")
    return Response("not ready\n", status=503, mimetype="text/plain")


@app.route("/fail")
def fail():
    """Inject a fault. Used by scripts/inject-failure.sh app-fail."""
    with _state_lock:
        state = _read_fault()
        state["alive"] = False
        state["ready"] = False
        state["fail_injections"] += 1
        _write_fault(state)
    return jsonify({"status": "fault injected", "pod": POD_NAME})


@app.route("/recover")
def recover():
    """Clear an injected fault."""
    with _state_lock:
        state = _read_fault()
        state["alive"] = True
        state["ready"] = True
        state["recoveries"] += 1
        _write_fault(state)
    return jsonify({"status": "recovered", "pod": POD_NAME})


@app.route("/burn")
def burn():
    """Consume CPU to drive the HPA. Bounded so it cannot wedge the pod."""
    try:
        seconds = float(request.args.get("seconds", 15))
    except ValueError:
        seconds = 15.0
    seconds = max(0.0, min(seconds, 300.0))
    threading.Thread(target=_burn, args=(seconds,), daemon=True).start()
    return jsonify({"status": "burning", "seconds": seconds, "pod": POD_NAME})


@app.route("/metrics")
def metrics():
    return Response(_prometheus_text(), mimetype="text/plain; version=0.0.4")


@app.route("/")
def root():
    fault = _read_fault()
    return jsonify(
        {
            "service": "demo-api",
            "pod": POD_NAME,
            "node": NODE_NAME,
            "alive": fault["alive"],
            "ready": fault["ready"],
            "uptime_seconds": round(time.time() - START_TIME, 3),
        }
    )


@app.route("/echo")
def echo():
    return jsonify(
        {
            "pod": POD_NAME,
            "method": request.method,
            "path": request.path,
            "query": request.args.to_dict(flat=False),
        }
    )


@app.after_request
def _count(response):
    _bump(request.path, request.method, response.status_code)
    return response


@app.errorhandler(404)
def _not_found(_error):
    return jsonify({"error": "not found", "path": request.path}), 404


if __name__ == "__main__":
    # Development only. The container runs this under gunicorn; see Dockerfile.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
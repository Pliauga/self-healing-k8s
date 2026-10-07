# Tier 2 remediation agent: Alertmanager webhook -> LLM diagnosis -> executor.
#
# BUILD CONTEXT IS app/agent/, WHICH IS WHY THE COPY PATHS HAVE NO PREFIX:
#   minikube image build -p selfhealing -t selfhealing/demo-agent:dev app/agent/
# This matches scripts/setup.sh's pattern for demo-api (APP_DIR=app/, Dockerfile
# beside the code) and the build command recorded in HANDOFF section 8.
#
# The package is NOT flattened. diagnosis.py, dsh_client.py and executor.py all
# use relative imports (`from . import ...`), so the modules must arrive as a
# package named `agent` on sys.path. Copying them to /app/ instead would make
# gunicorn fail at startup with:
#   ImportError: attempted relative import with no known parent package
# Verified against gunicorn 23.0.0 in both layouts before writing this file.

# --- kubectl -----------------------------------------------------------------
# The agent SHELLS OUT to kubectl: diagnosis.py's evidence reads and executor.py's
# eviction both invoke `["kubectl", ...]`. python:3.12-slim ships no kubectl, no
# curl and no wget (verified), so without this stage the image builds cleanly and
# then fails EVERY request at runtime with FileNotFoundError. The official image
# is used as a source for the binary rather than downloading it, so there is no
# unverified curl|tar step and no network dependency in the build.
#
# Pinned to the cluster's kubectl minor: client v1.37.1 against server v1.37.0,
# within the supported one-minor skew. /bin/kubectl in this image is a STATIC
# Go binary (verified: statically linked, aarch64) that runs against the slim
# image's glibc; the tag is multi-arch (linux/amd64 + linux/arm64), so the build
# is correct on this arm64 host and on a future amd64 runner.
FROM registry.k8s.io/kubectl:v1.37.1 AS kubectl

# --- runtime -----------------------------------------------------------------
FROM python:3.12-slim

COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl

# The namespace enforces the restricted Pod Security Standard and the Deployment
# sets runAsNonRoot with UID/GID 10001, so create a matching unprivileged user.
# Identical to app/Dockerfile, so both workloads satisfy the same policy.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin app

WORKDIR /app

# Dependencies first: this layer is cached across code-only changes, so editing
# a module does not trigger a re-install.
COPY requirements.txt /app/agent/requirements.txt
RUN pip install --no-cache-dir --requirement /app/agent/requirements.txt

# Explicit module list, not `COPY . .`. The tests and __pycache__ must not enter
# the runtime image: they are dead weight for a CVE scan and they would ship a
# second copy of this project's assertions into the cluster.
COPY --chown=10001:10001 __init__.py schema.py executor.py dsh_client.py \
     diagnosis.py /app/agent/

USER 10001:10001
EXPOSE 8080

# PYTHONUNBUFFERED so `kubectl logs` shows the diagnosis pipeline live.
ENV PYTHONUNBUFFERED=1 \
    PORT=8080 \
    NAMESPACE=selfhealing

# Sync worker class, single worker. This serializes webhook handling
# deliberately: two concurrent alerts each independently deciding to evict is a
# race the executor's re-check would catch, but the queuing is simpler to reason
# about. See executor.py's lookup_pod re-check (design.md section 6.2).
#
# --workers 1 with the DEFAULT sync class. --threads is deliberately absent:
# adding it would silently re-enable concurrent webhook handling, which is the
# property this line exists to keep.
#
# --timeout 150 is sized from the worst case, NOT copied from demo-api's 30.
# Worst case per request: 3 LLM attempts x 30s (REQUEST_TIMEOUT_S) + 3s backoff,
# plus 3 kubectl evidence reads x 10s (EVIDENCE_TIMEOUT_S) = ~123s.
# gunicorn's --timeout is a worker-SILENCE limit, and a sync worker handling a
# request counts as busy - so a value below the worst case does not protect the
# request, it KILLS it mid-flight and returns 500. Reproduced: `--timeout 3`
# against an 8s request returned 500 at 3s with "WORKER TIMEOUT ... Worker
# exiting". At demo-api's 30 the agent would fail exactly the slow diagnoses it
# exists to handle and would never reach the eviction. 150 exceeds the 123s
# worst case with headroom for the eviction call itself (KUBECTL_TIMEOUT_S=20).
#
# NOTE: Alertmanager's default webhook timeout is 10s, so a slow diagnosis is
# still retried by the sender; that duplicate queues behind the first (one sync
# worker) and is caught by executor.lookup_pod ("already healed"). Correct by
# design, but it doubles LLM cost on slow diagnoses. See diagnosis.py's module
# docstring and DESIGN NOTES in the accompanying write-up. Not fixed in v1.
#
# --graceful-timeout exceeds the longest single request so an in-flight
# diagnosis completes on SIGTERM instead of being cut off mid-eviction.
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "1", \
     "--timeout", "150", \
     "--graceful-timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "agent.diagnosis:app"]

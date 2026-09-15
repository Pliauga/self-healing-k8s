# demo-api: Flask + gunicorn, per AGENTS.md tech stack.
#
# Built into minikube's image store by scripts/setup.sh (`minikube image build`),
# so no registry is required.
FROM python:3.12-slim

# The deployment's securityContext uses UID/GID 10001 and the namespace enforces
# the restricted Pod Security Standard, so create a matching unprivileged user.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin app

WORKDIR /app

# Dependencies first: this layer is cached across code-only changes, so an
# application edit does not trigger a re-install.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --requirement /app/requirements.txt

COPY --chown=10001:10001 app.py /app/app.py

USER 10001:10001
EXPOSE 8080

# Unbuffered output so `kubectl logs` is useful live.
ENV PYTHONUNBUFFERED=1 \
    PORT=8080 \
    FAULT_STATE_FILE=/tmp/demo-api-fault.json

# gunicorn with 4 workers.
#
# The worker count matters for the fault-injection demo: /fail must be visible
# to every worker, which is why the fault flag is a file rather than an
# in-process variable (see the module docstring in app.py).
#
# --graceful-timeout exceeds the app's drain period so in-flight requests
# complete on SIGTERM instead of being cut off mid-response.
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "4", \
     "--threads", "2", \
     "--timeout", "30", \
     "--graceful-timeout", "10", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
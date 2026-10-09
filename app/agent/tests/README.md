# Agent tests

Run from the repository root:

    cd /Users/ep/Documents/SELF-HEALING-K8S-CLUSTER
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -r app/agent/requirements.txt pytest
    pytest app/agent/tests/ -v

Everything here runs offline: kubectl is a stub on PATH, the LLM and the
executor are recording fakes, and no cluster, network or API key is touched.
pytest is deliberately not in app/agent/requirements.txt and never enters the
image, which is why the install step is explicit. `.venv/` is gitignored.
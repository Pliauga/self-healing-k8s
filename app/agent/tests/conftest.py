"""Shared fixtures for the Tier 2 agent tests.

Everything here runs offline. There are exactly two seams, and both already
exist in the production code:

1. PATH. executor.py and diagnosis.py each invoke
   ``subprocess.run(["kubectl", ...])`` with no executable override, so a shim
   named ``kubectl`` earlier on PATH intercepts every read and the eviction in
   both modules. The shim is generated per-test in tmp_path; the behaviour
   lives in the checked-in kubectl_stub.py. subprocess itself is untouched.

2. Module attributes. diagnosis.py calls through the module objects
   (``dsh_client.diagnose``, ``executor.execute``) rather than importing the
   names, so monkeypatching those two attributes replaces the LLM and the
   executor without modifying either module. No production hook was added to
   make this testable, because none was needed.
"""

from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

import pytest

# The package lives at app/agent/, so app/ must be importable. pytest's prepend
# import mode already handles this (app/ is the first ancestor without
# __init__.py); the insertion is kept so the failure mode is a clear message
# rather than a collection error if that assumption ever changes.
APP_DIR = Path(__file__).resolve().parents[2]
if str(APP_DIR) not in sys.path:
    sys.path.insert(0, str(APP_DIR))

from agent import diagnosis as diagnosis_module  # noqa: E402
from agent import executor as executor_module  # noqa: E402
from agent.schema import Diagnosis  # noqa: E402

STUB = Path(__file__).resolve().parent / "kubectl_stub.py"

# Verbs that change cluster state. Used to separate "read the cluster" from
# "mutate the cluster" in an assertion, so a mutation cannot hide inside a call
# list that also contains the two guard reads.
MUTATING_VERBS = frozenset(
    {"create", "delete", "apply", "patch", "replace", "edit", "scale",
     "cordon", "uncordon", "drain", "rollout", "annotate", "label", "evict"}
)


class KubectlStub:
    """A fake kubectl, driven by a plan held in the environment."""

    def __init__(self, log_path: Path, monkeypatch: pytest.MonkeyPatch):
        self.log_path = log_path
        self._monkeypatch = monkeypatch

    def plan(self, mapping: dict[str, dict]) -> None:
        """Install a plan. Any command not covered exits 99."""
        self._monkeypatch.setenv("KUBECTL_STUB_PLAN", json.dumps(mapping))
        self._monkeypatch.setenv("KUBECTL_STUB_LOG", str(self.log_path))

    def calls(self) -> list[list[str]]:
        """Every invocation, as a list of argument tokens."""
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in
                self.log_path.read_text(encoding="utf-8").splitlines()
                if line.strip()]

    def commands(self) -> list[str]:
        """The same calls, flattened to command strings for readable asserts."""
        return [" ".join(call) for call in self.calls()]

    def mutations(self) -> list[list[str]]:
        """Only the calls that could have changed cluster state."""
        return [call for call in self.calls() if call and call[0] in MUTATING_VERBS]


@pytest.fixture
def kubectl(tmp_path, monkeypatch):
    """A kubectl on PATH whose answers the test controls."""
    bindir = tmp_path / "bin"
    bindir.mkdir()

    shim = bindir / "kubectl"
    shim.write_text(
        "#!/bin/sh\n"
        f'exec "{sys.executable}" "{STUB}" "$@"\n',
        encoding="utf-8",
    )
    shim.chmod(shim.stat().st_mode | stat.S_IEXEC)

    monkeypatch.setenv(
        "PATH", str(bindir) + os.pathsep + os.environ.get("PATH", ""))

    stub = KubectlStub(tmp_path / "kubectl-calls.log", monkeypatch)
    stub.plan({})  # Nothing covered: an unmapped call fails loudly.
    return stub


@pytest.fixture
def stub_path():
    """The stub script itself, for the meta-test that proves it fails loudly.

    Exposed as a fixture rather than imported from conftest: with a tests/
    package present the module is agent.tests.conftest, and pytest does not
    guarantee ``import conftest`` resolves in every import mode.
    """
    return STUB


@pytest.fixture
def executor_mod():
    return executor_module


@pytest.fixture
def diagnosis_mod():
    return diagnosis_module


class PipelineRecorder:
    """Stand-in for the LLM and the executor, recording what they received."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch):
        self.diagnose_calls: list[dict] = []
        self.execute_calls: list[dict] = []

        # Set by the test to control the outcome of each stage.
        self.diagnosis_result: Diagnosis | None = None
        self.execution_result = None
        self.diagnose_raises: BaseException | None = None
        self.execute_raises: BaseException | None = None

        monkeypatch.setattr(
            diagnosis_module.dsh_client, "diagnose", self._diagnose)
        monkeypatch.setattr(
            diagnosis_module.executor, "execute", self._execute)

    def _diagnose(self, alert, evidence):
        self.diagnose_calls.append({"alert": alert, "evidence": evidence})
        if self.diagnose_raises is not None:
            raise self.diagnose_raises
        return self.diagnosis_result

    def _execute(self, diagnosis, namespace="selfhealing"):
        self.execute_calls.append(
            {"diagnosis": diagnosis, "namespace": namespace})
        if self.execute_raises is not None:
            raise self.execute_raises
        return self.execution_result


@pytest.fixture
def pipeline(monkeypatch):
    """The LLM and executor stages, replaced with recording fakes."""
    recorder = PipelineRecorder(monkeypatch)
    recorder.diagnosis_result = Diagnosis(
        root_cause="the container is wedged",
        action="restart-pod",
        target="demo-api-797748cc79-csfxl",
        confidence=0.95,
    )
    recorder.execution_result = executor_module.ExecutionResult(
        applied=False,
        action_taken="restart-pod",
        reason="stubbed",
    )
    return recorder


@pytest.fixture
def client():
    """Flask's test client over the real app object."""
    diagnosis_module.app.config.update(TESTING=True)
    return diagnosis_module.app.test_client()

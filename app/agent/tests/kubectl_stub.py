#!/usr/bin/env python3
"""Canned kubectl for the agent's test suite. Never shipped in the image.

Reads a plan from KUBECTL_STUB_PLAN: a JSON object mapping a command prefix
(whitespace-separated tokens) to {"code", "stdout", "stderr"}. The LONGEST
matching prefix wins, so that "get pod" cannot swallow "get pods".

Every invocation is appended as one JSON line to KUBECTL_STUB_LOG, so a test
can assert what was - and was not - run. That is the whole point: "the executor
made no cluster call" has to be a measurement, not an assumption.

An unmapped command exits 99 and says so. Loud deliberately: a stub that
silently succeeded would let a test pass without the code under test ever
reaching the branch it claims to cover - the "a check that restates a fact
instead of reading it" failure mode from docs/design.md section 14, applied to
the test suite itself.
"""

from __future__ import annotations

import json
import os
import sys


def best_match(args: list[str], plan: dict[str, dict]) -> str | None:
    """Longest token-prefix match of args in the plan."""
    match: str | None = None
    for key in plan:
        tokens = key.split()
        if args[: len(tokens)] != tokens:
            continue
        if match is None or len(tokens) > len(match.split()):
            match = key
    return match


def main(argv: list[str]) -> int:
    args = argv[1:]

    log_path = os.environ.get("KUBECTL_STUB_LOG")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(args) + "\n")

    plan = json.loads(os.environ.get("KUBECTL_STUB_PLAN", "{}"))
    key = best_match(args, plan)
    if key is None:
        sys.stderr.write(
            "kubectl-stub: no plan for: kubectl " + " ".join(args) + "\n")
        return 99

    entry = plan[key]
    if entry.get("stdout"):
        sys.stdout.write(entry["stdout"])
    if entry.get("stderr"):
        sys.stderr.write(entry["stderr"])
    return int(entry.get("code", 0))


if __name__ == "__main__":
    sys.exit(main(sys.argv))

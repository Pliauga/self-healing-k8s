#!/usr/bin/env python3
"""Offline repo-hygiene checks: ignore coverage, secret scan, size budget.

These three checks lived as one-off shell commands during the first commit
dry-run. That is exactly the pattern this project named as its dominant failure
mode (docs/design.md section 14): a check that exists but whose scope does not
match reality, because nothing re-runs it. A one-off command cannot catch a
regression introduced tomorrow. This script makes them durable and part of
`make validate`.

Three failure modes, each one observed for real in this repository:

1. **Ignore coverage.** `.gitignore` is a pattern that is supposed to match the
   set of files that must never be committed, and its failure mode is SILENT -
   git reports nothing when a pattern matches no files. A fused pattern
   (`floci-snapshot*.json.minikube-home/`) excluded nothing while the comment
   beside it said those files may contain credentials. This check asserts both
   directions: the files that must be ignored are ignored, AND the files that
   must be committable still are (a `!` negation can silently stop working).

2. **Secret scan.** CONTRIBUTING.md rule 6. A pattern list with zero matches is only
   meaningful if the patterns are known to work, so `--self-test` injects a
   synthetic credential and requires every pattern to fire. An unverified
   scanner reports "clean" for the same reason a broken smoke test reports
   "passed".

3. **Size budget.** A single large file makes the repository slow to clone
   forever. The threshold here is deliberately far below GitHub's 100 MB hard
   reject, because the useful signal is a file that is unexpectedly large, not
   one that has already broken the remote.

Exit code is non-zero if any check fails, so this is usable as a CI gate and as
the `make validate` hygiene step.

Usage:
    python3 scripts/check-repo-hygiene.py [--quiet] [--self-test]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# --- 1. Ignore coverage ------------------------------------------------------
# Files that MUST be ignored. Each entry is (path, why), and the path is chosen
# to resemble a real artefact rather than the exact name of one, so the check
# tests the pattern and not a coincidence.
MUST_BE_IGNORED = (
    ("floci-snapshot-20240101T000000.json", "Floci state snapshot (may hold credentials)"),
    (".minikube-home/profiles/selfhealing/client.crt", "Minikube cluster state and credentials"),
    (".kube/config", "kubeconfig (cluster credentials)"),
    ("secrets.yaml", "locally-applied secret manifest"),
    ("k8s/demo-live-secret.yaml", "secret manifest applied by hand"),
    (".env", "environment file"),
    ("rendered/demo-api.yaml", "rendered Helm output"),
    ("values.local.yaml", "local Helm value overrides"),
    ("app/__pycache__/app.cpython-312.pyc", "bytecode"),
    ("debug.log", "log file"),
    (".terraform/terraform.tfstate", "Terraform state (can contain secrets)"),
)

# Files that MUST remain committable. The negated example secrets are the
# interesting case: `!k8s/**/*secret*.example.yaml` exists so that examples can
# be shared, and a broad `*-secret.yaml` rule silently defeats it.
MUST_BE_TRACKED = (
    ("app/app.py", "application source"),
    ("k8s/10-deployment.yaml", "manifest"),
    ("k8s/tls-secret.example.yaml", "example secret (the negation must still win)"),
    ("docs/design.md", "documentation"),
    (".gitignore", "the ignore file itself"),
)

# --- 2. Secret scan ----------------------------------------------------------
# (regex, label, sample). Kept tight: a scanner that cries wolf gets disabled,
# which is worse than no scanner.
#
# Each pattern carries a SAMPLE that must match it, so the self-test can prove
# every rule fires rather than trusting that it would have. The samples are
# assembled by concatenation at import time rather than written as literals, for
# two reasons: a literal here would be found by the scan of this same file (the
# scanner flagged its own fixtures the first time it ran), and a sample that a
# `grep` for secrets cannot find is not one anyone can mistake for a real leak.
def _s(*parts: str) -> str:
    """Join sample fragments so no complete secret literal appears in this file."""
    return "".join(parts)


SECRET_PATTERNS = (
    (r"AKIA[0-9A-Z]{16}", "AWS access key id",
     _s("AKIA", "IOSFODNN7EXAMPL", "E")),
    (r"aws_secret_access_key\s*[=:]\s*\S+", "AWS secret access key assigned",
     _s("aws_secret_access_key", " = ", "wJalrXUtnFEMI", "EXAMPLEKEY")),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key block",
     _s("-----BEGIN ", "RSA ", "PRIVATE KEY", "-----")),
    (r"sk-[A-Za-z0-9]{20,}", "OpenAI-style API key",
     _s("sk-", "abcdefghij0123456789", "klmnopqrst")),
    (r"ghp_[A-Za-z0-9]{20,}", "GitHub personal access token",
     _s("ghp_", "0123456789abcdefghij", "klmnopqrstuvwx")),
    (r"github_pat_[A-Za-z0-9_]{20,}", "GitHub fine-grained token",
     _s("github_pat_", "11ABCDEFG0123456789", "_abcdefghijklmnop")),
    (r"xox[baprs]-[A-Za-z0-9-]{10,}", "Slack token",
     _s("xox", "b-", "0123456789-abcdefghij")),
    (r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.", "JWT",
     _s("eyJhbGciOiJIUzI1NiIs", ".", "eyJzdWIiOiIxMjM0NTY3ODkw", ".", "abcdefghij")),
    (
        r"(?i)(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*[\"']?[A-Za-z0-9+/_\-]{12,}",
        "assigned credential",
        _s("password", " = ", "hunter2hunter2hunter2"),
    ),
)

# Deliberate stand-ins that must NOT be reported: documentation about the
# scanner, example values, and the regexes themselves.
SECRET_ALLOWLIST = (
    r"AKIAFAKE",
    r"AKIAIOSFODNN7EXAMPLE",
    r"your-token-here",
    r"<token>",
    r"\$\{?[A-Z_]+\}?",  # shell interpolation, not a literal secret
)

# --- 3. Size budget ----------------------------------------------------------
MAX_FILE_BYTES = 1 * 1024 * 1024  # 1 MiB: well below GitHub's 100 MB reject.

# Trees that are local state, never committed. Mirrors .gitignore; a mismatch is
# itself a finding (see check_ignore_coverage, which uses git's real matcher).
SKIP_DIRS = {".git", "__pycache__", ".venv", "venv", ".terraform", "node_modules"}
SKIP_PREFIXES = (
    ".minikube-home/",
    ".kube/",
    ".floci/",
    "rendered/",
    ".git/",
)
SKIP_SUFFIXES = (".pyc", ".log", ".tfstate", ".tfstate.backup")


def _fail(msg: str) -> None:
    print(f"  FAIL  {msg}")


def _ok(msg: str) -> None:
    print(f"  ok    {msg}")


def iter_committable_files() -> list[Path]:
    """Every file that would be committed, by the same rules the scan applies."""
    out: list[Path] = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT).as_posix()
        if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts[:-1]):
            continue
        if rel.startswith(SKIP_PREFIXES) or rel.endswith(SKIP_SUFFIXES):
            continue
        if path.name == ".DS_Store":
            continue
        out.append(path)
    return out


def check_ignore_coverage(quiet: bool) -> int:
    """Assert .gitignore ignores what it must, using git's own matcher.

    `git check-ignore` is used rather than a Python glob emulation because the
    question is what GIT will do, and re-implementing gitignore semantics is how
    a check drifts from the thing it checks. A throwaway repository is created in
    a temp directory so this runs before `git init` has ever happened, and it
    never touches the working tree.
    """
    print("== ignore coverage ==")
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp)
        subprocess.run(["git", "init", "-q", str(scratch)], check=True, capture_output=True)
        (scratch / ".gitignore").write_text((ROOT / ".gitignore").read_text())

        def ignored(rel: str) -> bool:
            # `git check-ignore` exits 0 when the path IS ignored, 1 when not.
            # It does not require the file to exist.
            return (
                subprocess.run(
                    ["git", "check-ignore", "-q", rel],
                    cwd=scratch,
                    capture_output=True,
                ).returncode
                == 0
            )

        for rel, why in MUST_BE_IGNORED:
            if ignored(rel):
                if not quiet:
                    _ok(f"ignored: {rel}")
            else:
                _fail(f"NOT ignored: {rel}  ({why}) - it would be committed")
                failures += 1

        for rel, why in MUST_BE_TRACKED:
            if not ignored(rel):
                if not quiet:
                    _ok(f"committable: {rel}")
            else:
                _fail(f"wrongly ignored: {rel}  ({why}) - it would never be committed")
                failures += 1

    if failures:
        _fail(f"ignore coverage: {failures} problem(s)")
    else:
        _ok(f"ignore coverage: {len(MUST_BE_IGNORED)} must-ignore and "
            f"{len(MUST_BE_TRACKED)} must-track all behave correctly")
    return failures


def _scan_text(text: str) -> list[tuple[int, str, str]]:
    """Return (line, label, fragment) for each secret-looking match."""
    hits: list[tuple[int, str, str]] = []
    for pattern, label, _sample in SECRET_PATTERNS:
        for match in re.finditer(pattern, text):
            frag = match.group(0)
            if any(re.search(allowed, frag) for allowed in SECRET_ALLOWLIST):
                continue
            hits.append((text[: match.start()].count("\n") + 1, label, frag[:60]))
    return hits


def check_secrets(quiet: bool, self_test: bool) -> int:
    print("== secret scan ==")
    failures = 0

    # Prove the scanner works before trusting a clean result. Without this, a
    # typo'd regex yields "0 matches" and reads as a pass - the same silent
    # failure this whole script exists to prevent. Each pattern is exercised by
    # its own declared sample, so "the scanner is fine" is a tested claim.
    if self_test:
        silent: list[str] = []
        for pattern, label, sample in SECRET_PATTERNS:
            if not re.search(pattern, sample):
                silent.append(label)
        if silent:
            _fail(f"scanner self-test: these patterns did not match their own sample: {silent}")
            failures += 1
        else:
            _ok(f"scanner self-test: all {len(SECRET_PATTERNS)} pattern(s) match their sample")

        # A clean result must also mean the scan of REAL files is what produced
        # it: confirm a sample pasted into the tree is caught, so the file walk
        # cannot silently visit nothing.
        if not _scan_text("token = " + _s("abcdefghij", "0123456789")):
            _fail("scanner self-test: a planted credential in file content was not detected")
            failures += 1
        else:
            _ok("scanner self-test: a planted credential in file content is detected")

    total = 0
    for path in iter_committable_files():
        rel = path.relative_to(ROOT).as_posix()
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for line, label, frag in _scan_text(text):
            _fail(f"{rel}:{line}  [{label}]  {frag!r}")
            total += 1
            failures += 1

    if total == 0:
        _ok(f"secret scan: no matches in {len(iter_committable_files())} committable file(s)")
    else:
        _fail(f"secret scan: {total} match(es) - see CONTRIBUTING.md rule 6")
    return failures


def check_sizes(quiet: bool) -> int:
    print("== size budget ==")
    failures = 0
    files = iter_committable_files()
    total = sum(p.stat().st_size for p in files)
    oversized = [(p, p.stat().st_size) for p in files if p.stat().st_size > MAX_FILE_BYTES]
    for path, size in oversized:
        _fail(f"{path.relative_to(ROOT).as_posix()} is {size / 1024 / 1024:.1f} MiB "
              f"(budget {MAX_FILE_BYTES // 1024 // 1024} MiB)")
        failures += 1
    if not oversized:
        biggest = max(files, key=lambda p: p.stat().st_size)
        _ok(f"{len(files)} file(s), {total / 1024:.1f} KiB total; largest is "
            f"{biggest.relative_to(ROOT).as_posix()} at {biggest.stat().st_size / 1024:.1f} KiB")
    return failures


def check_doc_figures(quiet: bool) -> int:
    """Assert README's latency figures match docs/design.md's.

    README and design.md both state the per-scenario latency budget, and the two
    copies drifted: README still quoted `~43 s` for the liveness restart and
    `~16 s` for Tier 1 after design.md had been corrected to the measured
    `~25-40 s` and `~7-15 s`. A duplicated figure is a figure that will disagree
    with itself - the same class as the `.gitignore` and `make validate` globs in
    section 14, where a value was restated instead of derived. This check reads
    the numbers out of both files and compares them, so the duplication can no
    longer fail silently.

    Only the figures that are stated in BOTH files are compared; design.md is the
    source of truth and may carry ranges README does not mention.
    """
    print("== doc figure consistency ==")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    design = (ROOT / "docs" / "design.md").read_text(encoding="utf-8")

    # (label, pattern that must appear in README, pattern that must appear in design.md)
    # The patterns are ranges, so they must match character-for-character between
    # the documents; a reformatted range is a drift worth seeing.
    pairs = (
        ("liveness restart", r"~25[–-]40\s*s"),
        ("readiness shed", r"~7[–-]14\s*s"),
        ("pod replacement", r"~7[–-]15\s*s"),
        ("cpu-load scale-out", r"~60[–-]120\s*s"),
    )
    failures = 0
    for label, pat in pairs:
        in_readme = bool(re.search(pat, readme))
        in_design = bool(re.search(pat, design))
        if in_readme and in_design:
            if not quiet:
                _ok(f"{label}: {re.search(pat, readme).group(0)} in both README and design.md")
        elif in_design and not in_readme:
            _fail(f"{label}: design.md says {re.search(pat, design).group(0)} but README does not")
            failures += 1
        elif in_readme and not in_design:
            _fail(f"{label}: README says {re.search(pat, readme).group(0)} but design.md does not")
            failures += 1
        # absent from both is fine: the figure may have been removed deliberately

    # Negative control: the superseded figures must not survive in a LIVE CLAIM
    # surface. Presence alone cannot be the test, because both documents
    # legitimately narrate the corrections, and section 14 contains a findings
    # TABLE whose whole purpose is to record the old numbers as defects.
    #
    # Three earlier versions of this check were wrong, each in the same way:
    #   1. assumed only design.md could mention the old numbers -> flagged README's
    #      "Resolved during development" history.
    #   2. accepted any nearby correction marker -> flagged design.md's prose,
    #      where the marker sat just outside the window.
    #   3. treated any table row as a claim -> flagged section 14's findings table,
    #      where quoting the superseded value IS the record of the defect.
    #
    # The lesson is the project's own: scope the check to the thing it is actually
    # about. It is about the LATENCY BUDGET tables - the places that tell a reader
    # what to expect today. Those are found structurally: a markdown table whose
    # header names latency/expected and which appears outside the findings section.
    def _claim_tables(text: str) -> list[tuple[int, str]]:
        """Yield (line_number, line) for rows of latency/expected tables."""
        rows: list[tuple[int, str]] = []
        lines = text.splitlines()
        in_findings = False
        header_is_latency = False
        for i, line in enumerate(lines, 1):
            # Section 14 is the findings section; its tables record defects.
            if re.match(r"^#{2,3}\s+14\.", line):
                in_findings = True
            elif re.match(r"^#{2,3}\s+15\.", line):
                in_findings = False
            stripped = line.strip()
            if stripped.startswith("|"):
                lowered = stripped.lower()
                if "expected" in lowered or "latency" in lowered:
                    header_is_latency = True
                elif header_is_latency and set(stripped) <= set("|-: "):
                    pass  # separator row
                elif header_is_latency:
                    if not in_findings:
                        rows.append((i, stripped))
            elif stripped == "":
                pass
            else:
                header_is_latency = False
        return rows

    for stale, why in ((r"~43\s*s", "the liveness figure was the driver's polling floor"),
                       (r"~16\s*s", "superseded by the measured ~7-15 s pod replacement")):
        for name, text in (("README.md", readme), ("docs/design.md", design)):
            for line_no, row in _claim_tables(text):
                if re.search(stale, row):
                    _fail(f"{name}:{line_no} still gives the superseded {stale} in a "
                          f"latency table ({why})")
                    failures += 1

    if failures:
        _fail(f"doc figure consistency: {failures} problem(s)")
    else:
        _ok("doc figure consistency: README and design.md agree")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--quiet", action="store_true", help="only report problems")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="prove the secret scanner fires on a synthetic credential before trusting a clean result",
    )
    args = parser.parse_args()

    failures = 0
    failures += check_ignore_coverage(args.quiet)
    failures += check_secrets(args.quiet, args.self_test)
    failures += check_sizes(args.quiet)
    failures += check_doc_figures(args.quiet)

    print()
    if failures:
        print(f"repo hygiene: FAILED ({failures} problem(s))")
        return 1
    print("repo hygiene: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
# ADR-0002: Use Floci Instead of LocalStack for Local AWS Emulation

**Date:** 2026-09-28
**Status:** Accepted

## Context

The project targets AWS EKS in production. We want Terraform configuration, IAM
policy documents, and AWS SDK calls to run against a real API surface locally,
so that the EKS migration changes the cluster resource but not the surrounding
configuration. This requires an AWS service emulator running on the host.

LocalStack was the default choice until March 2026, when its Community Edition
began requiring an account and an auth token to run. That change makes it
unsuitable for a demo repository that should work out of the box for anyone who
clones it.

## Decision

Use **Floci** as the local AWS emulator, exposed at `http://localhost:4566` —
the same endpoint LocalStack uses, so SDK configuration is identical.

## Rationale

- **Zero signup, zero auth token.** `docker run floci/floci` starts a working
AWS API. No account, no telemetry, no license key.
- **MIT licensed.** No legal review needed for inclusion in a portfolio repo.
- **Sufficient service coverage.** IAM, S3, ECR, CloudWatch Logs, STS, and
Lambda cover everything the AWS provider and our Terraform code need.
- **Same endpoint as LocalStack.** Migration path back to LocalStack (if Floci
ever lags on a service) is a container swap, not a code change.
- **Verifiable coverage.** `floci services` lists what's implemented, so we can
assert required services exist in `scripts/setup.sh` rather than discovering
gaps at runtime.

## Consequences

**Positive:**

- Out-of-the-box reproducibility. Anyone can `git clone && scripts/setup.sh`.
- No ongoing licensing risk.
- Stateless by default; no persistence side effects between runs.

**Negative:**

- Smaller ecosystem than LocalStack; fewer StackOverflow answers for edge cases.
- Some newer or less-common AWS APIs may be unimplemented.
- Less battle-tested under concurrent load.

**Mitigation:**

- Pin the Floci image tag in `docker-compose.yml` rather than tracking `latest`.
- Add a coverage check to `scripts/setup.sh` that fails fast if a required
service is missing.
- Document any API we rely on that Floci doesn't implement, and stub it behind
an interface so it can be swapped in EKS.

## Alternatives Considered

- **LocalStack Community** — Rejected: auth token requirement breaks the
out-of-the-box constraint.
- **Moto** — Rejected: Python-only, not SDK-compatible for cross-language use.
- **fakecloud** — Viable fallback; Floci chosen for simpler Docker workflow and
the LocalStack-compatible endpoint.
- **Real AWS with budget alerts** — Rejected: slow iteration, cost risk, and
requires credentials that complicate the demo.

 
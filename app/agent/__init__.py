"""app/agent package: the Tier 2 remediation agent.

Two responsibilities in one container, split by ADR-0003 into a component that
decides and a component that acts:

  diagnosis.py  Flask webhook. Receives an Alertmanager payload, gathers
                read-only evidence, asks the LLM for a Diagnosis.
  executor.py   Deterministic. Validates a Diagnosis and performs at most one
                budget-checked eviction. Contains no LLM call.

Neither module reaches for a verb outside the closed vocabulary.
"""

"""Tests for the Tier 2 remediation agent.

A package (rather than a bare directory) on purpose: pytest's prepend import
mode walks up to the first ancestor WITHOUT an __init__.py to decide what to
put on sys.path. With __init__.py here and in app/agent/, that ancestor is
app/, so ``import agent.diagnosis`` resolves and the tests drive the same
package the image runs.
"""

#!/usr/bin/env python3
"""Offline structural validation for the manifests in k8s/.

Schema validation (`kubectl apply --dry-run=server`) only happens when a cluster
is reachable. It also cannot catch the class of bug that actually breaks a
self-healing setup: a selector that matches nothing, a probe pointed at a port
that does not exist, an HPA whose target has no CPU request. Those are
cross-references *between* manifests, so they are checked here, with no cluster
required.

Exit code is non-zero if any check fails, so this is usable as a CI gate and as
the `make validate` manifest step.

Usage:
    python3 scripts/validate-manifests.py [--quiet]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
K8S = ROOT / "k8s"

# Files that are not Kubernetes manifests, matched by filename. Helm values are
# chart configuration that lives under k8s/ for locality; they carry a .helm
# extension so no directory-wide `kubectl apply -f k8s/...` can pick them up.
# These globs are a second line of defence for the .yaml spellings.
EXEMPT_GLOBS = ("values-*.yaml", "values.yaml", "Chart.yaml", "*.helm")


def is_manifest(path: Path) -> bool:
    """True if path should be parsed as a Kubernetes manifest."""
    path = Path(path)
    if not path.is_absolute():
        path = (ROOT / path).resolve()
    return not any(path.match(pattern) for pattern in EXEMPT_GLOBS)

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def load_manifests() -> list[tuple[str, dict]]:
    """Return (source-file, document) for every manifest under k8s/."""
    out: list[tuple[str, dict]] = []
    for path in sorted(K8S.rglob("*.yaml")):
        if not is_manifest(path):
            continue
        try:
            docs = list(yaml.safe_load_all(path.read_text()))
        except yaml.YAMLError as exc:
            err(f"{path.relative_to(ROOT)}: invalid YAML: {exc}")
            continue
        for doc in docs:
            if doc:
                out.append((str(path.relative_to(ROOT)), doc))
    return out


def check_common_shape(manifests: list[tuple[str, dict]]) -> None:
    for src, doc in manifests:
        kind = doc.get("kind")
        if not doc.get("apiVersion"):
            err(f"{src}: document has no apiVersion")
        if not kind:
            err(f"{src}: document has no kind")
        meta = doc.get("metadata") or {}
        if not meta.get("name"):
            err(f"{src}: {kind} has no metadata.name")


def check_namespace_consistency(manifests: list[tuple[str, dict]]) -> None:
    """Every namespaced resource should agree on the namespace.

    A mismatch is silent at apply time and produces resources that exist but are
    never reconciled together.
    """
    namespaces = {}
    cluster_scoped = {
        "Namespace",
        "ClusterRole",
        "ClusterRoleBinding",
        "CustomResourceDefinition",
        "PersistentVolume",
        "StorageClass",
        "Node",
    }
    for src, doc in manifests:
        kind = doc.get("kind", "")
        if kind in cluster_scoped:
            continue
        ns = (doc.get("metadata") or {}).get("namespace")
        if ns:
            namespaces.setdefault(ns, []).append(f"{src}:{kind}/{(doc.get('metadata') or {}).get('name')}")

    if len(namespaces) > 1:
        listing = "; ".join(f"{ns} ({len(v)})" for ns, v in sorted(namespaces.items()))
        err(f"resources span multiple namespaces: {listing}")


def build_index(manifests: list[tuple[str, dict]]) -> dict[str, list[dict]]:
    index: dict[str, list[dict]] = {}
    for _, doc in manifests:
        index.setdefault(doc.get("kind", ""), []).append(doc)
    return index


def check_deployments(index: dict[str, list[dict]]) -> None:
    for dep in index.get("Deployment", []):
        name = dep["metadata"]["name"]
        spec = dep.get("spec") or {}
        selector = ((spec.get("selector") or {}).get("matchLabels")) or {}
        template_labels = ((spec.get("template") or {}).get("metadata") or {}).get("labels") or {}

        # The single most common Deployment bug: a selector that does not match
        # the pod template, so the controller owns and replaces nothing.
        missing = {k: v for k, v in selector.items() if template_labels.get(k) != v}
        if missing:
            err(
                f"Deployment/{name}: selector.matchLabels {missing} not present in "
                f"template labels {template_labels} - the ReplicaSet would own no pods"
            )

        containers = ((spec.get("template") or {}).get("spec") or {}).get("containers") or []
        if not containers:
            err(f"Deployment/{name}: no containers defined")
            continue

        for container in containers:
            cname = container.get("name", "?")
            ports = container.get("ports") or []
            port_names = {p.get("name") for p in ports if p.get("name")}
            port_numbers = {p.get("containerPort") for p in ports}

            for probe_kind in ("livenessProbe", "readinessProbe", "startupProbe"):
                probe = container.get(probe_kind)
                if not probe:
                    if probe_kind != "startupProbe":
                        warn(f"Deployment/{name}/{cname}: no {probe_kind}")
                    continue
                http = probe.get("httpGet")
                if not http:
                    continue
                target = http.get("port")
                if isinstance(target, str) and target not in port_names:
                    err(
                        f"Deployment/{name}/{cname}: {probe_kind} targets port name "
                        f"'{target}' which is not a declared container port "
                        f"(declared: {sorted(port_names) or 'none'})"
                    )
                elif isinstance(target, int) and target not in port_numbers:
                    err(
                        f"Deployment/{name}/{cname}: {probe_kind} targets port {target} "
                        f"which is not a declared container port "
                        f"(declared: {sorted(port_numbers) or 'none'})"
                    )

            # Probes must not be tighter than the failure semantics allow.
            live = container.get("livenessProbe") or {}
            ready = container.get("readinessProbe") or {}
            if live and ready:
                live_budget = (live.get("periodSeconds", 10) * live.get("failureThreshold", 3))
                ready_budget = (ready.get("periodSeconds", 10) * ready.get("failureThreshold", 3))
                if live_budget < ready_budget:
                    warn(
                        f"Deployment/{name}/{cname}: liveness budget ({live_budget}s) is "
                        f"tighter than readiness ({ready_budget}s); liveness should be the "
                        f"slower, more forgiving probe"
                    )


def check_services(index: dict[str, list[dict]]) -> None:
    deployments = index.get("Deployment", [])
    for svc in index.get("Service", []):
        name = svc["metadata"]["name"]
        spec = svc.get("spec") or {}
        selector = spec.get("selector") or {}

        if not selector:
            warn(f"Service/{name}: no selector (headless or manual endpoints?)")
            continue

        matched = False
        for dep in deployments:
            labels = ((dep.get("spec") or {}).get("template") or {}).get("metadata", {}).get("labels") or {}
            if all(labels.get(k) == v for k, v in selector.items()):
                matched = True
                break
        if not matched:
            err(
                f"Service/{name}: selector {selector} matches no Deployment pod "
                f"template - the Service would have no endpoints"
            )

        for port in spec.get("ports") or []:
            target = port.get("targetPort")
            if isinstance(target, str):
                found = any(
                    target in {p.get("name") for p in (c.get("ports") or []) if p.get("name")}
                    for dep in deployments
                    for c in (((dep.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []
                )
                if not found:
                    err(
                        f"Service/{name}: targetPort '{target}' is not a named container "
                        f"port on any Deployment"
                    )


def check_hpa(index: dict[str, list[dict]]) -> None:
    deployments = {d["metadata"]["name"]: d for d in index.get("Deployment", [])}

    # Index HPAs by the Deployment they target, so Deployments can be checked
    # for the CPU request the HPA needs.
    for hpa in index.get("HorizontalPodAutoscaler", []):
        name = hpa["metadata"]["name"]
        spec = hpa.get("spec") or {}
        ref = spec.get("scaleTargetRef") or {}
        target_name = ref.get("name")

        if ref.get("kind") != "Deployment":
            warn(f"HPA/{name}: scales {ref.get('kind')}/{target_name}; only Deployments checked here")
            continue
        target = deployments.get(target_name)
        if target is None:
            err(f"HPA/{name}: scaleTargetRef names Deployment '{target_name}' which does not exist")
            continue

        if spec.get("minReplicas", 1) > spec.get("maxReplicas", 1):
            err(f"HPA/{name}: minReplicas > maxReplicas")

        replicas = (target.get("spec") or {}).get("replicas", 1)
        if replicas < spec.get("minReplicas", 1):
            warn(
                f"HPA/{name}: target Deployment/{target_name} has replicas={replicas} "
                f"below minReplicas={spec.get('minReplicas')}"
            )
        if replicas > spec.get("maxReplicas", 1):
            warn(
                f"HPA/{name}: target Deployment/{target_name} has replicas={replicas} "
                f"above maxReplicas={spec.get('maxReplicas')}"
            )

        # Utilisation targets are a percentage of the *request*. Without a
        # request the HPA reports <unknown> forever.
        for metric in spec.get("metrics") or []:
            resource = metric.get("resource") or {}
            if (resource.get("target") or {}).get("type") != "Utilization":
                continue
            resource_name = resource.get("name")
            containers = (((target.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []
            for container in containers:
                requests = (container.get("resources") or {}).get("requests") or {}
                if resource_name not in requests:
                    err(
                        f"HPA/{name}: targets {resource_name} Utilization but "
                        f"Deployment/{target_name} container '{container.get('name')}' has "
                        f"no {resource_name} request - the HPA would report <unknown>"
                    )


def check_pdb(index: dict[str, list[dict]]) -> None:
    deployments = index.get("Deployment", [])
    for pdb in index.get("PodDisruptionBudget", []):
        name = pdb["metadata"]["name"]
        spec = pdb.get("spec") or {}
        selector = ((spec.get("selector") or {}).get("matchLabels")) or {}

        if not selector:
            err(f"PDB/{name}: empty selector - it would apply to every pod in the namespace")
            continue

        matched_replicas = [
            (d.get("spec") or {}).get("replicas", 1)
            for d in deployments
            if all(
                (((d.get("spec") or {}).get("template") or {}).get("metadata", {}).get("labels") or {}).get(k) == v
                for k, v in selector.items()
            )
        ]
        if not matched_replicas:
            err(f"PDB/{name}: selector {selector} matches no Deployment - it protects nothing")
            continue

        replicas = max(matched_replicas)
        if spec.get("minAvailable") is not None:
            min_available = spec["minAvailable"]
            if isinstance(min_available, int):
                if min_available >= replicas:
                    err(
                        f"PDB/{name}: minAvailable={min_available} >= replicas={replicas} - "
                        f"every voluntary eviction would be refused"
                    )
                elif min_available == replicas - 1 and replicas > 1:
                    warn(
                        f"PDB/{name}: minAvailable={min_available} of {replicas} permits "
                        f"only one concurrent disruption"
                    )
        if spec.get("maxUnavailable") is not None and spec.get("minAvailable") is not None:
            err(f"PDB/{name}: both minAvailable and maxUnavailable set; they are mutually exclusive")


def check_rbac(index: dict[str, list[dict]]) -> None:
    roles = {r["metadata"]["name"] for r in index.get("Role", [])}
    roles |= {r["metadata"]["name"] for r in index.get("ClusterRole", [])}

    for binding in index.get("RoleBinding", []) + index.get("ClusterRoleBinding", []):
        name = binding["metadata"]["name"]
        ref = binding.get("roleRef") or {}
        if ref.get("name") not in roles:
            err(f"{binding['kind']}/{name}: roleRef '{ref.get('name')}' does not resolve to a Role/ClusterRole")
        if not binding.get("subjects"):
            err(f"{binding['kind']}/{name}: no subjects - the binding grants nothing")

    # Flag any rule that grants cluster-wide authority to a namespaced agent.
    for role in index.get("Role", []):
        name = role["metadata"]["name"]
        for rule in role.get("rules") or []:
            verbs = set(rule.get("verbs") or [])
            resources = set(rule.get("resources") or [])
            if "*" in verbs or "*" in resources:
                err(f"Role/{name}: wildcard in verbs/resources - violates least privilege")
            if "delete" in verbs and "pods" in resources:
                warn(
                    f"Role/{name}: grants delete on pods, which bypasses the "
                    f"PodDisruptionBudget; prefer pods/eviction"
                )
            if "secrets" in resources:
                warn(f"Role/{name}: grants access to secrets")


def check_servicemonitor(index: dict[str, list[dict]]) -> None:
    services = index.get("Service", [])
    for sm in index.get("ServiceMonitor", []):
        name = sm["metadata"]["name"]
        selector = ((sm.get("spec") or {}).get("selector") or {}).get("matchLabels") or {}
        if not selector:
            err(f"ServiceMonitor/{name}: empty selector - it would scrape every Service")
            continue
        if not any(
            all((s.get("metadata", {}).get("labels") or {}).get(k) == v for k, v in selector.items())
            for s in services
        ):
            err(f"ServiceMonitor/{name}: selector {selector} matches no Service in these manifests")

        # Each endpoint port must exist on the matched Service.
        for endpoint in (sm.get("spec") or {}).get("endpoints") or []:
            port = endpoint.get("port")
            if port and not any(
                port in {p.get("name") for p in (s.get("spec") or {}).get("ports") or []}
                for s in services
            ):
                warn(f"ServiceMonitor/{name}: endpoint port '{port}' is not a named Service port")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="only print failures")
    args = parser.parse_args()

    manifests = load_manifests()
    if not manifests:
        err(f"no manifests found under {K8S}")
        return 1

    check_common_shape(manifests)
    check_namespace_consistency(manifests)

    index = build_index(manifests)
    check_deployments(index)
    check_services(index)
    check_hpa(index)
    check_pdb(index)
    check_rbac(index)
    check_servicemonitor(index)

    if not args.quiet:
        kinds: dict[str, int] = {}
        for _, doc in manifests:
            kinds[doc.get("kind", "?")] = kinds.get(doc.get("kind", "?"), 0) + 1
        print(f"  parsed {len(manifests)} manifest document(s): "
              + ", ".join(f"{k}x{v}" for k, v in sorted(kinds.items())))

    for message in warnings:
        print(f"  warn {message}")
    for message in errors:
        print(f"  FAIL {message}", file=sys.stderr)

    if errors:
        print(f"\n{len(errors)} error(s), {len(warnings)} warning(s)", file=sys.stderr)
        return 1
    print(f"  ok   all structural checks passed ({len(warnings)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
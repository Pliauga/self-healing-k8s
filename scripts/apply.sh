#!/usr/bin/env bash
# apply.sh - apply the Kubernetes manifests to the current cluster context.
#
# This is separated from setup.sh so manifests can be re-applied quickly
# without rebuilding the image or touching the cluster itself.
#
# Usage:
#   scripts/apply.sh [--optional] [--yes]
#
#   --optional   also apply k8s/optional/agent/ (RBAC and load generator)
#   --yes        do not prompt for confirmation
#
# The base manifests in k8s/ are applied in filename order (00-, 10-, 20-, ...)
# so that the namespace exists before namespaced resources are created.

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

WITH_OPTIONAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --optional) WITH_OPTIONAL=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    -h|--help)  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
export ASSUME_YES="${ASSUME_YES:-0}"

# This script only mutates: there is no read-only mode to fall back on, so
# without an explicit --yes (or a live TTY to answer the prompt) it must not run
# at all. See consent_or_die in lib/common.sh.
consent_or_die "Apply the manifests in ${K8S_DIR} to the current cluster?"

require_cluster

log "applying manifests from ${K8S_DIR}"
detail "context   : $(kubectl config current-context)"
detail "namespace : ${K8S_NAMESPACE}"

# Apply the namespace first and wait for it to be Active: applying namespaced
# resources in the same instant as their namespace occasionally races.
# Every manifest goes through apply_manifest, which runs a server-side dry-run
# before applying (project safety policy, CONTRIBUTING.md rule 1).
log "dry-run then apply"
apply_manifest "${K8S_DIR}/00-namespace.yaml" || die "namespace manifest failed validation"
kubectl wait --for=jsonpath='{.status.phase}'=Active \
  "namespace/${K8S_NAMESPACE}" --timeout=60s >/dev/null 2>&1 \
  || warn "namespace did not report Active within 60s; continuing"

# Then everything else. `find | sort` keeps the ordering explicit and skips the
# optional/ subdirectories, which are applied separately.
while IFS= read -r manifest; do
  detail "$(basename "${manifest}")"
  apply_manifest "${manifest}" || die "aborting: ${manifest} failed validation"
done < <(find "${K8S_DIR}" -maxdepth 1 -name '*.yaml' ! -name '00-namespace.yaml' | sort)

if [[ "${WITH_OPTIONAL}" == "1" ]]; then
  log "applying optional agent resources (RBAC + load generator)"
  while IFS= read -r manifest; do
    detail "$(basename "${manifest}")"
    apply_manifest "${manifest}" || die "aborting: ${manifest} failed validation"
  done < <(find "${K8S_DIR}/optional/agent" -name '*.yaml' | sort)
  detail "note: the load generator is deployed but the HPA will not scale out"
  detail "      until it is generating CPU load"
fi

log "waiting for the deployment to roll out"
if wait_for_rollout "${K8S_NAMESPACE}" demo-api; then
  ok "demo-api is available"
else
  err "the deployment did not become available"
  detail "diagnose with:"
  detail "  kubectl get pods -n ${K8S_NAMESPACE}"
  detail "  kubectl describe deployment/demo-api -n ${K8S_NAMESPACE}"
  detail "  kubectl get events -n ${K8S_NAMESPACE} --sort-by=.lastTimestamp"
  exit 1
fi
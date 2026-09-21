#!/usr/bin/env bash
# teardown.sh - tear down the local self-healing demo environment.
#
# Deliberately granular: deleting the minikube profile is destructive and slow
# to rebuild, so it is a separate, explicitly-confirmed step from removing the
# application.
#
# Usage:
#   scripts/teardown.sh [--app-only] [--keep-cluster] [--all] [--yes]
#
#   --app-only      delete only the selfhealing namespace (keep the cluster)
#   --keep-cluster  remove manifests and monitoring, keep the minikube profile
#   --all           delete the minikube profile as well (destroys all cluster
#                   state, images and volumes - cannot be undone)
#   --yes           do not prompt for confirmation
#
# With no flags, the script prompts for the level of destruction.

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

MODE=""
ASSUME_YES="${ASSUME_YES:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-only)     MODE="app" ;;
    --keep-cluster) MODE="keep" ;;
    --all)          MODE="all" ;;
    --yes|-y)       ASSUME_YES=1 ;;
    -h|--help)      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
export ASSUME_YES

if [[ -z "${MODE}" ]]; then
  # Same reasoning as confirm() in lib/common.sh: a bare `read` on a non-TTY
  # stdin blocks forever when stdin is an open pipe that never delivers data.
  # Require an explicit mode instead of guessing, so an unattended run cannot
  # silently pick a destructive scope.
  if [[ ! -t 0 ]]; then
    die "no teardown mode selected and stdin is not a terminal.
     Pass one explicitly: --app-only | --keep-cluster | --all
     Add --yes to skip the confirmation prompts."
  fi
  printf '\nSelect teardown scope:\n\n'
  printf '  1) application only   - delete the %s namespace\n' "${K8S_NAMESPACE}"
  printf '  2) keep cluster       - also uninstall monitoring\n'
  printf '  3) everything         - also delete the minikube profile "%s"\n\n' "${CLUSTER_NAME}"
  read -r -p 'Choice [1/2/3]: ' choice || die "no choice read from stdin"
  case "${choice}" in
    1) MODE="app" ;;
    2) MODE="keep" ;;
    3) MODE="all" ;;
    *) die "invalid choice: ${choice}" ;;
  esac
fi

require_cmd kubectl

if ! kubectl cluster-info >/dev/null 2>&1; then
  warn "no cluster is reachable; nothing to clean up inside the cluster"
else
  log "cleaning up namespace '${K8S_NAMESPACE}'"
  if kubectl get namespace "${K8S_NAMESPACE}" >/dev/null 2>&1; then
    if confirm "Delete namespace ${K8S_NAMESPACE} and everything in it?"; then
      # --wait=false then poll: namespace deletion can take a while when
      # finalizers are involved, and blocking here hides progress.
      kubectl delete namespace "${K8S_NAMESPACE}" --wait=false
      ok "deletion of namespace '${K8S_NAMESPACE}' requested"
      wait_for "namespace '${K8S_NAMESPACE}' to be gone" 180 \
        bash -c "! kubectl get namespace '${K8S_NAMESPACE}' >/dev/null 2>&1" \
        || warn "namespace is still terminating (a finalizer may be stuck)"
    else
      warn "skipped namespace deletion"
    fi
  else
    ok "namespace '${K8S_NAMESPACE}' does not exist"
  fi

  # --- monitoring ----------------------------------------------------------
  if [[ "${MODE}" != "app" ]]; then
    if kubectl get namespace "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
      log "removing monitoring stack"
      if command -v helm >/dev/null 2>&1 \
        && helm status kube-prometheus-stack -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
        if confirm "Uninstall kube-prometheus-stack?"; then
          helm uninstall kube-prometheus-stack -n "${MONITORING_NAMESPACE}" \
            || warn "helm uninstall reported an error; continuing"
          ok "helm release removed"
        fi
      else
        warn "no helm release 'kube-prometheus-stack' found in ${MONITORING_NAMESPACE}"
      fi
      if confirm "Delete namespace ${MONITORING_NAMESPACE} (removes any leftovers)?"; then
        kubectl delete namespace "${MONITORING_NAMESPACE}" --wait=false
        ok "deletion of namespace '${MONITORING_NAMESPACE}' requested"
      fi
    else
      ok "monitoring namespace '${MONITORING_NAMESPACE}' does not exist"
    fi
  fi
fi

# --- cluster ----------------------------------------------------------------
if [[ "${MODE}" == "all" ]]; then
  log "deleting the minikube profile '${CLUSTER_NAME}'"
  warn "this destroys the cluster, its images, and its volumes"
  if confirm "Permanently delete minikube profile '${CLUSTER_NAME}'?"; then
    require_cmd minikube
    # -p targets the profile explicitly rather than relying on the active one.
    minikube delete --profile "${CLUSTER_NAME}" --purge
    ok "cluster '${CLUSTER_NAME}' deleted"
  else
    warn "skipped cluster deletion"
  fi
else
  detail "minikube profile '${CLUSTER_NAME}' left running"
  detail "delete it with: ${SCRIPTS_DIR}/teardown.sh --all"
  detail "or stop it with: minikube stop --profile ${CLUSTER_NAME}"
fi

log "teardown complete"
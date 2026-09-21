#!/usr/bin/env bash
# setup.sh - bring up the local self-healing demo environment.
#
# Steps:
#   1. verify the toolchain and that Docker is running
#   2. start (or reuse) the minikube cluster with adequate resources
#   3. enable the metrics-server and ingress addons
#   4. build the demo-api image directly into minikube's image store
#   5. apply the Kubernetes manifests and wait for a healthy rollout
#
# Usage:
#   scripts/setup.sh [--monitoring] [--load-generator] [--yes]
#
#   --monitoring      also install kube-prometheus-stack via Helm (slow,
#                     ~1.5 CPU / ~3Gi in-cluster)
#   --load-generator  deploy the CPU load generator (needed for HPA tests)
#   --yes             do not prompt for confirmation
#
# Environment overrides: CLUSTER_NAME, MINIKUBE_CPUS, MINIKUBE_MEMORY,
# MINIKUBE_DRIVER, APP_IMAGE, K8S_NAMESPACE.

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

WITH_MONITORING=0
WITH_LOAD_GENERATOR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --monitoring)     WITH_MONITORING=1 ;;
    --load-generator) WITH_LOAD_GENERATOR=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    -h|--help)        sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
export ASSUME_YES="${ASSUME_YES:-0}"

# Bring-up creates a cluster, builds an image and applies manifests: every step
# mutates, and there is no read-only mode. Require consent up front rather than
# discovering halfway through that nobody could answer a prompt.
consent_or_die "Start the cluster and deploy the workload?"

log "self-healing demo setup"
detail "project root : ${PROJECT_ROOT}"
detail "cluster      : ${CLUSTER_NAME} (${MINIKUBE_CPUS} cpu, ${MINIKUBE_MEMORY} MiB, driver=${MINIKUBE_DRIVER})"
detail "namespace    : ${K8S_NAMESPACE}"
detail "image        : ${APP_IMAGE}"

# --- 1. toolchain ------------------------------------------------------------
log "checking prerequisites"
require_cmd minikube kubectl
require_docker
ok "minikube $(minikube version --short 2>/dev/null || echo '?'), kubectl present, docker running"

# Surface a project-local state fallback (restricted sandbox or read-only home)
# before touching the cluster, so its consequences are not a surprise later.
report_state_location

# kubectl writes the context into $KUBECONFIG on first use; it will not create
# the parent directory itself.
if [[ -n "${KUBECONFIG:-}" ]]; then
  mkdir -p "$(dirname "${KUBECONFIG}")"
fi

# --- 2. cluster --------------------------------------------------------------
if cluster_is_running; then
  ok "minikube profile '${CLUSTER_NAME}' is already running - reusing it"
else
  log "starting minikube profile '${CLUSTER_NAME}' (this may take a few minutes)"
  # --cpus/--memory are set generously because kube-prometheus-stack and the
  # HPA tests both need headroom; a 2-CPU cluster produces misleading results.
  minikube start \
    --profile "${CLUSTER_NAME}" \
    --driver "${MINIKUBE_DRIVER}" \
    --cpus "${MINIKUBE_CPUS}" \
    --memory "${MINIKUBE_MEMORY}" \
    || die "minikube start failed - see the output above"
  ok "cluster started"
fi

# Point kubectl at this profile for the rest of the script and afterwards.
kubectl config use-context "${CLUSTER_NAME}" >/dev/null
ok "kubectl context set to '${CLUSTER_NAME}'"

# --- 3. addons ---------------------------------------------------------------
# metrics-server is what makes the HPA work at all. Without it the HPA
# reports <unknown> for CPU and never scales.
log "enabling addons"
if minikube addons enable metrics-server --profile "${CLUSTER_NAME}" >/dev/null 2>&1; then
  ok "metrics-server addon enabled"
else
  warn "could not enable metrics-server; the HPA will report <unknown> CPU"
fi

# --- 4. build the application image -----------------------------------------
log "building ${APP_IMAGE} into the minikube image store"
detail "source: ${APP_DIR}"
if minikube image build --profile "${CLUSTER_NAME}" -t "${APP_IMAGE}" "${APP_DIR}"; then
  ok "image built"
else
  die "image build failed - check app/Dockerfile and the build output above"
fi

# --- 5. manifests ------------------------------------------------------------
log "applying Kubernetes manifests"
SKIP_IMAGE_BUILD=1 "${SCRIPTS_DIR}/apply.sh" --yes

if [[ "${WITH_LOAD_GENERATOR}" == "1" ]]; then
  log "deploying the load generator"
  kubectl apply -f "${K8S_DIR}/optional/agent/load-generator.yaml"
  wait_for_rollout "${K8S_NAMESPACE}" load-generator || true
fi

# --- 6. optional monitoring --------------------------------------------------
if [[ "${WITH_MONITORING}" == "1" ]]; then
  log "installing kube-prometheus-stack"
  require_cmd helm
  helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || warn "helm repo update failed; using cached index"
  if confirm "Install kube-prometheus-stack into namespace '${MONITORING_NAMESPACE}'?"; then
    helm upgrade --install kube-prometheus-stack \
      prometheus-community/kube-prometheus-stack \
      --namespace "${MONITORING_NAMESPACE}" \
      --create-namespace \
      --values "${K8S_DIR}/optional/observability/kube-prometheus-stack.helm" \
      --wait --timeout 10m
    ok "kube-prometheus-stack installed"
    log "applying ServiceMonitor and PrometheusRule"
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
      for manifest in "${K8S_DIR}"/optional/observability/*.yaml; do
        detail "$(basename "${manifest}")"
        apply_manifest "${manifest}" || warn "skipped ${manifest}"
      done
    else
      warn "ServiceMonitor CRD not found; skipping the observability manifests"
      detail "the pod annotations (prometheus.io/scrape) still apply"
    fi
  else
    warn "skipped monitoring installation"
  fi
else
  detail "monitoring not requested; re-run with --monitoring to install it"
fi

# --- 7. report ---------------------------------------------------------------
log "setup complete"
"${SCRIPTS_DIR}/status.sh" || true

cat <<EOF

Next steps:
  scripts/inject-failure.sh pod-kill      # delete a pod, watch it be replaced
  scripts/inject-failure.sh app-fail      # make a pod fail its probes
  scripts/inject-failure.sh cpu-load      # drive the HPA to scale out
  scripts/inject-failure.sh --list        # all available scenarios
  scripts/status.sh --watch               # follow cluster state live
  scripts/teardown.sh                     # stop the cluster
EOF
#!/usr/bin/env bash
# status.sh - report the state of the self-healing demo environment.
#
# Designed to be readable at a glance and to answer "is self-healing working,
# and if not, why?" rather than merely dumping resources.
#
# Usage:
#   scripts/status.sh [--watch]
#
#   --watch   refresh every 5 seconds (Ctrl-C to stop)

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

WATCH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch|-w) WATCH=1 ;;
    -h|--help)  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

require_cluster

render() {
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
  printf '\n%s=== self-healing cluster status ===%s\n' "$_C_BLUE" "$_C_RESET"
  printf 'context: %s    time: %s\n\n' "$ctx" "$(date '+%H:%M:%S')"

  # --- nodes ---------------------------------------------------------------
  printf '%s-- nodes%s\n' "$_C_DIM" "$_C_RESET"
  kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLE:.metadata.labels.node-role\.kubernetes\.io/control-plane,VERSION:.status.nodeInfo.kubeletVersion' \
    2>/dev/null || warn "could not list nodes"

  # --- namespace check -----------------------------------------------------
  if ! kubectl get namespace "${K8S_NAMESPACE}" >/dev/null 2>&1; then
    printf '\n'
    warn "namespace '${K8S_NAMESPACE}' does not exist - run scripts/apply.sh"
    return 0
  fi

  # --- workload ------------------------------------------------------------
  printf '\n%s-- deployment%s\n' "$_C_DIM" "$_C_RESET"
  kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
    -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,UPDATED:.status.updatedReplicas' \
    2>/dev/null || true

  printf '\n%s-- pods%s\n' "$_C_DIM" "$_C_RESET"
  kubectl get pods -n "${K8S_NAMESPACE}" \
    -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount,NODE:.spec.nodeName,AGE:.metadata.creationTimestamp' \
    2>/dev/null || true

  # Restart counts are the single best signal that liveness remediation is
  # firing. Surface them explicitly rather than making the reader scan.
  local total_restarts
  total_restarts="$(kubectl get pods -n "${K8S_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END {print s+0}')"
  if [[ "${total_restarts}" -gt 0 ]]; then
    printf '%s     total restarts across pods: %s%s\n' "$_C_YELLOW" "${total_restarts}" "$_C_RESET"
  else
    printf '%s     total restarts across pods: 0%s\n' "$_C_GREEN" "$_C_RESET"
  fi

  # --- service / endpoints -------------------------------------------------
  printf '\n%s-- service and endpoints%s\n' "$_C_DIM" "$_C_RESET"
  kubectl get service demo-api -n "${K8S_NAMESPACE}" \
    -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,PORT:.spec.ports[*].port' \
    2>/dev/null || true

  # A pod failing readiness disappears from here. This is the clearest visual
  # proof that readiness-based self-healing is working.
  local endpoints
  endpoints="$(kubectl get endpoints demo-api -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  if [[ -n "${endpoints}" ]]; then
    local count
    count="$(wc -w <<<"${endpoints}" | tr -d ' ')"
    printf '%s     ready endpoints: %s (%s)%s\n' "$_C_GREEN" "${count}" "${endpoints}" "$_C_RESET"
  else
    printf '%s     ready endpoints: NONE - all pods are failing readiness%s\n' \
      "$_C_RED" "$_C_RESET"
  fi

  # --- autoscaler ----------------------------------------------------------
  printf '\n%s-- horizontal pod autoscaler%s\n' "$_C_DIM" "$_C_RESET"
  if kubectl get hpa demo-api -n "${K8S_NAMESPACE}" >/dev/null 2>&1; then
    kubectl get hpa demo-api -n "${K8S_NAMESPACE}" 2>/dev/null || true
    # Detect a missing metric from the JSON, not the rendered table.
    #
    # The <unknown> in `kubectl get` output is a client-side rendering of an
    # absent value, so grepping the table for the literal string never works
    # against -o jsonpath output. When metrics are unavailable the API returns
    # entries with an empty type and no `current` block, e.g.
    #     [{"type":""},{"type":""}]
    # so the reliable test is whether any metric carries a `current` value.
    local metric_json
    metric_json="$(kubectl get hpa demo-api -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.status.currentMetrics[*].resource.current.averageUtilization}' 2>/dev/null)"
    if [[ -z "${metric_json}" ]]; then
      warn "HPA has no current metric - metrics-server is not serving yet"
      detail "check: minikube addons enable metrics-server --profile ${CLUSTER_NAME}"
      detail "       kubectl top pods -n ${K8S_NAMESPACE}"
      detail "       note: metrics take 60-90s to appear after a fresh start"
    fi
  else
    warn "HPA not found"
  fi

  # --- disruption budget ---------------------------------------------------
  printf '\n%s-- pod disruption budget%s\n' "$_C_DIM" "$_C_RESET"
  kubectl get pdb demo-api -n "${K8S_NAMESPACE}" 2>/dev/null || warn "PDB not found"

  # --- recent events -------------------------------------------------------
  printf '\n%s-- recent events (last 10)%s\n' "$_C_DIM" "$_C_RESET"
  kubectl get events -n "${K8S_NAMESPACE}" \
    --sort-by=.lastTimestamp \
    -o custom-columns='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' \
    2>/dev/null | tail -n 11 || true

  # --- monitoring ----------------------------------------------------------
  if kubectl get namespace "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
    printf '\n%s-- monitoring%s\n' "$_C_DIM" "$_C_RESET"
    kubectl get pods -n "${MONITORING_NAMESPACE}" \
      -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase' \
      2>/dev/null | head -n 8 || true
    detail "Grafana: kubectl port-forward -n ${MONITORING_NAMESPACE} svc/kube-prometheus-stack-grafana 3000:80"
    detail "          http://localhost:3000  (admin / prom-operator)"
  fi
}

if [[ "${WATCH}" == "1" ]]; then
  # Clear the screen between refreshes, but restore the cursor on exit so a
  # Ctrl-C does not leave the terminal in a broken state.
  trap 'printf "\033[?25h"; exit 0' INT TERM
  printf '\033[?25l'
  while true; do
    printf '\033[2J\033[H'
    render || true
    sleep 5
  done
else
  render
fi
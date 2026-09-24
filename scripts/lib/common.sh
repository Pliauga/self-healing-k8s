#!/usr/bin/env bash
# Shared helpers for the self-healing-cluster scripts.
#
# Source this file, do not execute it:  . "$(dirname "$0")/lib/common.sh"
#
# Every script in scripts/ relies on these functions so that naming, logging
# and failure behaviour stay consistent.

set -euo pipefail

# --- project layout ----------------------------------------------------------
# Resolve paths from this file's location so scripts work from any CWD.
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${COMMON_SH_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
K8S_DIR="${PROJECT_ROOT}/k8s"
APP_DIR="${PROJECT_ROOT}/app"
DOCS_DIR="${PROJECT_ROOT}/docs"
export PROJECT_ROOT SCRIPTS_DIR K8S_DIR APP_DIR DOCS_DIR

# --- configuration (override via environment) --------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-selfhealing}"
K8S_NAMESPACE="${K8S_NAMESPACE:-selfhealing}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
APP_IMAGE="${APP_IMAGE:-selfhealing/demo-api:dev}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8192}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
export CLUSTER_NAME K8S_NAMESPACE MONITORING_NAMESPACE APP_IMAGE
export MINIKUBE_CPUS MINIKUBE_MEMORY MINIKUBE_DRIVER

# --- state location ----------------------------------------------------------
# Minikube writes cluster state to $MINIKUBE_HOME (default ~/.minikube) and
# kubectl reads its context from $KUBECONFIG (default ~/.kube/config). Both live
# outside the project, so a restricted file sandbox - or a plain read-only home
# directory - makes `minikube start` fail with:
#
#   Failed to save config: mkdir /Users/<you>/.minikube/profiles/<profile>:
#   operation not permitted
#
# When either location is unwritable, fall back to keeping state inside the
# project so the tooling works without elevated permissions. Detection uses a
# real write probe because `mkdir -p` succeeds on an existing directory that is
# not writable - a false negative that would misdiagnose this exact failure.
#
# Set MINIKUBE_HOME / KUBECONFIG explicitly to override; the fallback only
# applies when the preferred location is unusable.

_is_writable() {
  local dir="$1"
  # Walk up to the nearest existing ancestor and try to create a temp file in it.
  while [[ ! -d "${dir}" && "${dir}" != "/" ]]; do
    dir="$(dirname "${dir}")"
  done
  local probe="${dir}/.dsh-write-probe.$$"
  if ( set -o noclobber; : >"${probe}" ) 2>/dev/null; then
    rm -f "${probe}"
    return 0
  fi
  return 1
}

# Minikube state.
if [[ -z "${MINIKUBE_HOME:-}" ]]; then
  if _is_writable "${HOME}/.minikube"; then
    : # default location is fine
  else
    MINIKUBE_HOME="${PROJECT_ROOT}/.minikube-home"
    export MINIKUBE_HOME
    STATE_FALLBACK_REASON="MINIKUBE_HOME: ~/.minikube is not writable"
  fi
fi

# kubectl context. Only redirect when the user has not chosen a kubeconfig and
# the default location is unusable.
if [[ -z "${KUBECONFIG:-}" ]] && ! _is_writable "${HOME}/.kube"; then
  KUBECONFIG="${PROJECT_ROOT}/.kube/config"
  export KUBECONFIG
  STATE_FALLBACK_REASON="${STATE_FALLBACK_REASON:+${STATE_FALLBACK_REASON}; }KUBECONFIG: ~/.kube is not writable"
fi

export MINIKUBE_HOME="${MINIKUBE_HOME:-}" KUBECONFIG="${KUBECONFIG:-}"

# --- logging -----------------------------------------------------------------
# Respect NO_COLOR (https://no-color.org) and non-TTY output.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'; _C_DIM=$'\033[2m'
else
  _C_RESET=""; _C_RED=""; _C_GREEN=""; _C_YELLOW=""; _C_BLUE=""; _C_DIM=""
fi
export _C_RESET _C_RED _C_GREEN _C_YELLOW _C_BLUE _C_DIM

log()   { printf '%s==>%s %s\n' "$_C_BLUE"   "$_C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$_C_GREEN"  "$_C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
err()   { printf '%s err%s %s\n' "$_C_RED"    "$_C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
detail(){ printf '%s     %s%s\n' "$_C_DIM" "$*" "$_C_RESET"; }

# Report the state-location fallback once, lazily, so callers can surface it
# without every script repeating the logic.
report_state_location() {
  if [[ -n "${STATE_FALLBACK_REASON:-}" ]]; then
    warn "using project-local state: ${STATE_FALLBACK_REASON}"
    detail "minikube home : ${MINIKUBE_HOME:-<default>}"
    detail "kubeconfig    : ${KUBECONFIG:-<default>}"
    detail "your global ~/.kube/config will NOT see this cluster"
  fi
}

# --- preconditions -----------------------------------------------------------
require_cmd() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "required command not found: ${cmd}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || die "install the missing tools and retry"
}

# Docker must be running before minikube can create a container-based cluster.
require_docker() {
  require_cmd docker
  if ! docker info >/dev/null 2>&1; then
    die "the Docker daemon is not reachable.
     Start Docker Desktop (or colima) and re-run.
     Verify with: docker info"
  fi
}

# Fail early, with a useful message, if no cluster is reachable.
require_cluster() {
  require_cmd kubectl
  if ! kubectl cluster-info >/dev/null 2>&1; then
    die "no Kubernetes cluster is reachable with the current context.
     Start one with: ${SCRIPTS_DIR}/setup.sh"
  fi
}

# True when minikube reports the named cluster as Running.
cluster_is_running() {
  minikube status --profile "${CLUSTER_NAME}" >/dev/null 2>&1
}

# --- waiting -----------------------------------------------------------------
# wait_for <description> <timeout-seconds> <command...>
# Polls until the command succeeds or the timeout expires.
wait_for() {
  local description="$1" timeout="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  log "waiting up to ${timeout}s for ${description}"
  while true; do
    if "$@" >/dev/null 2>&1; then
      ok "${description}"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      err "timed out after ${timeout}s waiting for ${description}"
      return 1
    fi
    sleep 2
  done
}

# wait_for_rollout <namespace> <deployment>
wait_for_rollout() {
  local ns="$1" deploy="$2"
  wait_for "rollout of ${ns}/${deploy}" 300 \
    kubectl rollout status "deployment/${deploy}" -n "${ns}" --timeout=10s
}

# --- assertions --------------------------------------------------------------
assert_namespace() {
  local ns="$1"
  kubectl get namespace "${ns}" >/dev/null 2>&1 \
    || die "namespace '${ns}' does not exist - run scripts/setup.sh or scripts/apply.sh first"
}

assert_deployment() {
  local ns="$1" deploy="$2"
  kubectl get deployment "${deploy}" -n "${ns}" >/dev/null 2>&1 \
    || die "deployment '${ns}/${deploy}' does not exist - run scripts/apply.sh first"
}

# --- misc --------------------------------------------------------------------
# Print the ready replica count of a deployment, or REFUSE with a non-zero exit
# and empty stdout if it is not a number.
#
# Callers use this to establish a baseline and then assert recovery *relative* to
# it ("ready count returns to what it was") rather than against a hardcoded
# literal. A literal is the bug this helper exists to prevent: the HPA's
# memory-bound fixed point (docs/design.md section 5) holds at 5, 6 or 7 and
# cannot descend to `minReplicas: 3`, so any `== 3` predicate is unreachable at
# the natural steady state - it wastes the full timeout and then reports a
# failure that did not happen.
#
# The numeric check mirrors baseline_replicas: stdout is the return value, so a
# broken metric read must never be adopted as a count. All diagnostics go to
# stderr for the same reason.
deployment_ready_replicas() {
  local ns="${1:-${K8S_NAMESPACE}}" deploy="${2:-demo-api}"
  local value

  value="$(kubectl get deployment "${deploy}" -n "${ns}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"

  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    {
      err "could not read a numeric ready-replica count for ${deploy} in ${ns} (got '${value:-<empty>}')"
      detail "a workload scaled to zero reports no readyReplicas field at all;"
      detail "refusing to return a non-numeric value that a caller would treat as a baseline"
    } >&2
    return 1
  fi

  printf '%s' "${value}"
}

# Print the pod names of a deployment, one per line.
deployment_pods() {
  local ns="$1" deploy="$2"
  kubectl get pods -n "${ns}" \
    -l "app.kubernetes.io/name=${deploy}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

# Ask the user to confirm. Behaviour is deliberately fail-closed:
#
#   ASSUME_YES=1        -> proceed (explicit opt-in, e.g. --yes)
#   stdin is not a TTY  -> REFUSE, and say how to opt in
#   stdin is a TTY      -> prompt and wait for an answer
#
# The TTY guard exists because a bare `read` on a non-TTY stdin blocks forever
# when stdin is an open pipe that never delivers data and never reaches EOF.
# That is the normal shape of stdin under an agent harness, a CI runner, or
# `... | script`, so a prompt would hang with no visible message and no way to
# answer. Failing closed is the only safe default for a destructive action: a
# missing answer must never be read as consent.
confirm() {
  local prompt="${1:-Continue?}" reply=""
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    detail "ASSUME_YES=1, auto-confirming: ${prompt}"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    warn "cannot prompt (stdin is not a terminal): ${prompt}"
    detail "assuming NO. Re-run with --yes if you intend to proceed unattended."
    return 1
  fi
  read -r -p "${prompt} [y/N] " reply || return 1
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# Gate a mutating entrypoint on explicit consent.
#
# confirm() lets a caller skip one step and carry on; this refuses the whole
# run, and is used at the top of scripts that have no read-only mode at all.
# Without it, a script like apply.sh would change the cluster the moment it was
# invoked from anything non-interactive - a CI job, a wrapper, an agent harness -
# because there would be no prompt to answer and no --yes to notice the absence
# of.
consent_or_die() {
  local prompt="$1"
  if confirm "${prompt}"; then
    return 0
  fi
  die "refusing to continue without confirmation (no TTY and no --yes)"
}

# --- safe apply --------------------------------------------------------------
# Project policy (CONTRIBUTING.md safety rule 1): always run a server-side dry-run
# before applying. A dry-run that the API server *accepts* is authoritative -
# it runs the real admission chain and schema validation.
#
# The subtlety: a dry-run can also fail for reasons that have nothing to do
# with the manifest being wrong - the API server is unreachable, or the CRD for
# a custom resource is not installed yet. Treating those as validation failures
# would make the script unusable. So the two cases are distinguished explicitly,
# and a genuine validation refusal aborts rather than falling through to a
# blind apply.
apply_manifest() {
  local manifest="$1"; shift
  local extra=("$@")
  local name; name="$(basename "${manifest}")"
  local out

  if out="$(kubectl apply --dry-run=server -f "${manifest}" "${extra[@]}" 2>&1)"; then
    kubectl apply -f "${manifest}" "${extra[@]}"
    return 0
  fi

  # Dry-run failed. Decide whether it is our problem or the environment's.
  if grep -qE 'connection refused|failed to download openapi|Unable to connect to the server|couldn.t get current server API group list' <<<"${out}"; then
    warn "server-side dry-run unavailable (API server unreachable); applying ${name} without it"
    kubectl apply -f "${manifest}" "${extra[@]}"
    return 0
  fi

  if grep -qE 'no matches for kind|unable to recognize' <<<"${out}"; then
    warn "CRD not installed; applying ${name} without server-side dry-run"
    detail "install the operator that provides this kind, or omit this manifest"
    kubectl apply -f "${manifest}" "${extra[@]}"
    return 0
  fi

  # A real validation failure: refuse to apply.
  err "server-side dry-run REJECTED ${name}:"
  printf '%s\n' "${out}" >&2
  return 1
}

# --- safe delete -------------------------------------------------------------
# Project policy (CONTRIBUTING.md safety rule 1): dry-run server-side before deleting
# too. `kubectl delete --dry-run=server` runs the same admission and finalizer
# logic as a real delete without performing it, so a manifest or RBAC problem
# surfaces before anything is destroyed.
#
# Callers are still responsible for asking the user first (safety rule 2).
safe_delete() {
  local kind="$1" name="$2" ns="${3:-}"
  local nsargs=()
  [[ -n "${ns}" ]] && nsargs=(-n "${ns}")

  if kubectl delete "${kind}" "${name}" "${nsargs[@]}" --dry-run=server >/dev/null 2>&1; then
    kubectl delete "${kind}" "${name}" "${nsargs[@]}"
    return 0
  fi

  warn "server-side dry-run of 'delete ${kind}/${name}' failed - not deleting"
  detail "inspect with: kubectl get ${kind} ${name} ${nsargs[*]:-}"
  return 1
}
# --- baseline sampling guard --------------------------------------------------
#
# Some scenarios measure a *transition*: "the HPA scaled from N to M". Those need
# a baseline (N) that is only valid if it was sampled before the thing that
# causes the transition. Sampled afterwards it can already contain the effect,
# and the comparison "M > N" can then never become true.
#
# That failure is silent and expensive: the scenario burns its whole timeout and
# reports "did not scale" on a system that scaled correctly. It was observed for
# real in the cpu-load scenario, whose load generator declares replicas: 1 - so
# applying it started the load immediately, the HPA went 3 -> 10 unprompted, and
# the baseline would have been read as 10.
#
# The guard below makes the ordering a hard precondition instead of a comment.
# Callers cannot obtain a baseline while the load generator is running; the read
# fails loudly rather than returning a plausible-looking wrong number.

# Running replicas of the load generator (from .status, i.e. reality rather than
# intent). Returns 0 when the deployment is absent or unreadable, so a missing
# fixture reads as "idle" rather than blocking the caller.
loadgen_running_replicas() {
  local ns="$1" deploy="${2:-load-generator}" value
  value="$(kubectl get deployment "${deploy}" -n "${ns}" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || true)"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "${value}"
}

# Block until the load generator reports no running replicas.
wait_loadgen_idle() {
  local ns="$1" timeout="$2" deploy="${3:-load-generator}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    [[ "$(loadgen_running_replicas "${ns}" "${deploy}")" == "0" ]] && return 0
    sleep 2
  done
  return 1
}

# baseline_replicas <namespace> <deployment> [loadgen]
#
# Prints the replica count the HPA is about to scale FROM, or returns non-zero
# without printing anything if the load generator is running. The refuse-loudly
# behaviour is the point: it makes "sample the baseline after starting load"
# structurally impossible rather than merely discouraged.
baseline_replicas() {
  local ns="$1" deploy="$2" loadgen="${3:-load-generator}"
  local running value

  running="$(loadgen_running_replicas "${ns}" "${loadgen}")"
  if [[ "${running}" != "0" ]]; then
    # Every diagnostic here goes to STDERR, including the `detail` lines.
    #
    # This function's stdout is its return value, so anything written there is
    # read by the caller as data. `detail` writes to stdout by default, which
    # meant a refusal emitted this explanation as though it were a replica
    # count - and a caller that ignored the exit status would adopt the text as
    # its baseline, reintroducing the exact bug this guard exists to prevent.
    # (Caught by the "guard: stdout stays empty" check in scripts/smoke-test.sh.)
    {
      err "refusing to sample the baseline: ${loadgen} is already running (${running} replica(s))"
      detail "a baseline must be read while ${loadgen} is idle"
      detail "read after load starts it may already include the HPA's scale-up, and"
      detail "'replicas > baseline' could never become true - a false failure"
    } >&2
    return 1
  fi

  value="$(kubectl get deployment "${deploy}" -n "${ns}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)"

  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    err "could not read a numeric replica count for ${deploy} (got '${value:-<empty>}')"
    return 1
  fi

  printf '%s' "${value}"
}

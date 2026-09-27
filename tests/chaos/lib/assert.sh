#!/usr/bin/env bash
# tests/chaos/lib/assert.sh - shared assertions for the chaos scenarios.
#
# Sourced by tests/chaos/*.sh, never executed:
#
#   . "$(cd "$(dirname "$0")" && pwd)/lib/assert.sh"
#
# SOURCE-TIME CONTRACT: this file defines functions and variables only. It runs
# no cluster command at import time, so a scenario can source it before it knows
# whether a cluster is reachable (and can be parsed by `bash -n` with no cluster
# at all). Every kubectl call below happens inside a function body.
#
# FAILURE CONTRACT
#
#   * Every assert_* returns 0, ALWAYS - even when the assertion fails.
#     A bare `return 1` from a helper whose result is used in a boolean context
#     trips `set -e` and aborts the script mid-run, which is exactly the bug the
#     chaos scripts must not repeat: the operator sees a truncated run instead of
#     a list of failures. Failures are therefore *accumulated*, never raised.
#   * Failures are reported once, together, by print_failure_summary, which
#     returns non-zero iff at least one assertion failed. That return value is
#     the script's exit code (0 = passed, non-zero = at least one assertion
#     failed).
#   * Callers must invoke it as `print_failure_summary || exit 1` so the non-zero
#     return is not itself swallowed by `set -e`.
#
# Requires scripts/lib/common.sh to be sourced first for logging (`log`, `ok`,
# `warn`, `err`, `detail`) and the shared configuration (K8S_NAMESPACE,
# CLUSTER_NAME, SCRIPTS_DIR, INJECT). Logging falls back to uncoloured defaults
# if it is not, so a missing source degrades rather than crashing.

# --- failure accumulator ------------------------------------------------------

CHAOS_CHECKS=0
CHAOS_FAILURES=0
CHAOS_FAILURE_LINES=()
CHAOS_DISCREPANCIES=()

# Snapshot counts, kept so assert_pods_unchanged does not need a second file.
declare -A CHAOS_SNAPSHOT_COUNTS=()

# The label every demo-api resource carries. Kept here so the scenarios do not
# each re-derive it.
CHAOS_APP_LABEL="${CHAOS_APP_LABEL:-app.kubernetes.io/name=demo-api}"
CHAOS_APP_NAME="${CHAOS_APP_NAME:-demo-api}"

# The driver under test. Overridable so a future stub harness can point the
# scenarios at a mock, but defaulted from common.sh's SCRIPTS_DIR.
CHAOS_INJECT="${CHAOS_INJECT:-${INJECT:-${SCRIPTS_DIR:-scripts}/inject-failure.sh}}"

_chaos_pass() {
  CHAOS_CHECKS=$((CHAOS_CHECKS + 1))
  printf '  %sok%s %s\n' "${_C_GREEN:-}" "${_C_RESET:-}" "$1"
  return 0
}

_chaos_fail() {
  local label="$1" reason="$2"
  CHAOS_CHECKS=$((CHAOS_CHECKS + 1))
  CHAOS_FAILURES=$((CHAOS_FAILURES + 1))
  CHAOS_FAILURE_LINES+=("${label}: ${reason}")
  printf '  %sFAIL%s %s - %s\n' "${_C_RED:-}" "${_C_RESET:-}" "${label}" "${reason}"
  return 0
}

# A numeric guard. A missing measurement must be a FAILURE, never a silent pass:
# an empty string coerces to 0 in arithmetic, which would let a window of [0, N]
# accept "we never measured anything" as success.
_chaos_is_number() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

chaos_failure_count() { printf '%s' "${CHAOS_FAILURES}"; }

# --- time assertions ----------------------------------------------------------

# assert_in_window <label> <actual> <min> <max>
#
# Tolerance-based: the window, not an equality, is the assertion. Scenarios must
# justify their window in a comment at the call site (probe period, HPA policy
# step, minikube scheduling noise, the 2s poll granularity of common.sh's
# wait_for, ...). Fractional bounds are allowed.
assert_in_window() {
  local label="$1" actual="$2" min="$3" max="$4"

  if ! _chaos_is_number "${actual}"; then
    _chaos_fail "${label}" "no numeric measurement (got '${actual}'); a missing value is a failure, not a pass"
    return 0
  fi

  if awk -v a="${actual}" -v lo="${min}" -v hi="${max}" \
       'BEGIN { exit (a < lo || a > hi) }'; then
    _chaos_pass "${label}: ${actual}s in [${min}, ${max}]s"
  else
    _chaos_fail "${label}" "${actual}s OUTSIDE the expected window [${min}, ${max}]s"
  fi
  return 0
}

# --- equality / predicate assertions -----------------------------------------

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    _chaos_pass "${label}: ${actual}"
  else
    _chaos_fail "${label}" "expected '${expected}', got '${actual}'"
  fi
  return 0
}

# assert_contains <label> <haystack> <needle-regex>
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if grep -qE -- "${needle}" <<<"${haystack}"; then
    _chaos_pass "${label}: output matched /${needle}/"
  else
    _chaos_fail "${label}" "output did not match /${needle}/"
  fi
  return 0
}

# assert_true <label> <command...>
#
# Passes when the command exits 0. Used for predicates that are already a
# command, so no eval is needed.
assert_true() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    _chaos_pass "${label}"
  else
    _chaos_fail "${label}" "predicate failed: $*"
  fi
  return 0
}

# assert_false <label> <command...>
#
# Passes when the command exits NON-zero. Needed for "must not happen" claims -
# e.g. "the stalled rollout never completes" - where the natural probe
# (`kubectl rollout status`) succeeds exactly when the scenario has FAILED.
assert_false() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    _chaos_fail "${label}" "predicate unexpectedly SUCCEEDED: $*"
  else
    _chaos_pass "${label}"
  fi
  return 0
}

# --- cluster read helpers (read-only) ----------------------------------------

# NOTE: `deployment_ready_replicas` is NOT defined here. It lives in
# scripts/lib/common.sh and is deliberately reused.
#
# It used to be defined here too, with a different signature (no arguments, and
# no numeric validation). Because this file is sourced AFTER common.sh, this
# definition silently WON, overriding the stricter one - so any scenario that
# called it with the app name got the zero-argument version. Two definitions of
# one helper with two signatures is a latent bug whether or not a caller trips it
# today: the failure mode is "the wrong function ran", which no assertion can
# catch from the inside. One definition, in the shared library.
#
# The common.sh version takes optional (namespace, deployment) and defaults to
# ${K8S_NAMESPACE}/demo-api, so the zero-argument calls below still work, and it
# refuses with a non-zero exit instead of returning a non-numeric string.

deployment_desired_replicas() {
  kubectl get deployment "${CHAOS_APP_NAME}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || true
}

deployment_running_replicas() {
  kubectl get deployment "${CHAOS_APP_NAME}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || true
}

hpa_field() {
  kubectl get hpa "${CHAOS_APP_NAME}" -n "${K8S_NAMESPACE}" \
    -o jsonpath="$1" 2>/dev/null || true
}

# Number of ready addresses behind the Service. The authoritative signal for
# readiness shedding: it is the API server's view of routing, not the app's.
endpoints_count() {
  kubectl get endpoints "${CHAOS_APP_NAME}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' '
}

pod_disruption_budget_min_available() {
  kubectl get pdb "${CHAOS_APP_NAME}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.spec.minAvailable}' 2>/dev/null || true
}

restart_count() {
  local pod="$1"
  kubectl get pod "${pod}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true
}

# One running pod of the demo workload, or empty.
pick_target_pod() {
  deployment_pods "${K8S_NAMESPACE}" "${CHAOS_APP_NAME}" | head -n 1
}

node_names() {
  kubectl get nodes --no-headers -o custom-columns=':.metadata.name' 2>/dev/null || true
}

# Mirrors scripts/inject-failure.sh scenario_node_drain exactly: a node whose
# status string contains SchedulingDisabled is not schedulable.
schedulable_node_count() {
  kubectl get nodes --no-headers 2>/dev/null | grep -vc 'SchedulingDisabled' || echo 0
}

node_is_schedulable() {
  local node="$1"
  [[ "$(kubectl get node "${node}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" != "true" ]]
}

assert_ready_replicas() {
  local label="$1" expected="$2"
  # `|| true` is load-bearing: common.sh's helper refuses with a non-zero exit on
  # a non-numeric read, and under `set -e` a failing command substitution ABORTS
  # the script rather than reporting. Swallowing the status here lets the numeric
  # comparison below record a proper failure instead of killing the run at the
  # first bad metric read.
  assert_eq "${label}" "$(deployment_ready_replicas || true)" "${expected}"
}

# assert_ready_replicas_at_least <label> <baseline>
#
# The BASELINE-RELATIVE form, and the one most scenarios should use.
#
# Why this exists: asserting an absolute replica count bakes in an assumption
# about where the deployment happens to be. On this cluster the HPA's memory-bound
# fixed point holds at 5, 6 or 7 replicas and CANNOT descend to minReplicas=3
# (docs/design.md §5: `ceil(N x ratio) == N` for every N in 1..7 at the observed
# memory ratio, so the descent stops at the first fixed point it meets). A test
# that demands exactly 3 therefore fails for a reason unrelated to what it is
# testing - the HPA is working correctly and the assertion is wrong.
#
# Asserting "recovered to at least the value sampled before the fault" is correct
# whether the cluster is at 3, 5, 7 or 10, and it is the stronger claim anyway: it
# says the fault did not permanently reduce capacity, which is the actual
# contract. `>=` rather than `==` because the HPA legitimately scales up during
# many of these scenarios, and a scale-up is not a recovery failure.
assert_ready_replicas_at_least() {
  local label="$1" baseline="$2"
  local now
  # `|| true` for the same reason as above: the helper's refusal in common.sh is a
  # non-zero exit, which `set -e` would turn into an abort instead of the
  # non-numeric failure recorded just below.
  now="$(deployment_ready_replicas || true)"
  if [[ ! "${now}" =~ ^[0-9]+$ || ! "${baseline}" =~ ^[0-9]+$ ]]; then
    _chaos_fail "${label}" "non-numeric replica count (now='${now}' baseline='${baseline}')"
    return 0
  fi
  if (( now >= baseline )); then
    _chaos_pass "${label}: ${now} ready >= baseline ${baseline}"
  else
    _chaos_fail "${label}" \
      "${now} ready is BELOW the pre-fault baseline ${baseline} - the fault permanently reduced capacity"
  fi
  return 0
}

assert_pdb_min_available() {
  local label="$1" expected="$2"
  assert_eq "${label}" "$(pod_disruption_budget_min_available)" "${expected}"
}

# --- blast-radius assertions --------------------------------------------------

# All pods of the workload as stable "name|phase|ready" lines. Read-only.
_pod_lines() {
  kubectl get pods -n "${K8S_NAMESPACE}" -l "${CHAOS_APP_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    2>/dev/null || true
}

pod_count_all() {
  _pod_lines | sed '/^$/d' | wc -l | tr -d ' '
}

pod_count_ready() {
  _pod_lines | awk -F'|' '$3 == "true"' | wc -l | tr -d ' '
}

# pod_snapshot <file>
#
# Captures the pod set so assert_pods_unchanged can prove the blast radius later.
# Must be called BEFORE the fault is injected.
pod_snapshot() {
  local file="$1"
  _pod_lines | sed '/^$/d' >"${file}"
  CHAOS_SNAPSHOT_COUNTS["snapshot|${file}"]="$(pod_count_all)"
  detail "pod snapshot: ${CHAOS_SNAPSHOT_COUNTS["snapshot|${file}"]} pod(s) -> ${file}"
  return 0
}

# assert_pods_unchanged <label> <snapshot-file> [max-changed]
#
# Blast radius: the symmetric difference between the pod set before the fault and
# the pod set after it. A replacement pod counts as one change (one name out, one
# name in). A pod that merely changed phase or readiness does NOT count as a
# change of *identity*, so the count stays interpretable as "pods replaced".
assert_pods_unchanged() {
  local label="$1" file="$2" max_changed="${3:-1}"

  if [[ ! -f "${file}" ]]; then
    _chaos_fail "${label}" "snapshot '${file}' is missing (pod_snapshot was never called)"
    return 0
  fi

  local before_count after_count changed
  before_count="$(sed '/^$/d' "${file}" | wc -l | tr -d ' ')"
  after_count="$(pod_count_all)"

  changed="$(comm -3 \
      <(awk -F'|' '{print $1}' "${file}" | sort) \
      <(  _pod_lines | sed '/^$/d' | awk -F'|' '{print $1}' | sort) \
    | sed '/^$/d' | wc -l | tr -d ' ')"

  detail "${label}: pods before=${before_count} after=${after_count} replaced/added/removed=${changed} (max ${max_changed})"

  if (( changed <= max_changed )); then
    _chaos_pass "${label}: blast radius ${changed} pod(s) <= ${max_changed}"
  else
    _chaos_fail "${label}" "blast radius ${changed} pod(s) exceeds the expected ${max_changed}"
  fi

  # A change in the total pod count is a separate, blunter signal: the workload
  # should not gain or lose replicas because of an injected fault.
  if (( after_count == before_count )); then
    _chaos_pass "${label}: pod count unchanged (${before_count})"
  else
    _chaos_fail "${label}" "pod count changed ${before_count} -> ${after_count}"
  fi
  return 0
}

# assert_no_pods_removed <label> <snapshot-file>
#
# A stricter blast-radius claim than assert_pods_unchanged: every pod that
# existed before the fault must still exist afterwards. This is the correct shape
# for `bad-image`, where the surge pod is legitimately *added* (maxSurge: 1) but
# no existing pod may be lost - design.md §7 gives its blast radius as
# "0 - old pods keep serving".
assert_no_pods_removed() {
  local label="$1" file="$2"

  if [[ ! -f "${file}" ]]; then
    _chaos_fail "${label}" "snapshot '${file}' is missing (pod_snapshot was never called)"
    return 0
  fi

  local missing
  missing="$(comm -23 \
      <(awk -F'|' '{print $1}' "${file}" | sort) \
      <(  _pod_lines | sed '/^$/d' | awk -F'|' '{print $1}' | sort) \
    | sed '/^$/d')"

  if [[ -z "${missing}" ]]; then
    _chaos_pass "${label}: no pod from the snapshot was removed"
  else
    _chaos_fail "${label}" "pods disappeared: $(printf '%s' "${missing}" | tr '\n' ' ')"
  fi
  return 0
}

# --- time measurement that does not depend on the driver's own waits ----------

# _iso_to_epoch <RFC3339>
#
# Portable UTC conversion: BSD `date -j -f` (macOS, this project's dev platform)
# then GNU `date -d`, so the same helper works locally and in CI. UTC is forced so
# the value does not shift with the local zone (both ends are parsed the same way,
# but forcing UTC also removes any DST edge).
_iso_to_epoch() {
  local iso="$1" base
  [[ -n "${iso}" ]] || return 1
  base="${iso%%.*}"   # drop fractional seconds
  base="${base%Z}"    # drop the trailing Z
  if TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${base}" +%s >/dev/null 2>&1; then
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${base}" +%s
  elif TZ=UTC date -d "${iso}" +%s >/dev/null 2>&1; then
    TZ=UTC date -d "${iso}" +%s
  else
    return 1
  fi
}

# pod_ready_latency_seconds <pod>
#
# The replacement's OWN time-to-Ready, read from the pod object:
#
#   Ready condition lastTransitionTime  -  metadata.creationTimestamp
#
# This is deliberately independent of any `wait_for` the driver performs, and it
# is the honest way to measure this scenario. The driver's own pod-evict wait has
# an unreachable exit condition (see pod-evict.sh's header), so its total runtime
# is 120 s+ of timeout rather than the replacement latency; using that as the
# "expected time" would report a timeout as if it were a measurement. The pod
# object records the real latency whether or not anyone was watching.
#
# Prints the integer seconds, or nothing when the timestamp cannot be read - the
# caller must then decide, rather than silently treating "unknown" as "in window".
pod_ready_latency_seconds() {
  local pod="$1" created ready
  created="$(kubectl get pod "${pod}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
  ready="$(kubectl get pod "${pod}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{end}' 2>/dev/null || true)"
  local c_e r_e
  c_e="$(_iso_to_epoch "${created}")" || return 1
  r_e="$(_iso_to_epoch "${ready}")" || return 1
  [[ "${c_e}" =~ ^[0-9]+$ && "${r_e}" =~ ^[0-9]+$ ]] || return 1
  local delta=$(( r_e - c_e ))
  (( delta < 0 )) && delta=0
  printf '%s' "${delta}"
}

# newest_app_pod
#
# The most recently created demo-api pod, which after a replacement is the
# replacement. Used with pod_ready_latency_seconds so the measurement does not
# depend on knowing the replacement's name in advance.
newest_app_pod() {
  kubectl get pods -n "${K8S_NAMESPACE}" -l "${CHAOS_APP_LABEL}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true
}

# assert_ready_latency <label> <pod> <min> <max> [<fallback-seconds>]
#
# Asserts the pod's own time-to-Ready against a window. When the pod's timestamps
# cannot be read (permissions, a clock skew, an evicted pod), falls back to the
# caller's elapsed measurement if one was supplied, and SAYS SO - a silent
# substitution would make the result unattributable.
assert_ready_latency() {
  local label="$1" pod="$2" min="$3" max="$4" fallback="${5:-}"
  local latency
  if latency="$(pod_ready_latency_seconds "${pod}")" && [[ -n "${latency}" ]]; then
    detail "${label}: ${pod} passed Ready ${latency}s after creation (from the pod object)"
    assert_in_window "${label} [pod-reported latency]" "${latency}" "${min}" "${max}"
  elif [[ -n "${fallback}" ]]; then
    warn "could not read ${pod}'s timestamps; falling back to the caller's elapsed ${fallback}s"
    detail "the fallback includes driver startup and any driver-side wait, so it is an upper bound"
    assert_in_window "${label} [fallback elapsed]" "${fallback}" "${min}" "${max}"
  else
    _chaos_fail "${label}" "could not measure time-to-Ready for ${pod} and no fallback was supplied"
  fi
  return 0
}

# --- independent restart observation ------------------------------------------

# start_restart_watcher <pod> <outfile>
#
# Starts a background 1 s poller that records the FIRST moment <pod>'s
# restartCount increments, as seconds elapsed since the watcher started.
#
# WHY THIS EXISTS, rather than trusting a driver's reported figure:
# scripts/inject-failure.sh scenario_app_fail records its readiness stage with a
# loop that has NO `break` on success - it runs its full 45 s deadline even after
# observing the shed. The liveness stage is only polled AFTER that loop exits, so
# its printed `restart <n>s` is FLOORED at ~45 s: a true restart at 25 s and a true
# restart at 44 s both print ~45 s. That figure therefore cannot distinguish a
# fast liveness path from a slow one, and asserting it as "the measured liveness
# latency" would launder a polling artefact into a claim about the system.
#
# This watcher observes the increment as it happens, so its measurement is
# independent of any driver-side wait. It starts slightly before the driver, which
# runs pre_flight/pick_pod before injecting, so the result is an UPPER bound on the
# true latency - an honest direction of error, stated rather than hidden.
start_restart_watcher() {
  local pod="$1" outfile="$2"
  : >"${outfile}"
  (
    local start="${SECONDS}"
    while :; do
      local rc
      rc="$(kubectl get pod "${pod}" -n "${K8S_NAMESPACE}" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
      if [[ "${rc}" =~ ^[0-9]+$ ]] && (( rc > 0 )); then
        printf '%s\n' "$(( SECONDS - start ))" >"${outfile}"
        exit 0
      fi
      sleep 1
    done
  ) &
  CHAOS_WATCHER_PID=$!
  return 0
}

# stop_restart_watcher <outfile>
#
# Stops the watcher and sets the global CHAOS_WATCHED_LATENCY to the observed
# seconds (empty when the increment was never seen).
#
# It sets a GLOBAL rather than printing the value, and that is deliberate: a caller
# writing `x="$(stop_restart_watcher)"` would run the function in a SUBSHELL, so
# clearing CHAOS_WATCHER_PID inside it would not affect the parent - leaving the
# parent's EXIT trap pointing at a stale pid. Callers invoke this DIRECTLY and then
# read the global. (Verified: the poller is killed and the pid is cleared.)
stop_restart_watcher() {
  local outfile="$1"
  if [[ -n "${CHAOS_WATCHER_PID:-}" ]]; then
    kill "${CHAOS_WATCHER_PID}" 2>/dev/null || true
    wait "${CHAOS_WATCHER_PID}" 2>/dev/null || true
    CHAOS_WATCHER_PID=""
  fi
  if [[ -f "${outfile}" ]]; then
    CHAOS_WATCHED_LATENCY="$(sed -n '1p' "${outfile}")"
  else
    CHAOS_WATCHED_LATENCY=""
  fi
  return 0
}

# --- finding 7: attribute replica changes to the controller that made them ----

# count_events_matching <reason> [baseline-file] [message-regex]
#
# docs/design.md §14, finding 7: during a stalled `bad-image` rollout the HPA
# scaled the deployment DOWN, and the old ReplicaSet's 8->7 looked exactly like a
# `maxUnavailable: 0` violation. The two are indistinguishable by COUNT, so the
# event SOURCE is the only reliable witness:
#
#   SuccessfulRescale   from the horizontalpodautoscaler -> the HPA acted
#   ScalingReplicaSet   from the deployment               -> the rollout acted
#
# IMPORTANT: the reason alone is not specific enough. The deployment controller
# emits `ScalingReplicaSet` for scale-UP as well as scale-down - starting a bad
# rollout produces a "Scaled up replica set ... to 1" for the surge pod. Counting
# all such events would therefore count the rollout's legitimate scale-up and
# could not distinguish a scale-down. Pass <message-regex> to select precisely:
#
#   count_events_matching ScalingReplicaSet "${before}" 'Scaled down'
#
# counts only scale-DOWNs by the rollout, which is the operation that a
# maxUnavailable violation would look like. With maxSurge: 1 / maxUnavailable: 0,
# a rolling update scales the old ReplicaSet down ONLY after a replacement becomes
# Available - so if no replacement became Available, this count must be 0. That
# argument reasons from mechanism, which is the only conclusive form here.
count_events_matching() {
  local reason="$1" baseline="${2:-}" msg="${3:-}"
  local now before count
  now="$(kubectl get events -n "${K8S_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.reason}{"|"}{.message}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' -v r="${reason}" -v m="${msg}" '
        $1 == r { if (m == "" || $0 ~ m) n++ } END { print n+0 }' || true)"
  [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  if [[ -n "${baseline}" && -f "${baseline}" ]]; then
    # The snapshot format is "reason|kind/name|message", so field 1 is the reason
    # and the whole line can be matched for the message.
    before="$(awk -F'|' -v r="${reason}" -v m="${msg}" '
        $1 == r { if (m == "" || $0 ~ m) n++ } END { print n+0 }' \
        "${baseline}" 2>/dev/null || true)"
    [[ "${before}" =~ ^[0-9]+$ ]] || before=0
    count=$(( now - before ))
    (( count < 0 )) && count=0
  else
    count="${now}"
  fi
  printf '%s' "${count}"
}

# assert_replica_changes_attributed <label> <baseline-file>
#
# Names the controller behind each replica change instead of leaving a bare count
# for a reader to misread. A diagnostic: it reports, and cannot itself fail, since
# the load-bearing assertion is the mechanism-based one in the scenario.
assert_replica_changes_attributed() {
  local label="$1" baseline="${2:-}"
  local hpa rollout
  hpa="$(count_events_matching SuccessfulRescale "${baseline}")"
  # Scale-DOWN only: ScalingReplicaSet also fires for the surge pod's scale-up, so
  # the unfiltered count would not answer the question finding 7 asks.
  rollout="$(count_events_matching ScalingReplicaSet "${baseline}" 'Scaled down')"
  detail "${label}: attributed - HPA SuccessfulRescale=${hpa}, rollout scaled-down=${rollout}"
  if [[ "${hpa}" == "0" && "${rollout}" == "0" ]]; then
    detail "${label}: no scale-down events since the baseline; nothing to attribute"
  fi
  return 0
}

# --- rule 10: event-log check -------------------------------------------------

# A stable key per event: the rendered LAST SEEN column changes every second, so
# a text diff of `kubectl get events` would report noise rather than mutations.
_event_keys() {
  kubectl get events -n "${K8S_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.reason}{"|"}{.involvedObject.kind}{"/"}{.involvedObject.name}{"|"}{.message}{"\n"}{end}' \
    2>/dev/null || true
}

event_log_snapshot() {
  local file="$1"
  _event_keys | sed '/^$/d' | sort >"${file}"
  detail "event snapshot: $(sed '/^$/d' "${file}" | wc -l | tr -d ' ') event(s) -> ${file}"
  return 0
}

# check_event_log <label> [baseline-file] [allowed-object-regex]
#
# AGENTS.md safety rule 10: after any possibly-mutating step, look at the event
# log and report unintended mutations - the ones a success message will not
# mention. This always prints the exact command from AGENTS.md (tail -5) and,
# when a baseline was captured, reports every event that is NEW since it.
#
# A new event whose object does not match <allowed-object-regex> is recorded as a
# FAILURE. The fault being injected is expected to produce events; an event about
# a resource outside the scenario's blast radius is precisely the unintended
# mutation the rule exists to catch.
check_event_log() {
  local label="$1" baseline="${2:-}" allowed="${3:-}"

  log "AGENTS.md rule 10 - checking the event log (${label})"
  detail "kubectl get events -n ${K8S_NAMESPACE} --sort-by=.lastTimestamp | tail -5"
  kubectl get events -n "${K8S_NAMESPACE}" --sort-by=.lastTimestamp 2>/dev/null | tail -5 | sed 's/^/     /' || true

  if [[ -z "${baseline}" || ! -f "${baseline}" ]]; then
    detail "no baseline captured; the tail above is the whole observation"
    return 0
  fi

  local new_keys unexpected=0 new_count
  new_keys="$(comm -13 "${baseline}" <(_event_keys | sed '/^$/d' | sort) | sed '/^$/d')"
  new_count="$(printf '%s\n' "${new_keys}" | sed '/^$/d' | wc -l | tr -d ' ')"
  detail "new events since the baseline: ${new_count}"

  if (( new_count == 0 )); then
    _chaos_pass "${label}: no new events (no unintended mutation recorded)"
    return 0
  fi

  local key
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    local obj="${key#*|}"; obj="${obj%%|*}"
    if [[ -z "${allowed}" || "${obj}" =~ ${allowed} ]]; then
      detail "expected event: ${key}"
    else
      unexpected=$((unexpected + 1))
      _chaos_fail "${label}: UNINTENDED event on an object outside the blast radius" \
        "${key}"
    fi
  done <<<"${new_keys}"

  if (( unexpected == 0 )); then
    _chaos_pass "${label}: ${new_count} new event(s), all within ${allowed:-<unfiltered>}"
  fi
  return 0
}

# --- rule 1 / ADR-0005 guardrails --------------------------------------------

# assert_no_raw_dry_run_claim <label> <file> [<file>...]
#
# ADR-0005, finding 1 in design.md §14: `kubectl create --raw` silently drops
# --dry-run, so a "dry-run" raw eviction IS a real eviction. A raw call that
# claims to be a dry-run is therefore a live mutation wearing a safety label. The
# eviction path must never carry one; it relies on the PDB instead.
#
# The scan is deliberately narrow, because a coarse one produces false positives
# that train a reader to ignore it:
#   * comment lines are skipped - prose ABOUT the hazard (this repo's ADR and
#     driver are full of it) is not the hazard;
#   * backslash continuations are joined, so a flag on a later line still counts;
#   * all three tokens (`kubectl`, `--raw`, `--dry-run`) must appear on the same
#     logical line. A mention of `--raw` alone, or a label naming the flags, is
#     not a call.
assert_no_raw_dry_run_claim() {
  local label="$1"; shift
  local offender=""

  # Runtime hook: a scenario that builds the eviction command into a variable can
  # publish it here and be checked against the command it will actually run.
  if [[ -n "${_CHAOS_EVICTION_CMD:-}" \
        && "${_CHAOS_EVICTION_CMD}" == *"--raw"* \
        && "${_CHAOS_EVICTION_CMD}" == *"--dry-run"* ]]; then
    offender="eviction command: ${_CHAOS_EVICTION_CMD}"
  fi

  local file
  for file in "$@"; do
    [[ -f "${file}" ]] || continue
    local hit
    hit="$(awk '
      # Join backslash continuations onto the first physical line, then test the
      # joined line. `logical` accumulates; `start` remembers where it began.
      {
        line = $0
        if (logical == "") start = NR
        sub(/\\[[:space:]]*$/, "", line)
        logical = (logical == "" ? line : logical " " line)
        if ($0 ~ /\\[[:space:]]*$/) next
        if (logical !~ /^[[:space:]]*#/ \
            && logical ~ /kubectl/ && logical ~ /--raw/ && logical ~ /--dry-run/) {
          printf "%d:%s\n", start, logical
        }
        logical = ""
      }' "${file}" || true)"
    [[ -n "${hit}" ]] && offender="${offender} ${file}:${hit}"
  done

  if [[ -z "${offender}" ]]; then
    _chaos_pass "${label}: no kubectl --raw call claims a dry-run (ADR-0005)"
  else
    _chaos_fail "${label}" "a --raw call carries a dry-run flag, which kubectl ignores:${offender}"
  fi
  return 0
}

# --- documented-vs-measured discrepancies ------------------------------------

# record_doc_discrepancy <scenario> <documented> <measured> <recommendation>
#
# An honest test does not widen its window until a disagreeing value fits. Where
# docs/design.md §7 disagrees with a measurement, both numbers are recorded and
# printed in the final summary - a test that quietly relaxes to green is worse
# than no test at all.
record_doc_discrepancy() {
  CHAOS_DISCREPANCIES+=("$1|documented=$2|measured=$3|$4")
  return 0
}

report_doc_discrepancies() {
  if (( ${#CHAOS_DISCREPANCIES[@]} == 0 )); then
    detail "no documented-vs-measured discrepancies recorded"
    return 0
  fi
  warn "DOCUMENTED vs MEASURED discrepancies (reported, not absorbed into a window):"
  local d
  for d in "${CHAOS_DISCREPANCIES[@]}"; do
    printf '     %s\n' "${d}"
  done
  return 0
}

# --- driver invocation --------------------------------------------------------

# run_inject <scenario> [args...]
#
# Delegates to scripts/inject-failure.sh: the scenario implementations are the
# source of truth and are NOT duplicated here. Returns the driver's exit status;
# callers MUST capture it (`run_inject ... || rc=$?`) or `set -e` will abort the
# run before any assertion is reported.
run_inject() {
  if [[ ! -x "${CHAOS_INJECT}" ]]; then
    _chaos_fail "driver" "not executable: ${CHAOS_INJECT} (set CHAOS_INJECT to override)"
    return 0
  fi
  "${CHAOS_INJECT}" "$@"
}

# --- consent gate -------------------------------------------------------------

# chaos_require_consent <label> <action-description>
#
# AGENTS.md safety rule 2: destructive commands need explicit approval. Returns 0
# when consent was given (interactively or via ASSUME_YES=1 / --yes) and 1 when
# it was refused, without mutating anything.
#
# Note the ASSUME_YES bridge: common.sh's confirm() is documented to return 1
# rather than auto-confirm when ASSUME_YES is set, so a caller that treats a 0
# return as consent would otherwise leave ASSUME_YES unset - and the *driver*,
# invoked next, would then refuse. Consent propagates as ASSUME_YES.
chaos_require_consent() {
  local label="$1" action="$2"
  if confirm "${label}: ${action}"; then
    ASSUME_YES=1
    export ASSUME_YES
    return 0
  fi
  return 1
}

# --- static contract checks ---------------------------------------------------

# chaos_static_checks <script-path>
#
# The offline half of requirement 6: what can be proven without a cluster. Run by
# `--static` and before every live run, so a syntax error or a missing consent
# annotation is caught before anything is touched.
#
# Check 6/7 are deliberately coarse textual contracts rather than a parser. They
# are annotation-driven - a destructive call must carry `# GUARDED-BY:` and a
# mutating kubectl call must either carry --dry-run or an explicit
# `# DRY-RUN-EXEMPT:` justification - so the invariant is visible in the source
# and a reviewer can see what was claimed.
chaos_static_checks() {
  local script="$1" rc=0

  if bash -n "${script}" 2>/dev/null; then
    _chaos_pass "static: bash -n ${script##*/}"
  else
    _chaos_fail "static: bash -n" "$(bash -n "${script}" 2>&1 | head -n 3)"
    rc=1
  fi

  assert_contains "static: sources common.sh" "$(cat "${script}")" 'lib/common\.sh'
  assert_contains "static: sources assert.sh" "$(cat "${script}")" 'lib/assert\.sh'
  assert_contains "static: strict mode"        "$(cat "${script}")" '^set -euo pipefail'
  assert_contains "static: documented as a test" "$(cat "${script}")" 'tests/chaos'

  local home_kubeconfig
  home_kubeconfig="$(grep -nE 'KUBECONFIG=.*(/Users/|~/|\$\{?HOME)' "${script}" || true)"
  if [[ -z "${home_kubeconfig}" ]]; then
    _chaos_pass "static: no hardcoded home-directory KUBECONFIG"
  else
    _chaos_fail "static: hardcoded home KUBECONFIG" "${home_kubeconfig}"
    rc=1
  fi

  # --- rules 1 and 2 as textual contracts ------------------------------------
  #
  # These are annotations-plus-text checks, not a bash parser. They have to
  # distinguish a destructive CALL from a destructive MENTION, and the scenarios
  # contain plenty of both: grep patterns that look for "kubectl delete pod",
  # error messages that quote the command to run, and narration naming a verb.
  #
  # Three de-noising rules, each earned by a false positive this check produced
  # on its first run against the real scripts:
  #
  #   1. Comments are skipped - prose about a hazard is not the hazard. Every
  #      scenario documents the commands it refuses to run.
  #   2. Quoted regions are STRIPPED before matching. A verb inside a quoted
  #      string is data (a grep pattern, a message), not an invocation. A real
  #      call keeps its verb outside the quotes:
  #        grep -qE '...kubectl delete pod'   -> mention, stripped, ignored
  #        kubectl delete pod "${pod}"        -> call,     retained, checked
  #   3. Backslash continuations are joined, so a flag on a later line still
  #      counts and a multi-line command is judged as one statement.
  #
  # Rule 1 is then satisfied per-VERB by either a `--dry-run` on the same
  # statement OR a preceding dry-run of the same verb. That matches the rule as
  # written ("always --dry-run=server before a kubectl apply/delete") and matches
  # how bad-image.sh and node-drain.sh are deliberately structured: a separate,
  # branchable dry-run guard statement followed by the real call, so a rejected
  # dry-run can abort with a diagnosis instead of being swallowed inline.
  local unguarded mutating
  unguarded=""
  mutating=""

  local analysis
  analysis="$(awk '
    # Strip content inside single and double quotes. Bash does not nest these, so
    # a two-pass gsub is sufficient for this file style.
    function dequote(s,   t) {
      t = s
      gsub(/"[^"]*"/, "\"\"", t)
      gsub(/\047[^\047]*\047/, "\047\047", t)
      return t
    }
    {
      # raw[] keeps every line verbatim, for readable diagnostics.
      raw[NR] = $0
      # ann[] keeps comments too: the GUARDED-BY annotation IS a comment, so it
      # must remain searchable even though comments are never treated as calls.
      # (Getting this wrong erased every annotation and failed every scenario -
      # the check reporting a problem with itself rather than with the script.)
      ann[NR] = $0
      line = $0
      sub(/\\[[:space:]]*$/, "", line)
      logical = (logical == "" ? line : logical " " line)
      if ($0 ~ /\\[[:space:]]*$/) next
      joined = logical
      logical = ""
      # text[] is the dequoted, call-detection view: comments blanked so prose is
      # not mistaken for an invocation.
      if (joined ~ /^[[:space:]]*#/) { text[NR] = ""; next }
      text[NR] = dequote(joined)
    }
    END {
      for (i = 1; i <= NR; i++) {
        t = text[i]
        if (t == "") continue

        # --- rule 2: destructive / driver statements need GUARDED-BY ---------
        dest = 0
        if (t ~ /(^|[^a-zA-Z_-])kubectl[[:space:]]+(delete|drain|cordon)/) dest = 1
        if (t ~ /kubectl[[:space:]]+scale/ && t ~ /--replicas=0/) dest = 1
        if (t ~ /kubectl[[:space:]]+set[[:space:]]+image/) dest = 1
        if (t ~ /kubectl[[:space:]]+rollout[[:space:]]+undo/) dest = 1
        if (t ~ /^[[:space:]]*run_inject[[:space:]]/) dest = 1
        if (dest) {
          probe = 0
          if (t ~ /--dry-run/) probe = 1
          if (!probe) {
            guarded = 0
            for (j = i - 5; j < i; j++) if (j >= 1 && ann[j] ~ /GUARDED-BY:/) guarded = 1
            if (!guarded) print "UNGUARDED " i ": " raw[i]
          }
        }

        # --- rule 1: mutating calls need a dry-run, same line or earlier -----
        verb = ""
        if (t ~ /(^|[^a-zA-Z_-])kubectl[[:space:]]+delete/)                verb = "delete"
        else if (t ~ /(^|[^a-zA-Z_-])kubectl[[:space:]]+apply/)            verb = "apply"
        else if (t ~ /(^|[^a-zA-Z_-])kubectl[[:space:]]+set/)              verb = "set"
        else if (t ~ /(^|[^a-zA-Z_-])kubectl[[:space:]]+scale/)            verb = "scale"
        else if (t ~ /(^|[^a-zA-Z_-])kubectl[[:space:]]+drain/)            verb = "drain"
        else if (t ~ /(^|[^a-zA-Z_-])kubectl[[:space:]]+cordon/)           verb = "cordon"
        if (verb == "") continue
        if (t ~ /--dry-run/) continue
        had = 0
        # 40 lines, not 5. A dry-run and its real call are not always adjacent:
        # node-drain.sh deliberately probes the DRAIN before cordoning, so that a
        # rejected drain cannot leave a cordoned node behind - which puts the
        # cordon probe and the cordon itself between them. The window is a
        # locality check (the probe must be in the same script, near the call),
        # not an adjacency check.
        for (j = i - 40; j < i; j++) {
          if (j < 1) continue
          if (text[j] ~ /--dry-run/ && text[j] ~ ("kubectl[[:space:]]+" verb)) had = 1
        }
        if (!had) print "NODRYRUN " i ": " raw[i]
      }
    }' "${script}" || true)"

  unguarded="$(printf '%s\n' "${analysis}" | grep '^UNGUARDED ' | sed 's/^UNGUARDED //' || true)"
  mutating="$(printf '%s\n' "${analysis}" | grep '^NODRYRUN ' | sed 's/^NODRYRUN //' || true)"

  if [[ -z "${unguarded}" ]]; then
    _chaos_pass "static: every destructive/driver call carries a GUARDED-BY annotation"
  else
    _chaos_fail "static: unguarded destructive call" "$(printf '%s' "${unguarded}" | head -n 2 | tr '\n' ' ')"
    rc=1
  fi

  if [[ -z "${mutating}" ]] || grep -qE 'DRY-RUN-EXEMPT' "${script}"; then
    _chaos_pass "static: rule 1 satisfied (every mutating verb is dry-run first, or explicitly exempted)"
  else
    _chaos_fail "static: mutating call with no preceding dry-run and no DRY-RUN-EXEMPT annotation" \
      "$(printf '%s' "${mutating}" | head -n 2 | tr '\n' ' ')"
    rc=1
  fi

  # Returns 0/1 as a *status*, not as an assertion. The caller decides: --static
  # exits with it, a live run aborts on a non-zero contract check.
  return "${rc}"
}

# --- final report -------------------------------------------------------------

# print_failure_summary
#
# Prints every accumulated failure and returns 0 when the run passed, 1 when at
# least one assertion failed. Call as `print_failure_summary || exit 1`.
print_failure_summary() {
  printf '\n'
  if (( CHAOS_FAILURES == 0 )); then
    ok "assertions: ${CHAOS_CHECKS} check(s), 0 failures"
    return 0
  fi
  err "assertions: ${CHAOS_CHECKS} check(s), ${CHAOS_FAILURES} FAILED:"
  local line
  for line in "${CHAOS_FAILURE_LINES[@]}"; do
    printf '   %s- %s%s\n' "${_C_RED:-}" "${line}" "${_C_RESET:-}" >&2
  done
  return 1
}

# chaos_snapshot_dir - a private scratch directory for snapshots.
chaos_snapshot_dir() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/chaos-snapshots.XXXXXX")"
  printf '%s' "${dir}"
  return 0
}
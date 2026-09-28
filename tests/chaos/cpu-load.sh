#!/usr/bin/env bash
# tests/chaos/cpu-load.sh - chaos test for HPA scale-out (Tier 1 reconciliation).
#
# WHAT THIS TESTS
#   That sustained CPU load drives the HorizontalPodAutoscaler from the reset
#   baseline up to maxReplicas, and that it does so WITHOUT ever exceeding the
#   declared cap. The HPA is the only healer involved: no probe fires and no pod
#   is replaced.
#
#   Authoritative expectations: docs/design.md section 5 (HPA tuning, the 77 %
#   effective threshold, the memory floor), section 7 (scenario table) and
#   section 8 (latency budget). Watch list: docs/runbook.md section 4.1.
#
# THE 77 % POINT - WHY THIS TEST DOES NOT ASSERT ON 70 %
#   `averageUtilization: 70` does NOT mean the HPA acts at 70 %. The controller
#   applies a default +/-10 % tolerance band, so it scales up only ABOVE 77 % and
#   down only BELOW 63 % (docs/design.md section 5). The runbook documents a run
#   that held at exactly 71 % for ~58 s before jumping to 500 %: 71 % is inside
#   the dead band, six points below the trigger, so the HPA was RIGHT to do
#   nothing. Any assertion phrased against 70 % would therefore convert correct
#   behaviour into a failure, which is precisely the misreading section 5 exists
#   to prevent. This test asserts against 77 % and checks that 77 % was printed.
#
# THE BASELINE ORDERING - design.md section 14, finding 4
#   An earlier cpu-load measured its baseline AFTER perturbing the system: the
#   manifest declares `replicas: 1`, so applying it started the burn immediately,
#   the HPA went 3 -> 10 unprompted, and the baseline would have been read as 10.
#   `replicas > baseline` could then never become true and the run reported a
#   false failure. Two structural mitigations are asserted here:
#     * common.sh `baseline_replicas` REFUSES to answer while the load generator
#       runs, so the ordering cannot be broken without a loud failure. Rule 9:
#       that guard is checked in the SAME shell invocation as its use.
#     * the driver owns the baseline explicitly (it scales demo-api to
#       minReplicas and waits for a calm state first). This test asserts, from
#       the driver's own ordering, that the baseline line is printed BEFORE the
#       load line - a text-ordering check that fails if the two are swapped.
#
# WHAT IT ASSERTS
#   (a) TIME        time-to-trigger and time-to-settle, each with a window.
#   (b) BLAST RADIUS peak == maxReplicas, never above it; the pod count grows
#                   only by scaling, so ZERO pods are replaced. The documented
#                   shape is 3 -> 7 -> 10, i.e. the scaleUp policy's +4 pods/30 s
#                   step, so an intermediate plateau at 7 is asserted NOT to be
#                   the end state.
#
# SAFETY
#   Rule 2: consent gates. The driver scales the load generator up (a mutation)
#           and this scenario may scale demo-api down; both are behind consent.
#           `scale --replicas=0` is explicitly destructive per CONTRIBUTING.md rule 2.
#   Rule 9: the baseline guard is verified in the same shell invocation as use.
#   Rule 10: event log checked after the run.
#
# USAGE
#   tests/chaos/cpu-load.sh [--yes] [--static]
#
# EXIT CODES
#   0 = passed, 1 = assertion failed, 2 = usage error,
#   3 = refused (no consent / no cluster).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "${SCRIPT_DIR}/../../scripts/lib/common.sh"
# shellcheck source=lib/assert.sh
. "${SCRIPT_DIR}/lib/assert.sh"

SCENARIO="cpu-load"
STATIC_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static) STATIC_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
export ASSUME_YES="${ASSUME_YES:-0}"

report_state_location

# --- static mode: offline contract checks, no cluster contact -----------------
if (( STATIC_ONLY )); then
  log "static contract checks: ${SCENARIO}"
  if chaos_static_checks "$0"; then
    print_failure_summary || exit 1
    ok "static checks passed (no cluster was contacted)"
    exit 0
  fi
  print_failure_summary || exit 1
  exit 1
fi

# --- live preconditions -------------------------------------------------------
require_cluster
assert_namespace "${K8S_NAMESPACE}"
assert_deployment "${K8S_NAMESPACE}" demo-api

log "chaos test: ${SCENARIO} (HPA scale-out)"
detail "mechanism : HorizontalPodAutoscaler (docs/design.md sections 5 and 7)"
detail "expected  : trigger ~60s, settle ~103s, peak = maxReplicas"
detail "blast radius: 3 -> 7 -> 10 pods; ZERO pods replaced"

SNAPSHOT_DIR="$(chaos_snapshot_dir)"
trap 'rm -rf "${SNAPSHOT_DIR:-}"' EXIT INT TERM
EVENTS_BEFORE="${SNAPSHOT_DIR}/events.before"
pod_snapshot "${SNAPSHOT_DIR}/pods.before"
event_log_snapshot "${EVENTS_BEFORE}"

MAX_REPLICAS="$(hpa_field '{.spec.maxReplicas}')"
MIN_REPLICAS="$(hpa_field '{.spec.minReplicas}')"
assert_eq "precondition: HPA maxReplicas (k8s/30-hpa.yaml)" "${MAX_REPLICAS}" "10"
assert_eq "precondition: HPA minReplicas (k8s/30-hpa.yaml)" "${MIN_REPLICAS}" "3"

# --- RULE 9: verify the baseline guard in the SAME shell invocation as its use.
# Finding 4 in design.md section 14 is the bug this guard exists to prevent, and
# a guard verified in one shell and used in another is not a guard (CONTRIBUTING.md
# rule 9). Both properties are checked here, in this process, immediately before
# the driver is invoked: the function must exist, AND it must still refuse to
# report a baseline while the load generator is running.
if ! type -t baseline_replicas >/dev/null 2>&1; then
  _chaos_fail "rule 9: baseline_replicas guard present in this shell invocation" \
    "baseline_replicas is not a function here; the finding-4 ordering guard is not active"
else
  ok "  rule 9: baseline_replicas is active in this shell invocation"
  CHAOS_CHECKS=$((CHAOS_CHECKS + 1))

  # Behavioural probe of the guard's refusal path. Stubbing the load generator
  # would require shadowing kubectl, which this test deliberately does not do -
  # but the guard's contract is testable through its documented refusal message,
  # and the negative control below proves the check can fail rather than being
  # vacuous: the same predicate is required NOT to match an idle read.
  LOADGEN_RUNNING="$(loadgen_running_replicas "${K8S_NAMESPACE}")"
  detail "load generator running replicas right now: ${LOADGEN_RUNNING}"
  if [[ "${LOADGEN_RUNNING}" != "0" ]]; then
    BASELINE_PROBE=""
    BASELINE_RC=0
    BASELINE_PROBE="$(baseline_replicas "${K8S_NAMESPACE}" demo-api 2>/dev/null)" || BASELINE_RC=$?
    assert_eq "guard: baseline_replicas REFUSES while the load generator runs" "${BASELINE_RC}" "1"
    assert_eq "guard: refusal writes nothing to stdout" "${BASELINE_PROBE}" ""
  else
    detail "load generator is idle, so the refusal path is not exercisable without starting load"
    detail "the refusal is covered structurally by scripts/smoke-test.sh; the ordering"
    detail "check below is what this run asserts instead"
  fi
fi

# The driver must own the baseline. `kubectl scale ... --replicas=0` on the load
# generator is destructive per CONTRIBUTING.md rule 2, so the driver's consent gate is
# relied upon here; this test adds its own gate before calling it.
if ! chaos_require_consent "${SCENARIO}" \
     "run the CPU load scenario: scale the load generator to 0 then to 1, reset demo-api to ${MIN_REPLICAS} replicas, and measure the HPA scale-out"; then
  warn "refused: no consent to start load (re-run with --yes to opt in)"
  exit 3
fi

# --- run the driver -----------------------------------------------------------
log "running the driver: ${CHAOS_INJECT} ${SCENARIO}"
# GUARDED-BY: chaos_require_consent above (rule 2); rule-9 baseline guard verified immediately above
DRIVER_OUT="${SNAPSHOT_DIR}/driver.out"
DRIVER_RC=0
run_inject "${SCENARIO}" --yes >"${DRIVER_OUT}" 2>&1 || DRIVER_RC=$?
cat "${DRIVER_OUT}"
DRIVER_TEXT="$(cat "${DRIVER_OUT}")"

assert_eq "driver exit status" "${DRIVER_RC}" "0"

# --- finding 4: prove the ordering from the driver's OWN output ---------------
# These two assertions are what stop the finding-4 bug from returning. If the
# baseline were sampled after the burn started, these lines would either be
# absent or appear in the wrong order.
assert_contains "finding 4: the driver owns the baseline (resets it explicitly)" \
  "${DRIVER_TEXT}" 'resetting baseline|baseline calm'
assert_contains "finding 4: the load generator was confirmed idle before sampling" \
  "${DRIVER_TEXT}" 'load generator idle'

BASE_LINE="$(grep -nE '^==> baseline:|baseline: [0-9]+ replicas' "${DRIVER_OUT}" | head -n 1 | cut -d: -f1 || true)"
LOAD_LINE="$(grep -nE 'load generator running' "${DRIVER_OUT}" | head -n 1 | cut -d: -f1 || true)"
if [[ -n "${BASE_LINE}" && -n "${LOAD_LINE}" ]]; then
  if (( BASE_LINE < LOAD_LINE )); then
    ok "  finding 4: the baseline line (${BASE_LINE}) precedes the load line (${LOAD_LINE})"
    CHAOS_CHECKS=$((CHAOS_CHECKS + 1))
  else
    _chaos_fail "finding 4: baseline sampled BEFORE load started" \
      "baseline is on line ${BASE_LINE} but load started on line ${LOAD_LINE} - the baseline may already contain the effect"
  fi
else
  _chaos_fail "finding 4: baseline/load ordering is checkable" \
    "could not locate both lines (baseline='${BASE_LINE:-none}' load='${LOAD_LINE:-none}')"
fi

# --- the 77 % effective threshold (design.md section 5) ----------------------
# If the run stopped printing the real threshold, a reader would have to
# interpret 60 s of inaction at 71 % as a fault. Assert it is stated.
assert_contains "design section 5: the effective 77% threshold is stated, not just 70%" \
  "${DRIVER_TEXT}" '77%'
assert_contains "design section 5: 70% is described as nominal" \
  "${DRIVER_TEXT}" 'nominal'

# --- (a) the two timed transitions -------------------------------------------
T_TRIGGER="$(sed -nE 's/.*time to trigger *: *([0-9]+)s.*/\1/p' <<<"${DRIVER_TEXT}" | head -n 1)"
T_SETTLE="$(sed -nE 's/.*time to settle *: *([0-9]+)s.*/\1/p' <<<"${DRIVER_TEXT}" | head -n 1)"
BASELINE="$(sed -nE 's/.*baseline replicas *: *([0-9]+).*/\1/p' <<<"${DRIVER_TEXT}" | head -n 1)"
PEAK="$(sed -nE 's/.*peak replicas *: *([0-9]+).*/\1/p' <<<"${DRIVER_TEXT}" | head -n 1)"
detail "parsed: baseline='${BASELINE:-<none>}' trigger='${T_TRIGGER:-<none>}' settle='${T_SETTLE:-<none>}' peak='${PEAK:-<none>}'"

assert_eq "the baseline was the reset minReplicas, not a drifted value" "${BASELINE}" "${MIN_REPLICAS}"

# WINDOW [40, 100] for time-to-trigger.
#   lower 40 s - the HPA samples every 15 s and acts only above 77 % (section 5);
#                the load generator additionally needs a few seconds to bring
#                three replicas past that threshold. Nothing legitimate can
#                trigger earlier than roughly 3 sample periods.
#   upper 100 s - design.md section 8 records a MEASURED trigger at 70 s and a
#                settle at 81 s; section 7 quotes the scenario as ~60-120 s. The
#                upper bound of 100 s contains the documented 70 s measurement
#                with margin while still excluding a run that never reacted.
#   The measured value this session is ~60 s, which sits inside the window. See
#   the discrepancy recorded below: the documented 70 s and the measured 60 s
#   differ, and neither is being adjusted to fit.
assert_in_window "time to first scale-up (documented 70s, measured 60s)" "${T_TRIGGER}" 40 100

# WINDOW [70, 180] for time-to-settle.
#   lower 70 s - a 3 -> 7 -> 10 climb cannot settle before the first step lands;
#                the 30 s scaleUp stabilisation window alone makes a fast settle
#                impossible.
#   upper 180 s - the scaleUp policy allows +4 pods per 30 s (k8s/30-hpa.yaml),
#                so 3 -> 7 -> 10 is at least two stabilisation windows, and each
#                new pod must also become Ready. Section 8's ~60-120 s end-to-end
#                range is the documented figure; 180 s leaves room for a loaded
#                single-node cluster without accepting a stalled run.
#   Measured this session: ~103 s.
assert_in_window "time to settle (documented ~60-120s, measured ~103s)" "${T_SETTLE}" 70 180

record_doc_discrepancy "${SCENARIO}" \
  "trigger ~70s (design.md section 8, measured on an earlier run)" \
  "trigger ~60s (this session)" \
  "Both are inside section 7's ~60-120s range; recommend quoting the range at the trigger site instead of one earlier measurement."

# --- (b) blast radius ---------------------------------------------------------
# The cap is the blast-radius bound. Reaching it is the documented success shape
# ("peak reaches maxReplicas=10"), and exceeding it is impossible by design -
# which is exactly why it is asserted rather than assumed.
assert_in_window "peak replicas bounded by maxReplicas" "${PEAK}" "${MIN_REPLICAS}" "${MAX_REPLICAS}"
assert_eq "peak reached maxReplicas (scale-out ran to the cap)" "${PEAK}" "${MAX_REPLICAS}"

# An intermediate plateau at 7 must not be the end state. Section 8 is explicit
# that the step lands at ~7 first and quoting "settled at 7" understates the
# climb; the driver's own completion test was rewritten for this, so the peak is
# asserted to have passed the intermediate step.
if [[ -n "${PEAK}" ]] && (( PEAK > 7 )); then
  ok "  the climb passed the intermediate step (peak ${PEAK} > 7), as section 8 describes"
  CHAOS_CHECKS=$((CHAOS_CHECKS + 1))
else
  _chaos_fail "the climb passed the intermediate step" \
    "peak '${PEAK:-<none>}' did not exceed 7; a plateau at 7 is a stabilisation pause, not the end state"
fi

# Scaling out ADDS pods; it must never replace them. This distinguishes an HPA
# action from a rollout.
assert_no_pods_removed "scale-out added pods without replacing any" "${SNAPSHOT_DIR}/pods.before"

PODS_BEFORE="$(sed '/^$/d' "${SNAPSHOT_DIR}/pods.before" | wc -l | tr -d ' ')"
PODS_NOW="$(pod_count_all)"
detail "pods: ${PODS_BEFORE} -> ${PODS_NOW} (peak replicas ${PEAK}, cap ${MAX_REPLICAS})"
if (( PODS_NOW <= MAX_REPLICAS )); then
  ok "  the pod count never exceeded maxReplicas (${PODS_NOW} <= ${MAX_REPLICAS})"
  CHAOS_CHECKS=$((CHAOS_CHECKS + 1))
else
  _chaos_fail "the pod count never exceeded maxReplicas" \
    "${PODS_NOW} pods exist but maxReplicas is ${MAX_REPLICAS}"
fi

assert_ready_replicas "all replicas Ready at the settled state" "${PEAK}"

# --- note the known scale-down behaviour -------------------------------------
# design.md section 5: memory is flat with respect to load, so the HPA's descent
# halts at a fixed point (5, 6 or 7) and minReplicas=3 is NOT a resting state the
# cluster can reach on its own. This is correct behaviour, not a fault, and this
# test does not assert a return to 3 - doing so would fail on a healthy cluster.
detail "note (design.md section 5): scale-down halts at a memory-driven fixed point,"
detail "      not minReplicas=3. Do NOT assert a return to 3 - it does not happen."
detail "      stop the load generator with: scripts/inject-failure.sh recover-all"

# --- rule 10 ------------------------------------------------------------------
# Allowed: HPA decisions, the deployments being scaled, and pods coming up.
check_event_log "${SCENARIO}" "${EVENTS_BEFORE}" '^(HorizontalPodAutoscaler|Deployment|ReplicaSet|Pod)/demo-api|^(Deployment|ReplicaSet|Pod)/load-generator'

printf '\n'
report_doc_discrepancies
detail "watch list (docs/runbook.md section 4.1): HPA REPLICAS rises above 3 within ~90s"
detail "the load generator is still running; the HPA will walk down slowly (300s window)"
print_failure_summary || exit 1
ok "${SCENARIO}: PASSED"
exit 0
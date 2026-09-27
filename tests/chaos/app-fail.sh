#!/usr/bin/env bash
# tests/chaos/app-fail.sh - chaos test for the kubelet probe paths (Tier 0).
#
# WHAT THIS TESTS
#   That an application-level fault is handled by the KUBELET, in two stages, and
#   in the documented order:
#     1. readiness fails first -> the pod leaves the Service endpoints WITHOUT
#        being restarted (traffic shedding, no availability loss);
#     2. liveness fails later -> the kubelet restarts the container.
#   Then that /recover clears the fault, confirming the recovery path.
#
#   Authoritative expectations: docs/design.md section 4.2 (probe budget) and
#   section 7/8 (scenario table, latency budget). Watch list: docs/runbook.md
#   section 4.1.
#
#   The measured values this test encodes, from the live cluster:
#     readiness shed     ~7-14 s   (design section 4.2: 7-14 s, fast end ~7 s;
#                                   an observed 6-7 s is the fast end, NOT a bug)
#     liveness restart   ~43-45 s  (design section 4.2: ~43 s)
#     recovery           ~45 s
#
# WHAT IT ASSERTS
#   (a) TIME        all three stages, each against a justified window.
#   (b) BLAST RADIUS ZERO pod identities change. The point of app-fail is that a
#                   fault is healed by a container RESTART, not by replacing the
#                   pod: the same pod name must survive. "1 pod affected" in
#                   design.md section 7 means one pod's health, not one pod
#                   replaced - and this test distinguishes the two, because a
#                   silent pod replacement here would mean liveness never fired.
#
# SAFETY
#   Rule 2: consent gate before the driver call, and again before /recover (the
#           smoke-test harness classifies curl /fail and /recover as MUTATIONS,
#           so /recover is treated as destructive here too).
#   Rule 9: the consent gate is asserted to be active in the SAME shell
#           invocation as the /recover call it guards (see the rule-9 block).
#   Rule 10: event log checked after the run.
#   Finding 3 in design.md section 14: a bare `read` on a non-TTY stdin hangs
#           forever. This script never reads stdin directly; consent goes through
#           common.sh's confirm(), which fails closed on a non-TTY.
#
# USAGE
#   tests/chaos/app-fail.sh [--yes] [--static] [--skip-recover]
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

SCENARIO="app-fail"
STATIC_ONLY=0
SKIP_RECOVER=0
RECOVER_PORT=18082

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)       STATIC_ONLY=1 ;;
    --skip-recover) SKIP_RECOVER=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

log "chaos test: ${SCENARIO} (kubelet probes, Tier 0)"
detail "mechanism : readiness, then liveness (docs/design.md sections 4.2 and 7)"
detail "expected  : readiness ~7-14s, liveness restart ~43-45s, recovery ~45s"
detail "blast radius: 1 pod's health - ZERO pods replaced"

SNAPSHOT_DIR="$(chaos_snapshot_dir)"
EVENTS_BEFORE="${SNAPSHOT_DIR}/events.before"
pod_snapshot "${SNAPSHOT_DIR}/pods.before"
event_log_snapshot "${EVENTS_BEFORE}"

TARGET_POD="$(pick_target_pod)"
[[ -n "${TARGET_POD}" ]] || die "no running demo-api pod to target - is the deployment healthy?"
RESTARTS_BEFORE="$(restart_count "${TARGET_POD}")"
# Sampled BEFORE the fault so the availability assertion is relative. The HPA's
# memory-bound fixed point holds at 5/6/7 and cannot descend to minReplicas=3
# (docs/design.md §5), so an absolute "== 3" would fail on a healthy cluster.
BASELINE_READY="$(deployment_ready_replicas)"
detail "target pod: ${TARGET_POD} (restartCount before: ${RESTARTS_BEFORE:-?})"
detail "baseline: ${BASELINE_READY} ready replica(s)"

# The port-forward used by the driver and by the /recover leg. Registered as a
# global and torn down by the EXIT trap, matching the driver's own pattern: under
# `set -u` an unset local inside a trap handler would abort the cleanup.
PF_PID=""
# shellcheck disable=SC2064
trap 'kill "${CHAOS_WATCHER_PID:-}" 2>/dev/null || true; kill "${PF_PID:-}" 2>/dev/null || true; rm -rf "${SNAPSHOT_DIR:-}"' EXIT INT TERM

# --- consent (rule 2) ---------------------------------------------------------
if ! chaos_require_consent "${SCENARIO}" "inject a probe failure into ${TARGET_POD} (/fail)"; then
  warn "refused: no consent to inject a fault (re-run with --yes to opt in)"
  exit 3
fi

# --- run the driver -----------------------------------------------------------
# The driver implements the injection and measures all three timings itself,
# printing them as:
#   observed: readiness <n>s, restart <n>s, recovered <n>s
# This test parses those measurements and asserts them. It does NOT re-time the
# stages with its own polling loop: duplicating the driver's instrumentation
# would add a second, disagreeing clock to the same transition (the error
# described in design.md section 14, "the measurement and the claim came from the
# same untrusted source" - except worse, from two sources).
log "running the driver: ${CHAOS_INJECT} ${SCENARIO}"
# The independent liveness watcher is started BEFORE the driver and stopped AFTER
# it. It observes restartCount incrementing as it happens, so the liveness figure
# does not depend on the driver's own polling - see the contamination note below.
RESTART_WATCH_FILE="${SNAPSHOT_DIR}/restart.watch"
start_restart_watcher "${TARGET_POD}" "${RESTART_WATCH_FILE}"
DRIVER_OUT="${SNAPSHOT_DIR}/driver.out"
DRIVER_RC=0
# GUARDED-BY: chaos_require_consent above (rule 2); driver carries its own confirm() and /fail endpoint
run_inject "${SCENARIO}" --yes >"${DRIVER_OUT}" 2>&1 || DRIVER_RC=$?
# Called DIRECTLY (not in a substitution) so the pid is cleared in THIS shell and
# the EXIT trap cannot point at a stale process; the value arrives via the global.
stop_restart_watcher "${RESTART_WATCH_FILE}"
T_WATCHED_LIVENESS="${CHAOS_WATCHED_LATENCY:-}"
cat "${DRIVER_OUT}"
DRIVER_TEXT="$(cat "${DRIVER_OUT}")"

assert_eq "driver exit status" "${DRIVER_RC}" "0"

# A missing measurement is a FAILURE, not a skip. If the driver never reports a
# stage, the stage was never observed and the assertion would be vacuous.
T_READY="$(sed -nE 's/.*readiness ([0-9]+)s.*/\1/p' <<<"${DRIVER_TEXT}" | head -n 1)"
T_RESTART="$(sed -nE 's/.*restart ([0-9]+)s.*/\1/p' <<<"${DRIVER_TEXT}" | head -n 1)"
T_RECOVERED="$(sed -nE 's/.*recovered ([0-9]+)s.*/\1/p' <<<"${DRIVER_TEXT}" | head -n 1)"
detail "parsed from the driver: readiness='${T_READY:-<none>}' restart='${T_RESTART:-<none>}' recovered='${T_RECOVERED:-<none>}'"

# The readiness stage must be proven to have HAPPENED, not just to have been
# fast: without this, a run where readiness never fired would pass on a missing
# number. The endpoints transition is the authoritative evidence (design.md
# section 12.1 lists "endpoints count < replica count" as the shedding signal).
assert_contains "readiness actually shed the pod (not a vacuous timing)" \
  "${DRIVER_TEXT}" 'readiness removed the pod from the Service endpoints after'

# --- (a) the three timed stages ----------------------------------------------

# WINDOW [5, 18] for readiness shedding.
#   lower 5 s  - one readiness periodSeconds (k8s/10-deployment.yaml: period 5s,
#                threshold 2). Readiness cannot act before one full period.
#   upper 18 s - the design.md section 4.2 worst case is ~14 s (10 s of failed
#                probes + 2 s timeout + 1-2 s endpoint propagation); +4 s absorbs
#                the driver's 1 s polling granularity and endpoint propagation
#                jitter. Contains BOTH the measured 6-7 s (section 4.2, line 256)
#                and the documented 7-14 s range, so neither reads as a failure.
assert_in_window "readiness shed (documented 7-14s, measured 6-7s)" "${T_READY}" 5 18

# WINDOW [24, 60] for the liveness restart - a RANGE, and the driver's figure is
# NOT trusted as the measurement. Two problems, both found by working the probe
# arithmetic rather than accepting the printed number:
#
# (1) THE DRIVER'S `restart <n>s` IS CONTAMINATED. Its readiness stage polls in a
#     `while SECONDS < deadline` loop with NO `break` on success, so it always runs
#     its full 45 s. The liveness stage is only polled after that loop exits, so
#     the printed figure is FLOORED at ~45 s: a true restart at 25 s and a true
#     restart at 44 s both print ~45 s. The documented "measured 43-45 s" is
#     therefore the POLLING FLOOR, not the liveness path's latency. This test
#     measures the increment independently with start_restart_watcher() so the
#     assertion is about the system, not about the driver's loop.
#
# (2) LIVENESS IS PHASE-OFFSET DEPENDENT, like readiness. /healthz returns 500
#     immediately, so timeoutSeconds=3 does NOT apply (that is the hanging-probe
#     case). With period 10 s and threshold 3 the kubelet needs three CONSECUTIVE
#     failures; if the fault lands an offset o in [0,10] before the next probe,
#     they occur at o, o+10, o+20 and the decision is at o+20:
#
#       detection   20-30 s      (o=0 -> 20 s, o=10 -> 30 s)
#       restart     5-10 s       (container kill + boot, design.md section 4.2)
#       total       25-40 s
#
#     So a point value here would be the same class of error as the pod-kill
#     `~15 s` and the readiness `~14 s` before it: a worst case asserted as if
#     deterministic.
#
#   lower 24 s - just below the 25 s floor of the true range. Below ~20 s the
#                kubelet cannot have observed three failures, so anything faster
#                means liveness did not fire (and the blast-radius assertions
#                below would catch a replacement masquerading as a restart).
#   upper 60 s - the 40 s upper end of the true range, plus generous headroom for
#                a slow gunicorn boot on a loaded single-node cluster. Deliberately
#                above the driver's ~45 s floor, so a run where only the driver's
#                figure is available still passes rather than failing on an
#                artefact of the driver's polling.
if [[ -n "${T_WATCHED_LIVENESS}" ]]; then
  assert_in_window "liveness restart, independently observed (documented ~43s = polling floor; true 25-40s)" \
    "${T_WATCHED_LIVENESS}" 24 60
  detail "driver-reported restart '${T_RESTART:-<none>}s' vs independently observed '${T_WATCHED_LIVENESS}s'"
  if [[ -n "${T_RESTART}" ]] && (( T_RESTART > T_WATCHED_LIVENESS + 15 )); then
    detail "the driver's figure is ~${T_RESTART}s while the restart happened at ~${T_WATCHED_LIVENESS}s:"
    detail "consistent with the ~45s polling floor documented above, and it is why the"
    detail "driver's number is reported rather than asserted as the latency."
  fi
else
  # The watcher saw no increment; fall back to the driver's contaminated figure but
  # SAY that it is a floor, and keep the window wide enough that the artefact alone
  # cannot fail the run.
  warn "independent restart observation unavailable; falling back to the driver's figure"
  detail "the driver's 'restart <n>s' is FLOORED at ~45s by its own readiness loop - see above"
  assert_in_window "liveness restart (driver figure; known ~45s polling floor)" "${T_RESTART}" 24 60
fi

# WINDOW [35, 70] for the pod returning to Ready.
#   lower 35 s - recovery cannot precede the restart decision at ~33 s.
#   upper 70 s - the ~45 s measured total plus a wide margin: after a restart the
#                container must re-run its startupProbe path and re-join the
#                endpoints, and the ~45 s figure is a measurement on an idle
#                cluster, not a bound.
assert_in_window "recovered and Ready (measured ~45s)" "${T_RECOVERED}" 35 70

# --- (b) blast radius: a restart, NOT a replacement --------------------------
# This is the load-bearing assertion of the whole scenario. If the pod were
# replaced instead of restarted, liveness never fired and the test above would be
# reporting a ReplicaSet action as a probe action.
assert_true "the same pod still exists (container restarted, not replaced)" \
  kubectl get pod "${TARGET_POD}" -n "${K8S_NAMESPACE}"
assert_pods_unchanged "blast radius: ZERO pods replaced (restart, not reschedule)" \
  "${SNAPSHOT_DIR}/pods.before" 0

RESTARTS_AFTER="$(restart_count "${TARGET_POD}")"
detail "restartCount: ${RESTARTS_BEFORE:-?} -> ${RESTARTS_AFTER:-?}"
if [[ "${RESTARTS_AFTER:-0}" -gt "${RESTARTS_BEFORE:-0}" ]]; then
  ok "  restartCount incremented (liveness provably fired)"
  CHAOS_CHECKS=$((CHAOS_CHECKS + 1))
else
  _chaos_fail "restartCount incremented" \
    "restartCount did not increase (${RESTARTS_BEFORE:-?} -> ${RESTARTS_AFTER:-?}); liveness may not have fired"
fi

# Relative to the sampled baseline, not an absolute 3: the HPA's memory-bound
# fixed point cannot descend to minReplicas (design.md section 5), so a literal 3
# would fail on a correctly-behaving cluster.
assert_ready_replicas_at_least "full availability restored to the pre-fault baseline" \
  "${BASELINE_READY}"

# --- /recover leg -------------------------------------------------------------
# `recovery via /recover ~45s` is one of the measured expectations for this
# scenario, so the recovery endpoint is exercised explicitly rather than inferred
# from the restart. This is a MUTATION (the smoke-test harness classifies
# curl /recover as one), so it is gated like any other.
if (( SKIP_RECOVER )); then
  warn "skipping the /recover leg (--skip-recover)"
else
  # --- RULE 9: the guard is verified in the SAME shell invocation as the call
  # it guards. Not a prior command, not a separate step: the gate is checked, the
  # gate is then used, in this block, in this process. A guard checked elsewhere
  # is not a guard (AGENTS.md rule 9).
  if ! type -t chaos_require_consent >/dev/null 2>&1; then
    _chaos_fail "rule 9: consent guard present in this shell invocation" \
      "chaos_require_consent is not a function here; refusing to call /recover"
  else
    ok "  rule 9: chaos_require_consent is active in this shell invocation"
    CHAOS_CHECKS=$((CHAOS_CHECKS + 1))

    if chaos_require_consent "${SCENARIO}" "call /recover on ${TARGET_POD} to clear the fault"; then
      log "calling /recover on ${TARGET_POD}"
      kubectl port-forward "pod/${TARGET_POD}" -n "${K8S_NAMESPACE}" \
        "${RECOVER_PORT}:8080" >/dev/null 2>&1 &
      PF_PID=$!

      # Wait for the tunnel before using it (the driver uses the same pattern).
      local_i=0
      for local_i in $(seq 1 20); do
        curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:${RECOVER_PORT}/healthz" 2>/dev/null && break
        sleep 0.5
      done

      T_RECOVER0="${SECONDS}"
      RECOVER_BODY=""
      RECOVER_OK=0
      if RECOVER_BODY="$(curl -sS --max-time 10 "http://127.0.0.1:${RECOVER_PORT}/recover" 2>&1)"; then
        RECOVER_OK=1
      fi
      T_RECOVER_CALL=$(( SECONDS - T_RECOVER0 ))
      detail "/recover returned in ${T_RECOVER_CALL}s: ${RECOVER_BODY}"

      assert_eq "/recover reports success" "${RECOVER_OK}" "1"
      assert_contains "/recover reports the fault cleared" "${RECOVER_BODY}" 'recover|cleared|status'

      # The pod must be Ready once /recover has run. wait_for is reused from
      # common.sh rather than reimplemented (2 s polling period).
      # WINDOW [0, 45]: the endpoint call itself is immediate, but the kubelet
      # only re-adds the pod to the endpoints on its next readiness probe, so
      # allow the documented ~45 s recovery budget; a timeout here is recorded as
      # a failure by the assert below rather than aborting the script.
      RECOVER_READY=0
      if wait_for "pod ${TARGET_POD} Ready after /recover" 45 \
           bash -c "[[ \"\$(kubectl get pod '${TARGET_POD}' -n '${K8S_NAMESPACE}' -o jsonpath='{.status.containerStatuses[0].ready}')\" == \"true\" ]]"; then
        RECOVER_READY=1
      fi
      assert_eq "pod Ready after /recover" "${RECOVER_READY}" "1"
      assert_in_window "recovery via /recover (documented ~45s)" \
        "$(( SECONDS - T_RECOVER0 ))" 0 45

      kill "${PF_PID}" 2>/dev/null || true
      wait "${PF_PID}" 2>/dev/null || true
      PF_PID=""
    else
      warn "refused: no consent to call /recover; leaving any residual fault in place"
    fi
  fi
fi

# --- rule 10 ------------------------------------------------------------------
check_event_log "${SCENARIO}" "${EVENTS_BEFORE}" '^(Pod|ReplicaSet|Deployment)/demo-api'

# Record the liveness measurement defect so it is PRINTED as part of the run, not
# only described in a comment. A finding that lives solely in a source comment is
# a finding nobody reads.
record_doc_discrepancy "${SCENARIO}" \
  "liveness restart ~43s (design.md sections 4.2 and 7; §4.2 derives 30s probes + 3s timeout + 5-10s restart)" \
  "driver's 'restart <n>s' is FLOORED at ~45s by its own readiness loop (no break on success), so 43-45s is the polling floor; independently-observed value is reported above" \
  "Two changes recommended, neither in tests/. (1) scripts/inject-failure.sh scenario_app_fail: break the readiness loop when t_ready is found, before polling restartCount, or the reported liveness figure cannot distinguish a fast path from a slow one. (2) design.md sections 4.2 and 7: state liveness as the range 25-40s. timeoutSeconds=3 should not be added - /healthz fails fast with a 500, so that term is the hanging-probe case and does not apply; the range comes from the three-consecutive-failures phase offset (20-30s) plus restart and boot (5-10s)."

printf '\n'
report_doc_discrepancies
printf '\n'
detail "watch list (docs/runbook.md section 4.1):"
detail "  - ready endpoints drop to 2 within ~7-14s (worst case ~14s)"
detail "  - restartCount increments ~25-40s (the doc's ~43s is the driver's polling floor)"
detail "if the pod never returns to Ready, the fault is surviving the restart:"
detail "  see design.md section 4.1 and the emptyDir finding (section 14, finding 2)"
print_failure_summary || exit 1
ok "${SCENARIO}: PASSED"
exit 0
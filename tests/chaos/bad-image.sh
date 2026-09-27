#!/usr/bin/env bash
# tests/chaos/bad-image.sh - chaos test for a rollout that stalls safely and is
# NEVER remediated automatically.
#
# THE AXIS THIS SCRIPT GOT WRONG, AND THE CORRECTION
#   The scenario row once read `never (by design)`, and this script asserted that
#   as an absence: "the rollout never completes, therefore nothing is reported".
#   That conflates two different questions, and docs/design.md §7 now separates
#   them. Measured on this cluster:
#
#     injection (:does-not-exist)          03:13:46Z
#     ProgressDeadlineExceeded             03:23:57Z     = 611 s
#     declared progressDeadlineSeconds     600 s
#
#   So detection is BOUNDED and AUTOMATIC — the standard mechanism declares the
#   rollout failed on schedule. What never happens is REMEDIATION: no tier acts,
#   because a Deployment that fails to progress is not a condition any controller
#   is authorised to undo. Read the row as:
#
#     detection   : bounded and automatic  -> progressDeadlineSeconds: 600
#     remediation : never automatic        -> requires an explicit `rollout undo`
#
#   A reader who took "never" to mean "nothing is reported for a long time" would
#   mis-size their alerting: the deployment surfaces Progressing=False /
#   ProgressDeadlineExceeded on schedule, and THAT is the condition to alert on.
#   This script therefore asserts BOTH axes, and neither is an absence any more.
#
# WHAT IT ASSERTS
#   (a) TIME
#       a1. DETECTION is bounded: progressDeadlineSeconds is 600, read from the
#           live object rather than quoted from the document. With
#           --wait-progress-deadline it also waits out the deadline and asserts
#           the condition actually fires at ~600 s (measured 611 s = one
#           control-loop sync of overshoot), so a bounded claim is not merely
#           asserted from the spec.
#       a2. REMEDIATION never happens on its own: the stall persists past the
#           observation window and the rollout never completes.
#   (b) BLAST RADIUS zero — the old pods keep serving throughout (maxUnavailable:
#       0), and the bad ReplicaSet stays at 0 ready. Blast radius is "0 — old pods
#       keep serving" (§7).
#
#   Plus the documented remedy is exercised, so it is proven rather than quoted:
#   an EXPLICIT `kubectl rollout undo` restores the workload.
#
# FINDING 7 - REPLICA CHANGES MUST BE ATTRIBUTED, NOT COUNTED
#   docs/design.md §14, finding 7: the HPA scaled demo-api DOWN *during* this very
#   scenario, and the old ReplicaSet's 8->7 looked exactly like a `maxUnavailable:
#   0` violation. The count is equally consistent with "the guarantee held" and
#   "the guarantee leaked", so this script attributes changes by their event
#   SOURCE (`SuccessfulRescale` = HPA, `ScalingReplicaSet` = rollout) and argues
#   from the MECHANISM:
#
#     with maxSurge: 1 / maxUnavailable: 0, a rolling update scales the old
#     ReplicaSet down ONLY after a replacement becomes Available. The replacement
#     sat in ImagePullBackOff for the whole window, so the rollout could NOT have
#     performed that scale-down.
#
#   The conclusive argument is the second one, because it reasons from semantics
#   rather than from a number that a concurrent controller can also produce.
#
# WHY THIS TEST OWNS THE INJECTION INSTEAD OF CALLING THE DRIVER WHOLESALE
#   `scenario_bad_image` injects, sleeps 15 s, then offers an interactive rollback;
#   with --yes it rolls back immediately, collapsing the stall this scenario exists
#   to observe. This test performs the mutating steps itself, each behind rule 1 and
#   rule 2, and reuses common.sh for all waiting and logging. The driver remains
#   canonical and its contract is cross-checked read-only via `--list`.
#
# SAFETY
#   Rule 1: `--dry-run=server` before BOTH mutations (set image, rollout undo).
#   Rule 2: both mutations behind an explicit consent gate.
#   Rule 10: event log checked after the run.
#
# USAGE
#   tests/chaos/bad-image.sh [--yes] [--static] [--stall-window N]
#                            [--wait-progress-deadline]
#
#   --wait-progress-deadline  wait out progressDeadlineSeconds (~600 s) and assert
#                             Progressing=False/ProgressDeadlineExceeded fires.
#                             OFF by default: the short run asserts the bound from
#                             the live spec plus the stall's persistence, and says
#                             so, rather than either skipping the claim or
#                             pretending to have measured it.
#
# EXIT CODES
#   0 = passed, 1 = assertion failed, 2 = usage error,
#   3 = refused (no consent / no cluster / workload not healthy to begin with).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "${SCRIPT_DIR}/../../scripts/lib/common.sh"
# shellcheck source=lib/assert.sh
. "${SCRIPT_DIR}/lib/assert.sh"

SCENARIO="bad-image"
STATIC_ONLY=0
WAIT_DEADLINE=0

# The reference image the deployment must return to. APP_IMAGE comes from
# common.sh, so the app's own convention is reused rather than restated.
EXPECTED_IMAGE="${APP_IMAGE}"

# The deliberately non-existent tag, matching scripts/inject-failure.sh
# scenario_bad_image. Duplicated narrowly (one literal) because `--list` is a text
# contract that cannot be parsed for it.
BAD_IMAGE_TAG="selfhealing/demo-api:does-not-exist"

# Observation window for the short run. 45 s exceeds the ~15 s the driver watches
# for and covers several Deployment/ReplicaSet reconcile cycles: if any controller
# were going to self-correct, it would have acted. It is a FLOOR on the
# observation, not a predicted healing time - remediation is expected never.
STALL_WINDOW="${CHAOS_STALL_WINDOW:-45}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static) STATIC_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --wait-progress-deadline) WAIT_DEADLINE=1 ;;
    --stall-window) shift; STALL_WINDOW="${1:-}"; [[ -n "${STALL_WINDOW}" ]] || die "--stall-window needs a value" ;;
    -h|--help) sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

log "chaos test: ${SCENARIO} (stalls safely; detection bounded, remediation never)"
detail "mechanism : rollout stall + manual undo (docs/design.md section 7)"
detail "detection : bounded and automatic - progressDeadlineSeconds (asserted below)"
detail "remediation: never automatic - requires an explicit rollout undo"
detail "blast radius: 0 - old pods keep serving (maxUnavailable: 0)"
detail "stall observation window: ${STALL_WINDOW}s"

# Cross-check the driver's contract without mutating: `--list` exits before
# require_cluster and names every scenario.
assert_true "driver advertises the bad-image scenario" \
  bash -c "'${CHAOS_INJECT}' --list 2>/dev/null | grep -q '^bad-image'"

SNAPSHOT_DIR="$(chaos_snapshot_dir)"
trap 'rm -rf "${SNAPSHOT_DIR:-}"' EXIT INT TERM
EVENTS_BEFORE="${SNAPSHOT_DIR}/events.before"
pod_snapshot "${SNAPSHOT_DIR}/pods.before"
event_log_snapshot "${EVENTS_BEFORE}"

READY_BEFORE="$(deployment_ready_replicas)"
DESIRED_BEFORE="$(deployment_desired_replicas)"
ORIGINAL_IMAGE="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
detail "image before: ${ORIGINAL_IMAGE}"
detail "before: ${READY_BEFORE:-0}/${DESIRED_BEFORE:-0} ready"

# Starting from a degraded workload would make "the old pods kept serving"
# untestable, so refuse rather than report a green run on a broken baseline.
if [[ "${READY_BEFORE:-0}" != "${DESIRED_BEFORE:-0}" || "${READY_BEFORE:-0}" == "0" ]]; then
  warn "workload is not fully ready (${READY_BEFORE:-0}/${DESIRED_BEFORE:-0}); refusing to start"
  detail "heal the baseline first, then re-run"
  exit 3
fi

# --- (a1) DETECTION IS BOUNDED: read the bound from the LIVE object -----------
# Asserted before any mutation, because this is what makes the stall a managed
# condition rather than a silent hang. The value is read, not quoted.
PROGRESS_DEADLINE="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
  -o jsonpath='{.spec.progressDeadlineSeconds}' 2>/dev/null || true)"
# apps/v1 defaults progressDeadlineSeconds to 600 and the API server PERSISTS the
# default, so an empty read means the field is genuinely absent - report that
# rather than silently substituting the documented number.
if [[ -z "${PROGRESS_DEADLINE}" ]]; then
  warn "progressDeadlineSeconds is not set on the live object"
  detail "the apps/v1 API default is 600s; the deployment relies on that default"
  detail "asserting the documented default rather than a read value"
  PROGRESS_DEADLINE=600
  record_doc_discrepancy "${SCENARIO}" \
    "progressDeadlineSeconds: 600 (apps/v1 API default)" \
    "field absent from the live object (relying on server-side defaulting)" \
    "Consider setting progressDeadlineSeconds explicitly in k8s/10-deployment.yaml so the detection bound is visible in the manifest rather than implicit."
fi
detail "detection bound (progressDeadlineSeconds): ${PROGRESS_DEADLINE}s"
assert_in_window "detection is BOUNDED: progressDeadlineSeconds is a finite, sane bound" \
  "${PROGRESS_DEADLINE}" 60 3600

# --- MUTATION 1: break the image ---------------------------------------------
if ! chaos_require_consent "${SCENARIO}" "point deployment/demo-api at ${BAD_IMAGE_TAG} (breaks the rollout)"; then
  warn "refused: no consent to break the image (re-run with --yes to opt in)"
  exit 3
fi

# Rule 1, before the mutation. `kubectl set image` supports --dry-run=server.
log "rule 1: server-side dry-run of the image change"
if ! kubectl set image deployment/demo-api "api=${BAD_IMAGE_TAG}" \
      -n "${K8S_NAMESPACE}" --dry-run=server >/dev/null 2>&1; then
  err "server-side dry-run of 'set image' was REJECTED; refusing to mutate"
  detail "inspect with: kubectl get deployment demo-api -n ${K8S_NAMESPACE} -o yaml"
  print_failure_summary || exit 1
  exit 1
fi
ok "dry-run accepted"

# GUARDED-BY: chaos_require_consent above (rule 2); --dry-run=server immediately above (rule 1)
kubectl set image deployment/demo-api "api=${BAD_IMAGE_TAG}" -n "${K8S_NAMESPACE}" >/dev/null
ok "image updated to ${BAD_IMAGE_TAG} - new pods will fail with ImagePullBackOff"
T_INJECT="${SECONDS}"
INJECT_EPOCH="$(date -u +%s)"

# Confirm the injection actually took effect. Without this the whole test could be
# observing an unchanged deployment and reporting "never healed" - true, and
# meaningless.
INJECTED=0
for _ in $(seq 1 30); do
  if kubectl get pods -n "${K8S_NAMESPACE}" -l "${CHAOS_APP_LABEL}" \
       -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
       | grep -qE 'ImagePullBackOff|ErrImagePull'; then
    INJECTED=1
    break
  fi
  sleep 2
done
assert_eq "the bad image is really present (ImagePullBackOff observed)" "${INJECTED}" "1"

# --- ASSERTION a2 + b: it stalls, it stays stalled, and nothing is lost ------
# a2 (remediation never) and b (blast radius 0) are checked INSIDE the window
# continuously, so a brief blip of availability loss cannot hide between samples.
log "observing the stall for ${STALL_WINDOW}s (expecting NO self-healing)"
STALL_DEADLINE=$(( SECONDS + STALL_WINDOW ))
MIN_READY_DURING_STALL=99
ROLLOUT_COMPLETED_DURING_STALL=0

while (( SECONDS < STALL_DEADLINE )); do
  READY_NOW="$(deployment_ready_replicas)"
  [[ "${READY_NOW:-0}" =~ ^[0-9]+$ ]] || READY_NOW=0
  (( READY_NOW < MIN_READY_DURING_STALL )) && MIN_READY_DURING_STALL="${READY_NOW}"

  # If the rollout ever succeeded during the stall, the system "healed" a bad
  # change - the exact behaviour design.md section 7 forbids.
  if kubectl rollout status deployment/demo-api -n "${K8S_NAMESPACE}" --timeout=1s >/dev/null 2>&1; then
    ROLLOUT_COMPLETED_DURING_STALL=1
  fi

  printf '\r     stall observation: %ss remaining, ready %s/%s   ' \
    "$(( STALL_DEADLINE - SECONDS ))" "${READY_NOW}" "${DESIRED_BEFORE}"
  sleep 5
done
printf '\n'

T_STALLED=$(( SECONDS - T_INJECT ))

# (a2) REMEDIATION never happens on its own. The observation window's basis is
# stated above; this asserts the absence of self-remediation, which is a real
# claim with a real failure mode (an auto-rollback of a legitimate change).
assert_eq "remediation NEVER happened automatically (rollout never completed)" \
  "${ROLLOUT_COMPLETED_DURING_STALL}" "0"
assert_in_window "the stall persisted at least the observation window" \
  "${T_STALLED}" "${STALL_WINDOW}" 600

# (b) BLAST RADIUS: availability floor, not mean. maxUnavailable: 0 is what makes
# the stall a non-event, so the floor is the assertion.
assert_eq "old pods kept serving throughout (min ready during stall)" \
  "${MIN_READY_DURING_STALL}" "${DESIRED_BEFORE}"
assert_no_pods_removed "blast radius: 0 - no old pod was removed by the broken rollout" \
  "${SNAPSHOT_DIR}/pods.before"

# The bad ReplicaSet must stay at 0 ready. If it ever became ready the rollout
# would be progressing, which is a different (and wrong) story than a stall.
BAD_RS_READY="$(kubectl get pods -n "${K8S_NAMESPACE}" -l "${CHAOS_APP_LABEL}" \
  -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
  | grep -c '^True$' || true)"
[[ "${BAD_RS_READY}" =~ ^[0-9]+$ ]] || BAD_RS_READY=0
detail "pods reporting Ready=True during the stall: ${BAD_RS_READY} (expected ${DESIRED_BEFORE})"
assert_eq "the bad revision produced NO ready pod (the stall is real)" \
  "${BAD_RS_READY}" "${DESIRED_BEFORE}"

# --- FINDING 7: attribute the replica changes ---------------------------------
# The HPA can scale down during this scenario. Name the controller instead of
# leaving a bare count, so a scale-down cannot be misread as a maxUnavailable
# violation.
assert_replica_changes_attributed "finding 7 (bad-image)" "${EVENTS_BEFORE}"
# count_events_matching() gives the same attribution as a number, asserted here so
# the conclusion is explicit in the pass/fail record rather than only in the log.
#
# The message filter matters: the deployment controller emits ScalingReplicaSet for
# scale-UP too (the surge pod is a "Scaled up replica set" event), so counting all
# such events would count the rollout's legitimate scale-up. Only "Scaled down" is
# the operation a maxUnavailable violation would look like, and it must be absent:
# with maxUnavailable: 0 the rollout scales the old ReplicaSet down ONLY after a
# replacement becomes Available, and none did.
ROLLOUT_SCALED_DOWN="$(count_events_matching ScalingReplicaSet "${EVENTS_BEFORE}" 'Scaled down')"
HPA_SCALES="$(count_events_matching SuccessfulRescale "${EVENTS_BEFORE}")"
assert_eq "finding 7: the ROLLOUT did not scale down (no replacement ever became Available)" \
  "${ROLLOUT_SCALED_DOWN}" "0"
detail "finding 7: HPA SuccessfulRescale events during the stall: ${HPA_SCALES}"
if (( HPA_SCALES > 0 )); then
  detail "  a replica decrease is attributed to the HPA (${HPA_SCALES} SuccessfulRescale),"
  detail "  i.e. the documented memory walk-down (design.md sections 5 and 14, finding 7)."
fi

# The conclusive, mechanism-based argument. With maxSurge: 1 / maxUnavailable: 0
# a rolling update scales the old ReplicaSet down ONLY after a replacement becomes
# Available. No replacement became Available (asserted just above), so the rollout
# could not have performed any scale-down attributed to it.
MAX_UNAVAIL="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
  -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null || true)"
if [[ "${MAX_UNAVAIL}" == "0" ]]; then
  ok "  finding 7: maxUnavailable=0 and 0 replacements became Available"
  detail "    -> the rollout COULD NOT have scaled the old ReplicaSet down, so any"
  detail "       replica decrease during this window is the HPA (SuccessfulRescale),"
  detail "       not a maxUnavailable violation. This argues from mechanism, which"
  detail "       is the only conclusive form (design.md section 14, finding 7)."
  CHAOS_CHECKS=$((CHAOS_CHECKS + 1))
else
  warn "maxUnavailable is '${MAX_UNAVAIL}', not 0 - the mechanism argument above does not hold"
  detail "the stall was still safe, but a scale-down cannot be attributed this way"
fi

# --- (a1, continued) OPTIONAL: wait out the deadline and observe detection -----
if (( WAIT_DEADLINE )); then
  # The deployment's Progressing condition turns False/ProgressDeadlineExceeded
  # once progressDeadlineSeconds elapses without progress. Waiting is opt-in
  # because ~600 s is a long test; the short run asserts the bound from the spec
  # instead of pretending to have measured it.
  log "waiting for ProgressDeadlineExceeded (bound ${PROGRESS_DEADLINE}s) - this takes ~10 min"
  DEADLINE_WAIT=$(( PROGRESS_DEADLINE + 180 ))
  WAIT_UNTIL=$(( SECONDS + DEADLINE_WAIT ))
  CONDITION_FIRED=0
  while (( SECONDS < WAIT_UNTIL )); do
    REASON="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
      -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null || true)"
    if [[ "${REASON}" == "ProgressDeadlineExceeded" ]]; then
      CONDITION_FIRED=1
      break
    fi
    printf '\r     waiting for ProgressDeadlineExceeded: %ss elapsed (%ss bound)   ' \
      "$(( SECONDS - T_INJECT ))" "${PROGRESS_DEADLINE}"
    sleep 10
  done
  printf '\n'
  T_DETECTED=$(( SECONDS - T_INJECT ))

  assert_eq "detection FIRED automatically (Progressing=False/ProgressDeadlineExceeded)" \
    "${CONDITION_FIRED}" "1"

  # WINDOW [600, 780], justified: the condition cannot fire BEFORE
  # progressDeadlineSeconds (600 s) - firing early would mean the bound is not
  # honoured - and the measured overshoot was 11 s, one control-loop sync. 180 s
  # of headroom accommodates a slower sync interval without accepting a rollout
  # that is never declared failed at all.
  assert_in_window "time to ProgressDeadlineExceeded (bound ${PROGRESS_DEADLINE}s; measured 611s)" \
    "${T_DETECTED}" "${PROGRESS_DEADLINE}" 780

  OVERSHOOT=$(( T_DETECTED - PROGRESS_DEADLINE ))
  detail "overshoot beyond progressDeadlineSeconds: ${OVERSHOOT}s (documented measure: 11s = one sync)"
  detail "DETECTION IS BOUNDED AND AUTOMATIC - this is the condition to alert on,"
  detail "not the absence of activity. See docs/design.md section 7."
  record_doc_discrepancy "${SCENARIO}" \
    "ProgressDeadlineExceeded at 611s (design.md section 7, one control-loop sync over the 600s bound)" \
    "measured ${T_DETECTED}s this run (overshoot ${OVERSHOOT}s)" \
    "Consistent. The overshoot is bounded by the deployment controller's sync interval; no change recommended unless it grows with the bound."

  event_log_snapshot "${SNAPSHOT_DIR}/events.after-deadline"
  assert_true "the deadline was reported as a deployment event (alertable symptom)" \
    bash -c "grep -q 'ProgressDeadlineExceeded' '${SNAPSHOT_DIR}/events.after-deadline'"
else
  detail "skipping the ~600s deadline wait (pass --wait-progress-deadline to observe it)"
  detail "detection is asserted BOUNDED from the live spec above; it was not measured this run"
fi

# --- REMEDIATION requires an EXPLICIT undo -----------------------------------
# Nothing above healed it, so the documented remedy is performed here. Were this
# automatic in production the system would be rolling back legitimate deploys; the
# test proves the remedy works while keeping it a conscious act.
if ! chaos_require_consent "${SCENARIO}" \
     "explicitly roll back deployment/demo-api with 'kubectl rollout undo' (the documented remedy)"; then
  warn "refused: no consent to roll back; the deployment is LEFT BROKEN"
  detail "recover by hand: kubectl rollout undo deployment/demo-api -n ${K8S_NAMESPACE}"
  print_failure_summary || exit 1
  exit 3
fi

# Rule 1, before the undo. `rollout undo` supports --dry-run=server.
log "rule 1: server-side dry-run of the rollback"
if ! kubectl rollout undo deployment/demo-api -n "${K8S_NAMESPACE}" --dry-run=server >/dev/null 2>&1; then
  err "server-side dry-run of 'rollout undo' was REJECTED; refusing to mutate"
  print_failure_summary || exit 1
  exit 1
fi
ok "dry-run accepted"

T_UNDO_START="${SECONDS}"
# GUARDED-BY: chaos_require_consent above (rule 2); --dry-run=server immediately above (rule 1)
kubectl rollout undo deployment/demo-api -n "${K8S_NAMESPACE}" >/dev/null
ok "explicit rollback issued (this is the remedy; nothing auto-healed before it)"

# wait_for_rollout is reused from common.sh (polls `kubectl rollout status`). A
# failure is recorded, not raised, so the report is complete rather than truncated.
ROLLED_OUT=0
if wait_for_rollout "${K8S_NAMESPACE}" demo-api; then
  ROLLED_OUT=1
fi
assert_eq "explicit rollback healed the workload (rollout completed)" "${ROLLED_OUT}" "1"
T_RECOVERED=$(( SECONDS - T_UNDO_START ))

# WINDOW [0, 120]: the rollback is a fresh rollout, whose reverted pods must be
# created, pass their startupProbe (up to 24 x 5 s is allowed for a slow boot) and
# become Ready under maxUnavailable: 0. 120 s is a generous ceiling that still
# fails a rollback that never lands.
assert_in_window "time from explicit undo to a completed rollout" "${T_RECOVERED}" 0 120

IMAGE_AFTER="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
detail "image after rollback: ${IMAGE_AFTER}"
assert_eq "the image is back to the known-good reference" "${IMAGE_AFTER}" "${EXPECTED_IMAGE}"
assert_ready_replicas_at_least "full availability restored after the rollback" "${READY_BEFORE}"

# No pod from before the test should have been lost, even across the undo: the
# rollback replaces the bad surge pods, not the serving ones.
assert_no_pods_removed "no original serving pod was lost across injection + rollback" \
  "${SNAPSHOT_DIR}/pods.before"

# --- rule 10 ------------------------------------------------------------------
check_event_log "${SCENARIO}" "${EVENTS_BEFORE}" '^(Pod|ReplicaSet|Deployment)/demo-api'

printf '\n'
detail "watch list (docs/runbook.md section 4.1): pod STATUS is ImagePullBackOff, but READY stays ${READY_BEFORE}"
detail "alert on Progressing=False/ProgressDeadlineExceeded - that condition fires on"
detail "schedule. Do NOT alert on 'no events', which is not what happens here."
detail "if this ever remediates itself, a legitimate bad deploy would be rolled back"
detail "automatically - see docs/design.md section 7 and section 9."
print_failure_summary || exit 1
ok "${SCENARIO}: PASSED"
exit 0
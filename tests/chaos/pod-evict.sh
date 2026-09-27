#!/usr/bin/env bash
# tests/chaos/pod-evict.sh - chaos test for the SANCTIONED pod replacement path.
#
# WHAT THIS TESTS
#   That pod replacement goes through the eviction subresource, so the API server
#   consults the PodDisruptionBudget before agreeing. This is the sanctioned path
#   (AGENTS.md safety rule 3; docs/adr/0005-use-eviction-api-not-delete.md).
#
#   The scenario has TWO distinct outcomes and BOTH are asserted, because a
#   refusal is not a failure - it is the budget working (ADR-0005, Consequences):
#
#     ALLOWED  PDB has disruption headroom -> the pod is evicted and the
#              ReplicaSet replaces it. Time window applies.
#     REFUSED  PDB is exhausted -> the API server returns 429 and NO pod is
#              replaced. Blast radius is zero and nothing is waited for.
#
#   The driver prints which happened, so this test does not have to guess: it
#   parses the driver's own verdict and asserts the matching contract. Asserting
#   "replaced" on a refused run (or vice versa) would be exactly the kind of
#   divergence between claim and observation that design.md §14 catalogues.
#
# WHAT IT ASSERTS
#   (a) TIME        on ALLOWED, eviction -> Ready replacement within a window.
#                   On REFUSED, time is not asserted (nothing was promised);
#                   the assertion is that the wait was NOT entered.
#   (b) BLAST RADIUS on ALLOWED, at most one pod replaced (the PDB bounds it).
#                   On REFUSED, ZERO pods changed - asserted strictly, because
#                   "refused but a pod vanished anyway" is the worst bug this
#                   scenario could have.
#
# SAFETY
#   Rule 1: `kubectl create --raw` CANNOT honour --dry-run (ADR-0005: the flag is
#           silently dropped and the "dry-run" is a real eviction). The dry-run
#           gate is therefore performed by other means: the PDB itself, plus the
#           precondition check that minAvailable is 2 and the workload is fully
#           Ready before anything is evicted. This is stated rather than faked -
#           a raw call carrying --dry-run would be a live mutation wearing a
#           safety label, which assert_no_raw_dry_run_claim() fails on.
#   Rule 2: consent gate before the driver call.
#   Rule 3: eviction only; the driver is asserted NOT to delete a pod here.
#   Rule 10: event log checked after the run.
#
# BASELINE-RELATIVE REPLICA ASSERTIONS - AND A DEFECT IN THE DRIVER'S OWN WAIT
#   Every replica assertion here is made against a value sampled BEFORE the
#   eviction, never against a literal. The reason is a real bug in the canonical
#   scenario this test wraps, which this script deliberately does NOT reproduce:
#
#     scripts/inject-failure.sh:196-198 (scenario_pod_evict)
#       wait_for "3 ready replicas" 120 \
#         bash -c "[[ \"\$(...readyReplicas)\" == \"3\" ]]"
#
#   That exit condition can be UNREACHABLE. The deployment's spec.replicas is an
#   absolute count chosen by the HPA, and per design.md §5 the HPA's memory-bound
#   fixed point sits at 5, 6 or 7 replicas - `ceil(N x ratio) == N` holds for
#   every N in 1..7 at the observed memory ratio, so the descent stops at the
#   first fixed point it meets and never reaches minReplicas=3. On a cluster that
#   has walked down to 7 (the natural resting state), readyReplicas goes 7 -> 6 ->
#   7 and is never equal to 3, so the driver's wait burns its full 120 s and then
#   reports a FALSE FAILURE - the eviction worked, and the assertion was wrong.
#
#   This is the same defect class as the ad-hoc wait loop whose exit condition
#   (`replicas == 3 && desired == 3`) was unreachable and was removed earlier.
#   Asserting "ready returned to the sampled baseline" is correct whether the
#   deployment is at 3, 5, 7 or 10, and is the stronger claim besides: it says
#   the eviction did not permanently reduce capacity.
#
#   NOTE: this is a report, not a fix. scripts/inject-failure.sh is not modified.
#
# USAGE
#   tests/chaos/pod-evict.sh [--case allowed|refused|auto] [--yes] [--static]
#
#   --case auto (default) asserts whichever outcome the cluster actually
#   produces, after requiring the outcome to be one of the two known verdicts.
#   --case allowed|refused additionally requires that specific outcome, so a CI
#   matrix can force each branch.
#
#   To exercise REFUSED deliberately: raise the PDB to minAvailable: 3 and let
#   the workload sit at 3/3 (no headroom). See docs/runbook.md §4.
#
# EXIT CODES
#   0 = passed, 1 = assertion failed, 2 = usage error,
#   3 = refused (no consent / no cluster),
#   4 = the driver produced no recognisable verdict.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "${SCRIPT_DIR}/../../scripts/lib/common.sh"
# shellcheck source=lib/assert.sh
. "${SCRIPT_DIR}/lib/assert.sh"

SCENARIO="pod-evict"
STATIC_ONLY=0
CASE_MODE="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static) STATIC_ONLY=1 ;;
    --case)   shift; CASE_MODE="${1:-}"; [[ -n "${CASE_MODE}" ]] || die "--case needs a value" ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
export ASSUME_YES="${ASSUME_YES:-0}"

case "${CASE_MODE}" in
  auto|allowed|refused) ;;
  *) die "--case must be one of: auto, allowed, refused (got '${CASE_MODE}')" ;;
esac

report_state_location

# --- static mode: offline contract checks, no cluster contact -----------------
if (( STATIC_ONLY )); then
  log "static contract checks: ${SCENARIO} (case=${CASE_MODE})"
  if chaos_static_checks "$0"; then
    assert_no_raw_dry_run_claim "ADR-0005: no --raw call claims --dry-run" "$0" \
      "${SCRIPTS_DIR}/inject-failure.sh" || true
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

# ADR-0005 / design.md section 14 finding 1: the eviction subresource is
# addressed by its raw path because discovery has no top-level `kind: Eviction`.
# Those two properties are what make the dry-run gate impossible here, so they
# are asserted to still hold rather than assumed - if the API ever gains a
# top-level kind, this test should be rewritten, not left passing by luck.
assert_no_raw_dry_run_claim "ADR-0005: no --raw call claims --dry-run" \
  "${SCRIPTS_DIR}/inject-failure.sh"

log "chaos test: ${SCENARIO} (case=${CASE_MODE})"
detail "mechanism : eviction API + PDB gate (docs/design.md section 7)"
detail "expected  : ~15s replaced, or refused (design section 7)"
detail "blast radius: <=1 pod, PDB-bounded"

SNAPSHOT_DIR="$(chaos_snapshot_dir)"
trap 'rm -rf "${SNAPSHOT_DIR:-}"' EXIT INT TERM
EVENTS_BEFORE="${SNAPSHOT_DIR}/events.before"
pod_snapshot "${SNAPSHOT_DIR}/pods.before"
event_log_snapshot "${EVENTS_BEFORE}"

TARGET_POD="$(pick_target_pod)"
[[ -n "${TARGET_POD}" ]] || die "no running demo-api pod to target - is the deployment healthy?"
detail "target pod: ${TARGET_POD}"

# --- the baseline the PDB decision is made against ---------------------------
PDB_MIN="$(pod_disruption_budget_min_available)"
READY_BEFORE="$(deployment_ready_replicas)"
DESIRED_BEFORE="$(deployment_desired_replicas)"
detail "before: ${READY_BEFORE}/${DESIRED_BEFORE} ready, PDB minAvailable=${PDB_MIN}"

# Rule 1's substitute for this path. The eviction cannot be dry-run, so the
# safety comes from the budget: a workload that is already below minAvailable
# would be evicted only in the REFUSED direction, but evicting from an already
# degraded workload is not a demonstration worth having. Refuse to start.
if [[ "${READY_BEFORE:-0}" != "${DESIRED_BEFORE:-0}" ]]; then
  warn "workload is not fully ready (${READY_BEFORE:-0}/${DESIRED_BEFORE:-0}); refusing to evict"
  detail "evicting a degraded workload would confound the result and is not a safe demonstration"
  exit 3
fi
assert_pdb_min_available "precondition: PDB minAvailable (design.md section 5)" "2"

# --- consent (rule 2) ---------------------------------------------------------
if ! chaos_require_consent "${SCENARIO}" "evict pod ${TARGET_POD} through the eviction API (PDB-gated)"; then
  warn "refused: no consent to evict (re-run with --yes to opt in)"
  exit 3
fi

# --- run the driver -----------------------------------------------------------
# WINDOW [6, 45] applies only in the ALLOWED case, justified:
#   lower 6 s  - the driver's own wait_for polls readyReplicas on a 2 s period
#                (common.sh), so the measurement is quantised to 2 s; 6 s leaves
#                room for that quantisation plus ReplicaSet scheduling jitter.
#   upper 45 s - generous upper bound over the documented ~15 s (§7) and §8's
#                ~16 s. Eviction adds an API round-trip and, unlike pod-kill, the
#                replacement competes with the terminating pod for resources on a
#                single-node cluster.
log "running the driver: ${CHAOS_INJECT} ${SCENARIO}"
T0="${SECONDS}"
# GUARDED-BY: chaos_require_consent above (rule 2); PDB + readiness precondition above (rule 1 substitute)
DRIVER_OUT="${SNAPSHOT_DIR}/driver.out"
DRIVER_RC=0
run_inject "${SCENARIO}" --yes >"${DRIVER_OUT}" 2>&1 || DRIVER_RC=$?
T_ELAPSED=$(( SECONDS - T0 ))
cat "${DRIVER_OUT}"
DRIVER_TEXT="$(cat "${DRIVER_OUT}")"

# The driver's exit status. ONE specific non-zero status is diagnosed rather than
# simply failing: the known-unreachable `== "3"` wait documented in the header.
# The eviction itself succeeded in that case, so reporting "driver exit status 1"
# would blame the wrong thing and hide a bug that lives in scripts/, not here.
if (( DRIVER_RC != 0 )); then
  if grep -qE 'not healed|timed out|timeout' "${DRIVER_OUT}" \
     && grep -qE 'eviction accepted' "${DRIVER_OUT}"; then
    warn "driver exit ${DRIVER_RC}: the eviction SUCCEEDED but the driver's own"
    detail "  'wait_for \"3 ready replicas\"' condition was never satisfied - see the"
    detail "  BASELINE-RELATIVE note in this file's header. The deployment is not at"
    detail "  3 replicas and cannot reach it (design.md section 5), so that wait is"
    detail "  unreachable and its failure is a defect in scripts/inject-failure.sh."
    detail "  This script asserts the eviction against the BASELINE sampled above"
    detail "  (${READY_BEFORE}) instead, which is the correct contract."
    detail "  REPORTED, NOT FIXED: scripts/inject-failure.sh is out of scope here."
  else
    assert_eq "driver exit status" "${DRIVER_RC}" "0"
  fi
fi

# --- determine which of the two sanctioned outcomes occurred ------------------
# The driver's own words, per ADR-0005's "observe a refusal" language and the
# runbook's watch list ("eviction accepted" - or "REFUSED by the PDB").
VERDICT=""
if grep -qE 'eviction accepted' <<<"${DRIVER_TEXT}"; then
  VERDICT="allowed"
elif grep -qE 'REFUSED by the PodDisruptionBudget' <<<"${DRIVER_TEXT}"; then
  VERDICT="refused"
fi

if [[ -z "${VERDICT}" ]]; then
  err "the driver produced no recognisable verdict (expected 'eviction accepted' or 'REFUSED by the PodDisruptionBudget')"
  detail "a run that neither evicted nor was refused proves nothing; see the output above"
  print_failure_summary || exit 1
  exit 4
fi
ok "verdict: ${VERDICT}"

if [[ "${CASE_MODE}" != "auto" && "${CASE_MODE}" != "${VERDICT}" ]]; then
  assert_eq "requested case" "${VERDICT}" "${CASE_MODE}"
  print_failure_summary || exit 1
  exit 1
fi

# --- assert the contract for the observed outcome ----------------------------
if [[ "${VERDICT}" == "allowed" ]]; then
  log "case ALLOWED: asserting the replacement contract"

  # (a) time. Window [4, 30], justified.
  #
  # pod-evict and pod-kill share the SAME replacement mechanism: the ReplicaSet
  # creates a replacement, which must pass its first readiness probe. So the
  # documented pod-kill range (~7-15 s, design.md §7/§8) describes this path too -
  # the spread there is probe PHASE OFFSET and cold-vs-cached image pull, neither
  # of which the eviction API changes. The `~15 s` in §7's pod-evict row is
  # therefore the same "worst case written as if deterministic" error that row's
  # pod-kill sibling was corrected for; it should be a range, and this window is
  # built as one rather than asserting a point value.
  #
  #   lower 4 s  - below the fast path's 7 s, absorbing the 1-3 s of driver startup
  #                included in T0 and wait_for's 2 s polling granularity.
  #   upper 30 s - above the slow path's 15 s and §8's ~16 s ceiling. Slightly
  #                wider than pod-kill's 25 s because eviction adds an API
  #                round-trip (the PDB admission check) and, unlike delete, the
  #                terminating pod and its replacement briefly coexist, competing
  #                for resources on a single-node cluster.
  # The pod object records the replacement's REAL time-to-Ready, so that is the
  # primary measurement. It is preferred over T_ELAPSED because the driver's own
  # wait has an unreachable exit condition (header note): on a deployment that is
  # not at 3 replicas the driver burns a 120 s timeout, so T_ELAPSED measures the
  # TIMEOUT rather than the replacement. Asserting that would convert a defect in
  # scripts/ into a failure of the system under test.
  NEW_POD="$(newest_app_pod)"
  if [[ -n "${NEW_POD}" ]]; then
    assert_ready_latency "time from eviction to a Ready replacement (documented ~15s; range note above)" \
      "${NEW_POD}" 4 30 "${T_ELAPSED}"
  else
    _chaos_fail "time from eviction to a Ready replacement" \
      "no demo-api pod found after the eviction, so latency could not be measured"
  fi

  # T_ELAPSED is reported, not asserted as the primary figure. It is still checked
  # against a deliberately loose ceiling so a driver that hangs FAR beyond its own
  # 120 s wait is caught - without turning the known-unreachable wait into a
  # spurious failure here.
  detail "driver elapsed (upper bound; includes any driver-side wait): ${T_ELAPSED}s"
  assert_in_window "driver did not hang beyond its own wait budget" "${T_ELAPSED}" 0 180

  assert_false "the evicted pod was really removed" \
    kubectl get pod "${TARGET_POD}" -n "${K8S_NAMESPACE}"
  # Relative to the sampled baseline, never an absolute 3: the HPA's memory-bound
  # fixed point holds at 5/6/7 and cannot descend to minReplicas=3 (design.md §5),
  # so an absolute assertion would fail on a correctly-behaving cluster.
  assert_ready_replicas_at_least "recovery: ready replicas restored to the pre-eviction baseline" \
    "${READY_BEFORE}"

  # (b) blast radius: the PDB bounds it at <=1 replaced.
  assert_pods_unchanged "blast radius: at most one pod replaced (PDB-bounded)" \
    "${SNAPSHOT_DIR}/pods.before" 1
else
  log "case REFUSED: asserting the budget held"

  # A refusal is the budget working, so there is nothing to time: no replacement
  # was promised and none should be waited for. The driver returns immediately,
  # and the assertion is that it did.
  assert_in_window "refusal returned promptly (no replacement was waited for)" \
    "${T_ELAPSED}" 0 30

  assert_true "the targeted pod still exists (the budget protected it)" \
    kubectl get pod "${TARGET_POD}" -n "${K8S_NAMESPACE}"

  # (b) ZERO tolerance here. "Refused, but a pod disappeared anyway" means the
  # refusal was cosmetic, which is strictly worse than no test at all.
  assert_pods_unchanged "blast radius: ZERO pods changed on a refusal" \
    "${SNAPSHOT_DIR}/pods.before" 0
  # Same baseline-relative rule as the ALLOWED branch, and for the same reason.
  assert_ready_replicas_at_least "workload still fully available after the refusal" \
    "${READY_BEFORE}"
fi

# --- rule 3: this path must not delete --------------------------------------
# The driver's eviction path reaches the API via `create --raw`; a `delete pod`
# appearing in this scenario's own output would mean the sanctioned path had been
# silently swapped for the negative control.
assert_false "rule 3: the sanctioned path did not fall back to 'delete pod'" \
  grep -qE '(^|[[:space:]])kubectl delete pod' "${DRIVER_OUT}"

# --- rule 10 ------------------------------------------------------------------
check_event_log "${SCENARIO}" "${EVENTS_BEFORE}" '^(Pod|ReplicaSet|Deployment)/demo-api'

printf '\n'
detail "watch list (docs/runbook.md section 4.1): 'eviction accepted' - or 'REFUSED by the PDB'"
detail "the sanctioned path is the eviction API, never 'kubectl delete pod' (ADR-0005)"
print_failure_summary || exit 1
ok "${SCENARIO}: PASSED (case=${VERDICT})"
exit 0
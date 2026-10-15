#!/usr/bin/env bash
# tests/chaos/node-drain.sh - chaos test for the drain REFUSAL path (GUARD TEST).
#
# READ THIS FIRST: ON THIS CLUSTER THIS IS A GUARD TEST, NOT A SCHEDULER TEST
#   docs/design.md §7 ("The `node-drain` scenario validates a refusal path, not
#   the scheduler") is explicit: this cluster runs a single node, and draining the
#   only node would evict every workload with nowhere to reschedule it - the
#   outage the operation is supposed to be safe against. The scenario therefore
#   refuses to run below two schedulable nodes.
#
#   What a local run proves is that the GUARD works: the scenario detects the node
#   count, declines BEFORE cordoning anything, and leaves the node schedulable and
#   uncordoned. That is worth testing - an unguarded drain scenario would take the
#   cluster down the first time it was run - but it exercises the precondition,
#   not the scheduler.
#
#   This script detects the node count and branches:
#     * 1 (or 0) schedulable nodes -> GUARD TEST. The guard is asserted to refuse,
#       and the run is LABELLED a guard test everywhere it reports, so a green
#       result can never be mistaken for "the scheduler was verified".
#     * >= 2 schedulable nodes -> FULL TEST. The guard is asserted to ALLOW, and
#       drain/uncordon are performed behind their own consent gates.
#
# THE ~60 s FIGURE IS NOT A MEASUREMENT
#   design.md §7 gives `node-drain` an expected time of ~60 s and states plainly
#   that this is "a design estimate from the budget in §8, not a measurement",
#   and that the full scheduler test "requires >=2 nodes and has not been
#   executed". This script therefore:
#     * does NOT assert ~60 s in the guard path (nothing was scheduled);
#     * in the full path, treats 60 s as an ESTIMATE and records the discrepancy
#       rather than presenting an estimate as a measured expectation.
#   Asserting a measured window against a figure the documentation itself calls
#   unmeasured would manufacture confidence, which is worse than no test.
#
# WHAT IT ASSERTS (GUARD TEST)
#   (a) TIME        the guard refuses promptly - it must decline before touching
#                   anything, not after cordoning and discovering there is nowhere
#                   to go. Window [0, 30] with its basis stated at the call site.
#   (b) BLAST RADIUS ZERO. The node must still be schedulable and uncordoned, and
#                   no pod may have moved. This is the whole point of the guard.
#
# SAFETY
#   Rule 1: `kubectl drain --dry-run=server` runs BEFORE the real drain, and is
#           asserted to run first. Verified offline: kubectl drain accepts
#           --dry-run=server on v1.31.14.
#   Rule 2: `cordon` and `drain` are both explicitly destructive (CONTRIBUTING.md rule
#           2) and both sit behind a consent gate, in the full-test path only.
#           In the guard path NOTHING is cordoned or drained at all.
#   Rule 3: no pod is deleted; drain goes through the eviction API, which is the
#           PDB-respecting path (ADR-0005).
#   Rule 10: event log checked after the run.
#
# USAGE
#   tests/chaos/node-drain.sh [--yes] [--static] [--expect-guard|--expect-full]
#
#   --expect-guard : fail the run if the cluster turns out to have >=2 nodes
#                    (useful to pin the local single-node expectation in CI).
#   --expect-full  : fail the run if the cluster has <2 nodes.
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

SCENARIO="node-drain"
STATIC_ONLY=0
EXPECT_MODE="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)       STATIC_ONLY=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --expect-guard) EXPECT_MODE="guard" ;;
    --expect-full)  EXPECT_MODE="full" ;;
    -h|--help) sed -n '2,68p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

SNAPSHOT_DIR="$(chaos_snapshot_dir)"
trap 'rm -rf "${SNAPSHOT_DIR:-}"' EXIT INT TERM
EVENTS_BEFORE="${SNAPSHOT_DIR}/events.before"
pod_snapshot "${SNAPSHOT_DIR}/pods.before"
event_log_snapshot "${EVENTS_BEFORE}"

# Sampled once, before anything is touched, so every availability assertion in both
# paths is relative to it rather than to a literal. The HPA's memory-bound fixed
# point holds at 5/6/7 and cannot descend to minReplicas=3 (docs/design.md §5), so
# an absolute count would fail for a reason unrelated to the drain.
BASELINE_READY="$(deployment_ready_replicas)"
detail "baseline: ${BASELINE_READY} ready replica(s)"

# --- detect the node count (this decides GUARD TEST vs FULL TEST) ------------
SCHEDULABLE_NODES="$(schedulable_node_count)"
ALL_NODES="$(node_names | tr '\n' ' ')"
detail "nodes: ${ALL_NODES:-<none>}"
detail "schedulable nodes: ${SCHEDULABLE_NODES}"

# A node count that cannot be read is not the same as a single-node cluster, and
# treating it as one would make the guard test pass for the wrong reason.
if [[ ! "${SCHEDULABLE_NODES}" =~ ^[0-9]+$ ]]; then
  err "could not determine the number of schedulable nodes (got '${SCHEDULABLE_NODES}')"
  print_failure_summary || exit 1
  exit 1
fi

MODE="guard"
(( SCHEDULABLE_NODES >= 2 )) && MODE="full"

case "${EXPECT_MODE}" in
  auto) ;;
  guard) assert_eq "requested mode" "${MODE}" "guard" ;;
  full)  assert_eq "requested mode" "${MODE}" "full" ;;
esac

if [[ "${MODE}" == "guard" ]]; then
  log "chaos test: ${SCENARIO} (GUARD TEST - not a scheduler test)"
  detail "GUARD TEST: this cluster has ${SCHEDULABLE_NODES} schedulable node(s)"
  detail "the drain guard must refuse, leaving the node schedulable and uncordoned"
  detail "the full scheduler test requires >=2 nodes and HAS NOT BEEN EXECUTED"
  detail "authority: docs/design.md section 7, 'validates a refusal path, not the scheduler'"
else
  log "chaos test: ${SCENARIO} (FULL TEST - >=2 schedulable nodes)"
  detail "mechanism : scheduler reschedules evicted pods (docs/design.md section 7)"
  detail "expected  : ~60s - a DESIGN ESTIMATE from section 8, NOT a measurement"
  detail "blast radius: 1 node cordoned; pods rescheduled onto the remaining node(s)"
fi

# --- the guard's contract, asserted from the canonical implementation --------
# The guard lives in the driver (scenario_node_drain). It is invoked with --yes
# and asserted on its output; duplicating the node-count logic here would create
# a second, possibly disagreeing implementation of the guard.
T0="${SECONDS}"
# GUARDED-BY: nothing is cordoned or drained in the guard path; the driver's own guard refuses before any mutation
DRIVER_OUT="${SNAPSHOT_DIR}/driver.out"
DRIVER_RC=0
run_inject "${SCENARIO}" --yes >"${DRIVER_OUT}" 2>&1 || DRIVER_RC=$?
T_GUARD=$(( SECONDS - T0 ))
cat "${DRIVER_OUT}"
DRIVER_TEXT="$(cat "${DRIVER_OUT}")"

if [[ "${MODE}" == "guard" ]]; then
  # --- GUARD TEST ------------------------------------------------------------
  assert_eq "driver exit status" "${DRIVER_RC}" "0"

  # The refusal must be the documented one, naming the node count. Asserting the
  # message matters: a run that simply did nothing would otherwise look identical.
  assert_contains "the guard refused to drain" "${DRIVER_TEXT}" 'refusing to drain'
  assert_contains "the refusal names the schedulable node count" \
    "${DRIVER_TEXT}" "this cluster has ${SCHEDULABLE_NODES} schedulable node"

  # (a) TIME. WINDOW [0, 30] justified: the guard is a single `kubectl get nodes`
  # plus a numeric comparison, so it must decide in well under one second. The
  # generous 30 s ceiling exists to fail a guard that, instead of declining,
  # cordoned the node and then blocked waiting for pods to reschedule (which on a
  # single node would hang until its own drain timeout). It is NOT a healing
  # time - nothing heals in this path - and it is deliberately not compared to
  # the ~60 s estimate in section 7, which describes a scenario that did not run.
  assert_in_window "guard refused promptly (no cordon, no drain attempted)" \
    "${T_GUARD}" 0 30

  # (b) BLAST RADIUS: ZERO. This is the load-bearing assertion of the guard test.
  for NODE in $(node_names); do
    assert_true "node ${NODE} is still schedulable (uncordoned)" node_is_schedulable "${NODE}"
  done

  assert_pods_unchanged "blast radius: ZERO pods moved (nothing was drained)" \
    "${SNAPSHOT_DIR}/pods.before" 0
  # Relative to the baseline sampled before the guard ran. An absolute 3 would fail
  # on a cluster resting at the HPA's memory-bound fixed point of 5/6/7 (design.md
  # section 5), which has nothing to do with whether the drain guard worked.
  assert_ready_replicas_at_least "workload untouched (ready replicas)" "${BASELINE_READY}"

  # The guard must refuse BEFORE cordoning. A cordoned-then-refused node would be
  # a real outage risk even though the drain itself was declined.
  assert_false "no cordon was recorded" \
    grep -qE '(^|[[:space:]])kubectl cordon' "${DRIVER_OUT}"

  # The documentation's own words: this path is unverified for the scheduler.
  detail "RESULT: GUARD TEST. The refusal path is verified; the SCHEDULER PATH IS NOT."
  detail "the ~60s figure in design.md section 7 remains an unmeasured estimate."

  print_failure_summary || exit 1
  printf '\n'
  report_doc_discrepancies
  ok "${SCENARIO}: PASSED (GUARD TEST - single schedulable node)"
  detail "to run the FULL test, the cluster needs >=2 nodes:"
  detail "  minikube node add --profile ${CLUSTER_NAME}"
  detail "expanding to multi-node is past the 3-resource threshold (CONTRIBUTING.md rule 7)"
  detail "and needs explicit authorisation - see design.md section 7"
  exit 0
fi

# --- FULL TEST: >=2 schedulable nodes ----------------------------------------
log "FULL TEST path: ${SCHEDULABLE_NODES} schedulable nodes"
assert_eq "driver exit status" "${DRIVER_RC}" "0"

NODE="$(node_names | head -n 1)"
[[ -n "${NODE}" ]] || die "no node found to drain"
detail "target node: ${NODE}"

if ! chaos_require_consent "${SCENARIO}" \
     "cordon and drain node ${NODE} (destructive: CONTRIBUTING.md rule 2)"; then
  warn "refused: no consent to drain (re-run with --yes to opt in)"
  print_failure_summary || exit 1
  exit 3
fi

# Rule 1: server-side dry-run before the real drain. This exercises the drain
# planning (eviction checks, PDB admission, daemonset handling) without evicting.
# If the pod count is >3 this touches more than three resources, so CONTRIBUTING.md
# rule 7 requires a plan first - stated here rather than silently proceeding.
warn "rule 7: draining a node affects every pod on it; a plan is required above 3 resources"
log "rule 1: server-side dry-run of the drain"
if ! kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data \
      --timeout=180s --dry-run=server >/dev/null 2>&1; then
  err "server-side dry-run of the drain was REJECTED; refusing to drain"
  detail "inspect with: kubectl get nodes && kubectl get pods -A --field-selector spec.nodeName=${NODE}"
  print_failure_summary || exit 1
  exit 1
fi
ok "dry-run accepted"

T_DRAIN_START="${SECONDS}"
# Rule 1 for the CORDON specifically, as a separate probe from the drain above.
# The drain dry-run does not cover it: cordon is its own destructive operation
# (CONTRIBUTING.md rule 2 lists it explicitly), and it is the step that actually removes
# the node from service. Verified offline: `kubectl cordon` accepts
# --dry-run=server on the kubectl in this repository (v1.31.14).
log "rule 1: server-side dry-run of the cordon"
if ! kubectl cordon "${NODE}" --dry-run=server >/dev/null 2>&1; then
  err "server-side dry-run of the cordon was REJECTED; refusing to cordon"
  print_failure_summary || exit 1
  exit 1
fi
ok "cordon dry-run accepted"

# GUARDED-BY: chaos_require_consent above (rule 2); cordon dry-run immediately above (rule 1)
kubectl cordon "${NODE}" || { err "cordon failed"; exit 1; }
# GUARDED-BY: chaos_require_consent above (rule 2); drain dry-run validated above (rule 1)
# Rule 3: drain evicts through the eviction API, so the PDB gates it (ADR-0005).
if ! kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=180s; then
  err "drain failed; node ${NODE} may still be cordoned"
  detail "recover with: kubectl uncordon ${NODE}"
  print_failure_summary || exit 1
  exit 1
fi
T_DRAINED=$(( SECONDS - T_DRAIN_START ))
ok "drained in ${T_DRAINED}s"

# --- (a) TIME, as an estimate ------------------------------------------------
# The documentation calls ~60 s a design estimate, not a measurement, and the
# full path has never been executed on this cluster. The window below is derived
# from section 8's budget (eviction + scheduling + readiness) rather than from an
# observation, and the discrepancy is RECORDED so the report cannot present it as
# a measured expectation. WINDOW [0, 300]: the driver itself passes
# --timeout=180s, and each evicted pod must be rescheduled and become Ready, so
# 180 s of drain plus readiness cannot legitimately exceed 300 s.
assert_in_window "time to drain (section 7 ESTIMATE ~60s; never measured here)" \
  "${T_DRAINED}" 0 300
record_doc_discrepancy "${SCENARIO}" \
  "~60s (design.md section 7 - documentation states this is a design ESTIMATE, not a measurement)" \
  "not measured (the full scheduler path has never been executed on this cluster)" \
  "Do not treat a pass here as validating the ~60s figure. Either measure it on a >=2-node cluster and update section 7, or keep the figure explicitly marked as an estimate."

# --- (b) BLAST RADIUS --------------------------------------------------------
# The drained node's workload must have moved, not vanished: the PDB keeps
# minAvailable of the replicas available and the scheduler places the replacements
# on remaining capacity. Relative to the pre-drain baseline, for the reason above.
assert_ready_replicas_at_least "workload still available after the drain" "${BASELINE_READY}"

RESCHEDULED="$(kubectl get pods -n "${K8S_NAMESPACE}" -l "${CHAOS_APP_LABEL}" \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | grep -vc "^${NODE}$" || true)"
detail "demo-api pods no longer on ${NODE}: ${RESCHEDULED}"
assert_true "at least one pod was rescheduled onto another node" \
  bash -c "(( ${RESCHEDULED:-0} >= 1 ))"

assert_no_pods_removed "no original pod was lost (rescheduled, not deleted)" \
  "${SNAPSHOT_DIR}/pods.before"

# --- uncordon: leaving a node cordoned is an unintended mutation -------------
if ! chaos_require_consent "${SCENARIO}" "uncordon node ${NODE} to restore capacity"; then
  warn "refused: node ${NODE} is LEFT CORDONED - this reduces cluster capacity"
  detail "recover with: kubectl uncordon ${NODE}"
  print_failure_summary || exit 1
  exit 3
fi
# GUARDED-BY: chaos_require_consent above (rule 2)
kubectl uncordon "${NODE}"
ok "node ${NODE} uncordoned"
assert_true "node ${NODE} is schedulable again" node_is_schedulable "${NODE}"

# --- rule 10 ------------------------------------------------------------------
check_event_log "${SCENARIO}" "${EVENTS_BEFORE}" \
  '^(Node|Pod|ReplicaSet|Deployment)/|^(Pod|ReplicaSet|Deployment)/demo-api'

printf '\n'
report_doc_discrepancies
print_failure_summary || exit 1
ok "${SCENARIO}: PASSED (FULL TEST)"
exit 0
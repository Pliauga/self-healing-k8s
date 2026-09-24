#!/usr/bin/env bash
# inject-failure.sh - deliberately break the demo workload and observe the
# cluster heal itself.
#
# Each scenario exercises a *different* self-healing mechanism. Running them in
# order is a reasonable demo script.
#
# Usage:
#   scripts/inject-failure.sh --list
#   scripts/inject-failure.sh <scenario> [--yes]
#
# Scenarios:
#   pod-evict      Evict a pod via the eviction API. RESPECTS the PDB, so the
#                  API server can refuse it. This is the sanctioned way to
#                  replace a pod (CONTRIBUTING.md safety rule 3, ADR-0002).
#   pod-kill       Delete a pod directly. NOT a remediation method: it bypasses
#                  the PodDisruptionBudget entirely. Provided only as a negative
#                  control, to demonstrate what the PDB protects against.
#   app-fail       Call /fail in a pod: liveness fails (kubelet restarts the
#                  container) and readiness fails (pod leaves the Service
#                  endpoints). Exercises both probe paths.
#   cpu-load       Drive real CPU load to demonstrate the HPA scaling out.
#   bad-image      Point the deployment at a non-existent image tag. Pods go
#                  ImagePullBackOff and the rollout stalls. Recovery is a
#                  rollout undo.
#   node-drain     Cordoning/draining on a single-node cluster would evict
#                  everything; this scenario refuses to run unless the cluster
#                  has at least two schedulable nodes.
#   recover-all    Undo bad-image (if set), clear injected faults, stop load.

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

LIST_ONLY=0
SCENARIO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l) printf '%s\n' \
                 'pod-evict    evict a pod through the eviction API (respects the PDB) - sanctioned' \
                 'pod-kill     delete a pod directly (bypasses the PDB) - negative control only' \
                 'app-fail     make a pod fail its liveness and readiness probes' \
                 'cpu-load     generate CPU load so the HPA scales out' \
                 'bad-image    break the image tag; roll back to heal' \
                 'node-drain   drain a node (requires >= 2 schedulable nodes)' \
                 'recover-all  revert every injected fault'
               exit 0 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1 (try --help)" ;;
    *)         [[ -n "${SCENARIO}" ]] && die "only one scenario at a time"
               SCENARIO="$1" ;;
  esac
  shift
done
export ASSUME_YES="${ASSUME_YES:-0}"

[[ -n "${SCENARIO}" ]] || { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

require_cluster
assert_namespace "${K8S_NAMESPACE}"

# The Service DNS name, used by the in-cluster curl helper below.
SERVICE_URL="http://demo-api.${K8S_NAMESPACE}.svc.cluster.local"

# --- helpers -----------------------------------------------------------------

# Run curl from inside the cluster, so no local port-forward is needed. Uses a
# throwaway pod with a pinned image and an explicit restart policy.
cluster_curl() {
  local url="$1"
  kubectl run "curl-$(date +%s)-$$" \
    --namespace "${K8S_NAMESPACE}" \
    --image=curlimages/curl:8.11.1 \
    --image-pull-policy=IfNotPresent \
    --restart=Never \
    --quiet \
    --rm -i --command -- curl -sS --max-time 15 "${url}" 2>/dev/null
}

# Pick one running pod of the demo-api deployment.
pick_pod() {
  local pod
  pod="$(deployment_pods "${K8S_NAMESPACE}" demo-api | head -n 1)"
  [[ -n "${pod}" ]] || die "no running demo-api pods found - is the deployment healthy?"
  printf '%s' "${pod}"
}

# Print a pod's restart count, retrying briefly while the value settles.
restart_count() {
  local pod="$1"
  kubectl get pod "${pod}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?"
}

pre_flight() {
  assert_deployment "${K8S_NAMESPACE}" demo-api
  local ready desired
  ready="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  [[ "${ready:-0}" == "${desired:-0}" ]] \
    || warn "deployment is not fully ready (${ready:-0}/${desired:-0}); heal that first"
  detail "baseline: ${ready:-0}/${desired:-0} ready"
}

# --- scenarios ---------------------------------------------------------------

scenario_pod_kill() {
  local pod; pod="$(pick_pod)"
  local before; before="$(restart_count "${pod}")"
  log "scenario: pod-kill (NEGATIVE CONTROL)"
  detail "target pod: ${pod} (restarts: ${before})"

  # CONTRIBUTING.md safety rule 3 forbids `delete pod` as a remediation method, and
  # ADR-0002 explains why: it bypasses the PodDisruptionBudget. This scenario is
  # retained purely to *demonstrate* that bypass, by contrast with pod-evict.
  # It is not a recovery procedure.
  warn "this is NOT a remediation method - it bypasses the PodDisruptionBudget"
  detail "for the sanctioned equivalent, run: scripts/inject-failure.sh pod-evict"

  confirm "Delete pod ${pod} directly (bypassing the PDB)?" || { warn "aborted"; return 0; }

  # Project safety policy (CONTRIBUTING.md rule 1): dry-run server-side before
  # destroying anything. This exercises the real admission chain without
  # performing the delete.
  if ! kubectl delete pod "${pod}" -n "${K8S_NAMESPACE}" --dry-run=server >/dev/null 2>&1; then
    err "server-side dry-run of the pod delete failed; aborting without deleting"
    detail "inspect with: kubectl describe pod ${pod} -n ${K8S_NAMESPACE}"
    return 1
  fi

  kubectl delete pod "${pod}" -n "${K8S_NAMESPACE}" --wait=false
  ok "delete issued - the ReplicaSet controller should create a replacement"
  detail "note: no PDB check occurred; this would have been refused via eviction"

  # The ReplicaSet observes the deletion and creates a new pod. On minikube
  # this typically takes 5-20s including image pull from the local store.
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    local ready desired
    ready="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    desired="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    if [[ "${ready:-0}" == "${desired:-0}" && "${desired:-0}" != "0" ]]; then
      ok "healed: ${ready}/${desired} replicas ready after $((120 - (deadline - SECONDS)))s"
      detail "the killed pod is gone; a new pod name should appear below"
      kubectl get pods -n "${K8S_NAMESPACE}" -l app.kubernetes.io/name=demo-api
      return 0
    fi
    sleep 2
  done
  err "not healed within 120s - investigate with scripts/status.sh"
  return 1
}

scenario_pod_evict() {
  local pod; pod="$(pick_pod)"
  log "scenario: pod-evict"
  detail "target pod: ${pod}"
  detail "eviction is subject to the PodDisruptionBudget (minAvailable: 2)"

  # Sample the baseline BEFORE evicting, and assert recovery against it.
  #
  # This used to read `== "3"`, which is wrong in two independent ways. It assumes
  # the deployment sits at its `minReplicas`, but the HPA's memory-bound fixed
  # point (docs/design.md section 5) holds at 5, 6 or 7 and cannot descend to 3
  # autonomously - so at the natural post-cpu-load state the predicate was
  # unreachable and this scenario burned its full 120s timeout and returned 1
  # AFTER a successful eviction. It also assumes the baseline is stable, when the
  # HPA may be mid-walk-down.
  #
  # The invariant that actually matters is relative: the ready count must return
  # to whatever it was, because the eviction removed exactly one pod and the
  # ReplicaSet replaced it. That holds at 3, 5, 7 or 10.
  local baseline
  baseline="$(deployment_ready_replicas "${K8S_NAMESPACE}" demo-api)" || return 1
  if (( baseline < 1 )); then
    err "baseline ready count is ${baseline}; refusing to evict from an empty workload"
    return 1
  fi
  detail "baseline: ${baseline} ready replica(s) - recovery is asserted against this"

  confirm "Evict pod ${pod}?" || { warn "aborted"; return 0; }

  # Unlike delete, this goes through the eviction subresource, so the API server
  # checks the PDB first and returns 429 if the disruption would violate it.
  #
  # Eviction is exposed ONLY as the subresource `pods/eviction`, not as a
  # top-level resource. `kubectl create -f` cannot map `kind: Eviction` because
  # API discovery has no entry for it, and fails with:
  #
  #   no matches for kind "Eviction" in version "policy/v1"
  #
  # The subresource must therefore be addressed by its raw path. The body is a
  # normal policy/v1 Eviction object.
  local out
  local eviction_body
  eviction_body="$(printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"%s"}}' \
    "${pod}" "${K8S_NAMESPACE}")"

  if out="$(printf '%s' "${eviction_body}" | kubectl create --raw \
      "/api/v1/namespaces/${K8S_NAMESPACE}/pods/${pod}/eviction" -f - 2>&1)"; then
    ok "eviction accepted - the ReplicaSet will replace the pod"
  else
    if grep -qE 'TooManyRequests|disruption budget|Cannot evict' <<<"${out}"; then
      warn "eviction REFUSED by the PodDisruptionBudget"
      detail "this is correct behaviour: the budget protected the workload"
      detail "${out}"
      # A refusal is a successful demonstration of the budget working, but the
      # pod was NOT replaced, so do not wait for a new replica to appear.
      return 0
    else
      err "eviction failed unexpectedly"
      detail "${out}"
      return 1
    fi
  fi

  # Wait for the ready count to return to the sampled baseline, not to a literal.
  #
  # The invariant is relative and holds at any scale: the eviction removed one
  # pod and the ReplicaSet replaced it, so ready must come back to `baseline`.
  # Evaluating against `baseline` (rather than `baseline - 1`) is deliberate - the
  # replacement pod is admitted only once it passes its readiness probe, so the
  # transient dip is never the settled state. A `>= baseline - 1` predicate would
  # pass while the workload was still a replica short, which is the failure this
  # scenario is supposed to detect.
  wait_for "${baseline} ready replicas (back to the pre-eviction baseline)" 120 \
    bash -c "[[ \"\$(kubectl get deployment demo-api -n '${K8S_NAMESPACE}' -o jsonpath='{.status.readyReplicas}')\" == \"${baseline}\" ]]" \
    || return 1

  # NOTE: there is deliberately no "the evicted pod is gone" check here.
  #
  # One was written and removed because it asserted a STRONGER claim than the wait
  # above establishes, so its correctness depended on a race rather than on the
  # contract. The mechanism, confirmed on this cluster:
  #
  #   eviction accepted -> API server sets deletionTimestamp (pod Terminating)
  #                     -> the ReplicaSet EXCLUDES terminating pods from its
  #                        count, so it creates the replacement immediately
  #                     -> replacement passes readiness => readyReplicas == baseline
  #                     -> old pod may still be in its 30s grace period
  #
  # Observed: at t=1s the old pod had deletionTimestamp set, its container was
  # still `ready=true` and phase `Running`, yet readyReplicas had already dropped
  # to 6 - so terminating pods really are excluded. Whether the old pod is gone by
  # the time the count is restored is then a race between the replacement becoming
  # ready (~7s here) and the container's shutdown (this app exits in ~2s, so the
  # guard happened to pass).
  #
  # The race is the point. `terminationGracePeriodSeconds` is 30, and a workload
  # that used more of it would let the count be restored while the old pod was
  # still terminating - failing a cluster that had behaved correctly. That is
  # finding 7's pattern in miniature: a concurrent asynchronous process producing
  # a measurement that looks like a failure of the system under test. A guard that
  # passes here only because the app shuts down quickly is not a guard.
  #
  # The authoritative evidence is already captured above and is stronger: the API
  # server ACCEPTED the eviction (no 429, so it went through the subresource and
  # the PDB admitted it) and ready returned to the sampled baseline (so capacity
  # was restored). Neither depends on shutdown timing.
  ok "recovered: ${baseline}/${baseline} ready after the eviction was accepted"
}

scenario_app_fail() {
  local pod; pod="$(pick_pod)"
  log "scenario: app-fail"
  detail "target pod: ${pod}"
  detail "calls /fail inside the pod: liveness -> 500, readiness -> 503"

  confirm "Inject a probe failure into ${pod}?" || { warn "aborted"; return 0; }

  # /fail is served by the pod itself, so reach it through a port-forward
  # rather than the Service (the Service would route to any healthy pod).
  local port=18080
  kubectl port-forward "pod/${pod}" -n "${K8S_NAMESPACE}" "${port}:8080" \
    >/dev/null 2>&1 &
  # Deliberately a global, not a `local`: the trap below can fire at script
  # exit, long after this function's locals are out of scope, and under
  # `set -u` an unset local in the trap handler would abort the cleanup.
  PF_PID=$!
  # Always tear down the port-forward, even on Ctrl-C or early return.
  trap 'kill "${PF_PID:-}" 2>/dev/null || true' EXIT INT TERM

  # Wait for the tunnel to accept connections before using it.
  local i
  for i in $(seq 1 20); do
    if curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:${port}/healthz" 2>/dev/null; then
      break
    fi
    sleep 0.5
  done

  # Sample the ready-endpoint count BEFORE injecting the fault.
  #
  # The predicate below used to read `== "2"`, which assumes a 3-replica
  # deployment. The HPA's memory-bound fixed point (docs/design.md section 5)
  # holds at 5, 6 or 7 and cannot descend to 3, so at the natural steady state the
  # count went 7 -> 6 and `== 2` never matched: the loop ran its full 45s and then
  # printed "readiness may not have failed" for a readiness probe that had worked
  # perfectly. This is the same defect class as the pod-evict literal above.
  #
  # The invariant that actually matters is a DROP relative to the baseline, which
  # holds at any scale. `-1` is not asserted exactly because the HPA may be
  # scaling concurrently, so any decrease is the observable of interest.
  local ep_baseline
  ep_baseline="$(kubectl get endpoints demo-api -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')"
  if [[ ! "${ep_baseline}" =~ ^[0-9]+$ ]] || (( ep_baseline < 2 )); then
    err "could not read a usable ready-endpoint baseline (got '${ep_baseline:-<empty>}')"
    detail "need at least 2 ready endpoints to observe one leaving without empty-service noise"
    return 1
  fi
  detail "baseline: ${ep_baseline} ready endpoint(s) - readiness is asserted to drop below this"

  if ! curl -sS --max-time 5 "http://127.0.0.1:${port}/fail"; then
    err "could not reach the pod on the forwarded port"
    detail "the port-forward may have failed; check 'kubectl get pods -n ${K8S_NAMESPACE}'"
    return 1
  fi
  printf '\n'
  ok "fault injected"
  detail "expect: readiness fails within ~7-14s -> the pod leaves the endpoints"
  detail "expect: liveness fails after ~25-40s -> the kubelet restarts the container"

  # Readiness is tighter (period 5s, threshold 2 => ~13s), so it fires first.
  # Record the moment the pod actually leaves the endpoints rather than
  # asserting a fixed window, so the reported figure is a measurement.
  local t0=${SECONDS} ep t_ready="" 
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    ep="$(kubectl get endpoints demo-api -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')"
    if [[ "${ep}" =~ ^[0-9]+$ ]] && (( ep < ep_baseline )) && [[ -z "${t_ready}" ]]; then
      t_ready=$(( SECONDS - t0 ))
      printf '\r     readiness removed the pod after %ss (endpoints %s -> %s)   \n' \
        "${t_ready}" "${ep_baseline}" "${ep}"
      # Break as soon as the measurement is taken. The loop previously ran its
      # full 45s unconditionally, and because `restartCount` is not read until
      # AFTER it exits, the liveness figure below was FLOORED at ~45s: a restart
      # at 25s and one at 44s both reported ~45s. The documented "~43s" was
      # therefore the polling floor rather than a measurement of the liveness
      # path - the same "reported result diverges from actual behaviour" class as
      # findings 1-5, and the same "check whose scope does not match reality"
      # class as 6-7. Breaking here lets the liveness loop start when readiness
      # actually fails, so `t_restart` measures the restart instead of the loop.
      break
    else
      printf '\r     ready endpoints: %s (baseline %s)   ' "${ep}" "${ep_baseline}"
    fi
    sleep 1
  done
  printf '\n'
  if [[ -n "${t_ready}" ]]; then
    ok "readiness removed the pod from the Service endpoints after ${t_ready}s"
  else
    warn "endpoints never dropped below ${ep_baseline} within 45s - readiness may not have failed"
  fi

  log "waiting for liveness to restart the container"
  local t_restart=""
  deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    local rc
    rc="$(restart_count "${pod}")"
    if [[ "${rc}" != "0" && "${rc}" != "?" && -z "${t_restart}" ]]; then
      t_restart=$(( SECONDS - t0 ))
      ok "liveness restarted the container after ${t_restart}s (restartCount=${rc})"
      # Do not stop here. A restart is only healing if the pod returns to
      # Ready; if the fault outlives the restart the container loops forever,
      # which is the failure this scenario exists to catch.
      log "verifying the restarted container actually becomes Ready"
      break
    fi
    sleep 1
  done

  local t_healed=""
  deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    local rdy
    rdy="$(kubectl get pod "${pod}" -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)"
    if [[ "${rdy}" == "true" ]]; then
      t_healed=$(( SECONDS - t0 ))
      ok "healed: pod is Ready again after ${t_healed}s (restartCount=$(restart_count "${pod}"))"
      break
    fi
    sleep 1
  done

  if [[ -z "${t_healed}" ]]; then
    # The pod is cycling and will never recover on its own. Say so plainly
    # instead of reporting success on a restartCount bump alone.
    err "NOT healed: the pod restarted but never returned to Ready"
    detail "restartCount=$(restart_count "${pod}") - if this keeps climbing, the"
    detail "fault state is surviving the restart and the pod is in a crash loop"
    detail "recover with: scripts/inject-failure.sh recover-all"
    kubectl get pod "${pod}" -n "${K8S_NAMESPACE}"
    return 1
  fi

  # Compare against the budget documented in docs/design.md §4.2.
  #
  # Readiness is quoted as a RANGE, not a point: the kubelet samples on a fixed
  # period, so where the fault lands in that cycle decides whether 1 or 2 probe
  # intervals elapse before the pod is shed (5-10s of detection, ~7-14s total).
  # Printing both numbers keeps an observed 7s from reading as an under-run.
  printf '\n'
  detail "observed: readiness ${t_ready:-?}s, restart ${t_restart:-?}s, recovered ${t_healed}s"
  detail "predicted: readiness ~7-14s (worst case ~14s), restart ~25-40s (docs/design.md section 4.2)"
  kubectl get pod "${pod}" -n "${K8S_NAMESPACE}"
}

scenario_cpu_load() {
  log "scenario: cpu-load (HPA scale-out)"
  detail "requires the load generator and metrics-server"

  # --- 1. Load generator present, and IDLE -----------------------------------
  if ! kubectl get deployment load-generator -n "${K8S_NAMESPACE}" >/dev/null 2>&1; then
    warn "load generator is not deployed"
    if confirm "Deploy it now?"; then
      # Applied as-is (its manifest declares replicas: 1), then immediately
      # idled below. The manifest is not modified: this scenario owns the
      # ordering, not the fixture's default.
      kubectl apply -f "${K8S_DIR}/optional/agent/load-generator.yaml" >/dev/null
      ok "load generator deployed"
    else
      return 0
    fi
  fi

  if ! kubectl scale deployment load-generator -n "${K8S_NAMESPACE}" --replicas=0 >/dev/null 2>&1; then
    err "could not scale the load generator to zero"
    return 1
  fi
  if ! wait_loadgen_idle "${K8S_NAMESPACE}" 60; then
    err "load generator did not reach zero replicas within 60s"
    detail "refusing to sample the baseline while load may still be running"
    return 1
  fi
  detail "load generator idle: 0 replicas"

  # --- 2. Reset to the documented baseline, THEN sample it ------------------
  #
  # This scenario measures `baseline -> peak`. It therefore has to OWN the
  # baseline, not inherit whatever the cluster drifted into. Relying on the
  # operator to pre-scale by hand is not a precondition, it is a ritual: the run
  # then measures from an arbitrary starting point and the numbers mean nothing.
  #
  # This is not hypothetical. The HPA's natural fixed point on this workload is
  # 7 replicas, not minReplicas=3 (see docs/design.md sections 10 and 12): memory
  # settles at ~69% against an 80% target, so the implied floor
  # ceil(N x 0.8625) equals N for every N up to 7, and a cluster that lands on 7
  # never walks down. A run started from 7 would have measured "7 -> 10" and
  # silently misreported the scale-out behaviour.
  local target_replicas="${CPU_LOAD_BASELINE_REPLICAS:-3}"
  local pre
  pre="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
  if [[ "${pre}" != "${target_replicas}" ]]; then
    detail "resetting baseline: demo-api ${pre} -> ${target_replicas} replicas"
    if ! kubectl scale deployment demo-api -n "${K8S_NAMESPACE}" \
          --replicas="${target_replicas}" >/dev/null 2>&1; then
      err "could not scale demo-api to ${target_replicas}"
      return 1
    fi
    if ! kubectl wait --for=condition=Available deployment/demo-api \
          -n "${K8S_NAMESPACE}" --timeout=300s >/dev/null 2>&1; then
      err "demo-api did not become Available at ${target_replicas} replicas"
      return 1
    fi
  fi

  # Confirm the baseline is genuinely calm before measuring. Scaling alone is not
  # enough: a cluster still burning off a previous run's load, or still walking
  # down from a higher count, would produce a misleading first sample. Require
  # 3/3 ready AND CPU under 10% AND memory under 80% before starting the clock.
  local calm_deadline=$((SECONDS + 300)) cpu_now="" mem_now="" ready_now=""
  while (( SECONDS < calm_deadline )); do
    ready_now="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    cpu_now="$(kubectl get hpa demo-api -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.status.currentMetrics[?(@.resource.name=="cpu")].resource.current.averageUtilization}' \
      2>/dev/null || echo '?')"
    mem_now="$(kubectl get hpa demo-api -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.status.currentMetrics[?(@.resource.name=="memory")].resource.current.averageUtilization}' \
      2>/dev/null || echo '?')"

    # Non-numeric samples mean the metrics pipeline is not ready; waiting cannot
    # fix that, and treating it as "still busy" would burn the full timeout and
    # then misreport. Fail with the real reason instead.
    if [[ ! "${cpu_now}" =~ ^[0-9]+$ || ! "${mem_now}" =~ ^[0-9]+$ ]]; then
      warn "no usable CPU/memory metric while checking the baseline (cpu='${cpu_now}' mem='${mem_now}')"
      detail "metrics-server may not be ready: kubectl top pods -n ${K8S_NAMESPACE}"
      return 1
    fi

    if [[ "${ready_now:-0}" == "${target_replicas}" ]] \
       && (( cpu_now < 10 )) && (( mem_now < 80 )); then
      detail "baseline calm: ${ready_now}/${target_replicas} ready, cpu ${cpu_now}%, memory ${mem_now}%"
      break
    fi
    printf '\r     waiting for a calm baseline: %s/%s ready, cpu %s%%, mem %s%%   ' \
      "${ready_now:-0}" "${target_replicas}" "${cpu_now}" "${mem_now}"
    sleep 5
  done
  if [[ "${ready_now:-0}" != "${target_replicas}" ]] \
     || ! (( cpu_now < 10 )) || ! (( mem_now < 80 )); then
    printf '\n'
    err "baseline never became calm within 300s (ready ${ready_now:-0}/${target_replicas}, cpu ${cpu_now}%, mem ${mem_now}%)"
    detail "refusing to measure a transition from an unstable baseline"
    return 1
  fi

  # --- 3. Baseline, sampled BEFORE any load starts --------------------------
  # baseline_replicas refuses to answer if the generator is running, so this
  # ordering cannot be broken by a later edit without an immediate loud failure.
  local current
  if ! current="$(baseline_replicas "${K8S_NAMESPACE}" demo-api)"; then
    return 1
  fi

  local max_replicas
  max_replicas="$(kubectl get hpa demo-api -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo 10)"

  # The HPA applies a default +/-10% tolerance band around the target
  # (--horizontal-pod-autoscaler-tolerance, unset on this cluster, defaults to
  # 0.1). It therefore does NOT scale at 70% - it scales above 77% and back
  # below 63%. Reporting only the nominal 70% makes a correct non-action look
  # like a 60s delay: a run that sits at 71% is inside the dead band by design.
  local scale_up_at=$(( 70 * 110 / 100 )) scale_down_at=$(( 70 * 90 / 100 ))
  log "baseline: ${current} replicas; maxReplicas ${max_replicas}"
  detail "HPA target: 70% CPU nominal, but the default 10% tolerance band means"
  detail "            it acts only above ${scale_up_at}% or below ${scale_down_at}%"
  detail "the HPA samples every 15s and applies a 30s scale-up stabilisation window"
  detail "a hold inside the band is correct behaviour, not a slow reaction"

  if (( current >= max_replicas )); then
    warn "demo-api is already at maxReplicas (${current}/${max_replicas}); no scale-up is possible"
    detail "wait for the HPA to converge back to minReplicas, then re-run"
    detail "scale-down releases ~1 step per 300s stabilisation window, so this is slow"
    return 1
  fi

  confirm "Start CPU load and wait for the HPA to react?" || { warn "aborted"; return 0; }

  # --- 4. Start load. Cause and effect are now strictly ordered. -----------
  local t_start t_trigger="" peak="${current}"
  t_start="$(date +%s)"
  kubectl scale deployment load-generator -n "${K8S_NAMESPACE}" --replicas=1 >/dev/null
  ok "load generator running - this is the cause; any scale-up is the effect"

  # --- 5. Watch for the transition, recording the timings -------------------
  #
  # "Settled" is NOT "the pod count did not change for two samples". An earlier
  # version used exactly that, and it fired at 7 replicas while the HPA was
  # still climbing to 10: the scaleUp policy allows only 4 pods per 30s, so a
  # 3 -> 10 scale-up necessarily passes through intermediate values and pauses
  # at each one. Two unchanged samples inside such a pause look identical to a
  # finished scale-up. The scenario then reported "settled at 7" and a peak of
  # 7, understating a scale-out that went to maxReplicas.
  #
  # The correct completion signal is the HPA's own view: desiredReplicas has
  # stopped moving AND the deployment has caught up to it AND everything is
  # ready. That is stable regardless of how many intermediate steps occur.
  local deadline=$((SECONDS + 360)) stable=0 settle_replicas="" last_desired=""
  while (( SECONDS < deadline )); do
    local replicas ready target desired elapsed
    replicas="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" -o jsonpath='{.spec.replicas}')"
    ready="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" -o jsonpath='{.status.readyReplicas}')"
    target="$(kubectl get hpa demo-api -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.status.currentMetrics[?(@.resource.name=="cpu")].resource.current.averageUtilization}' \
      2>/dev/null || echo '?')"
    desired="$(kubectl get hpa demo-api -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo '')"
    elapsed=$(( $(date +%s) - t_start ))

    printf '\r     t=%-3ss replicas: %-3s ready: %-3s desired: %-3s cpu: %-6s ' \
      "${elapsed}" "${replicas}" "${ready:-0}" "${desired:-?}" "${target:-?}"

    # Require a NUMERIC sample. The jsonpath above falls back to '?' when it
    # fails, and an earlier version of this check only caught "<unknown>" or
    # empty - so a broken read was accepted as a valid sample, the loop ran its
    # full 360s, and the failure surfaced as "the HPA did not scale" instead of
    # "metrics are unavailable". Two very different problems, one misleading
    # message. Anything non-numeric is a metrics problem.
    if [[ ! "${target}" =~ ^[0-9]+$ ]]; then
      printf '\n'
      warn "no usable CPU metric from the HPA (got '${target}') - metrics-server may not be ready"
      detail "check: kubectl top pods -n ${K8S_NAMESPACE}"
      detail "enable it: minikube addons enable metrics-server --profile ${CLUSTER_NAME}"
      return 1
    fi

    if [[ -z "${t_trigger}" && "${replicas:-0}" -gt "${current}" ]]; then
      t_trigger="${elapsed}"
      printf '\n'
      ok "HPA trigger at ${t_trigger}s: scaled ${current} -> ${replicas}"
    fi
    (( replicas > peak )) && peak="${replicas}"

    # Completion is "the HPA no longer wants to grow", NOT "desired == replicas".
    #
    # `desired == replicas` is a FALSE completion signal during a scale-up. The
    # 30s scaleUp stabilisation window deliberately holds desiredReplicas at the
    # lowest recent recommendation, so mid-climb the HPA can report desired=7
    # while the pods sit at 7 and utilisation is still 499% - it then jumps to
    # 10 thirty seconds later. An earlier version treated that pause as finished
    # and reported "settled at 7, peak 7" on a scale-out that went to 10 (the
    # event log showed `New size: 10` immediately after). Two consecutive
    # unchanged samples cannot distinguish a stabilisation pause from an end
    # state.
    #
    # The honest test is either:
    #   (a) replicas == maxReplicas - the hard cap, nothing further is possible, or
    #   (b) desired <= replicas AND utilisation is inside the tolerance band
    #       (<= scale_up_at), so the controller is not asking for more.
    # While utilisation is above the band the HPA will keep asking, however
    # briefly `desired` appears to match.
    local complete=0
    if [[ -n "${t_trigger}" && "${ready:-0}" == "${replicas}" && "${replicas}" == "${settle_replicas}" ]]; then
      if (( replicas >= max_replicas )); then
        complete=1
      elif [[ -n "${desired}" && "${desired}" -le "${replicas}" ]] && (( target <= scale_up_at )); then
        complete=1
      fi
    fi

    if (( complete )); then
      stable=$((stable + 1))
    else
      stable=0
      settle_replicas="${replicas}"
    fi
    (( desired != last_desired )) && last_desired="${desired}"

    if (( stable >= 2 )); then
      printf '\n'
      if (( replicas >= max_replicas )); then
        ok "settled at ${replicas} replicas - maxReplicas reached, scale-up complete"
      else
        ok "settled at ${replicas} replicas (desired ${desired}, cpu ${target}% inside the tolerance band)"
      fi
      printf '\n'
      detail "baseline replicas : ${current}"
      detail "time to trigger   : ${t_trigger}s (first scale-up observed)"
      detail "                     measured from load start; the HPA acts above"
      detail "                     ${scale_up_at}%, so time-in-band is not delay"
      detail "intermediate steps: see the desired column above; the scaleUp policy"
      detail "                    allows +4 pods/30s, so 3->10 passes through ~7"
      detail "peak replicas     : ${peak}"
      detail "time to settle    : $(( $(date +%s) - t_start ))s (desired == replicas, all ready)"
      detail "design budget     : ~60-90s scale-out (docs/design.md sections 7-8)"
      kubectl get hpa demo-api -n "${K8S_NAMESPACE}"
      detail "leave it running to watch scale-down, or:"
      detail "  scripts/inject-failure.sh recover-all"
      return 0
    fi
    sleep 5
  done

  printf '\n'
  warn "the HPA did not scale within 360s"
  detail "baseline was ${current}; peak observed ${peak}"
  detail "increase load: kubectl scale deployment load-generator -n ${K8S_NAMESPACE} --replicas=3"
  detail "check metrics: kubectl top pods -n ${K8S_NAMESPACE}"
  return 1
}

scenario_bad_image() {
  log "scenario: bad-image (rollout failure and rollback)"
  detail "sets the container image to a tag that does not exist"

  confirm "Break the demo-api image tag?" || { warn "aborted"; return 0; }

  # Record the current image so recovery is exact rather than guessed.
  local original
  original="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  detail "original image: ${original}"

  kubectl set image deployment/demo-api \
    api=selfhealing/demo-api:does-not-exist -n "${K8S_NAMESPACE}" >/dev/null
  ok "image updated - new pods will fail with ImagePullBackOff"

  # maxUnavailable: 0 means the old pods keep serving while the new ones fail.
  # This is the point of the scenario: the workload stays up.
  sleep 15
  local ready desired
  ready="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" -o jsonpath='{.status.readyReplicas}')"
  desired="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" -o jsonpath='{.spec.replicas}')"
  ok "workload still serving during the failed rollout: ${ready:-0}/${desired:-0} ready"
  detail "this is maxUnavailable: 0 doing its job"
  kubectl get pods -n "${K8S_NAMESPACE}" -l app.kubernetes.io/name=demo-api

  if confirm "Roll back to the original image now?"; then
    kubectl rollout undo deployment/demo-api -n "${K8S_NAMESPACE}" >/dev/null
    wait_for_rollout "${K8S_NAMESPACE}" demo-api || return 1
    ok "healed: rolled back and fully available"
  else
    warn "rollback skipped - the deployment is left broken"
    detail "recover with: kubectl rollout undo deployment/demo-api -n ${K8S_NAMESPACE}"
    detail "        or:  scripts/inject-failure.sh recover-all"
  fi
}

scenario_node_drain() {
  log "scenario: node-drain"
  local schedulable
  schedulable="$(kubectl get nodes --no-headers 2>/dev/null | grep -vc 'SchedulingDisabled' || echo 0)"
  detail "schedulable nodes: ${schedulable}"

  if [[ "${schedulable}" -lt 2 ]]; then
    warn "refusing to drain: this cluster has ${schedulable} schedulable node(s)"
    detail "draining the only node evicts every pod, including minikube's own"
    detail "add a node first:  minikube node add --profile ${CLUSTER_NAME}"
    return 0
  fi

  local node
  node="$(kubectl get nodes --no-headers -o custom-columns=':.metadata.name' | head -n 1)"
  confirm "Cordon and drain node ${node}?" || { warn "aborted"; return 0; }

  kubectl cordon "${node}"
  # --ignore-daemonsets is required on minikube because kube-proxy and the
  # CNI run as DaemonSets that cannot be evicted.
  if kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout=180s; then
    ok "drained - replacement pods were scheduled onto the remaining node(s)"
  else
    err "drain failed; the node may still be cordoned"
    detail "recover with: kubectl uncordon ${node}"
    return 1
  fi

  if confirm "Uncordon ${node} to restore the cluster?"; then
    kubectl uncordon "${node}"
    ok "node restored"
  fi
}

scenario_recover_all() {
  log "scenario: recover-all"

  # recover-all is not read-only: it can reset the deployment image, scale the
  # load generator to zero, clear probe faults inside pods and uncordon nodes.
  # Those are real mutations, so it needs the same consent gate as the other
  # scenarios - otherwise a non-interactive caller (CI, a wrapper, an agent)
  # would silently change the cluster with no way to decline.
  confirm "Revert every injected fault and restore the deployment?" \
    || { warn "aborted"; return 0; }

  # 1. Restore the image if it was broken.
  local image
  image="$(kubectl get deployment demo-api -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")"
  if [[ "${image}" != "${APP_IMAGE}" && -n "${image}" ]]; then
    warn "deployment image is '${image}', restoring '${APP_IMAGE}'"
    kubectl set image deployment/demo-api "api=${APP_IMAGE}" -n "${K8S_NAMESPACE}" >/dev/null
  else
    ok "image is correct (${image:-unknown})"
  fi

  # 2. Stop the load generator so the HPA can scale back in.
  if kubectl get deployment load-generator -n "${K8S_NAMESPACE}" >/dev/null 2>&1; then
    kubectl scale deployment load-generator -n "${K8S_NAMESPACE}" --replicas=0 >/dev/null
    ok "load generator stopped"
    detail "the HPA has a 300s scale-down stabilisation window; it will take ~5 min"
  fi

  # 3. Clear any injected probe faults. A restarted pod is healthy again, so
  #    this mainly matters for pods that were never restarted.
  local pod
  for pod in $(deployment_pods "${K8S_NAMESPACE}" demo-api); do
    local port=18081
    kubectl port-forward "pod/${pod}" -n "${K8S_NAMESPACE}" "${port}:8080" >/dev/null 2>&1 &
    local pf_pid=$!
    sleep 1
    curl -sS -o /dev/null --max-time 3 "http://127.0.0.1:${port}/recover" 2>/dev/null \
      && detail "cleared fault on ${pod}" \
      || detail "${pod}: no fault to clear (or not reachable)"
    kill "${pf_pid}" 2>/dev/null || true
    wait "${pf_pid}" 2>/dev/null || true
  done

  # 3b. Clear the EXIT trap set by app-fail, if this script inherited one.
  trap - EXIT INT TERM

  # 4. Uncordon any node that was drained.
  local node
  for node in $(kubectl get nodes --no-headers -o custom-columns=':.metadata.name' 2>/dev/null); do
    if kubectl get node "${node}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null | grep -q true; then
      kubectl uncordon "${node}"
      ok "uncordoned ${node}"
    fi
  done

  # 5. Make sure the rollout lands.
  wait_for_rollout "${K8S_NAMESPACE}" demo-api || warn "rollout did not complete"
  ok "recovery pass complete"
  "${SCRIPTS_DIR}/status.sh" || true
}

# --- dispatch ----------------------------------------------------------------
pre_flight
case "${SCENARIO}" in
  pod-kill)    scenario_pod_kill ;;
  pod-evict)   scenario_pod_evict ;;
  app-fail)    scenario_app_fail ;;
  cpu-load)    scenario_cpu_load ;;
  bad-image)   scenario_bad_image ;;
  node-drain)  scenario_node_drain ;;
  recover-all) scenario_recover_all ;;
  *)           die "unknown scenario: ${SCENARIO} (try --list)" ;;
esac
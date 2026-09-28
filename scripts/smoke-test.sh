#!/usr/bin/env bash
# smoke-test.sh - non-interactive safety net for the scripts/ entrypoints.
#
# WHY THIS EXISTS
#
# `make validate` used to be purely static: `bash -n` for syntax and a
# structural pass over the manifests. Three real bugs shipped through it:
#
#   1. `minReadySeconds` placed at `spec.template.spec` instead of `spec`
#      (a schema error the structural check cannot see)
#   2. an `app-fail` restart loop that contradicted itself, where the script
#      reported success on a bare restartCount bump
#   3. `confirm()` calling a bare `read`, which blocks FOREVER on a non-TTY
#      stdin that never reaches EOF - the process simply never returned
#
# Bugs 2 and 3 are control-flow bugs. No amount of static checking finds them;
# only executing the scripts does. This test executes every entrypoint under a
# stdin shape that has no TTY and no --yes consent, and asserts three things:
#
#   * it returns within SMOKE_LIMIT seconds (i.e. it does not hang)
#   * it refuses clearly, telling the operator how to opt in
#   * it makes NO state-changing call of any kind
#
# HOW "NO MUTATING CALLS" IS PROVEN
#
# The scripts call `kubectl`, `minikube`, `curl`, `docker` and `helm` purely by
# name, so a directory of stubs placed first on PATH intercepts all of them.
# Each stub logs every invocation, answers read-only calls from canned data (so
# the script can reach its consent gate), and REFUSES anything that would change
# state. A mutation is therefore both impossible and recorded.
#
# The stubs themselves are validated first by `detector_self_test`: a classifier
# that silently stopped recognising mutations would make every assertion below
# vacuous, so the detector is proven in both directions before the matrix runs.
#
# This test needs no cluster, no Docker and no network. It is safe to run at any
# time, including in CI, and it never touches a real API server.
#
# Usage:
#   scripts/smoke-test.sh            # run the matrix
#   SMOKE_LIMIT=10 scripts/smoke-test.sh

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

SMOKE_LIMIT="${SMOKE_LIMIT:-5}"
SMOKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/selfhealing-smoke.XXXXXX")"
SMOKE_BIN="${SMOKE_TMP}/bin"
SMOKE_LOG="${SMOKE_TMP}/log"
MUT_LOG="${SMOKE_LOG}/mutations.log"
mkdir -p "${SMOKE_BIN}" "${SMOKE_LOG}"
export SMOKE_LOG

# Put the stubs first on PATH. The scripts invoke their tools by bare name, so
# this is what intercepts them. Appending to (rather than replacing) PATH keeps
# the real coreutils - `timeout`, `mktemp`, `awk`, `sed` - reachable.
export PATH="${SMOKE_BIN}:${PATH}"

cleanup() { rm -rf "${SMOKE_TMP}"; }
trap cleanup EXIT INT TERM

# The per-invocation watchdog. GNU timeout puts the child in its own process
# group and kills the whole group, which is what we want when a script has left
# a background child behind. The bash fallback only kills the direct child, so
# prefer timeout when it exists (it does on this machine, via coreutils).
SMOKE_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  SMOKE_TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  SMOKE_TIMEOUT_BIN="$(command -v gtimeout)"
fi

# --- the stub toolchain ------------------------------------------------------
# Every stub shares the same contract:
#   * append the full command line to a log
#   * if the call could change state, append to mutations.log and exit 97
#   * otherwise answer from canned data and exit 0
# The canned data is what lets a script get as far as its consent prompt.
write_stubs() {
  cat >"${SMOKE_BIN}/kubectl" <<'KUBECTL_STUB'
#!/usr/bin/env bash
# Recording, refusing kubectl stub. See scripts/smoke-test.sh.
set -uo pipefail
LOG_DIR="${SMOKE_LOG:?SMOKE_LOG must be set}"
args="$*"
printf 'kubectl %s\n' "$args" >>"${LOG_DIR}/kubectl.log"

record_mutation() {
  printf 'kubectl %s\n' "$args" >>"${LOG_DIR}/mutations.log"
  # SMOKE_ALLOW_MUTATIONS=1 is used by the --yes positive control, which needs
  # the gate to open so it can prove the gate is what the other cases hit. It is
  # never set for the main matrix, so there a mutation is refused outright.
  if [[ "${SMOKE_ALLOW_MUTATIONS:-0}" == "1" ]]; then
    printf 'smoke-test stub: mutation ALLOWED by SMOKE_ALLOW_MUTATIONS: kubectl %s\n' "$args" >&2
    exit 0
  fi
  printf 'smoke-test stub: REFUSED mutating call: kubectl %s\n' "$args" >&2
  exit 97
}

# Classify the call.
#
# `--raw` is checked FIRST and wins: it bypasses the normal request builder and
# does not forward --dry-run to the query string, so a "dry-run" raw request is
# a real one. Verified against the live API server by wire capture:
#
#   kubectl create --raw .../eviction -f - --dry-run=server
#     -> curl -XPOST 'https://.../pods/x/eviction'        (no ?dryRun=All)
#   kubectl create -f - --dry-run=server
#     -> POST 'https://.../configmaps?dryRun=All&...'
#
# This matters because the raw path is exactly how inject-failure.sh evicts a
# pod, so misclassifying it would hide a real eviction.
is_mutation=0
case " ${args} " in
  *" --raw "*)     is_mutation=1 ;;
  *" --dry-run"*)  is_mutation=0 ;;
  *)
    for verb in delete drain cordon uncordon scale patch replace edit label \
                annotate taint expose create run set apply exec cp rollout; do
      case " ${args} " in *" ${verb} "*) is_mutation=1 ;; esac
    done
    # `rollout status` only reads; `rollout undo` mutates.
    case "${args}" in "rollout status"*) is_mutation=0 ;; esac
    ;;
esac
(( is_mutation )) && record_mutation

# --- canned read-only answers (most specific first) ---
case "${args}" in
  *"config current-context"*) printf 'selfhealing\n'; exit 0 ;;
  *"cluster-info"*)           printf 'Kubernetes control plane is running at https://127.0.0.1:1\n'; exit 0 ;;
  *"version"*"--client"*)     printf 'Client Version: v1.36.1\n'; exit 0 ;;
  *"api-resources"*)          exit 0 ;;
esac

# The load generator's *running* replica count drives the cpu-load baseline
# guard. This MUST be matched before the "not deployed" rule below, which would
# otherwise shadow it (same prefix). SMOKE_LOADGEN_REPLICAS lets the regression
# check drive the guard in both directions: idle (0) yields a baseline, running
# (>0) refuses.
case "${args}" in
  *"deployment load-generator"*.status.replicas*)
    printf '%s' "${SMOKE_LOADGEN_REPLICAS:-0}"; exit 0 ;;
esac

# Resources the scripts branch on the absence of.
case "${args}" in
  *"get deployment load-generator"*) exit 1 ;;   # not deployed
  *"get namespace monitoring"*)      exit 1 ;;   # not installed
esac


# Nodes: answered before the generic metadata.name rule below, because
# `get nodes --no-headers -o custom-columns=:.metadata.name` also mentions
# metadata.name and must not be answered as a pod name.
case "${args}" in
  *"get nodes"*"--no-headers"*) printf 'selfhealing\n'; exit 0 ;;
  *"get nodes"*)                printf 'NAME          STATUS   ROLE            AGE\nselfhealing   Ready    control-plane   10m\n'; exit 0 ;;
esac

case "${args}" in
  *"get namespace selfhealing"*) printf 'selfhealing\n'; exit 0 ;;
  *"get namespace"*)             exit 1 ;;
esac

# jsonpath reads. These must answer the real values or the scripts take a
# different branch and never reach the prompt under test.
case "${args}" in
  *"readyReplicas"*)       printf '3'; exit 0 ;;
  *"spec.replicas"*)       printf '3'; exit 0 ;;
  *"containers[0].image"*) printf 'selfhealing/demo-api:dev'; exit 0 ;;
  *"restartCount"*)        printf '0'; exit 0 ;;
  *"averageUtilization"*)  printf '12'; exit 0 ;;
  *"unschedulable"*)       printf 'false'; exit 0 ;;
  *"addresses"*)           printf '10.244.0.5 10.244.0.6 10.244.0.7'; exit 0 ;;
  *"metadata.name"*)       printf 'demo-api-stub-aaaa\n'; exit 0 ;;
esac

# Rendered tables. Content is plausible rather than accurate: nothing under test
# parses these, it only prints them.
case "${args}" in
  *"get pods"*)       printf 'NAME                   READY   STATUS    RESTARTS   AGE\ndemo-api-stub-aaaa     1/1     Running   0          2m\n'; exit 0 ;;
  *"get pod"*)        printf 'NAME                   READY   STATUS    RESTARTS   AGE\ndemo-api-stub-aaaa     1/1     Running   0          2m\n'; exit 0 ;;
  *"get hpa"*)        printf 'NAME       REFERENCE             TARGETS   MINPODS   MAXPODS   REPLICAS\ndemo-api   Deployment/demo-api   12%%/70%%   3         10        3\n'; exit 0 ;;
  *"get pdb"*)        printf 'NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE\ndemo-api   2               N/A               1                     2m\n'; exit 0 ;;
  *"get service"*)    printf 'NAME       TYPE        CLUSTER-IP   PORT(S)\ndemo-api   ClusterIP   10.96.0.1    80/TCP\n'; exit 0 ;;
  *"get endpoints"*)  printf 'NAME       ENDPOINTS                          AGE\ndemo-api   10.244.0.5:8080,10.244.0.6:8080   2m\n'; exit 0 ;;
  *"get events"*)     printf 'LAST SEEN   TYPE   REASON   OBJECT   MESSAGE\n'; exit 0 ;;
  *"get deployment"*) printf 'NAME       READY   UP-TO-DATE   AVAILABLE   AGE\ndemo-api   3/3     3            3           10m\n'; exit 0 ;;
  *"rollout status"*) printf 'deployment "demo-api" successfully rolled out\n'; exit 0 ;;
  *"wait "*)          exit 0 ;;
esac

exit 0
KUBECTL_STUB

  cat >"${SMOKE_BIN}/minikube" <<'MINIKUBE_STUB'
#!/usr/bin/env bash
# Recording, refusing minikube stub. See scripts/smoke-test.sh.
set -uo pipefail
LOG_DIR="${SMOKE_LOG:?SMOKE_LOG must be set}"
args="$*"
printf 'minikube %s\n' "$args" >>"${LOG_DIR}/minikube.log"

is_mutation=0
case " ${args} " in
  *" start "*|*" stop "*|*" delete "*|*" addons enable "*|*" addons disable "*|\
  *" image build "*|*" image load "*|*" node add "*|*" node delete "*|*" ssh "*|\
  *" update-context "*)
    is_mutation=1 ;;
esac
if (( is_mutation )); then
  printf 'minikube %s\n' "$args" >>"${LOG_DIR}/mutations.log"
  printf 'smoke-test stub: REFUSED mutating call: minikube %s\n' "$args" >&2
  exit 97
fi

case "${args}" in
  *"status"*)          exit 0 ;;   # report the profile as Running
  *"version"*)         printf 'v1.39.0\n'; exit 0 ;;
  *"profile list"*)    exit 0 ;;
esac
exit 0
MINIKUBE_STUB

  cat >"${SMOKE_BIN}/curl" <<'CURL_STUB'
#!/usr/bin/env bash
# Recording, refusing curl stub. See scripts/smoke-test.sh.
#
# /fail and /recover change the application's health state, so they are treated
# as mutations: if a script reaches one without consent, that is a failure.
set -uo pipefail
LOG_DIR="${SMOKE_LOG:?SMOKE_LOG must be set}"
args="$*"
printf 'curl %s\n' "$args" >>"${LOG_DIR}/curl.log"

case " ${args} " in
  *"/fail"*|*"/recover"*)
    printf 'curl %s\n' "$args" >>"${LOG_DIR}/mutations.log"
    printf 'smoke-test stub: REFUSED mutating call: curl %s\n' "$args" >&2
    exit 97 ;;
esac

case " ${args} " in
  *"/healthz"*) printf 'ok\n'; exit 0 ;;
  *"/readyz"*)  printf 'ready\n'; exit 0 ;;
  *"/metrics"*) printf '# HELP demo_api_up\n'; exit 0 ;;
esac
exit 0
CURL_STUB

  cat >"${SMOKE_BIN}/docker" <<'DOCKER_STUB'
#!/usr/bin/env bash
# Read-only docker stub: the scripts only ever call `docker info`. See
# scripts/smoke-test.sh.
set -uo pipefail
LOG_DIR="${SMOKE_LOG:?SMOKE_LOG must be set}"
args="$*"
printf 'docker %s\n' "$args" >>"${LOG_DIR}/docker.log"

case " ${args} " in
  *" info "*) printf 'Server Version: 29.7.2\n'; exit 0 ;;
esac
# Anything else is unexpected; allow it but record it, so an accidental
# `docker rm`/`docker rmi` in a script would show up as a mutation.
case " ${args} " in
  *" rm "*|*" rmi "*|*" prune "*|*" stop "*|*" kill "*)
    printf 'docker %s\n' "$args" >>"${LOG_DIR}/mutations.log"
    printf 'smoke-test stub: REFUSED mutating call: docker %s\n' "$args" >&2
    exit 97 ;;
esac
exit 0
DOCKER_STUB

  cat >"${SMOKE_BIN}/helm" <<'HELM_STUB'
#!/usr/bin/env bash
# Recording, refusing helm stub. See scripts/smoke-test.sh.
set -uo pipefail
LOG_DIR="${SMOKE_LOG:?SMOKE_LOG must be set}"
args="$*"
printf 'helm %s\n' "$args" >>"${LOG_DIR}/helm.log"

case " ${args} " in
  *" upgrade "*|*" install "*|*" uninstall "*|*" repo add "*|*" repo update "*|*" rollback "*)
    printf 'helm %s\n' "$args" >>"${LOG_DIR}/mutations.log"
    printf 'smoke-test stub: REFUSED mutating call: helm %s\n' "$args" >&2
    exit 97 ;;
esac

case "${args}" in
  *"status"*)  exit 1 ;;   # no release installed
  *"version"*) printf 'v4.3.0\n'; exit 0 ;;
esac
exit 0
HELM_STUB

  chmod +x "${SMOKE_BIN}"/*
}

# --- bookkeeping -------------------------------------------------------------
mutation_count() {
  local n=0
  if [[ -f "${MUT_LOG}" ]]; then
    n="$(wc -l <"${MUT_LOG}" | tr -d ' ')"
  fi
  printf '%s' "${n:-0}"
}

# _run_bounded <seconds> <outfile> <stdin-mode> <cmd...>
#
# Runs cmd and returns its exit status, or 124 if it outlived the limit. This is
# the timeout assertion for every case in the matrix.
#
# TWO STDIN SHAPES ARE TESTED, and the distinction matters:
#
#   eof   - stdin is /dev/null. This is what an agent harness provides, and it
#           is the shape in which the original `read` bug did NOT hang: read
#           hits EOF immediately and returns 1.
#   pipe  - stdin is a pipe whose write end is held open and which never sends
#           data and never closes. A bare `read` blocks on this FOREVER. This is
#           the shape that actually reproduced the hang, and testing only the
#           eof shape would leave the "does not hang" assertion vacuous.
#
# Both shapes are non-TTY, so both must reach the refusal path.
_run_bounded() {
  local limit="$1" out="$2" stdin_mode="${3:-eof}"; shift 3
  : >"${out}"

  local runner=("$@")
  local rc=0

  case "${stdin_mode}" in
    pipe)
      # A FIFO held open read-write on fd 9 is a pipe that never delivers data
      # and never reaches EOF, and - unlike `sleep N | cmd` - it costs nothing to
      # set up, so the case finishes as fast as the script itself.
      #
      # fd 9 must be opened with `<>` (read-write): opening it read-only would
      # block until a writer appeared, which is the very hang being tested for.
      local fifo="${SMOKE_TMP}/stdin.$$.fifo"
      rm -f "${fifo}"
      mkfifo "${fifo}"
      exec 9<>"${fifo}"

      if [[ -n "${SMOKE_TIMEOUT_BIN}" ]]; then
        "${SMOKE_TIMEOUT_BIN}" "${limit}" "${runner[@]}" <"${fifo}" >"${out}" 2>&1
        rc=$?
      else
        "${runner[@]}" <"${fifo}" >"${out}" 2>&1 &
        local pid=$!
        local deadline=$((SECONDS + limit))
        while kill -0 "${pid}" 2>/dev/null; do
          if (( SECONDS >= deadline )); then
            kill -9 "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
            exec 9>&-
            rm -f "${fifo}"
            return 124
          fi
          sleep 0.2
        done
        wait "${pid}" || rc=$?
      fi

      exec 9>&-
      rm -f "${fifo}"
      ;;
    *)
      if [[ -n "${SMOKE_TIMEOUT_BIN}" ]]; then
        "${SMOKE_TIMEOUT_BIN}" "${limit}" "${runner[@]}" </dev/null >"${out}" 2>&1
        rc=$?
      else
        "$@" </dev/null >"${out}" 2>&1 &
        local pid=$!
        local deadline=$((SECONDS + limit))
        while kill -0 "${pid}" 2>/dev/null; do
          if (( SECONDS >= deadline )); then
            kill -9 "${pid}" 2>/dev/null || true
            return 124
          fi
          sleep 0.2
        done
        wait "${pid}" || rc=$?
      fi
      ;;
  esac
  return "${rc}"
}

# --- the detector's self-test ------------------------------------------------
# Proves the classifier recognises mutations before we trust it to report that
# there were none. Without this, a stub that stopped flagging mutations would
# make the entire matrix pass vacuously.
detector_self_test() {
  local failures=0 probe="${SMOKE_TMP}/probe.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: smoke-probe\n' >"${probe}"

  # expect_mutation <description> <expect: yes|no> <cmd...>
  expect_mutation() {
    local desc="$1" expect="$2"; shift 2
    local before after got
    before="$(mutation_count)"
    "$@" </dev/null >/dev/null 2>&1 || true
    after="$(mutation_count)"
    if (( after > before )); then got="yes"; else got="no"; fi
    if [[ "${got}" != "${expect}" ]]; then
      err "detector self-test: '${desc}' classified as mutation=${got}, expected ${expect}"
      failures=$((failures + 1))
    fi
  }

  expect_mutation "kubectl apply --dry-run=server" no  kubectl apply --dry-run=server -f "${probe}"
  expect_mutation "kubectl apply"                   yes kubectl apply -f "${probe}"
  expect_mutation "kubectl delete --dry-run=server" no  kubectl delete pod x --dry-run=server
  expect_mutation "kubectl drain"                   yes kubectl drain node-1 --ignore-daemonsets
  expect_mutation "kubectl scale to 0"              yes kubectl scale deployment/demo-api --replicas=0
  # The real eviction path: --raw ignores --dry-run, so this must be a mutation.
  expect_mutation "kubectl create --raw .../eviction" yes \
    kubectl create --raw /api/v1/namespaces/selfhealing/pods/x/eviction -f - --dry-run=server
  expect_mutation "kubectl get pods"                no  kubectl get pods -n selfhealing
  expect_mutation "curl /healthz"                   no  curl -sS http://127.0.0.1:1/healthz
  expect_mutation "curl /fail"                      yes curl -sS http://127.0.0.1:1/fail
  expect_mutation "minikube addons enable"          yes minikube addons enable metrics-server
  expect_mutation "minikube status"                 no  minikube status --profile selfhealing

  # Reset: the probes above are instrumentation, not cases.
  : >"${MUT_LOG}"
  return "${failures}"
}

# --- the matrix --------------------------------------------------------------
FAILURES=0
CASES=0

# run_case <label> <expect-regex|""> <zero|nonzero|any> <stdin:eof|pipe> <cmd...>
run_case() {
  local label="$1" expect="$2" rc_mode="$3" stdin_mode="$4"; shift 4
  CASES=$((CASES + 1))

  local out="${SMOKE_TMP}/case.${CASES}.out"
  local before after rc=0
  before="$(mutation_count)"
  _run_bounded "${SMOKE_LIMIT}" "${out}" "${stdin_mode}" "$@" || rc=$?
  after="$(mutation_count)"

  local problems=()
  if (( rc == 124 )); then
    problems+=("HUNG: did not return within ${SMOKE_LIMIT}s")
  elif (( rc == 97 )); then
    problems+=("tried to mutate: the stub refused it (exit 97)")
  elif [[ "${rc_mode}" == "zero" && "${rc}" -ne 0 ]]; then
    problems+=("exit ${rc}, expected 0")
  elif [[ "${rc_mode}" == "nonzero" && "${rc}" -eq 0 ]]; then
    problems+=("exit 0, expected a refusal")
  fi

  if [[ -n "${expect}" ]] && ! grep -qE "${expect}" "${out}"; then
    problems+=("missing refusal message matching /${expect}/")
  fi

  if (( after > before )); then
    problems+=("MUTATED the cluster ($((after - before)) call(s)); see below")
  fi

  if (( ${#problems[@]} == 0 )); then
    printf '  %s%-28s%s ok (exit %s, stdin=%s, no mutations)\n' \
      "$_C_GREEN" "${label}" "$_C_RESET" "${rc}" "${stdin_mode}"
    return 0
  fi

  FAILURES=$((FAILURES + 1))
  printf '  %s%-28s%s FAIL\n' "$_C_RED" "${label}" "$_C_RESET"
  local p
  for p in "${problems[@]}"; do
    printf '      %s- %s%s\n' "$_C_RED" "${p}" "$_C_RESET"
  done
  printf '      %s--- output ---%s\n' "$_C_DIM" "$_C_RESET"
  sed 's/^/      /' "${out}" | head -n 20
  # Always return success: a failing case is recorded in FAILURES, and letting a
  # non-zero return escape here would trip `set -e` (inherited from common.sh)
  # and abort the run before the remaining cases had a chance to report.
  return 0
}

# --- canary ------------------------------------------------------------------
# Prove the watchdog can actually fire before trusting it to report "no hangs".
# A canary that is never caught would make every "did not hang" result empty.
watchdog_canary() {
  local canary="${SMOKE_TMP}/canary.sh"
  cat >"${canary}" <<'CANARY'
#!/usr/bin/env bash
# Blocks forever on a pipe that never delivers data and never closes: the exact
# shape that hung the real script.
read -r -p "canary: " x
echo "canary should never print"
CANARY
  chmod +x "${canary}"

  local out="${SMOKE_TMP}/canary.out" rc=0
  _run_bounded 2 "${out}" pipe "${canary}" || rc=$?
  if (( rc == 124 )); then
    return 0
  fi
  err "watchdog canary was NOT caught (exit ${rc}); the hang assertion is vacuous"
  detail "a blocking read under an open pipe must be killed by the ${SMOKE_LIMIT}s watchdog"
  sed 's/^/      /' "${out}" | head -n 5 >&2
  return 1
}

# --- main --------------------------------------------------------------------
write_stubs

log "non-interactive smoke test"
detail "limit per script : ${SMOKE_LIMIT}s"
detail "stdin shapes     : /dev/null (EOF) and an open pipe (no EOF)"
detail "consent          : none (no --yes, no ASSUME_YES)"
if [[ -n "${SMOKE_TIMEOUT_BIN}" ]]; then
  detail "watchdog         : ${SMOKE_TIMEOUT_BIN}"
else
  detail "watchdog         : bash fallback (no timeout binary found)"
fi
printf '\n'

if ! watchdog_canary; then
  err "refusing to report on the scripts: the watchdog does not work"
  exit 1
fi
ok "watchdog verified: a blocking read under a no-EOF pipe is caught"

if ! detector_self_test; then
  err "the mutation detector is unreliable; refusing to report on the scripts"
  detail "the smoke test's own classifier must work before its results mean anything"
  exit 1
fi
ok "mutation detector verified in both directions (11 probes)"
printf '\n'

log "entrypoints with no TTY and no consent"

# Read-only entrypoints must simply succeed.
run_case "status.sh"                ""                 zero    eof  "${SCRIPTS_DIR}/status.sh"
run_case "status.sh --help"         ""                 zero    eof  "${SCRIPTS_DIR}/status.sh" --help
run_case "inject-failure.sh --list" ""                 zero    eof  "${SCRIPTS_DIR}/inject-failure.sh" --list
run_case "inject-failure.sh --help" ""                 zero    eof  "${SCRIPTS_DIR}/inject-failure.sh" --help
run_case "inject-failure.sh (none)" ""                 nonzero eof  "${SCRIPTS_DIR}/inject-failure.sh"

# Mutating entrypoints must refuse, name the reason, and touch nothing. Each is
# run under BOTH stdin shapes: `eof` (an agent harness or /dev/null) and `pipe`
# (an open pipe that never closes, the shape that actually hung). A guard that
# only survives one of them is not a guard.
for shape in eof pipe; do
  run_case "teardown.sh [${shape}]"     "not a terminal" nonzero "${shape}" "${SCRIPTS_DIR}/teardown.sh"
  run_case "apply.sh [${shape}]"        "not a terminal" nonzero "${shape}" "${SCRIPTS_DIR}/apply.sh"
  run_case "setup.sh [${shape}]"        "not a terminal" nonzero "${shape}" "${SCRIPTS_DIR}/setup.sh"
done

# Every failure-injection scenario. Each must reach its gate and stop.
for shape in eof pipe; do
  run_case "inject pod-kill [${shape}]"    "not a terminal" zero "${shape}" "${SCRIPTS_DIR}/inject-failure.sh" pod-kill
  run_case "inject pod-evict [${shape}]"   "not a terminal" zero "${shape}" "${SCRIPTS_DIR}/inject-failure.sh" pod-evict
  run_case "inject app-fail [${shape}]"    "not a terminal" zero "${shape}" "${SCRIPTS_DIR}/inject-failure.sh" app-fail
  run_case "inject cpu-load [${shape}]"    "not a terminal" zero "${shape}" "${SCRIPTS_DIR}/inject-failure.sh" cpu-load
  run_case "inject bad-image [${shape}]"   "not a terminal" zero "${shape}" "${SCRIPTS_DIR}/inject-failure.sh" bad-image
  run_case "inject recover-all [${shape}]" "not a terminal" zero "${shape}" "${SCRIPTS_DIR}/inject-failure.sh" recover-all
done

# node-drain has its own guard, which fires before any prompt on a 1-node stub.
# Under `pipe` it must not hang either - it returns before reaching a prompt.
run_case "inject node-drain [eof]"  "refusing to drain" zero eof  "${SCRIPTS_DIR}/inject-failure.sh" node-drain
run_case "inject node-drain [pipe]" "refusing to drain" zero pipe "${SCRIPTS_DIR}/inject-failure.sh" node-drain

# --- positive control --------------------------------------------------------
# Everything above asserts that a script REFUSES. On its own that is weak
# evidence: a script could refuse for an unrelated reason - a missing binary, a
# typo in an argument, a crash before the gate - and still pass. This control
# proves the gate is the thing being hit, by re-running one scenario with
# consent explicitly granted and confirming it gets PAST the gate and reaches
# its first mutating call.
printf '\n'
log "positive control: consent must open the gate"
printf '\n'

CONTROL_OUT="${SMOKE_TMP}/control.out"
CONTROL_RC=0
before="$(mutation_count)"
SMOKE_ALLOW_MUTATIONS=1 _run_bounded "${SMOKE_LIMIT}" "${CONTROL_OUT}" eof \
  env SMOKE_ALLOW_MUTATIONS=1 "${SCRIPTS_DIR}/inject-failure.sh" pod-evict --yes || CONTROL_RC=$?
after="$(mutation_count)"

CONTROL_PROBLEMS=()
if (( CONTROL_RC == 124 )); then
  CONTROL_PROBLEMS+=("HUNG with --yes")
elif (( CONTROL_RC != 0 )); then
  CONTROL_PROBLEMS+=("exit ${CONTROL_RC} with --yes; consent should have let it proceed")
fi
if grep -q "not a terminal" "${CONTROL_OUT}"; then
  CONTROL_PROBLEMS+=("still refused despite --yes: the gate is not consent-driven")
fi
# An eviction attempt must be visible: that is the scenario's first mutation.
if ! grep -q 'eviction' "${CONTROL_OUT}" && ! grep -q 'eviction' "${MUT_LOG}" 2>/dev/null; then
  CONTROL_PROBLEMS+=("never reached the eviction call; the scenario did not get past the gate")
fi

CASES=$((CASES + 1))
if (( ${#CONTROL_PROBLEMS[@]} == 0 )); then
  printf '  %s%-28s%s ok (--yes proceeded past the gate)\n' "$_C_GREEN" "pod-evict --yes" "$_C_RESET"
else
  FAILURES=$((FAILURES + 1))
  printf '  %s%-28s%s FAIL\n' "$_C_RED" "pod-evict --yes" "$_C_RESET"
  # NOT `local`: this block is at the top level of the script, not inside a
  # function. `local` outside a function is a bash error, and because it aborted
  # here it replaced the real diagnostic with "local: can only be used in a
  # function" - the reporter failed before it could report. Reproduced by the
  # `make validate` run that first caught this.
  cp_msg=""
  for cp_msg in "${CONTROL_PROBLEMS[@]}"; do
    printf '      %s- %s%s\n' "$_C_RED" "${cp_msg}" "$_C_RESET"
  done
  printf '      %s--- output ---%s\n' "$_C_DIM" "$_C_RESET"
  sed 's/^/      /' "${CONTROL_OUT}" | head -n 15
fi
# The control's own mutations are expected and must not be reported as a leak.
: >"${MUT_LOG}"

# --- regression check: the cpu-load baseline guard ---------------------------
# The bug this prevents: sampling the demo-api baseline AFTER the load generator
# has started. The HPA may already have scaled, so `current` holds the
# post-scale value and the scenario's `replicas > current` test can never become
# true. It then waits out its full timeout and reports "the HPA did not scale" on
# a cluster that scaled correctly.
#
# The guard makes that ordering impossible: baseline_replicas refuses to return a
# value while the load generator is running. Both directions are asserted,
# because a guard that always refused would also satisfy a one-directional test
# while breaking the scenario entirely.
printf '\n'
log "regression check: cpu-load baseline guard"
printf '\n'

GUARD_FAILURES=0

# Run the guard with stdout and stderr kept apart: the contract is "the value
# goes to stdout, and on refusal stdout is EMPTY". Merging the streams would
# hide a leaked value behind the diagnostic text.
guard_probe() {
  local replicas="$1" out_file="$2" err_file="$3"
  SMOKE_LOADGEN_REPLICAS="${replicas}" bash -c \
    '. "${SCRIPTS_DIR}/lib/common.sh"; baseline_replicas selfhealing demo-api' \
    >"${out_file}" 2>"${err_file}"
}

# Direction 1: idle generator -> the guard must return the real baseline.
rc=0
guard_probe 0 "${SMOKE_TMP}/guard1.out" "${SMOKE_TMP}/guard1.err" || rc=$?
g1_out="$(cat "${SMOKE_TMP}/guard1.out")"
if (( rc == 0 )) && [[ "${g1_out}" == "3" ]]; then
  printf '  %s%-30s%s ok (idle generator -> baseline %s)\n' "$_C_GREEN" "guard: idle yields baseline" "$_C_RESET" "${g1_out}"
else
  printf '  %s%-30s%s FAIL (rc=%s, stdout=%q; expected rc=0, stdout=3)\n' \
    "$_C_RED" "guard: idle yields baseline" "$_C_RESET" "${rc}" "${g1_out}"
  GUARD_FAILURES=$((GUARD_FAILURES + 1))
fi

# Direction 2: generator running -> the guard must REFUSE.
rc=0
guard_probe 1 "${SMOKE_TMP}/guard2.out" "${SMOKE_TMP}/guard2.err" || rc=$?
g2_out="$(cat "${SMOKE_TMP}/guard2.out")"
g2_err="$(cat "${SMOKE_TMP}/guard2.err")"
if (( rc != 0 )) && grep -q "refusing to sample the baseline" <<<"${g2_err}"; then
  printf '  %s%-30s%s ok (running generator -> refused, rc=%s)\n' "$_C_GREEN" "guard: running refuses" "$_C_RESET" "${rc}"
else
  printf '  %s%-30s%s FAIL (rc=%s; expected non-zero + refusal on stderr)\n' \
    "$_C_RED" "guard: running refuses" "$_C_RESET" "${rc}"
  sed 's/^/      /' <<<"${g2_err}" | head -n 6
  GUARD_FAILURES=$((GUARD_FAILURES + 1))
fi

# Direction 3: the refusal must put NOTHING on stdout. A caller that ignores the
# exit status and reads stdout would otherwise silently adopt a stale or bogus
# number as its baseline - reintroducing the very bug the guard exists to stop.
# (Checking for digits anywhere would be wrong: the diagnostic legitimately says
# "1 replica(s)". What must stay empty is stdout.)
if [[ -z "${g2_out}" ]]; then
  printf '  %s%-30s%s ok (refusal writes nothing to stdout)\n' "$_C_GREEN" "guard: stdout stays empty" "$_C_RESET"
else
  printf '  %s%-30s%s FAIL (stdout=%q; ignoring rc would adopt this as a baseline)\n' \
    "$_C_RED" "guard: stdout stays empty" "$_C_RESET" "${g2_out}"
  GUARD_FAILURES=$((GUARD_FAILURES + 1))
fi

# Direction 4 (the important one): the ORDERING must hold in the real code.
#
# Directions 1-3 test the guard in isolation. They would all still pass if
# inject-failure.sh stopped calling it and read the baseline inline - the guard
# would simply be off the path. An earlier version of this check grepped the
# file for the string "baseline_replicas" and was therefore vacuous: the name
# still appears in a comment, so reverting the fix did not fail the check. That
# was caught by reverting the fix and watching the suite stay green.
#
# So this asserts positions in the comment-stripped function body:
#
#   * the baseline is sampled by CALLING baseline_replicas, and
#   * that call comes BEFORE the load generator is scaled to 1, and
#   * no bare `spec.replicas` read appears before it (the old inline shape).
#
# Comments are stripped first, because comments are exactly what made the
# previous check useless.
scenario_body="$(
  awk '/^scenario_cpu_load\(\) \{/,/^\}/' "${SCRIPTS_DIR}/inject-failure.sh" \
    | sed 's/#.*$//'
)"
# `|| true` on each: `set -o pipefail` is inherited from common.sh, so a grep
# that finds nothing would otherwise abort the entire suite instead of being
# reported as a failed case. A missing match is precisely the condition being
# tested for, so it must not be fatal.
line_baseline="$( { grep -n 'baseline_replicas' <<<"${scenario_body}" || true; } | head -n1 | cut -d: -f1)"
line_start="$( { grep -nE 'scale deployment load-generator.*--replicas=1' <<<"${scenario_body}" || true; } | head -n1 | cut -d: -f1)"
line_inline="$( { grep -nE "get deployment demo-api.*spec\.replicas" <<<"${scenario_body}" || true; } | head -n1 | cut -d: -f1)"

guard_problems=()
[[ -z "${line_baseline}" ]] && guard_problems+=("cpu-load never calls baseline_replicas (comment-stripped)")
[[ -z "${line_start}" ]]    && guard_problems+=("cpu-load has no 'scale load-generator --replicas=1' step")
if [[ -n "${line_baseline}" && -n "${line_start}" ]] && (( line_baseline > line_start )); then
  guard_problems+=("baseline (line ${line_baseline}) is read AFTER load starts (line ${line_start})")
fi
if [[ -n "${line_inline}" && -n "${line_baseline}" ]] && (( line_inline < line_baseline )); then
  guard_problems+=("bare demo-api spec.replicas read at line ${line_inline}, before the guard")
fi

if (( ${#guard_problems[@]} == 0 )); then
  printf '  %s%-30s%s ok (baseline at line %s, load starts at line %s)\n' \
    "$_C_GREEN" "guard: ordering in cpu-load" "$_C_RESET" "${line_baseline}" "${line_start}"
else
  printf '  %s%-30s%s FAIL\n' "$_C_RED" "guard: ordering in cpu-load" "$_C_RESET"
  for local_gp in "${guard_problems[@]}"; do
    printf '      %s- %s%s\n' "$_C_RED" "${local_gp}" "$_C_RESET"
  done
  GUARD_FAILURES=$((GUARD_FAILURES + 1))
fi

# Direction 5: the metrics-availability check must require a NUMERIC sample.
# The jsonpath falls back to '?' on failure; a check that only rejected
# "<unknown>" would treat '?' as valid, run the full 360s loop, and report the
# wrong problem ("did not scale" rather than "no metrics").
# Comment-stripped so a stray '?' in a comment cannot satisfy it.
metric_check="$(
  awk '/^scenario_cpu_load\(\) \{/,/^\}/' "${SCRIPTS_DIR}/inject-failure.sh" | sed 's/#.*$//'
)"
if grep -qE '\[\[ ! "\$\{target\}" =~ \^\[0-9\]\+\$ \]\]' <<<"${metric_check}"; then
  printf '  %s%-30s%s ok (non-numeric samples are rejected)\n' "$_C_GREEN" "guard: numeric metric required" "$_C_RESET"
else
  printf '  %s%-30s%s FAIL (cpu-load does not require a numeric CPU sample; a ? fallback would pass)\n' \
    "$_C_RED" "guard: numeric metric required" "$_C_RESET"
  GUARD_FAILURES=$((GUARD_FAILURES + 1))
fi

# Direction 6: completion must not be "desired == replicas".
#
# That equality is a FALSE completion signal mid-scale-up: the 30s scaleUp
# stabilisation window holds desiredReplicas at the lowest recent recommendation,
# so the HPA can report desired=7 with pods at 7 and CPU at 499%, then jump to 10
# thirty seconds later. The first version of this check accepted `desired ==
# replicas` and the scenario duly reported "settled at 7, peak 7" on a scale-out
# that reached maxReplicas=10. The check must therefore require the hard cap or
# the tolerance band, and must NOT be satisfiable by desired==replicas alone.
settle_body="$(
  awk '/^scenario_cpu_load\(\) \{/,/^\}/' "${SCRIPTS_DIR}/inject-failure.sh" | sed 's/#.*$//'
)"
settle_problems=()
if ! grep -q 'max_replicas' <<<"${settle_body}"; then
  settle_problems+=("completion does not consider maxReplicas (the hard cap)")
fi
if ! grep -qE 'target <= scale_up_at|scale_up_at >= target' <<<"${settle_body}"; then
  settle_problems+=("completion does not require utilisation inside the tolerance band")
fi
if grep -qE 'desired.*==.*"\$\{replicas\}"|"\$\{desired\}".*==.*replicas' <<<"${settle_body}"; then
  settle_problems+=("completion still treats desired == replicas as sufficient")
fi

if (( ${#settle_problems[@]} == 0 )); then
  printf '  %s%-30s%s ok (completion needs maxReplicas or in-band utilisation)\n' "$_C_GREEN" "guard: settle is not desired==" "$_C_RESET"
else
  printf '  %s%-30s%s FAIL\n' "$_C_RED" "guard: settle is not desired==" "$_C_RESET"
  for local_sp in "${settle_problems[@]}"; do
    printf '      %s- %s%s\n' "$_C_RED" "${local_sp}" "$_C_RESET"
  done
  GUARD_FAILURES=$((GUARD_FAILURES + 1))
fi

# Direction 7: the scenario must own its baseline, not inherit it.
#
# A scenario that measures `baseline -> peak` but depends on the operator to
# pre-scale by hand is a ritual, not a test: the run starts from whatever the
# cluster drifted into. That is a real failure mode here, because the HPA's
# natural fixed point is 7 replicas (memory-bound), so a cluster left alone
# never returns to minReplicas=3 and the next run would measure "7 -> 10".
#
# Require, in order: a reset of demo-api, THEN a calm-baseline verification,
# THEN the baseline sample. Comment-stripped so prose cannot satisfy it.
reset_body="$(
  awk '/^scenario_cpu_load\(\) \{/,/^\}/' "${SCRIPTS_DIR}/inject-failure.sh" | sed 's/#.*$//'
)"
reset_problems=()
# Each grep can legitimately find nothing (that is the bug being tested for).
# Under the inherited `set -euo pipefail` a failing grep inside a command
# substitution aborts the whole suite instead of reporting FAIL - so the guard
# would go silent exactly when it had something to say. `|| true` keeps the
# empty string, which is then handled as a problem below.
scale_line="$( { grep -n 'scale deployment demo-api' <<<"${reset_body}" || true; } | head -1 | cut -d: -f1)"
baseline_line="$( { grep -n 'baseline_replicas' <<<"${reset_body}" || true; } | head -1 | cut -d: -f1)"
calm_line="$( { grep -n 'baseline calm' <<<"${reset_body}" || true; } | head -1 | cut -d: -f1)"
if [[ -z "${scale_line}" ]]; then
  reset_problems+=("no explicit demo-api baseline reset")
fi
if [[ -z "${calm_line}" ]]; then
  reset_problems+=("baseline is not verified calm (cpu/mem/ready) before measuring")
fi
if [[ -n "${scale_line}" && -n "${baseline_line}" && "${scale_line}" -ge "${baseline_line}" ]]; then
  reset_problems+=("reset happens after the baseline sample (${scale_line} >= ${baseline_line})")
fi

if (( ${#reset_problems[@]} == 0 )); then
  printf '  %s%-30s%s ok (resets to 3, verifies calm, then samples at line %s)\n' \
    "$_C_GREEN" "guard: owns its baseline" "$_C_RESET" "${baseline_line}"
else
  printf '  %s%-30s%s FAIL\n' "$_C_RED" "guard: owns its baseline" "$_C_RESET"
  for local_rp in "${reset_problems[@]}"; do
    printf '      %s- %s%s\n' "$_C_RED" "${local_rp}" "$_C_RESET"
  done
  GUARD_FAILURES=$((GUARD_FAILURES + 1))
fi

CASES=$((CASES + 7))
FAILURES=$((FAILURES + GUARD_FAILURES))

# --- regression check: no baseline is restated as a literal -------------------
# The bug this prevents: asserting a replica count against a hardcoded number.
# `pod-evict` waited for `readyReplicas == "3"` and `app-fail` for
# `endpoints == "2"`. Both assume the deployment sits at its minReplicas, but the
# HPA's memory-bound fixed point holds at 5/6/7 (docs/design.md section 5) and
# cannot descend to 3 - so at the natural steady state the predicates were
# UNREACHABLE. pod-evict burned its full 120s timeout and then returned 1 after a
# SUCCESSFUL eviction; app-fail printed "readiness may not have failed" for a
# readiness probe that had worked. This is the same class as the unreachable
# `replicas==3 && desired==3` loop removed earlier.
#
# The check is source-level because the defect is source-level: a literal that
# should have been a sampled baseline. Comment-stripped so prose cannot satisfy
# it, and `|| true` guards every grep because pipefail would otherwise abort the
# suite exactly when there was something to report.
baseline_body="$(sed 's/#.*$//' "${SCRIPTS_DIR}/inject-failure.sh")"
baseline_problems=()

# An equality test against a small integer literal on a replica/endpoint read.
literal_hits="$(
  { grep -nE 'readyReplicas.*== *"[0-9]+"|== *"[0-9]+".*readyReplicas|addresses.*== *"[0-9]+"' \
      <<<"${baseline_body}" || true; }
)"
if [[ -n "${literal_hits}" ]]; then
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] && baseline_problems+=("replica/endpoint count compared to a literal: ${hit}")
  done <<<"${literal_hits}"
fi

# Both scenarios must establish a baseline from a live read before asserting.
# The check is for the ASSIGNMENT, not the bare name: grepping for the name alone
# also matches every later reference to the variable, so deleting the assignment
# would leave the check satisfied by the uses that remained. Verified by renaming
# the assignment and confirming the looser form stayed green.
if ! grep -qE '^[[:space:]]*(local[[:space:]]+)?baseline="\$\(deployment_ready_replicas|^[[:space:]]*(local[[:space:]]+)?baseline="\$\(kubectl' <<<"${baseline_body}"; then
  baseline_problems+=("pod-evict does not sample a ready-replica baseline (no assignment found)")
fi
if ! grep -qE '^[[:space:]]*(local[[:space:]]+)?ep_baseline="\$\(' <<<"${baseline_body}"; then
  baseline_problems+=("app-fail does not sample an endpoint baseline (no assignment found)")
fi

# The readiness loop must break once the measurement is taken. Without the break
# it runs its full 45s and the liveness figure is FLOORED at that period - which
# is what made the documented "~43s" the loop's floor rather than a measurement
# of the liveness path.
#
# Anchor on the loop's own `printf` (inside the body) and stop at the first
# `done`. An earlier version of this check anchored on the *post-loop* `ok` line
# and ran to the next `done`, which swept into the LIVENESS loop and matched ITS
# break - so the check passed with the readiness break removed. Verified by
# removing the break and confirming the check stayed green, which is how the
# anchoring bug was found rather than assumed away.
readiness_loop="$(
  { awk "/readiness removed the pod after/,/^  done$/" <<<"${baseline_body}"; } || true
)"
if [[ -z "${readiness_loop}" ]]; then
  baseline_problems+=("could not locate the app-fail readiness loop to inspect it")
elif ! grep -qE '^[[:space:]]*break[[:space:]]*$' <<<"${readiness_loop}"; then
  baseline_problems+=("app-fail readiness loop has no break: the liveness figure is floored by the loop period")
fi

# Negative control for the anchoring above: the captured range must NOT contain
# the liveness loop's own restart message. If it does, the anchor has drifted and
# the break check is inspecting the wrong loop - the exact failure this guard had.
#
# NOTE the deliberate absence of `|| true` here, and above. An earlier version
# wrote `{ grep -q ... || true; }` inside the condition, copying the idiom used
# for the `$( ... )` captures. That was wrong: `|| true` forces the status to 0,
# so `if { grep -q X || true; }` is ALWAYS true and `! { grep -q X || true; }` is
# always FALSE. Both conditions were constants, and the break check could never
# fire. Found by removing the break and confirming the check stayed silent.
# A `grep -q` in an `if` condition is already exempt from `set -e`, so the
# guard is unnecessary there - it was actively harmful.
if [[ -n "${readiness_loop}" ]] && grep -q 'liveness restarted the container' <<<"${readiness_loop}"; then
  baseline_problems+=("readiness-loop check captured the liveness loop: its anchor has drifted")
fi

CASES=$((CASES + 1))
if (( ${#baseline_problems[@]} == 0 )); then
  printf '  %s%-30s%s ok (baselines sampled; no literal counts; readiness loop breaks)\n' \
    "$_C_GREEN" "guard: baselines are sampled" "$_C_RESET"
else
  printf '  %s%-30s%s FAIL\n' "$_C_RED" "guard: baselines are sampled" "$_C_RESET"
  for baseline_msg in "${baseline_problems[@]}"; do
    printf '      %s- %s%s\n' "$_C_RED" "${baseline_msg}" "$_C_RESET"
  done
  FAILURES=$((FAILURES + 1))
fi
FAILURES=$((FAILURES + GUARD_FAILURES))

# --- report ------------------------------------------------------------------
printf '\n'
local_mutations="$(mutation_count)"
if (( local_mutations > 0 )); then
  err "${local_mutations} mutating call(s) were attempted during the smoke test:"
  sed 's/^/      /' "${MUT_LOG}" >&2
fi

if (( FAILURES > 0 )); then
  err "smoke test FAILED: ${FAILURES} of ${CASES} cases"
  exit 1
fi

ok "smoke test passed: ${CASES} cases, no hangs, no mutations"
detail "no entrypoint blocked on stdin, prompted without a TTY, or wrote to a cluster"
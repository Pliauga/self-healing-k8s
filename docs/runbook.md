# Runbook

Operational procedures for the local self-healing demo. Companion to
[`design.md`](design.md), which explains *why* the system is built this way.

---

## 1. Prerequisites

| Tool | Minimum | Check |
|---|---|---|
| Docker (Desktop or colima) | running | `docker info` |
| minikube | 1.30 | `minikube version` |
| kubectl | 1.27 | `kubectl version --client` |
| helm | 3.12 | `helm version` (only for `--monitoring`) |
| Floci | 0.2 | `floci version` (only for the AWS path) |

**Docker must be running before anything else.** `minikube start` fails with a
`socket` error otherwise — this is the single most common setup failure.

```bash
docker info >/dev/null && echo "docker ok" || echo "start Docker Desktop"
```

### Running `minikube` and `kubectl` by hand

Every script in `scripts/` sets these internally; a command typed manually does
not, and it needs both prefixes or it will fail in a way that does not look like
a failure:

```bash
MINIKUBE_HOME=$PWD/.minikube-home KUBECONFIG=$HOME/.kube/config \
  minikube image ls -p selfhealing
```

**`MINIKUBE_HOME` is mandatory on this host, not a fallback.** `~/.minikube` is
not writable here, and it holds a second, stale `selfhealing` profile record
whose SSH key no longer authenticates. Point `minikube` at the default home and
`minikube image build` prints nothing, **exits 0, and builds no image** — the
SSH handshake error is logged below the command's exit-code contract. This is
not theoretical: an agent image build was reported as successful, and the image
did not exist. **Assert the outcome** (`minikube image ls | grep <tag>`) — exit
code 0 is not evidence. `minikube ssh` and `minikube profile list` fail the same
way, the latter reporting a blank status rather than an error.

`scripts/lib/common.sh` derives both variables from a real write probe
(`_is_writable`) and exports them before any `minikube` call, which is why the
scripts work when a bare shell command does not. Note what that probe keys on: it
tests whether the *default location is writable*, not whether it holds the
working profile record. On this host those coincide. If `~/.minikube` ever became
writable, the stale record would win silently — see design.md §14, finding 11.

**Images are built into the node, not the host.** Minikube's `docker` driver
builds into the *node's* containerd store, so `docker images` on the host will
**not** list `selfhealing/demo-agent:dev`, and `demo-api` appears only via
`minikube image ls`. That is expected, not a failed build: kubelet reads the same
store, which is why the manifests use `imagePullPolicy: IfNotPresent`. To inspect
a built image directly, run
`minikube ssh -p selfhealing -- sudo crictl images | grep demo`.

**The agent Service is a single point of failure.** `demo-agent` runs at
`replicas: 1` — deliberately, so two concurrent webhooks cannot race the
executor into more than one eviction — so the ClusterIP Service fronting it is
single-replica too. If the pod is down, Alertmanager's webhook deliveries to
`http://demo-agent.selfhealing.svc.cluster.local:8080/alert` fail; Alertmanager
retries with backoff and eventually drops the notification rather than queueing
it indefinitely. A missed webhook does not lose the incident, because the alert
re-fires on `repeatInterval`, but it does mean a fault can go undiagnosed for
longer than `groupWait` implies.

---

## 2. Bring the environment up

```bash
# Minimal: cluster + workload, no monitoring stack
scripts/setup.sh

# With the observability stack (adds ~1.5 CPU / ~3 GiB)
scripts/setup.sh --monitoring

# With the CPU load generator, for HPA testing
scripts/setup.sh --monitoring --load-generator
```

`setup.sh` is idempotent: an existing cluster is reused rather than recreated, and
the image is rebuilt only on the path that builds it.

Expected duration: **2–4 minutes** without monitoring, **8–12 minutes** with it
(the Prometheus Operator's TLS bootstrap and CRD installation dominate).

---

## 3. Verify

```bash
scripts/status.sh          # point-in-time
scripts/status.sh --watch  # refresh every 5s
```

A healthy environment shows:

```
-- deployment
NAME       DESIRED   READY   AVAILABLE   UPDATED
demo-api   3         3       3           3

     total restarts across pods: 0
     ready endpoints: 3 (10.244.0.5 10.244.0.6 10.244.0.7)

-- horizontal pod autoscaler
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS
demo-api   Deployment/demo-api   12%/70%         3         10        3
```

Two things to confirm explicitly:

- **`TARGETS` is not `<unknown>`.** If it is, metrics-server is not ready and the
  HPA will never scale. Fix with
  `minikube addons enable metrics-server --profile selfhealing`, then wait ~60 s.
- **`ready endpoints: 3`** matches the replica count. Fewer means a pod is failing
  readiness.

---

## 4. Exercising self-healing

Run in this order for a complete demonstration. Each builds on the last.

```bash
scripts/inject-failure.sh pod-evict     # ~15s  - PDB-gated eviction (sanctioned)
scripts/inject-failure.sh app-fail      # ~7-14s then ~25-40s - readiness, then liveness
scripts/inject-failure.sh pod-kill      # negative control: bypasses the PDB
scripts/inject-failure.sh cpu-load      # ~60-90s - HPA scales 3 -> 10
scripts/inject-failure.sh bad-image     # stalls safely; roll back by hand
scripts/inject-failure.sh recover-all   # reset everything
```

Use `scripts/inject-failure.sh --list` for the full set.

### 4.1 What to watch during each scenario

Keep a second terminal on `scripts/status.sh --watch`. The signals to look for:

| Scenario | Watch this | Expected |
|---|---|---|
| `pod-evict` | command output | `eviction accepted` - or `REFUSED by the PDB` |
| `pod-kill` | pod list | new pod name appears, READY count returns to 3 |
| `app-fail` | `ready endpoints` | drops to 2 within ~7-14 s (worst case ~14 s) |
| `app-fail` | `total restarts` | increments within ~25-40 s |
| `cpu-load` | HPA `REPLICAS` | rises above 3 within ~90 s |
| `bad-image` | pod `STATUS` | `ImagePullBackOff`, but READY stays 3 |

The `bad-image` case is the one people find surprising: the workload stays fully
available throughout a broken rollout. That is `maxUnavailable: 0`.

**Readiness shedding is a range, not a fixed number.** The kubelet samples on a
fixed 5 s period, so whether the fault lands just before or just after a probe
decides whether one or two intervals elapse before the pod leaves the endpoints.
An observed **7 s is the fast end, not a bug**; ~14 s is the worst case. Read the
`observed:` / `predicted:` lines the scenario prints rather than checking the
clock against a single figure.

---

## 5. Demonstrating the API directly

```bash
# Port-forward the service (the Service, not a pod, so traffic is load-balanced)
kubectl port-forward -n selfhealing svc/demo-api 8080:80
```

In another terminal:

```bash
curl -s localhost:8080/ | jq        # which pod answered
curl -s localhost:8080/healthz      # 200 ok
curl -s localhost:8080/metrics      # Prometheus text format

# Inject a fault and watch it leave the endpoints
curl -s localhost:8080/fail
watch -n1 'kubectl get endpoints demo-api -n selfhealing'
```

Note that a load-balanced `/fail` call reaches exactly one pod, and because the
Service drops unready pods the *next* request lands on a different one. This is
readiness-based self-healing, visible in one command.

---

## 6. Observability

```bash
# Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000   admin / prom-operator
```

Useful PromQL:

```promql
# is the app healthy, per pod
demo_api_healthy

# restarts - proves liveness remediation fired
increase(kube_pod_container_status_restarts_total{namespace="selfhealing"}[10m])

# ready endpoints vs desired replicas - proves readiness shedding
kube_endpoint_address_available{namespace="selfhealing", endpoint="demo-api"}

# HPA behaviour
kube_horizontalpodautoscaler_status_current_replicas{namespace="selfhealing"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="selfhealing"}

# CPU per pod vs the 100m request
rate(container_cpu_usage_seconds_total{namespace="selfhealing", container="api"}[5m])
```

---

## 7. Troubleshooting

### Pods are `Pending`

```bash
kubectl describe pod -n selfhealing -l app.kubernetes.io/name=demo-api | tail -20
```

Usually insufficient cluster resources. Check `kubectl describe node` for
allocatable vs. requested. Recreate with more:
`minikube delete -p selfhealing && scripts/setup.sh`.

### Pods are `ImagePullBackOff`

The image is built into minikube's image store by `minikube image build`; it is
**not** in any registry. If the pod was scheduled to a node without the image, or
`imagePullPolicy` forced a pull, this fails.

```bash
minikube image ls --profile selfhealing | grep demo-api   # confirm it exists
```

Re-run `scripts/setup.sh` to rebuild, or:
`minikube image build -p selfhealing -t selfhealing/demo-api:dev app/`.

### HPA reports `<unknown>`

metrics-server is not serving. This is the most common blocker for the
`cpu-load` scenario.

```bash
minikube addons enable metrics-server --profile selfhealing
kubectl top pods -n selfhealing        # should return figures within ~60s
kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions}'
```

### HPA reports a metric but never scales

Check four things in order:

1. **Is the target actually exceeded?** The HPA applies a **±10 % tolerance band**
   around `averageUtilization`. With a 70 % target it acts only **above 77 %** or
   **below 63 %**; in between it deliberately does nothing.

   ```bash
   kubectl get hpa demo-api -n selfhealing -o jsonpath='{.status.currentMetrics[*].resource.current.averageUtilization}{"\n"}'
   ```

   A pod sitting at 71 % is **inside the band** and will not trigger a scale.
   This is the single most common false alarm: 70 % is the nominal target, not
   the trigger.

2. **Is there a CPU request?** Utilisation is a percentage *of the request*.
   Without a request the HPA cannot compute a target. `k8s/10-deployment.yaml`
   sets `requests.cpu: 100m`.
3. **Is load actually reaching the pods?** `kubectl top pods -n selfhealing`.
   The tight `limits.cpu: 500m` is what makes throttling visible. The load
   generator needs a moment to spin up its workers, so expect a plateau before
   the real climb.
4. **Is the target exceeded for long enough?** Scale-up has a 30 s stabilisation
   window, so the HPA needs ~45–90 s to act. This is expected, not a bug.

### The HPA scaled but the count looks wrong, or it stalls mid-scale-up

The 30 s `scaleUp` stabilisation window means a large scale-up arrives in
**steps**: the policy allows at most **+4 pods / 30 s**, so `3 → 10` passes
through an intermediate value (usually 7) and pauses there. During the pause the
HPA can report `desiredReplicas` equal to the current count while utilisation is
still far above the band — then jump again 30 s later.

```bash
# The authoritative view: what the HPA WANTS, not just what exists.
kubectl get hpa demo-api -n selfhealing \
  -o custom-columns='CPU:.status.currentMetrics[0].resource.current.averageUtilization,REPLICAS:.status.currentReplicas,DESIRED:.status.desiredReplicas'
kubectl get hpa demo-api -n selfhealing -o jsonpath='{.status.conditions[?(@.type=="AbleToScale")].reason}{"\n"}'
```

`ScaleUpStabilized` means a pause, not a stop. **Do not read a stable replica
count as a finished scale-up** — the scale is complete only when utilisation
falls back inside the band or the count reaches `maxReplicas`.

### The HPA will not scale back down to `minReplicas`

Expected on this workload, and it is the **memory** metric, not CPU. Each idle
`demo-api` replica holds ~86 Mi of its 128 Mi request regardless of traffic, so
memory utilisation stays ~66–70 %. Scale-down steps as
`desired = ceil(N × mem_util / mem_target)`, and the descent stops the first time
that equals `N`. With `mem_target: 80` the ratio is ~0.85, so:

```
mem 65-66%  ->  holds at 5
mem 67-68%  ->  holds at 6
mem 69-70%  ->  holds at 7
```

`ceil(N × 0.8625) == N` for every `N` in `1..7`, so **the cluster cannot walk
down to 3 on its own** — it stops wherever its memory ratio puts it. This is not
a delay you can wait out: no amount of waiting reaches `minReplicas`. To restore
the documented baseline you must scale explicitly:

```bash
kubectl scale deployment demo-api -n selfhealing --replicas=3
```

`scripts/inject-failure.sh cpu-load` does this itself as its first step, so the
scenario no longer depends on a manual pre-scale. See `docs/design.md` §5 and
§13, question 1, for whether the target should be changed to restore autonomous
descent (it needs ~91 %, not 90 %).

This is not "influencing" the scenario: the scenario measures `3 → N`, so it
needs to start at 3. A freshly created cluster starts there and stays there until
load is applied. See `docs/design.md` §10 for why memory, not CPU, is the binding
metric.

### `kubectl auth can-i create pods/eviction` says `no`, but the RBAC is correct

**This is a `kubectl` limitation, not a permissions problem. Do not "fix" the Role.**

The executor Role grants eviction in the `policy` API group:

```yaml
rules:
  - apiGroups: ["policy"]
    resources: ["pods/eviction"]
    verbs: ["create"]
```

`kubectl auth can-i create pods/eviction` builds a `SelfSubjectAccessReview` for
the **core** API group (`""`), not `policy`, so it asks a question the Role was
never meant to answer and correctly reports `no`. The `<resource>/<subresource>`
slash form does not carry an API group, and `can-i` has no `--api-group` flag to
supply one. Confirmed identical on kubectl **v1.31.14** and **v1.36.1**, so this
is not version skew — both clients ask the wrong group.

Three ways to see the truth, in increasing order of authority:

```bash
# 1. The grant is listed, annotated with its real group: pods.POLICY/eviction
kubectl auth can-i --list --as=system:serviceaccount:selfhealing:remediation-executor -n selfhealing

# 2. Ask the API server directly, naming the group (this is what admission uses)
kubectl create -f - -o jsonpath='{.status.allowed}{"\n"}' <<'EOF'
{"apiVersion":"authorization.k8s.io/v1","kind":"SubjectAccessReview",
 "spec":{"user":"system:serviceaccount:selfhealing:remediation-executor",
   "groups":["system:serviceaccounts","system:serviceaccounts:selfhealing","system:authenticated"],
   "resourceAttributes":{"namespace":"selfhealing","group":"policy",
     "resource":"pods","subresource":"eviction","verb":"create"}}}
EOF
```

Expected: `pods.policy/eviction ... [create]` in the first, and `true` in the
second, with a reason line naming the RoleBinding.

Beware of two adjacent traps when hand-testing an eviction:

- `kubectl create -f eviction.json --as=...` fails with
  `no matches for kind "Eviction" in version "policy/v1"` — the client cannot map
  the kind (ADR-0005), so it never reaches authorization. This error says nothing
  about permissions.
- Adding `--dry-run=server` trips client-side schema validation first, which tries
  to list CRDs; the executor cannot, so it fails with an unrelated
  `customresourcedefinitions ... is forbidden`. Also not a permissions verdict.

The trustworthy negative control is a plain `SubjectAccessReview` with an
**empty** `group` for pods: `delete pods` and `get pods` must both be `false` for
the executor. If any of those returns `true`, the Role is genuinely too broad and
should be corrected.

### Everything is `Running` but `ready endpoints: NONE`

All replicas are failing readiness simultaneously. Almost always the deployment
was left in a faulted state by a previous run:

```bash
scripts/inject-failure.sh recover-all
```

### A faulted pod restart-loops forever and never becomes Ready

**Symptom.** A pod's `RESTARTS` keeps climbing, it never reaches `READY 1/1`, and
`kubectl describe` shows the startup or liveness probe failing on a container that
looks healthy. This is a *crash loop*, not recovery — the restart count rises, but
the pod never heals.

**Cause.** The demo app keeps injected fault state in a file on an `emptyDir`:

```bash
kubectl get deployment demo-api -n selfhealing \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FAULT_STATE_FILE")]}'
```

`emptyDir` is ephemeral per **pod**, not per **container**. A container restart
keeps the pod, so it keeps the volume, so the fault file survives. The new process
reads the persisted flag, fails its probe, and is killed again — indefinitely.
Liveness remediation cannot break this cycle on its own, because the fault it is
supposed to fix is the thing that persists across the fix.

**Diagnosis.** Confirm the flag is present in the *running* container:

```bash
POD=$(kubectl get pods -n selfhealing -l app.kubernetes.io/name=demo-api \
      -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n selfhealing "$POD" -- cat /var/run/demo-api/fault.json
```

If that prints a fault document while the pod is restart-looping, you have this.

**Fix.** The app clears the file at startup (`_clear_fault_on_start`) and on
graceful exit (`atexit`); clearing at startup is the half that matters, because it
covers `SIGKILL` and OOM kills where no shutdown handler runs. If the loop
persists, the image predates that fix — rebuild:

```bash
minikube image build -p selfhealing -t selfhealing/demo-api:dev app/
kubectl rollout restart deployment/demo-api -n selfhealing
```

**Escape hatch.** Delete the pod — the replacement starts with a fresh, empty
`emptyDir` — or call `/recover`:

```bash
scripts/inject-failure.sh recover-all
```

**Do not "fix" this by disabling the probe.** The probe is correct; the persisted
state is the problem. Note also that `FAULT_STATE_PERSIST=1` deliberately disables
both clears, so a crash loop under that setting is expected, not a bug.

### An entrypoint exits immediately without doing anything

If a `scripts/` entrypoint refuses with `cannot prompt (stdin is not a terminal)`,
it was run non-interactively with no consent flag. This is intended fail-closed
behaviour: a prompt that cannot be answered must never be read as consent, so the
script declines instead of guessing. Re-run with `--yes`:

```bash
scripts/inject-failure.sh app-fail --yes
scripts/apply.sh --yes
```

This is the failure mode that used to *hang forever* with no output rather than
refusing — the smoke test below exists to keep it that way.

### Verify the scripts still behave without a cluster

```bash
make smoke          # or: scripts/smoke-test.sh
```

Runs every `scripts/*.sh` entrypoint with **non-TTY stdin and no `--yes`**, and
asserts that each one:

1. returns within 5 s instead of hanging,
2. refuses with a clear message naming the reason,
3. makes **no** state-changing `kubectl`, `minikube`, `curl`, `docker` or `helm`
   call, and
4. is proven to be *consenting*, by a positive control that re-runs one scenario
   with `--yes` and confirms it gets past the gate.

It needs no cluster, no Docker and no network, and it is part of `make validate`.
Two details matter when reading a failure:

- **Two stdin shapes are tested.** `eof` (`/dev/null`) and `pipe` (an open pipe
  that never closes). A bare `read` returns instantly under the first and blocks
  *forever* under the second, so testing only `/dev/null` would leave the "does
  not hang" assertion vacuous.
- **The harness validates itself first.** A watchdog canary proves the timeout
  actually fires, and a detector self-test proves the mutation classifier flags
  real mutations. If either fails, the run aborts rather than reporting a green
  suite built on a broken instrument.

`SMOKE_LIMIT=10 scripts/smoke-test.sh` raises the per-script budget.

### A namespace is stuck `Terminating`

A finalizer is blocking. Locate it, then decide:

```bash
kubectl get namespace selfhealing -o json | jq '.status.conditions'
kubectl get namespace selfhealing -o json \
  | jq '.spec.finalizers' -r
```

Force-removing finalizers is a last resort and can orphan resources. Prefer
fixing the responsible controller.

### `minikube start` fails with a socket error

Docker is not running. Start Docker Desktop or colima and retry.

### Prometheus finds no targets

Check that the ServiceMonitor's `release` label matches the Helm release name and
that the CRDs exist:

```bash
kubectl get crd servicemonitors.monitoring.coreos.com
kubectl get servicemonitor -n selfhealing -o yaml | grep -A2 labels
```

The chart values set `serviceMonitorSelectorNilUsesHelmValues: false` so that
ServiceMonitors outside the release namespace are discovered; without it the
`selfhealing` namespace is silently ignored.

### Duplicate diagnoses in the agent log during the end-to-end test

Alertmanager's default webhook timeout is 10s; a slow diagnosis (worst case
~123s) returns as a timeout, and Alertmanager redelivers. The retry finds the pod
already evicted and reports "already healed". This is expected and safe — no
double eviction occurs, but the LLM is called twice. Fix candidates: raise the
Alertmanager webhook timeout, or add in-flight dedup keyed on the alert
fingerprint. Not fixed in v1.

### Alertmanager has two config secrets and only one is live

The StatefulSet mounts
`alertmanager-kube-prometheus-stack-alertmanager-generated` (gzipped, key
`alertmanager.yaml.gz`), which is the config the Operator actually renders and
reloads — `config-reloader` watches the file and POSTs to `/-/reload`. The
sibling secret `alertmanager-kube-prometheus-stack-alertmanager` is a plaintext
leftover from an earlier version and is not mounted by anything. When inspecting
the live config, read the `-generated` secret and gunzip `alertmanager.yaml.gz`;
the plaintext one will mislead you into thinking an `AlertmanagerConfig` merge
failed:

```bash
kubectl get secret alertmanager-kube-prometheus-stack-alertmanager-generated \
  -n monitoring -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip
```

The rendered config the running process reads is at
`/etc/alertmanager/config_out/alertmanager.env.yaml` inside the pod.

### `kubectl run` with a throwaway pod is rejected by the namespace's restricted PSA

`selfhealing` sets `pod-security.kubernetes.io/enforce: restricted`, so a bare
`kubectl run` cannot be admitted — the pod fails admission with
`violates PodSecurity "restricted:latest"` (`allowPrivilegeEscalation != false`,
`runAsNonRoot != true`, `seccompProfile`, unrestricted capabilities). To test
in-cluster connectivity, either `kubectl exec` into an existing pod, or create
the probe in a namespace without restricted enforcement — `default` has no PSA
labels and admits it:

```bash
kubectl run psa-probe --rm -i --restart=Never --image=curlimages/curl \
  -n default -- curl -s -o /dev/null -w "%{http_code}" \
  http://demo-agent.selfhealing.svc.cluster.local:8080/healthz
```

### `kubectl port-forward pod/<name> 8081:80` succeeds but forwards to nothing

The demo-api pod exposes `http=8080/TCP`. The Service maps `port: 80 →
targetPort: http`, but that mapping exists only at the Service layer. Forwarding
directly to the pod must target the container port:

```bash
kubectl port-forward -n selfhealing pod/$TARGET 8081:8080
```

The wrong form (`8081:80`) prints `Forwarding from 127.0.0.1:8081 -> 80` with
no error, and the subsequent request fails with curl exit 52 (empty reply), not
connection-refused. The forwarder is happy; the port it forwards to has nothing
listening.

Note: `kubectl port-forward -n selfhealing svc/demo-agent 8080:8080` (the agent
Service) is correct as written — the agent's Service and container ports are
both 8080. The confusion only applies when forwarding to a demo-api pod
directly.

---

## 8. Teardown

```bash
scripts/teardown.sh                # interactive: choose the scope
scripts/teardown.sh --app-only     # just the selfhealing namespace
scripts/teardown.sh --keep-cluster # app + monitoring, keep the cluster
scripts/teardown.sh --all          # delete the minikube profile too
```

`--all` destroys the cluster, its images and its volumes. Rebuilding takes
2–4 minutes plus the monitoring install.

To merely pause:

```bash
minikube stop --profile selfhealing
minikube start --profile selfhealing    # same state returns
```

---

## 9. Reference

```bash
# contexts
kubectl config use-context selfhealing

# what is the cluster actually doing right now
kubectl get all -n selfhealing
kubectl get events -n selfhealing --sort-by=.lastTimestamp | tail -20

# why did a pod restart
kubectl describe pod <pod> -n selfhealing | sed -n '/Events/,$p'
kubectl logs <pod> -n selfhealing --previous

# rollout control
kubectl rollout status  deployment/demo-api -n selfhealing
kubectl rollout history deployment/demo-api -n selfhealing
kubectl rollout undo    deployment/demo-api -n selfhealing

# manual HPA control
kubectl scale deployment load-generator -n selfhealing --replicas=3   # more load
kubectl scale deployment load-generator -n selfhealing --replicas=0   # stop load
```

Environment variables honoured by every script: `CLUSTER_NAME`, `K8S_NAMESPACE`,
`MONITORING_NAMESPACE`, `MINIKUBE_CPUS`, `MINIKUBE_MEMORY`, `MINIKUBE_DRIVER`,
`APP_IMAGE`, `ASSUME_YES`, `NO_COLOR`.

```bash
K8S_NAMESPACE=staging scripts/status.sh
MINIKUBE_CPUS=6 MINIKUBE_MEMORY=12288 scripts/setup.sh
ASSUME_YES=1 scripts/teardown.sh --all      # non-interactive
```
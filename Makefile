# Convenience wrapper around scripts/. Every target delegates - the scripts are
# the source of truth and remain usable on their own.
#
# `make` or `make help` lists targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help
SCRIPTS := scripts
CHAOS := tests/chaos

.PHONY: help setup setup-full apply apply-optional status watch \
        demo kill evict fail load badimage drain recover \
        logs port-forward metrics lint validate smoke shellcheck hygiene \
        chaos chaos-static teardown clean

help: ## Show this help
	@printf '\nSelf-healing Kubernetes cluster\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

# --- lifecycle ---------------------------------------------------------------

setup: ## Start the cluster and deploy the workload
	$(SCRIPTS)/setup.sh --yes

setup-full: ## Start the cluster with monitoring and the load generator
	$(SCRIPTS)/setup.sh --monitoring --load-generator --yes

apply: ## Re-apply the base manifests
	$(SCRIPTS)/apply.sh --yes

apply-optional: ## Re-apply manifests including optional/agent/
	$(SCRIPTS)/apply.sh --optional --yes

status: ## Show cluster status
	$(SCRIPTS)/status.sh

watch: ## Follow cluster status live
	$(SCRIPTS)/status.sh --watch

teardown: ## Interactive teardown (choose the scope)
	$(SCRIPTS)/teardown.sh

clean: ## Delete the namespace and the minikube profile
	$(SCRIPTS)/teardown.sh --all --yes

# --- failure injection -------------------------------------------------------

demo: ## Run the failure scenarios in sequence
	$(SCRIPTS)/inject-failure.sh pod-kill --yes
	$(SCRIPTS)/inject-failure.sh app-fail --yes
	$(SCRIPTS)/inject-failure.sh cpu-load --yes

kill: ## Delete a pod; the ReplicaSet replaces it
	$(SCRIPTS)/inject-failure.sh pod-kill --yes

evict: ## Evict a pod through the eviction API (PDB-gated)
	$(SCRIPTS)/inject-failure.sh pod-evict --yes

fail: ## Make a pod fail its liveness and readiness probes
	$(SCRIPTS)/inject-failure.sh app-fail --yes

load: ## Generate CPU load so the HPA scales out
	$(SCRIPTS)/inject-failure.sh cpu-load --yes

badimage: ## Break the image tag, then roll back
	$(SCRIPTS)/inject-failure.sh bad-image --yes

drain: ## Drain a node (requires at least two schedulable nodes)
	$(SCRIPTS)/inject-failure.sh node-drain --yes

recover: ## Revert every injected fault
	$(SCRIPTS)/inject-failure.sh recover-all --yes

# --- debugging ---------------------------------------------------------------

logs: ## Show demo-api logs
	kubectl logs -n selfhealing -l app.kubernetes.io/name=demo-api --tail=50 --prefix

port-forward: ## Forward the demo-api Service to localhost:8080
	kubectl port-forward -n selfhealing svc/demo-api 8080:80

metrics: ## Query the demo-api metrics endpoint
	@kubectl run curl-$$$$ --namespace selfhealing \
	  --image=curlimages/curl:8.11.1 --image-pull-policy=IfNotPresent \
	  --restart=Never --quiet --rm -i --command -- \
	  curl -sS http://demo-api.selfhealing.svc.cluster.local/metrics

# --- quality -----------------------------------------------------------------

shellcheck: ## Run shellcheck over the scripts, if installed
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh; \
	  echo "shellcheck: clean"; \
	else \
	  echo "shellcheck not installed; skipping"; \
	fi

smoke: ## Run the non-interactive smoke test (no cluster needed)
	@$(SCRIPTS)/smoke-test.sh

validate: ## Syntax-check scripts and manifests
	@echo "== bash syntax =="
	@for f in $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh; do bash -n "$$f" && echo "  ok $$f"; done
	@echo "== chaos test syntax =="
	@for f in $(CHAOS)/*.sh $(CHAOS)/lib/*.sh; do bash -n "$$f" && echo "  ok $$f"; done
	@echo "== python syntax =="
	@python3 -m py_compile app/app.py $(SCRIPTS)/*.py && echo "  ok app/app.py $(SCRIPTS)/*.py"
	@echo "== manifest structure =="
	@python3 scripts/validate-manifests.py
	@echo "== repo hygiene (ignore coverage, secret scan, size) =="
	@python3 scripts/check-repo-hygiene.py --quiet --self-test
	@echo "== non-interactive smoke test =="
	@$(SCRIPTS)/smoke-test.sh

hygiene: ## Check ignore coverage, scan for secrets, enforce the size budget
	@python3 scripts/check-repo-hygiene.py --self-test

chaos-static: ## Run chaos tests in offline contract mode (no cluster contact)
	@echo "== chaos contract checks (no cluster) =="
	@for f in $(CHAOS)/*.sh; do \
	  echo "-- $$f"; \
	  "$$f" --static || exit 1; \
	done
	@echo "chaos-static: done"

chaos: ## Run the chaos scenarios against the live cluster (mutating; needs consent)
	@echo "== chaos scenarios (live; each asserts its own safety gates) =="
	@echo "NOTE: these mutate the cluster. Each script refuses without --yes"
	@echo "      (or ASSUME_YES=1). Pass it explicitly to opt in:"
	@echo "        make chaos CHAOS_ARGS=--yes"
	@for f in $(CHAOS)/*.sh; do \
	  echo "-- $$f"; \
	  "$$f" $(CHAOS_ARGS) || exit 1; \
	done
	@echo "chaos: done"

lint: validate shellcheck ## Run all static checks
	@echo "lint: done"
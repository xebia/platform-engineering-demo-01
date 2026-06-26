# Platform Engineering example — Score -> Docker Compose / Kubernetes (kind)
#
# Single source of truth: workloads/<name>/score.yaml
# Generated artifacts land in each workload's dist/ folder:
#   workloads/<name>/dist/k8s/manifests.yaml  -> committed k8s manifests (ArgoCD source)
#   workloads/<name>/dist/docker/compose.yaml -> local-dev compose (gitignored)

# ---- configuration ---------------------------------------------------------
WORKLOAD      ?= hello-world
WORKLOAD_DIR  := workloads/$(WORKLOAD)
SCORE_FILE    := $(WORKLOAD_DIR)/score.yaml
BUILD_CONTEXT := ./$(WORKLOAD_DIR)/app

# per-workload overrides (optional): workloads/<name>/workload.mk
-include $(WORKLOAD_DIR)/workload.mk

# convention-based fallbacks — apply only if workload.mk didn't set them
IMAGE         ?= localhost:$(REG_PORT)/$(WORKLOAD)-app:0.1.0
HOST_PORT     ?= 8080
CONTAINER_PORT?= 8080

# clusters (kind): dev = ephemeral/direct, test = persistent/GitOps
DEV_CLUSTER   ?= dev
TEST_CLUSTER  ?= test
STAGE_CLUSTER ?= stage
PROD_CLUSTER  ?= prod
CLUSTER       ?= $(TEST_CLUSTER)   # which cluster the generic primitives act on
ENV           ?= test              # which GitOps env (test|stage|prod) to bootstrap

# shared local registry (kind "local registry" pattern) — replaces `kind load`
REG_NAME      ?= kind-registry
REG_PORT      ?= 5001
export REG_NAME REG_PORT

ARGOCD_NS     ?= argocd
ARGOCD_UI_PORT?= 8081

# generated artifacts, kept in the workload's dist/ folder
DIST_DIR      := $(WORKLOAD_DIR)/dist
COMPOSE_FILE  := $(DIST_DIR)/docker/compose.yaml
MANIFESTS     := $(DIST_DIR)/k8s/manifests.yaml

# every workload folder (for the *-all fan-out targets)
WORKLOADS     := $(notdir $(wildcard workloads/*))

.DEFAULT_GOAL := help

# ---- meta ------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: init
init: ## Initialise per-workload score state (isolates each app's project)
	cd $(WORKLOAD_DIR) && score-compose init --no-sample && score-k8s init --no-sample

# ---- generate (Score -> artifacts) -----------------------------------------
# Both generate commands run *inside* the workload dir so each app gets its own
# .score-* state — otherwise score's shared project state leaks every workload's
# resources into every output file.
.PHONY: compose
compose: ## Generate the local-dev compose.yaml from score.yaml
	cd $(WORKLOAD_DIR) && { test -d .score-compose || score-compose init --no-sample; } && \
		mkdir -p dist/docker && \
		score-compose generate score.yaml \
			--build 'web={"context":"./app"}' \
			--publish '$(HOST_PORT):$(WORKLOAD):$(CONTAINER_PORT)' \
			-o dist/docker/compose.yaml

.PHONY: manifests
manifests: ## Render score.yaml -> committed k8s base (manifests + kustomization)
	cd $(WORKLOAD_DIR) && { test -d .score-k8s || score-k8s init --no-sample; } && \
		mkdir -p dist/k8s && \
		score-k8s generate score.yaml -o dist/k8s/manifests.yaml && \
		printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - manifests.yaml\n' \
			> dist/k8s/kustomization.yaml

.PHONY: generate
generate: compose manifests ## Generate both compose + k8s artifacts

.PHONY: manifests-all compose-all build-all
manifests-all: ## Render k8s manifests for ALL workloads
	@for w in $(WORKLOADS); do $(MAKE) --no-print-directory WORKLOAD=$$w manifests; done
compose-all: ## Generate compose for ALL workloads
	@for w in $(WORKLOADS); do $(MAKE) --no-print-directory WORKLOAD=$$w compose; done
build-all: ## Build the image for ALL workloads
	@for w in $(WORKLOADS); do $(MAKE) --no-print-directory WORKLOAD=$$w build; done

# ---- local dev (Docker Compose) --------------------------------------------
.PHONY: build
build: ## Build the application image
	docker build -t $(IMAGE) $(BUILD_CONTEXT)

.PHONY: up
up: compose ## Build + run locally via Docker Compose
	docker compose -f $(COMPOSE_FILE) --project-directory $(WORKLOAD_DIR) up --build

.PHONY: down
down: ## Stop the Docker Compose stack
	docker compose -f $(COMPOSE_FILE) --project-directory $(WORKLOAD_DIR) down

# ---- kubernetes (kind) -----------------------------------------------------
.PHONY: cluster
cluster: ## Create the kind cluster $(CLUSTER) (no-op if it exists) + wire the registry
	kind get clusters | grep -qx $(CLUSTER) || \
		kind create cluster --name $(CLUSTER) --config platform/kind/cluster.yaml
	bash platform/kind/registry.sh $(CLUSTER)

.PHONY: push
push: build ## Build the image and push it to the shared local registry
	bash platform/kind/registry.sh
	docker push $(IMAGE)

.PHONY: deploy
deploy: cluster push manifests ## Direct deploy to $(CLUSTER) (used by `make dev`)
	kubectl --context kind-$(CLUSTER) create namespace $(WORKLOAD) --dry-run=client -o yaml \
		| kubectl --context kind-$(CLUSTER) apply -f -
	kubectl --context kind-$(CLUSTER) apply -n $(WORKLOAD) -f $(MANIFESTS)
	kubectl --context kind-$(CLUSTER) rollout status -n $(WORKLOAD) deploy/$(WORKLOAD)

.PHONY: forward
forward: ## Port-forward the workload on $(CLUSTER) to localhost:$(HOST_PORT)
	kubectl --context kind-$(CLUSTER) port-forward -n $(WORKLOAD) deploy/$(WORKLOAD) $(HOST_PORT):$(CONTAINER_PORT)

# ---- dev environment (ephemeral, direct deploy — fast inner loop) ----------
# App only: NO ArgoCD, NO Gatekeeper, NO observability. Those platform addons
# live solely on the test cluster (installed by `make bootstrap`/`test-up`).
.PHONY: dev-up
dev-up: ## Spin up the ephemeral dev cluster and deploy $(WORKLOAD) directly (app only)
	$(MAKE) deploy CLUSTER=$(DEV_CLUSTER)

.PHONY: dev-down
dev-down: ## Destroy the ephemeral dev cluster
	kind delete cluster --name $(DEV_CLUSTER)

# ---- GitOps environments (persistent — promote via git, not make) ----------
# test, stage, prod are identical in shape: each is a kind cluster running
# ArgoCD that syncs the App-of-Apps from git. *-up provisions, *-down destroys.
# There is intentionally no "make deploy" to any of them — the image lives in the
# shared registry and the platform (ArgoCD) does the deploy. Promotion = git.
.PHONY: test-up test-down
test-up: ## Provision the test cluster: ArgoCD + addons + test ApplicationSet
	$(MAKE) bootstrap CLUSTER=$(TEST_CLUSTER) ENV=test
test-down: ## Destroy the test cluster
	kind delete cluster --name $(TEST_CLUSTER)

.PHONY: stage-up stage-down
stage-up: ## Provision the stage cluster: ArgoCD + addons + stage ApplicationSet
	$(MAKE) bootstrap CLUSTER=$(STAGE_CLUSTER) ENV=stage
stage-down: ## Destroy the stage cluster
	kind delete cluster --name $(STAGE_CLUSTER)

.PHONY: prod-up prod-down
prod-up: ## Provision the prod cluster: ArgoCD + addons + prod ApplicationSet
	$(MAKE) bootstrap CLUSTER=$(PROD_CLUSTER) ENV=prod
prod-down: ## Destroy the prod cluster
	kind delete cluster --name $(PROD_CLUSTER)

# ---- release & promotion (tag-driven, trunk-based) -------------------------
# A release builds+pushes immutable image tags and points test at the new tag.
# Promotion advances an env's image tag. Both touch only the app-side overlays
# (workloads/*/envs/<env>) — the platform ApplicationSets never change.
.PHONY: release
release: ## Cut a release: build+push images :VERSION and point test at it
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z"; exit 1; }
	bash platform/kind/registry.sh
	@for w in $(WORKLOADS); do \
		docker build -t localhost:$(REG_PORT)/$$w-app:$(VERSION) ./workloads/$$w/app && \
		docker push localhost:$(REG_PORT)/$$w-app:$(VERSION); \
	done
	bash platform/scripts/set-version.sh test $(VERSION)
	@echo ">> Release $(VERSION) pushed; test overlay updated. Commit + 'git tag v$(VERSION)' to record it."

.PHONY: promote
promote: ## Promote an env to a version: make promote ENV=stage VERSION=x.y.z
	@test -n "$(ENV)" || { echo "usage: make promote ENV=stage|prod VERSION=x.y.z"; exit 1; }
	@test -n "$(VERSION)" || { echo "usage: make promote ENV=stage|prod VERSION=x.y.z"; exit 1; }
	bash platform/scripts/set-version.sh $(ENV) $(VERSION)
	@echo ">> $(ENV) overlay set to $(VERSION). Commit + push; ArgoCD syncs $(ENV)."

# ---- platform (ArgoCD / GitOps control plane) ------------------------------
.PHONY: argocd
argocd: cluster ## Install ArgoCD into $(CLUSTER) (GitOps control plane)
	helm repo add argo https://argoproj.github.io/argo-helm
	kubectl --context kind-$(CLUSTER) create namespace $(ARGOCD_NS) --dry-run=client -o yaml \
		| kubectl --context kind-$(CLUSTER) apply -f -
	helm upgrade --install argocd argo/argo-cd -n $(ARGOCD_NS) \
		--kube-context kind-$(CLUSTER) --wait --timeout 5m

.PHONY: bootstrap
bootstrap: argocd ## Apply platform addons + the $(ENV) workloads ApplicationSet to $(CLUSTER)
	kubectl --context kind-$(CLUSTER) apply -f platform/gitops/bootstrap/addons.yaml
	kubectl --context kind-$(CLUSTER) apply -f platform/gitops/envs/$(ENV).yaml

.PHONY: argocd-password
argocd-password: ## Print the ArgoCD initial admin password
	@kubectl --context kind-$(CLUSTER) -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the ArgoCD UI to https://localhost:$(ARGOCD_UI_PORT)
	kubectl --context kind-$(CLUSTER) -n $(ARGOCD_NS) port-forward svc/argocd-server $(ARGOCD_UI_PORT):443

# ---- housekeeping ----------------------------------------------------------
.PHONY: clean
clean: ## Remove the local-dev compose artifact (k8s manifests are committed, kept)
	rm -rf $(dir $(COMPOSE_FILE))

.PHONY: destroy
destroy: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)

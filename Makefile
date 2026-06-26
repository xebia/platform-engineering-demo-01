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
manifests: ## Render score.yaml -> committed k8s manifests (ArgoCD source of truth)
	cd $(WORKLOAD_DIR) && { test -d .score-k8s || score-k8s init --no-sample; } && \
		mkdir -p dist/k8s && \
		score-k8s generate score.yaml -o dist/k8s/manifests.yaml

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

# ---- test environment (persistent, GitOps — promote via git push) ----------
.PHONY: test-up
test-up: ## Provision the test cluster: ArgoCD + GitOps bootstrap (one-time)
	$(MAKE) bootstrap CLUSTER=$(TEST_CLUSTER)

# NOTE: there is intentionally no "make deploy to test" and no image step here.
# The image already lives in the shared registry (pushed during `make dev`/`push`)
# and the test cluster is wired to it. Promotion to test = commit + git push;
# ArgoCD syncs from git. The platform does the deploy, not make.

# ---- platform (ArgoCD / GitOps control plane) ------------------------------
.PHONY: argocd
argocd: cluster ## Install ArgoCD into $(CLUSTER) (GitOps control plane)
	helm repo add argo https://argoproj.github.io/argo-helm
	kubectl --context kind-$(CLUSTER) create namespace $(ARGOCD_NS) --dry-run=client -o yaml \
		| kubectl --context kind-$(CLUSTER) apply -f -
	helm upgrade --install argocd argo/argo-cd -n $(ARGOCD_NS) \
		--kube-context kind-$(CLUSTER) --wait --timeout 5m

.PHONY: bootstrap
bootstrap: argocd ## Apply the App-of-Apps roots (platform addons + workloads)
	kubectl --context kind-$(CLUSTER) apply -f platform/gitops/bootstrap/

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

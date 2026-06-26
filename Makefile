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
IMAGE         ?= $(WORKLOAD)-app:0.1.0
HOST_PORT     ?= 8080
CONTAINER_PORT?= 8080

CLUSTER       ?= platform-engineering
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
cluster: ## Create the kind cluster (no-op if it exists)
	kind get clusters | grep -qx $(CLUSTER) || \
		kind create cluster --config platform/kind/cluster.yaml

.PHONY: load
load: build ## Build image and load it into the kind cluster
	kind load docker-image $(IMAGE) --name $(CLUSTER)

.PHONY: deploy
deploy: cluster load manifests ## Full deploy: cluster + image + apply manifests
	kubectl apply -f $(MANIFESTS)
	kubectl rollout status deploy/$(WORKLOAD)

.PHONY: forward
forward: ## Port-forward the workload to localhost:$(HOST_PORT)
	kubectl port-forward deploy/$(WORKLOAD) $(HOST_PORT):$(CONTAINER_PORT)

# ---- platform (ArgoCD / GitOps control plane) ------------------------------
.PHONY: argocd
argocd: cluster ## Install ArgoCD into the kind cluster (GitOps control plane)
	helm repo add argo https://argoproj.github.io/argo-helm
	kubectl create namespace $(ARGOCD_NS) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install argocd argo/argo-cd -n $(ARGOCD_NS) --wait --timeout 5m

.PHONY: bootstrap
bootstrap: argocd ## Apply the App-of-Apps roots (platform addons + workloads)
	kubectl apply -f platform/gitops/bootstrap/

.PHONY: argocd-password
argocd-password: ## Print the ArgoCD initial admin password
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the ArgoCD UI to https://localhost:$(ARGOCD_UI_PORT)
	kubectl -n $(ARGOCD_NS) port-forward svc/argocd-server $(ARGOCD_UI_PORT):443

# ---- housekeeping ----------------------------------------------------------
.PHONY: clean
clean: ## Remove the local-dev compose artifact (k8s manifests are committed, kept)
	rm -rf $(dir $(COMPOSE_FILE))

.PHONY: destroy
destroy: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)

# Platform Engineering example — Score -> Docker Compose / Kubernetes (kind)
#
# Single source of truth: workloads/<name>/score.yaml
# Generated artifacts land in dist/ (gitignored).

# ---- configuration ---------------------------------------------------------
WORKLOAD      ?= hello-world
WORKLOAD_DIR  := workloads/$(WORKLOAD)
SCORE_FILE    := $(WORKLOAD_DIR)/score.yaml
BUILD_CONTEXT := ./$(WORKLOAD_DIR)/app

IMAGE         ?= hello-world-app:0.1.0
CLUSTER       ?= platform-engineering
ARGOCD_NS     ?= argocd
ARGOCD_UI_PORT?= 8081
HOST_PORT     ?= 8080
CONTAINER_PORT?= 8080

DIST          := dist
COMPOSE_FILE  := $(DIST)/compose.yaml
MANIFESTS     := $(DIST)/manifests.yaml

.DEFAULT_GOAL := help

# ---- meta ------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: init
init: ## Initialise score-compose and score-k8s local state (one-time)
	score-compose init --no-sample
	score-k8s init --no-sample

# ---- generate (Score -> artifacts) -----------------------------------------
.PHONY: compose
compose: $(DIST) ## Generate dist/compose.yaml from score.yaml
	score-compose generate $(SCORE_FILE) \
		--build 'web={"context":"$(BUILD_CONTEXT)"}' \
		--publish '$(HOST_PORT):$(WORKLOAD):$(CONTAINER_PORT)' \
		-o $(COMPOSE_FILE)

.PHONY: manifests
manifests: $(DIST) ## Generate dist/manifests.yaml from score.yaml
	score-k8s generate $(SCORE_FILE) -o $(MANIFESTS)

.PHONY: generate
generate: compose manifests ## Generate both compose + k8s artifacts

$(DIST):
	mkdir -p $(DIST)

# ---- local dev (Docker Compose) --------------------------------------------
.PHONY: build
build: ## Build the application image
	docker build -t $(IMAGE) $(BUILD_CONTEXT)

.PHONY: up
up: compose ## Build + run locally via Docker Compose
	docker compose -f $(COMPOSE_FILE) --project-directory . up --build

.PHONY: down
down: ## Stop the Docker Compose stack
	docker compose -f $(COMPOSE_FILE) --project-directory . down

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
bootstrap: argocd ## Apply the App-of-Apps so ArgoCD installs the platform addons
	kubectl apply -f platform/gitops/bootstrap/addons.yaml

.PHONY: argocd-password
argocd-password: ## Print the ArgoCD initial admin password
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the ArgoCD UI to https://localhost:$(ARGOCD_UI_PORT)
	kubectl -n $(ARGOCD_NS) port-forward svc/argocd-server $(ARGOCD_UI_PORT):443

# ---- housekeeping ----------------------------------------------------------
.PHONY: clean
clean: ## Remove generated artifacts
	rm -rf $(DIST)

.PHONY: destroy
destroy: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)

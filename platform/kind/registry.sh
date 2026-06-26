#!/usr/bin/env bash
# Shared local Docker registry for kind, per the upstream "local registry"
# pattern: https://kind.sigs.k8s.io/docs/user/local-registry/
#
# One registry container serves every kind cluster, so an image pushed once is
# pullable from all clusters — no per-cluster `kind load`.
#
# Usage:
#   registry.sh                  # ensure the registry container is running
#   registry.sh <cluster>...     # ...and wire each named kind cluster to it
set -euo pipefail

REG_NAME="${REG_NAME:-kind-registry}"
REG_PORT="${REG_PORT:-5001}"

# 1. Ensure the registry container is running (shared by all clusters).
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" \
    --network bridge --name "${REG_NAME}" registry:2 >/dev/null
  echo "registry: started ${REG_NAME} on localhost:${REG_PORT}"
fi

# 2. Connect it to the 'kind' network so cluster nodes can reach it by name.
#    (The 'kind' network only exists once a cluster has been created.)
if docker network inspect kind >/dev/null 2>&1; then
  if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
    docker network connect kind "${REG_NAME}"
  fi
fi

# 3. For each named cluster: point containerd at the registry and publish the
#    standard discovery ConfigMap.
for cluster in "$@"; do
  for node in $(kind get nodes --name "${cluster}"); do
    docker exec "${node}" mkdir -p "/etc/containerd/certs.d/localhost:${REG_PORT}"
    docker exec -i "${node}" cp /dev/stdin \
      "/etc/containerd/certs.d/localhost:${REG_PORT}/hosts.toml" <<EOF
[host."http://${REG_NAME}:5000"]
EOF
  done
  kubectl --context "kind-${cluster}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  echo "registry: wired cluster ${cluster}"
done

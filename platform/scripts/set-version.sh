#!/usr/bin/env bash
# Set the deployed image tag for every workload's <env> Kustomize overlay.
# This is the ONLY thing that changes on a release or promotion — the platform
# ApplicationSets and the score-rendered base stay static.
#
# Usage: set-version.sh <env> <version>
set -euo pipefail

ENV="${1:?usage: set-version.sh <env> <version>}"
VERSION="${2:?usage: set-version.sh <env> <version>}"
REG_PORT="${REG_PORT:-5001}"

for wdir in workloads/*/; do
  w="$(basename "$wdir")"
  dir="${wdir}envs/${ENV}"
  mkdir -p "$dir"
  cat > "${dir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Promotion knob: the image tag this env runs. Bump via 'make release'/'make promote'.
resources:
  - ../../dist/k8s
images:
  - name: localhost:${REG_PORT}/${w}-app
    newTag: "${VERSION}"
EOF
  echo "set ${w} [${ENV}] -> ${VERSION}"
done

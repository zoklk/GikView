#!/bin/sh
# Adds the Reloader annotation to the StatefulSet (the subchart has no hook for it).
# ArgoCD's helm source skips post-renderers, so prod whitelist changes need a manual
# refresh or rollout (see context/knowledge/reloader.md).
set -e
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
cat > "$d/all.yaml"
cp "$(dirname "$0")/kustomization.yaml" "$d/"
kubectl kustomize "$d"

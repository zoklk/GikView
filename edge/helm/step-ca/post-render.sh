#!/bin/sh
# Post-renderer: the upstream step-certificates chart exposes no workload-metadata-annotation hook,
# so we add the Reloader annotation (configmap.reloader.stakater.com/reload: step-ca-whitelist) to the
# step-ca StatefulSet via a kustomize strategic-merge patch. The harness auto-detects this file
# (conventions.post_render_script) and passes --post-renderer to helm template / upgrade --install /
# upgrade --dry-run=server, so kubeconform/dry-run validate the patched output too.
#
# NOTE: ArgoCD's helm source does not run helm post-renderers, so a prod ArgoCD sync will not apply
# this annotation — after a whitelist change in prod, refresh the ArgoCD app or rollout step-ca manually
# (see context/knowledge/reloader.md / step-ca.md).
set -e
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
cat > "$d/all.yaml"
cp "$(dirname "$0")/kustomization.yaml" "$d/"
kubectl kustomize "$d"

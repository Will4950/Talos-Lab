#!/usr/bin/env bash
# OPTIONAL: register your private Git repo with Argo CD and deploy the
# app-of-apps root. Runs only when argocd.appOfApps.enabled is true.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd kubectl

if [[ "$(cfg '.argocd.appOfApps.enabled')" != "true" ]]; then
  log "argocd.appOfApps.enabled is not true - skipping."; exit 0
fi
repo="$(cfg '.argocd.appOfApps.repoURL')"; [[ -n "$repo" ]] || die "set argocd.appOfApps.repoURL"
rev="$(cfg '.argocd.appOfApps.targetRevision')"; rev="${rev:-main}"
path="$(cfg '.argocd.appOfApps.path')"; path="${path:-apps}"

# Register the private repo (shared with phase 9, which bootstraps Longhorn
# before this runs). Idempotent, so re-registering here is harmless.
register_private_repo

log "Creating app-of-apps root (path=${path}, rev=${rev})"
kubectl apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${repo}
    targetRevision: ${rev}
    path: ${path}
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
YAML
log "app-of-apps root created - Argo CD will sync your child applications."

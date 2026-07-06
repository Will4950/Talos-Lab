#!/usr/bin/env bash
# Install Argo CD. Uses --server-side because the CRDs are too large for a
# client-side apply.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd kubectl

ver="$(cfg '.versions.argocd')"; ver="${ver:-stable}"
if [[ "$ver" == "stable" ]]; then
  url="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
else
  url="https://raw.githubusercontent.com/argoproj/argo-cd/${ver}/manifests/install.yaml"
fi

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
log "Installing Argo CD (${ver})"
kubectl apply -n argocd --server-side --force-conflicts -f "$url"

log "Waiting for Argo CD components…"
kubectl -n argocd rollout status deploy/argocd-server        --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server   --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s 2>/dev/null \
  || kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=300s 2>/dev/null || true
log "Argo CD installed."

log "Configuring readonly account + RBAC"

# Enable an apiKey-capable 'readonly' account (merges into argocd-cm, leaving
# all upstream defaults intact).
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"accounts.readonly":"apiKey"}}'

# Grant the readonly account the built-in role:readonly (merges into
# argocd-rbac-cm). NOTE: a merge SETS policy.csv wholesale - if you add more
# custom policy lines later, keep them all in this one string.
kubectl -n argocd patch configmap argocd-rbac-cm --type merge \
  -p '{"data":{"policy.csv":"g, readonly, role:readonly"}}'

# argocd-server caches account config; restart to load the new account.
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status  deploy/argocd-server --timeout=300s

# The readonly account has no usable token until one is generated (manual,
# needs an admin argocd login):
#   pw=$(kubectl -n argocd get secret argocd-initial-admin-secret \
#         -o jsonpath='{.data.password}' | base64 -d)
#   argocd login <argocd-host> --username admin --password "$pw"
#   argocd account generate-token --account readonly   # printed once - save it
log "Argo CD configured. Generate the readonly token manually (see script comments)."

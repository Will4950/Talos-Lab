#!/usr/bin/env bash
# Deploy Longhorn as a SELF-CONTAINED Argo CD Application. The Helm values from
# manifests/longhorn/values.yaml are embedded inline (helm.values), so this needs
# no private repo and no apps/ directory - it works on a fresh cluster before any
# app-of-apps is set up. Runs before the app-of-apps root (phase 11) because
# storage must exist before child apps request PVCs.
#
# manifests/longhorn/values.yaml stays the single source of truth for Longhorn
# settings (replica count, data path, etc.). If you later manage Longhorn through
# your own app-of-apps repo, that Application (also named "longhorn") takes over.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd kubectl

ver="$(cfg '.versions.longhorn')"; [[ -n "$ver" ]] || die "versions.longhorn not set"
values_file="$REPO_ROOT/manifests/longhorn/values.yaml"
[[ -f "$values_file" ]] || die "missing $values_file"

log "Deploying Longhorn ${ver} via Argo CD (values inlined from manifests/longhorn/values.yaml)"

# Emit the Application with the values file embedded under helm.values. The values
# lines are indented 8 spaces so they sit inside the `values: |` block scalar.
{
cat <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://charts.longhorn.io
    chart: longhorn
    targetRevision: ${ver}
    helm:
      values: |
YAML
sed 's/^/        /' "$values_file"
cat <<'YAML'
  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/audit: privileged
        pod-security.kubernetes.io/warn: privileged
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
YAML
} | kubectl apply -f -

wait_for "longhorn-manager to appear" 600 "kubectl -n longhorn-system get ds longhorn-manager >/dev/null 2>&1"
kubectl -n longhorn-system rollout status ds/longhorn-manager --timeout=600s
log "StorageClasses:"; kubectl get storageclass

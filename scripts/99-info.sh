#!/usr/bin/env bash
# Print how to reach the cluster: kubeconfig, Argo CD, Longhorn, and the app pools.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd kubectl

pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
pools="$(yq -r '[.metallb.pools[]?.addresses[]] | join(", ")' "$CONFIG" 2>/dev/null || true)"

cat <<INFO

============================================================
 Cluster is up.
------------------------------------------------------------
 talosconfig : $TALOSCONFIG
 kubeconfig  : $KUBECONFIG
   export KUBECONFIG=$KUBECONFIG

 Argo CD
   port-forward : kubectl -n argocd port-forward svc/argocd-server 8080:443
   url / user   : https://localhost:8080  /  admin
   password     : ${pw:-<not found - already rotated?>}

 Longhorn
   port-forward : kubectl -n longhorn-system port-forward svc/longhorn-frontend 8081:80

 App IPs (MetalLB): ${pools:-disabled}
   auto  : kubectl expose deploy <app> --port=80 --type=LoadBalancer
   pinned: annotate the Service  metallb.universe.tf/loadBalancerIPs: <ip>
   check : kubectl get svc -A
============================================================
INFO

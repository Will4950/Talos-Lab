#!/usr/bin/env bash
# Install MetalLB in L2 mode and configure address pools from the YAML config.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd kubectl

if [[ "$(cfg '.metallb.enabled')" != "true" ]]; then
  log "metallb.enabled is not true - skipping."; exit 0
fi
ver="$(cfg '.versions.metallb')"; [[ -n "$ver" ]] || die "versions.metallb not set"
npools="$(yq -r '.metallb.pools | length' "$CONFIG")"
[[ "${npools:-0}" -gt 0 ]] || die "define at least one pool under metallb.pools"

url="https://raw.githubusercontent.com/metallb/metallb/${ver}/config/manifests/metallb-native.yaml"
log "Installing MetalLB ${ver} (L2 mode)"
kubectl apply -f "$url"

kubectl label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite

log "Waiting for MetalLB controller + speaker…"
kubectl -n metallb-system rollout status deploy/controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/speaker --timeout=300s

manifest="$OUT_DIR/metallb-pools.yaml"
: > "$manifest"
names=()
for i in $(seq 0 $((npools - 1))); do
  name="$(yq -r ".metallb.pools[$i].name" "$CONFIG")"
  names+=("$name")
  {
    echo "apiVersion: metallb.io/v1beta1"
    echo "kind: IPAddressPool"
    echo "metadata:"
    echo "  name: ${name}"
    echo "  namespace: metallb-system"
    echo "spec:"
    echo "  addresses:"
    yq -r ".metallb.pools[$i].addresses[] | \"    - \" + ." "$CONFIG"
    echo "---"
  } >> "$manifest"
done
{
  echo "apiVersion: metallb.io/v1beta1"
  echo "kind: L2Advertisement"
  echo "metadata:"
  echo "  name: lan"
  echo "  namespace: metallb-system"
  echo "spec:"
  echo "  ipAddressPools:"
  for n in "${names[@]}"; do echo "    - ${n}"; done
} >> "$manifest"

# The IPAddressPool/L2Advertisement webhook needs a few seconds after the
# controller is Available - retry until it accepts the config.
log "Configuring address pools: ${names[*]}"
tries=0
until kubectl apply -f "$manifest"; do
  tries=$((tries + 1)); (( tries > 12 )) && die "failed to apply MetalLB pools (webhook never became ready)"
  warn "MetalLB webhook not ready - retrying in 10s"; sleep 10
done
log "MetalLB ready. LoadBalancer services now get IPs from your pools."

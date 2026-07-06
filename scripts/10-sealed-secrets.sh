#!/usr/bin/env bash
# Install the Sealed Secrets controller from its pinned release manifest. It lands
# in kube-system named "sealed-secrets-controller" - exactly what the kubeseal CLI
# targets by default, so you can seal secrets with no extra flags.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd kubectl

if [[ "$(cfg '.sealedSecrets.enabled')" != "true" ]]; then
  log "sealedSecrets.enabled is not true - skipping."; exit 0
fi
ver="$(cfg '.sealedSecrets.version')"; [[ -n "$ver" ]] || die "sealedSecrets.version not set"

url="https://github.com/bitnami/sealed-secrets/releases/download/v${ver}/controller.yaml"
log "Installing Sealed Secrets controller v${ver} (kube-system)"
kubectl apply -f "$url"
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=300s

log "Sealed Secrets ready. Install the matching kubeseal CLI (v${ver}), then seal secrets:"
log "  kubeseal --fetch-cert > pub-cert.pem                       # public key, safe to commit"
log "  kubeseal --format yaml --cert pub-cert.pem < secret.yaml   # -> a SealedSecret you commit"

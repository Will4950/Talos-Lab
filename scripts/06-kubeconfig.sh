#!/usr/bin/env bash
# Wait for the cluster to come healthy, fetch a kubeconfig, and label every node
# with its Proxmox host (topology.kubernetes.io/zone) for storage placement.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd talosctl; require_cmd kubectl

cp1="$(first_cp_ip)"; [[ -n "$cp1" ]] || die "no control-plane nodes in config"
health_to="$(cfg '.timeouts.health')"; health_to="${health_to:-10m}"

cps=""; while IFS=';' read -r ip _; do [[ -z "$ip" ]] && continue; cps+="${cps:+,}$ip"; done < <(control_planes)
wks=""; while IFS=';' read -r ip _; do [[ -z "$ip" ]] && continue; wks+="${wks:+,}$ip"; done < <(workers)

talosctl config endpoint ${cps//,/ }
talosctl config node "$cp1"

hargs=(--nodes "$cp1" --control-plane-nodes "$cps" --wait-timeout "$health_to")
[[ -n "$wks" ]] && hargs+=(--worker-nodes "$wks")
log "Waiting for Talos / Kubernetes health…"
if ! talosctl health "${hargs[@]}"; then
  warn "health did not fully converge; continuing."
  warn "If it says 'unable to connect to <ip>:50000', that is a node's Talos API (apid) - the node is down, not booted (check the Proxmox console for the EFI shell), or not at its configured IP. Verify with: talosctl -n <ip> version --insecure   and   DHCP_VERIFY=1 ./bootstrap.sh dhcp"
fi

log "Fetching kubeconfig → $KUBECONFIG"
talosctl kubeconfig --nodes "$cp1" --force "$KUBECONFIG"

ep="$(api_endpoint)"
if [[ "$(endpoint_mode)" == "talos-vip" && -n "$ep" ]] && ! timeout 5 bash -c ": < /dev/tcp/${ep}/6443" 2>/dev/null; then
  warn "API endpoint https://${ep}:6443 (the VIP) isn't answering yet."
  warn "The cluster itself is healthy (in-cluster traffic uses KubePrism, localhost:7445); this only"
  warn "blocks kubectl/talosctl via the VIP and the node labeling below."
  warn "Confirm the VIP is bound on a control plane and reachable across hosts:"
  warn "  talosctl -n ${cp1} -e ${cp1} get addresses | grep ${ep}"
  warn "Then finish labeling once it is:  ./bootstrap.sh kubeconfig"
  exit 0
fi

kubectl wait --for=condition=Ready nodes --all --timeout="$health_to" || warn "not all nodes Ready yet"

log "Labeling nodes with their Proxmox host (topology.kubernetes.io/zone)"
label_zone() {
  local ip="$1" zone="$2" node
  node="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="$ip" '$2==ip{print $1; exit}')"
  if [[ -n "$node" ]]; then
    kubectl label node "$node" "topology.kubernetes.io/zone=${zone}" --overwrite >/dev/null
    log "  ${ip} (${node}) → zone=${zone}"
  else
    warn "  no node found with InternalIP ${ip} yet - label it later"
  fi
}
while IFS=';' read -r ip host _; do [[ -z "$ip" ]] && continue; label_zone "$ip" "$host"; done < <(all_nodes)

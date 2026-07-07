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

# Longhorn storage eligibility: workers always run Longhorn; control planes only
# when scheduleOnControlPlane is true. A node is a STORAGE node when it is
# eligible AND its Proxmox host is not in longhorn.excludeHosts.
lh_on_cp="$(cfg '.install.scheduleOnControlPlane')"

log "Labeling nodes: topology.kubernetes.io/zone + node.longhorn.io/create-default-disk"
label_node() {  # ip zone role(cp|wk)
  local ip="$1" zone="$2" role="$3" node storage="false"
  node="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="$ip" '$2==ip{print $1; exit}')"
  if [[ -z "$node" ]]; then
    warn "  no node found with InternalIP ${ip} yet - label it later"
    return
  fi
  kubectl label node "$node" "topology.kubernetes.io/zone=${zone}" --overwrite >/dev/null

  # storage node? eligible role AND host not excluded
  if [[ "$role" == "wk" || "$lh_on_cp" == "true" ]] && ! host_longhorn_excluded "$zone"; then
    storage="true"
  fi
  kubectl label node "$node" "node.longhorn.io/create-default-disk=${storage}" --overwrite >/dev/null
  log "  ${ip} (${node}) → zone=${zone}, longhorn-storage=${storage}"
}
while IFS=';' read -r ip host _; do [[ -z "$ip" ]] && continue; label_node "$ip" "$host" cp; done < <(control_planes)
while IFS=';' read -r ip host _; do [[ -z "$ip" ]] && continue; label_node "$ip" "$host" wk; done < <(workers)

#!/usr/bin/env bash
# DESTRUCTIVE: stop and destroy the Talos VMs (disks included) on each Proxmox
# host over SSH. Idempotent - VMs that don't exist are skipped. Guarded - you
# must type the cluster name to confirm, or set FORCE=1 to skip the prompt.
# DHCP reservations and the Talos ISO are left in place.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd ssh

[[ "$(cfg '.proxmox.provisionVMs')" == "true" ]] || \
  warn "proxmox.provisionVMs is not true - this only removes VMs by the vmids in your config."

ssh_opts="$(cfg '.proxmox.sshOpts')"
cluster="$(cfg '.clusterName')"

mapfile -t lines < <(all_nodes)
targets=()
for line in "${lines[@]}"; do
  [[ -z "$line" ]] && continue
  IFS=';' read -r ip host vmid mac <<<"$line"
  [[ -z "$vmid" ]] && { warn "node $ip has no vmid - skipping"; continue; }
  targets+=("${ip};${host};${vmid}")
done
[[ ${#targets[@]} -gt 0 ]] || die "no VMs with a vmid to remove"

warn "About to STOP and DESTROY these VMs (including their disks) on Proxmox:"
for t in "${targets[@]}"; do IFS=';' read -r ip host vmid <<<"$t"; echo "    VMID ${vmid}   ${ip}   on ${host}" >&2; done

if [[ "${FORCE:-}" != "1" ]]; then
  printf 'Type the cluster name "%s" to confirm: ' "$cluster" >&2
  read -r ans < /dev/tty || die "no terminal to confirm - re-run with FORCE=1 to proceed non-interactively"
  [[ "$ans" == "$cluster" ]] || die "confirmation did not match - aborting, nothing changed"
fi

destroy_vm() {  # ip host vmid
  local ip="$1" host="$2" vmid="$3" tgt
  tgt="$(host_ssh "$host")"; [[ -n "$tgt" ]] || die "no proxmox.hosts entry named '$host'"
  if ! ssh -n $ssh_opts "$tgt" "qm status ${vmid} >/dev/null 2>&1"; then
    warn "VMID ${vmid} not found on ${host} - skipping"; return 0
  fi
  log "→ VMID ${vmid} on ${host}: stopping"
  ssh -n $ssh_opts "$tgt" "qm stop ${vmid} --skiplock 1 >/dev/null 2>&1 || true"
  ssh -n $ssh_opts "$tgt" "for i in \$(seq 1 30); do qm status ${vmid} 2>/dev/null | grep -q stopped && break; sleep 1; done"
  log "→ VMID ${vmid} on ${host}: destroying (with disks)"
  ssh -n $ssh_opts "$tgt" "qm destroy ${vmid} --purge 1 --destroy-unreferenced-disks 1 --skiplock 1"
}

for t in "${targets[@]}"; do
  IFS=';' read -r ip host vmid <<<"$t"
  destroy_vm "$ip" "$host" "$vmid"
done
log "Done. VMs removed (disks purged). DHCP reservations and the Talos ISO were left in place."

# The VMs are wiped, so no Talos state survives on them. The only stale state is
# on this workstation, in secrets/out (talosconfig, kubeconfig, machine configs).
if [[ "${CLEAN_STATE:-}" == "1" ]]; then
  rm -rf "$OUT_DIR"
  log "Cleared workstation state in ${OUT_DIR}. A fresh ./bootstrap.sh regenerates new PKI + configs."
else
  warn "Workstation state in ${OUT_DIR} still points at the destroyed cluster (old talosconfig/kubeconfig)."
  warn "For a clean rebuild: rm -rf \"${OUT_DIR}\"   (or re-run this with CLEAN_STATE=1). Talos mints new PKI on the next gen-config."
fi

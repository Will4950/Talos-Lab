#!/usr/bin/env bash
# OPTIONAL: create and start the Talos VMs on each Proxmox host over SSH (qm).
# Workers get a second, blank data disk for Longhorn when longhorn.dedicatedDisk
# is enabled (control planes only if scheduleOnControlPlane is true).
# ssh uses -n and the node lists are read into arrays first, so ssh cannot swallow
# the loop\047s stdin (which would otherwise create VMs on only the first host).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [[ "$(cfg '.proxmox.provisionVMs')" != "true" ]]; then
  log "proxmox.provisionVMs is not true - skipping VM creation (build the VMs yourself)."
  exit 0
fi
require_cmd ssh

id="$(schematic_id)"; [[ -n "$id" ]] || die "no schematic id - run scripts/01-schematic.sh first"
talos="$(cfg '.versions.talos')"
iso_url="https://factory.talos.dev/image/${id}/${talos}/metal-amd64.iso"
iso_name="talos-${talos}-${id:0:12}.iso"

ssh_opts="$(cfg '.proxmox.sshOpts')"
bridge="$(cfg '.proxmox.bridge')"
storage="$(cfg '.proxmox.storage')"
iso_storage="$(cfg '.proxmox.isoStorage')"
iso_dir="$(cfg '.proxmox.isoDir')"

dedicated="$(cfg '.longhorn.dedicatedDisk.enabled')"
data_disk_gb="$(cfg '.longhorn.dedicatedDisk.sizeGB')"; data_disk_gb="${data_disk_gb:-100}"
lh_on_cp="$(cfg '.install.scheduleOnControlPlane')"

create_vm() {  # ip host vmid mac add_data_disk cores memory os_disk
  local ip="$1" host="$2" vmid="$3" mac="$4" add_data="$5" cores="$6" memory="$7" os_disk="$8"
  local ssh_target; ssh_target="$(host_ssh "$host")"
  [[ -n "$ssh_target" ]] || die "no proxmox.hosts entry named '$host' (needed for node $ip)"
  [[ -n "$vmid" ]] || die "node $ip is missing a vmid (needed to create the VM)"
  log "→ ${ip}  (VMID ${vmid} on ${host} → ${ssh_target}; ${cores} vCPU / ${memory} MiB; data-disk=${add_data})"

  ssh -n $ssh_opts "$ssh_target" "test -f '${iso_dir}/${iso_name}' || { echo 'downloading Talos ISO...'; curl -fL -o '${iso_dir}/${iso_name}' '${iso_url}'; }"

  if ssh -n $ssh_opts "$ssh_target" "qm status ${vmid} >/dev/null 2>&1"; then
    warn "VMID ${vmid} already exists on ${host} - skipping create"
    return 0
  fi

  local data_opt=""
  [[ "$add_data" == "true" ]] && data_opt="--scsi1 ${storage}:${data_disk_gb},discard=on,ssd=1"

  ssh -n $ssh_opts "$ssh_target" "qm create ${vmid} \
    --name talos-${vmid} --ostype l26 --machine q35 --cpu host \
    --bios ovmf --efidisk0 ${storage}:1,efitype=4m,pre-enrolled-keys=0 \
    --cores ${cores} --memory ${memory} --balloon 0 --numa 0 --onboot 1 \
    --scsihw virtio-scsi-pci --agent enabled=1 --serial0 socket \
    --net0 virtio,bridge=${bridge}${mac:+,macaddr=${mac}},firewall=0 \
    --scsi0 ${storage}:${os_disk},discard=on,ssd=1 \
    ${data_opt} \
    --ide2 ${iso_storage}:iso/${iso_name},media=cdrom \
    --boot order='scsi0;ide2'"
  ssh -n $ssh_opts "$ssh_target" "qm start ${vmid}"
}

# Per-Proxmox-host network prep, applied to every host in proxmox.hosts:
#
#   1. bnx2x VXLAN offload workaround. Broadcom bnx2x NICs corrupt the inner
#      checksum of VXLAN-encapsulated traffic, which silently breaks flannel
#      pod-to-pod TCP/UDP across that host (ICMP and control-plane underlay
#      traffic still work, so it hides until a workload lands there). Detect any
#      bnx2x NIC and disable offloads - live, and persisted via a post-up hook in
#      /etc/network/interfaces so it survives reboots. No-op on i40e/other drivers.
#
#   2. Ensure the vmbr0 bridge is VLAN-aware. Our nodes trunk a VLAN over vmbr0,
#      so 'bridge-vlan-aware yes' must be set. Only the config file is edited (and
#      only when wrong/missing) - flipping it on a live bridge is disruptive, so we
#      warn to reload/reboot rather than doing it automatically.
prep_host() {  # host ssh_target
  local host="$1" ssh_target="$2"
  # NOTE: no -n here - the remote script is fed on stdin via the heredoc, and
  # -n would redirect stdin from /dev/null and send an empty script.
  ssh $ssh_opts "$ssh_target" 'bash -s' <<'REMOTE'
set -euo pipefail
IFACES=/etc/network/interfaces
backup_once() { [ -f "/tmp/.interfaces.bak.$$" ] || cp "$IFACES" "/tmp/.interfaces.bak.$$"; }

# --- 1. bnx2x offload workaround ---
found=0
for dev in /sys/class/net/*; do
  name="$(basename "$dev")"
  [ -e "$dev/device/driver" ] || continue
  drv="$(basename "$(readlink -f "$dev/device/driver")")"
  [ "$drv" = "bnx2x" ] || continue
  found=1
  echo "  bnx2x NIC detected: $name - disabling offloads"
  ethtool -K "$name" tx off rx off gso off gro off tso off || true
  hook="post-up /sbin/ethtool -K $name tx off rx off gso off gro off tso off || true"
  if ! grep -qF "ethtool -K $name " "$IFACES"; then
    # Insert the hook into this NIC's stanza (matches "iface <name> inet ...").
    if grep -qE "^iface[[:space:]]+$name[[:space:]]+inet" "$IFACES"; then
      backup_once
      sed -i "/^iface[[:space:]]\+$name[[:space:]]\+inet/a \\\t$hook" "$IFACES"
      echo "  persisted post-up hook for $name in $IFACES"
    else
      echo "  WARN: no 'iface $name inet' stanza found - offload disable is live but NOT persisted" >&2
    fi
  else
    echo "  post-up hook for $name already present"
  fi
done
[ "$found" = 1 ] || echo "  no bnx2x NIC on this host - offload prep skipped"

# --- 2. vmbr0 VLAN-aware ---
if ! grep -qE "^iface[[:space:]]+vmbr0[[:space:]]+inet" "$IFACES"; then
  echo "  WARN: no 'iface vmbr0 inet' stanza - cannot set bridge-vlan-aware" >&2
elif grep -qE "^[[:space:]]*bridge-vlan-aware[[:space:]]+yes" "$IFACES"; then
  echo "  vmbr0 bridge-vlan-aware already yes"
elif grep -qE "^[[:space:]]*bridge-vlan-aware" "$IFACES"; then
  backup_once
  sed -i -E "s/^([[:space:]]*)bridge-vlan-aware[[:space:]]+.*/\1bridge-vlan-aware yes/" "$IFACES"
  echo "  set vmbr0 bridge-vlan-aware yes (was set to another value) - reload/reboot the host to apply"
else
  # key absent - add it right after the vmbr0 stanza header
  backup_once
  sed -i "/^iface[[:space:]]\+vmbr0[[:space:]]\+inet/a \\\tbridge-vlan-aware yes" "$IFACES"
  echo "  added vmbr0 bridge-vlan-aware yes - reload/reboot the host to apply"
fi
rm -f "/tmp/.interfaces.bak.$$"
REMOTE
}

log "Preparing Proxmox hosts (bnx2x offload workaround + vmbr0 VLAN-aware)"
mapfile -t host_lines < <(proxmox_hosts)
for line in "${host_lines[@]}"; do
  [[ -z "$line" ]] && continue
  IFS=';' read -r h_name h_ssh <<<"$line"
  [[ -n "$h_ssh" ]] || { warn "proxmox host '$h_name' has no ssh target - skipping host prep"; continue; }
  log "→ ${h_name} (${h_ssh})"
  prep_host "$h_name" "$h_ssh"
done

log "Provisioning VMs (ISO: ${iso_name})"

# control planes - data disk only if Longhorn also runs on them
cp_data="false"; [[ "$dedicated" == "true" && "$lh_on_cp" == "true" ]] && cp_data="true"
mapfile -t cp_lines < <(control_planes)
for line in "${cp_lines[@]}"; do
  [[ -z "$line" ]] && continue
  IFS=';' read -r ip host vmid mac <<<"$line"
  IFS=';' read -r c_cores c_mem c_disk <<<"$(node_resources cp "$ip")"
  create_vm "$ip" "$host" "$vmid" "$mac" "$cp_data" "$c_cores" "$c_mem" "$c_disk"
done

# workers - data disk whenever dedicatedDisk is enabled
wk_data="false"; [[ "$dedicated" == "true" ]] && wk_data="true"
mapfile -t wk_lines < <(workers)
for line in "${wk_lines[@]}"; do
  [[ -z "$line" ]] && continue
  IFS=';' read -r ip host vmid mac <<<"$line"
  IFS=';' read -r w_cores w_mem w_disk <<<"$(node_resources wk "$ip")"
  create_vm "$ip" "$host" "$vmid" "$mac" "$wk_data" "$w_cores" "$w_mem" "$w_disk"
done

log "VMs started. Make sure each MAC has a DHCP reservation to its listed IP."

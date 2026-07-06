#!/usr/bin/env bash
# Generate Talos machine configs (controlplane.yaml + worker.yaml) with the
# storage and multi-host patches baked in. Output lands in secrets/out.
#
# Dedicated Longhorn disk (longhorn.dedicatedDisk.enabled: true):
#   * a UserVolumeConfig mounts the blank data disk at /var/mnt/longhorn
#   * the kubelet gets a bind mount for that path
#   * only nodes that run Longhorn get the mount + volume (workers, plus control
#     planes when scheduleOnControlPlane is true)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd talosctl

id="$(schematic_id)"; [[ -n "$id" ]] || die "no schematic id - run scripts/01-schematic.sh first"
talos="$(cfg '.versions.talos')"
installer="factory.talos.dev/installer/${id}:${talos}"
cluster="$(cfg '.clusterName')"
disk="$(cfg '.install.disk')"
k8s="$(cfg '.versions.kubernetes')"
mode="$(endpoint_mode)"
ep="$(api_endpoint)"
sched_cp="$(cfg '.install.scheduleOnControlPlane')"
kubespan="$(cfg '.network.kubeSpan')"
endpoint="$(cp_endpoint)"

dedicated="$(cfg '.longhorn.dedicatedDisk.enabled')"
disk_selector="$(cfg '.longhorn.dedicatedDisk.diskSelector')"; disk_selector="${disk_selector:-!system_disk}"
min_size="$(cfg '.longhorn.dedicatedDisk.minSize')"; min_size="${min_size:-10GiB}"
if [[ "$dedicated" == "true" ]]; then lh_path="/var/mnt/longhorn"; else lh_path="/var/lib/longhorn"; fi
if [[ "$sched_cp" == "true" ]]; then lh_on_cp="true"; else lh_on_cp="false"; fi

log "Generating Talos configs (endpoint https://${endpoint}:6443, Longhorn path ${lh_path})"

cat > "$OUT_DIR/patch-common.yaml" <<PATCH
machine:
  install:
    disk: ${disk}
  features:
    kubePrism:            # in-cluster API load balancer on localhost:7445 - this is
      enabled: true       # how kubelet/CNI reach the API without an external VIP/LB
      port: 7445
PATCH

# machine.network - static node resolvers (fallback DNS) and/or kubespan. 
dns_servers="$(cfg '.network.dnsServers[]')"
if [[ -n "$dns_servers" || "$kubespan" == "true" ]]; then
  echo "  network:" >> "$OUT_DIR/patch-common.yaml"
  if [[ -n "$dns_servers" ]]; then
    echo "    nameservers:" >> "$OUT_DIR/patch-common.yaml"
    while IFS= read -r ns; do
      [[ -n "$ns" ]] && echo "      - ${ns}" >> "$OUT_DIR/patch-common.yaml"
    done <<< "$dns_servers"
    log "Node resolvers (machine.network.nameservers): $(echo $dns_servers | tr '\n' ' ')"
  fi
  if [[ "$kubespan" == "true" ]]; then
    cat >> "$OUT_DIR/patch-common.yaml" <<PATCH
    kubespan:
      enabled: true
PATCH
  fi
fi

# The kubelet bind-mount Longhorn needs, emitted only where Longhorn runs.
kubelet_mount() {
cat <<PATCH
machine:
  kubelet:
    extraMounts:
      - destination: ${lh_path}
        type: bind
        source: ${lh_path}
        options: [bind, rshared, rw]
PATCH
}

# control-plane patches - each a clean standalone doc, passed as its own
# --config-patch-control-plane so we never emit duplicate top-level keys.
cp_patches=()

# cluster-level: optional scheduling + API server certificate SANs. The cert must
# be valid for the endpoint (LB frontend or VIP) AND each control-plane IP, so the
# API works whether reached through the load balancer or a node directly.
{
  echo "cluster:"
  [[ "$sched_cp" == "true" ]] && echo "  allowSchedulingOnControlPlanes: true"
  echo "  apiServer:"
  echo "    certSANs:"
  [[ -n "$ep" ]] && echo "      - ${ep}"
  while IFS=';' read -r ip _rest; do [[ -n "$ip" ]] && echo "      - ${ip}"; done < <(control_planes)
} > "$OUT_DIR/patch-cp-cluster.yaml"
cp_patches+=(--config-patch-control-plane @"$OUT_DIR/patch-cp-cluster.yaml")

# machine-level: Talos etcd-elected VIP - only in talos-vip mode
if [[ "$mode" == "talos-vip" && -n "$ep" ]]; then
  cat > "$OUT_DIR/patch-cp-vip.yaml" <<PATCH
machine:
  network:
    interfaces:
      - deviceSelector:
          physical: true      # any physical NIC (NIC-agnostic; Sidero's recommended selector)
        dhcp: true
        vip:
          ip: ${ep}
PATCH
  cp_patches+=(--config-patch-control-plane @"$OUT_DIR/patch-cp-vip.yaml")
  log "endpointMode=talos-vip: control planes will elect the VIP ${ep} via etcd"
else
  log "endpointMode=${mode}: no etcd VIP; API endpoint is https://${endpoint}:6443 (KubePrism handles in-cluster access)"
fi

# machine-level: Longhorn kubelet mount - only if control planes run Longhorn
if [[ "$lh_on_cp" == "true" ]]; then
  kubelet_mount > "$OUT_DIR/patch-cp-kubelet.yaml"
  cp_patches+=(--config-patch-control-plane @"$OUT_DIR/patch-cp-kubelet.yaml")
fi

# worker patch - workers always run Longhorn, so always get the mount
kubelet_mount > "$OUT_DIR/patch-worker.yaml"

extra=()
[[ -n "$k8s" ]] && extra+=(--kubernetes-version "$k8s")

# Persistent PKI: generate the secrets bundle ONCE and reuse it.
secrets_file="$OUT_DIR/secrets.yaml"
if [[ -f "$secrets_file" ]]; then
  log "Reusing PKI bundle $secrets_file (delete it to rotate the cluster CA/tokens)"
else
  log "Generating a persistent PKI bundle -> $secrets_file"
  talosctl gen secrets -o "$secrets_file"
fi

talosctl gen config "$cluster" "https://${endpoint}:6443" \
  --with-secrets "$secrets_file" \
  --install-image "$installer" \
  ${extra[@]+"${extra[@]}"} \
  --config-patch @"$OUT_DIR/patch-common.yaml" \
  ${cp_patches[@]+"${cp_patches[@]}"} \
  --config-patch-worker @"$OUT_DIR/patch-worker.yaml" \
  --output-dir "$OUT_DIR" --force

# dedicated disk - append a UserVolumeConfig document to the relevant configs
if [[ "$dedicated" == "true" ]]; then
  uvc() {
cat <<PATCH
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn
provisioning:
  diskSelector:
    match: '${disk_selector}'
  minSize: ${min_size}
  grow: true
PATCH
}
  uvc >> "$OUT_DIR/worker.yaml"
  [[ "$lh_on_cp" == "true" ]] && uvc >> "$OUT_DIR/controlplane.yaml"
  log "Appended UserVolumeConfig (match: ${disk_selector}; minSize ${min_size}, grow); it mounts the data disk at ${lh_path}"
fi

log "Wrote controlplane.yaml, worker.yaml, talosconfig to $OUT_DIR"

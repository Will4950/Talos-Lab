#!/usr/bin/env bash
# Push the generated machine configs to each node. Waits for a node's
# maintenance API before applying, so it's safe to run right after the VMs boot.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd talosctl

[[ -f "$OUT_DIR/controlplane.yaml" && -f "$OUT_DIR/worker.yaml" ]] \
  || die "generated configs missing - run scripts/03-gen-config.sh first"
maint="$(cfg '.timeouts.maintenanceSeconds')"; maint="${maint:-600}"

apply_node() {
  local ip="$1" file="$2" role="$3"
  wait_for "node $ip (maintenance API)" "$maint" "talosctl -n $ip get disks --insecure >/dev/null 2>&1"
  log "Applying ${role} config → $ip"
  talosctl apply-config --insecure --nodes "$ip" --file "$file"
}

while IFS=';' read -r ip host vmid mac; do
  [[ -z "$ip" ]] && continue
  apply_node "$ip" "$OUT_DIR/controlplane.yaml" "control-plane"
done < <(control_planes)

while IFS=';' read -r ip host vmid mac; do
  [[ -z "$ip" ]] && continue
  apply_node "$ip" "$OUT_DIR/worker.yaml" "worker"
done < <(workers)

log "Configs applied. Nodes will install to disk and reboot."

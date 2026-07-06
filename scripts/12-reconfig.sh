#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# 12-reconfig.sh - (re)apply machine config to nodes, new OR already-running.
#
# Regenerates the machine configs (so a cluster.yaml edit is always reflected)
# then, PER NODE, auto-detects how to reach it:
#   * already-running node → AUTHENTICATED API. Config-only changes (e.g. adding
#     network.dnsServers) apply live with NO reboot; talosctl stages a reboot on
#     its own only if a change needs one. Applies instantly - no waiting.
#   * fresh maintenance-mode node → INSECURE API, after waiting for that node's
#     maintenance API (up to timeouts.maintenanceSeconds).
#
# So you can add nodes to cluster.yaml and run this: the NEW nodes get the
# first-boot insecure apply, while EXISTING nodes are reconfigured immediately
# instead of blocking on the maintenance timeout.
#
#   ./bootstrap.sh reconfig            # regenerate, then apply to every node
#   REGEN=0 ./bootstrap.sh reconfig    # skip regen, apply the existing out/*.yaml
#   NODES="10.2.16.11 10.2.16.21" ./bootstrap.sh reconfig   # only these nodes
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd talosctl

# Regenerate configs first unless explicitly skipped, so a cluster.yaml edit is
# always reflected. REGEN=0 applies whatever is already in secrets/out.
if [[ "${REGEN:-1}" != "0" ]]; then
  log "Regenerating machine configs (REGEN=0 to skip)…"
  bash "$(dirname "$0")/03-gen-config.sh"
fi

[[ -f "$OUT_DIR/controlplane.yaml" && -f "$OUT_DIR/worker.yaml" ]] \
  || die "generated configs missing - run scripts/03-gen-config.sh first"
maint="$(cfg '.timeouts.maintenanceSeconds')"; maint="${maint:-600}"

# Endpoint for the authenticated API (VIP/LB when set, else first control plane).
ep="$(cp_endpoint)"; [[ -n "$ep" ]] || die "could not determine an API endpoint"
talosctl config endpoint "$ep"

# Optional NODES filter: a space-separated allow-list of IPs to (re)configure.
declare -A only=()
if [[ -n "${NODES:-}" ]]; then
  for n in $NODES; do only["$n"]=1; done
fi

apply_node() {
  local ip="$1" file="$2" role="$3"
  if [[ ${#only[@]} -gt 0 && -z "${only[$ip]:-}" ]]; then
    log "Skipping ${role} $ip (not in NODES filter)"; return
  fi

  # Probe the AUTHENTICATED API with a short timeout. If it answers, the node is
  # already running → apply live (no maintenance wait, no forced reboot).
  if timeout 5 talosctl -n "$ip" version --short >/dev/null 2>&1; then
    log "Applying ${role} config → $ip (running node, authenticated, mode=auto)"
    talosctl apply-config --nodes "$ip" --file "$file"
    return
  fi

  # Otherwise treat it as a fresh node: wait for its maintenance API, apply insecure.
  log "$ip not reachable on the secure API - treating as a new node"
  wait_for "node $ip (maintenance API)" "$maint" "talosctl -n $ip get disks --insecure >/dev/null 2>&1"
  log "Applying ${role} config → $ip (new node, insecure)"
  talosctl apply-config --insecure --nodes "$ip" --file "$file"
}

# Control planes first, then workers - one node at a time, so a bad change can't
# take out more than one at once.
while IFS=';' read -r ip host vmid mac; do
  [[ -z "$ip" ]] && continue
  apply_node "$ip" "$OUT_DIR/controlplane.yaml" "control-plane"
done < <(control_planes)

while IFS=';' read -r ip host vmid mac; do
  [[ -z "$ip" ]] && continue
  apply_node "$ip" "$OUT_DIR/worker.yaml" "worker"
done < <(workers)

log "Reconfig complete. Verify a node's resolvers with:"
log "  talosctl -n <node-ip> get resolvers"

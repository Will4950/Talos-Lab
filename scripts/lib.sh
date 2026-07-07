#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# lib.sh - shared helpers and config access.
# Sourced by every scripts/*.sh and by ../bootstrap.sh. Not run directly.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

# --- locate repo + config -------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
CONFIG="${CONFIG:-$REPO_ROOT/secrets/cluster.yaml}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/secrets/out}"

# --- logging --------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# --- config access (yq - works with mikefarah v4 or the jq-based yq) ------
require_cmd yq
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG
  copy the template first:  mkdir -p secrets && cp cluster.example.yaml secrets/cluster.yaml"

# cfg '<yq path>' → the value, or "" if null/missing.
# Note: yq's // treats false as empty, which is fine here - booleans are only
# ever compared against "true", so a false value reads as not-true.
cfg() { yq -r "($1) // \"\"" "$CONFIG"; }

# Node lists as  ip;host;vmid;mac  lines.
control_planes() { yq -r '.nodes.controlPlanes[]? | [.ip, .host, (.vmid // "" | tostring), (.mac // "")] | join(";")' "$CONFIG"; }
workers()        { yq -r '.nodes.workers[]?       | [.ip, .host, (.vmid // "" | tostring), (.mac // "")] | join(";")' "$CONFIG"; }
all_nodes()      { control_planes; workers; }
host_ssh()       { yq -r ".proxmox.hosts[]? | select(.name == \"$1\") | .ssh // \"\"" "$CONFIG"; }
# Hosts excluded from Longhorn storage (one name per line).
longhorn_excluded_hosts() { yq -r '.longhorn.excludeHosts[]?' "$CONFIG"; }
# True if the given Proxmox host is in longhorn.excludeHosts.
host_longhorn_excluded()  { longhorn_excluded_hosts | grep -qxF "$1"; }
# Proxmox hosts as  name;ssh  lines.
proxmox_hosts()  { yq -r '.proxmox.hosts[]? | [.name, (.ssh // "")] | join(";")' "$CONFIG"; }

# Resolve a node's  cores;memory;diskGB , honoring:
#   per-node override (nodes[*].cores/memory/diskGB)
#     -> per-role default (proxmox.vm.controlPlane|worker.cores/memory)
#       -> legacy global (proxmox.vm.cores/memory) -> hard default
# Usage: node_resources cp|wk <ip>
node_resources() {
  local role="$1" ip="$2" sel vk dc dm dd line oc om od
  if [[ "$role" == "cp" ]]; then sel='.nodes.controlPlanes[]?'; vk='controlPlane'
  else                          sel='.nodes.workers[]?';       vk='worker'; fi
  dc="$(yq -r "(.proxmox.vm.${vk}.cores)  // (.proxmox.vm.cores)  // \"\"" "$CONFIG")"; [[ -z "$dc" ]] && dc=2
  dm="$(yq -r "(.proxmox.vm.${vk}.memory) // (.proxmox.vm.memory) // \"\"" "$CONFIG")"; [[ -z "$dm" ]] && dm=4096
  dd="$(yq -r "(.proxmox.vm.diskGB) // \"\"" "$CONFIG")"; [[ -z "$dd" ]] && dd=40
  line="$(yq -r "$sel | select(.ip == \"$ip\") | [(.cores // \"\" | tostring),(.memory // \"\" | tostring),(.diskGB // \"\" | tostring)] | join(\";\")" "$CONFIG")"
  IFS=';' read -r oc om od <<<"$line"
  printf '%s;%s;%s\n' "${oc:-$dc}" "${om:-$dm}" "${od:-$dd}"
}

# Resolve a node's Longhorn data-disk size (GiB), honoring:
#   per-node override (nodes[*].dataDiskGB)
#     -> global (longhorn.dedicatedDisk.sizeGB) -> hard default 100
# This lets hosts with a smaller Proxmox thin pool carry a smaller data disk so
# the pool is not overcommitted (sum of thin volumes > pool size risks fs
# corruption for every VM on that pool when it fills).
# Usage: node_data_disk_gb cp|wk <ip>
node_data_disk_gb() {
  local role="$1" ip="$2" sel dd od
  if [[ "$role" == "cp" ]]; then sel='.nodes.controlPlanes[]?'
  else                          sel='.nodes.workers[]?'; fi
  dd="$(cfg '.longhorn.dedicatedDisk.sizeGB')"; [[ -z "$dd" ]] && dd=100
  od="$(yq -r "$sel | select(.ip == \"$ip\") | (.dataDiskGB // \"\" | tostring)" "$CONFIG")"
  printf '%s\n' "${od:-$dd}"
}

# --- derived paths + values ----------------------------------------------
mkdir -p "$OUT_DIR"
export TALOSCONFIG="$OUT_DIR/talosconfig"
export KUBECONFIG="$OUT_DIR/kubeconfig"

first_cp_ip() { control_planes | head -n1 | cut -d';' -f1; }

# endpoint_mode: talos-vip | none  (default: none, or talos-vip
# if only the controlPlaneVIP key is set).
endpoint_mode() {
  local m; m="$(cfg '.network.endpointMode')"
  if [[ -n "$m" ]]; then printf '%s' "$m"; return; fi
  [[ -n "$(cfg '.network.controlPlaneVIP')" ]] && { printf 'talos-vip'; return; }
  printf 'none'
}

# api_endpoint: the stable API address (LB frontend or VIP)
api_endpoint() {
  local e; e="$(cfg '.network.apiEndpoint')"
  [[ -z "$e" ]] && e="$(cfg '.network.controlPlaneVIP')"
  printf '%s' "$e"
}

# cp_endpoint: the host used in the API URL. In talos-vip mode it is the
# apiEndpoint (when set); otherwise (or in 'none' mode) it is the first CP's IP.
cp_endpoint() {
  local mode ep; mode="$(endpoint_mode)"; ep="$(api_endpoint)"
  [[ "$mode" == "talos-vip" && -n "$ep" ]] && { printf '%s' "$ep"; return; }
  first_cp_ip
}

# Schematic id is written by 01-schematic.sh and reused by later phases.
schematic_id() {
  if [[ -n "${SCHEMATIC_ID:-}" ]]; then printf '%s' "$SCHEMATIC_ID"; return; fi
  [[ -f "$OUT_DIR/schematic-id.txt" ]] && cat "$OUT_DIR/schematic-id.txt" || true
}

# register_private_repo - ensure the app-of-apps Git repo is registered with
# Argo CD as a repository secret. Idempotent (kubectl apply). Needed before any
# Application that resolves Helm values from git via `$values` (e.g. longhorn,
# pihole). Reads argocd.appOfApps.{repoURL,sshKeyFile,pat}. No-op + return 1 if
# app-of-apps isn't enabled or no credential is set, so callers can skip cleanly.
register_private_repo() {
  [[ "$(cfg '.argocd.appOfApps.enabled')" == "true" ]] || { warn "app-of-apps not enabled - skipping repo registration"; return 1; }
  local repo keyfile pat
  repo="$(cfg '.argocd.appOfApps.repoURL')"; [[ -n "$repo" ]] || die "set argocd.appOfApps.repoURL"
  keyfile="$(cfg '.argocd.appOfApps.sshKeyFile')"; keyfile="${keyfile/#\~/$HOME}"
  pat="$(cfg '.argocd.appOfApps.pat')"

  log "Registering private repo ${repo}"
  if [[ -n "$keyfile" ]]; then
    [[ -f "$keyfile" ]] || die "sshKeyFile not found: $keyfile"
    kubectl create secret generic private-repo -n argocd \
      --from-literal=type=git --from-literal=url="$repo" \
      --from-file=sshPrivateKey="$keyfile" --dry-run=client -o yaml \
      | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
      | kubectl apply -f -
  elif [[ -n "$pat" ]]; then
    kubectl create secret generic private-repo -n argocd \
      --from-literal=type=git --from-literal=url="$repo" \
      --from-literal=username=git --from-literal=password="$pat" --dry-run=client -o yaml \
      | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
      | kubectl apply -f -
  else
    die "provide argocd.appOfApps.sshKeyFile (SSH deploy key) or .pat (token)"
  fi
}

# wait_for "description" <timeout-seconds> "<shell test command>"
wait_for() {
  local desc="$1" timeout="$2" cmd="$3" elapsed=0 interval=10
  log "Waiting for: ${desc} (up to ${timeout}s)"
  until eval "$cmd"; do
    sleep "$interval"; elapsed=$((elapsed + interval))
    (( elapsed >= timeout )) && die "timed out waiting for ${desc}"
    printf '.'
  done
  printf ' ready\n'
}

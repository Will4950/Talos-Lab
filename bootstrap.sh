#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# bootstrap.sh - orchestrator. Runs the functional scripts in scripts/ in order.
#
#   ./bootstrap.sh                 run the whole pipeline
#   ./bootstrap.sh metallb         run a single phase
#   ./bootstrap.sh apply kubeconfig    run a few, in the given order
#
# Each phase maps to a script in scripts/. They're independent and idempotent-ish,
# so you can also invoke any of them directly: bash scripts/07-metallb.sh
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/scripts/lib.sh"

phase_script() {
  case "$1" in
    dhcp)       echo scripts/00-dhcp-opnsense.sh ;;
    schematic)  echo scripts/01-schematic.sh ;;
    provision)  echo scripts/02-provision-vms.sh ;;
    config)     echo scripts/03-gen-config.sh ;;
    apply)      echo scripts/04-apply-config.sh ;;
    bootstrap)  echo scripts/05-bootstrap.sh ;;
    kubeconfig) echo scripts/06-kubeconfig.sh ;;
    metallb)    echo scripts/07-metallb.sh ;;
    argocd)     echo scripts/08-argocd.sh ;;
    longhorn)   echo scripts/09-longhorn.sh ;;
    sealed-secrets) echo scripts/10-sealed-secrets.sh ;;
    apps)       echo scripts/11-apps.sh ;;
    reconfig)   echo scripts/12-reconfig.sh ;;
    update)     echo scripts/98-update.sh ;;
    deprovision) echo scripts/90-deprovision-vms.sh ;;
    info)       echo scripts/99-info.sh ;;
    *)          die "unknown phase: $1" ;;
  esac
}

ALL=(schematic dhcp config apply bootstrap kubeconfig metallb argocd longhorn sealed-secrets apps info)
[[ "$(cfg '.proxmox.provisionVMs')" == "true" ]] \
  && ALL=(schematic dhcp provision config apply bootstrap kubeconfig metallb argocd longhorn sealed-secrets apps info)

if (( $# > 0 )); then PHASES=("$@"); else PHASES=("${ALL[@]}"); fi

log "Phases: ${PHASES[*]}"
for p in "${PHASES[@]}"; do
  s="$(phase_script "$p")"
  log "──────── ${p}  (${s})"
  bash "$HERE/$s"
done
log "All done."

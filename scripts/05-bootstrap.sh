#!/usr/bin/env bash
# Bootstrap etcd on the first control-plane node. Run exactly once per cluster;
# safe to re-run (it detects an already-bootstrapped cluster and continues).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd talosctl

cp1="$(first_cp_ip)"; [[ -n "$cp1" ]] || die "no control-plane nodes in config"
talosctl config endpoint "$cp1"
talosctl config node "$cp1"

log "Bootstrapping etcd on $cp1 (retries while the node finishes installing)…"
tries=0
until talosctl bootstrap --nodes "$cp1" 2>"$OUT_DIR/bootstrap.err"; do
  if grep -qiE "already|AlreadyExists" "$OUT_DIR/bootstrap.err"; then
    log "Already bootstrapped - continuing"; break
  fi
  tries=$((tries + 1)); (( tries > 40 )) && die "bootstrap failed: $(cat "$OUT_DIR/bootstrap.err")"
  sleep 15; printf '.'
done
printf '\n'
log "etcd bootstrapped."
log "Bootstrap runs ONCE per cluster. The other control-plane nodes will log 'etcd is waiting to join … run talosctl bootstrap' - that is NORMAL; they join on their own in a few minutes. Do NOT run bootstrap on them (it creates a second etcd and neither can form a quorum)."

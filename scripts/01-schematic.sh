#!/usr/bin/env bash
# Create the Talos Image Factory schematic (bakes in the extensions Longhorn and
# the guest agent need), and save its id for the later phases.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd curl; require_cmd jq

existing="$(schematic_id)"
if [[ -n "$existing" ]]; then
  log "Schematic already created: $existing"
  exit 0
fi

log "Creating Talos Image Factory schematic (qemu-guest-agent + iscsi-tools + util-linux-tools + serial console)"
cat > "$OUT_DIR/schematic.yaml" <<'YAML'
customization:
  extraKernelArgs:
    - console=tty0
    - console=ttyS0,115200n8
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
YAML

id="$(curl -fsSL -X POST -H 'Content-Type: application/yaml' \
  --data-binary @"$OUT_DIR/schematic.yaml" https://factory.talos.dev/schematics | jq -r '.id')"
[[ -n "$id" && "$id" != "null" ]] || die "failed to create schematic"
echo "$id" > "$OUT_DIR/schematic-id.txt"

talos="$(cfg '.versions.talos')"
log "SCHEMATIC_ID = $id"
log "Installer    = factory.talos.dev/installer/${id}:${talos}"
log "ISO          = https://factory.talos.dev/image/${id}/${talos}/metal-amd64.iso"

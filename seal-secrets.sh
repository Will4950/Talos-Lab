#!/bin/bash
# Seal all secrets from secrets/ directory into manifests/

set -e

if ! command -v kubeseal &> /dev/null; then
    echo "Error: kubeseal not found. Install it first."
    exit 1
fi

echo "Sealing secrets..."

# Pi-hole password
if [ -f secrets/pihole-secret.yaml ]; then
    echo "Sealing pihole-password..."
    kubeseal -f secrets/pihole-secret.yaml -w manifests/pihole/sealed-secret.yaml
    echo "manifests/pihole/sealed-secret.yaml"
fi

echo ""
echo "Done! Sealed secrets are ready to commit."

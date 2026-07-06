#!/usr/bin/env bash
# 98-update.sh - bump every component to latest, roll Talos node-by-node, re-apply
# cluster services, and hard-refresh every Argo CD Application. MANUAL phase: not
# in bootstrap.sh's default ALL pipeline because it reboots every node in sequence.
#
#   ./bootstrap.sh update              # interactive confirm
#   bash scripts/98-update.sh --yes    # skip confirm (bootstrap.sh doesn't forward args)
#   PIN_ARGOCD=1 ./bootstrap.sh update # pin .versions.argocd to the latest tag (default: leave as "stable")
#   GITHUB_TOKEN=... ./bootstrap.sh update
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_cmd kubectl
require_cmd talosctl
require_cmd yq
require_cmd curl
require_cmd jq

YES=0
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    *) die "unknown arg: $a" ;;
  esac
done

# --- yq detection ---------------------------------------------------------
# lib.sh already accepts either yq. Detect once so we know how to WRITE.
YQ_MIKEFARAH=0
if yq --version 2>&1 | grep -qi mikefarah; then YQ_MIKEFARAH=1; fi

yq_write() {
  # $1 = expression, $2 = file
  local expr="$1" file="$2"
  if (( YQ_MIKEFARAH )); then
    yq -i "$expr" "$file"
  else
    local tmp; tmp="$(mktemp)"
    yq -y "$expr" "$file" > "$tmp"
    mv "$tmp" "$file"
  fi
}

# Discover every Helm-chart source declared in apps/*.yaml 
# Emits one line per chart source:  appfile;chart;repoURL;currentRev
# Handles both the multi-source (.spec.sources[]) and singleton (.spec.source)
# shapes; path-only apps (no .chart) yield nothing.
chart_apps() {
  local f
  for f in "$REPO_ROOT"/apps/*.yaml; do
    [[ -e "$f" ]] || continue
    yq -r --arg f "${f#"$REPO_ROOT"/}" '
      [ (.spec.sources[]?), (.spec.source // empty) ]
      | .[] | select((.chart != null) and (.repoURL != null))
      | [$f, .chart, .repoURL, (.targetRevision // "")] | join(";")
    ' "$f" 2>/dev/null || true
  done
}

# Read a Helm chart's targetRevision in an apps/*.yaml.
# $1 = apps file (repo-relative), $2 = chart name.
chart_rev() {
  yq -r ".spec.sources[]? | select(.chart == \"$2\") | .targetRevision" \
    "$REPO_ROOT/$1" 2>/dev/null || true
}

bump_chart_rev() {
  # $1 = apps file (repo-relative), $2 = chart name, $3 = new version.
  # Covers both .spec.sources[] and singleton .spec.source layouts.
  local f="$REPO_ROOT/$1"
  [[ -f "$f" ]] || { warn "$1 missing - skipping $2 bump"; return 0; }
  log "Rewriting $1 ($2 chart -> $3)"
  export _CN="$2" _CV="$3"
  if (( YQ_MIKEFARAH )); then
    yq_write '
        (.spec.sources[]? | select(.chart == env(_CN)) | .targetRevision) = env(_CV)
      | (.spec.source | select(.chart == env(_CN)) | .targetRevision) = env(_CV)
    ' "$f"
  else
    yq_write '
        (.spec.sources[]? | select(.chart == env._CN) | .targetRevision) = env._CV
      | (if (.spec.source? != null) and (.spec.source.chart == env._CN)
           then .spec.source.targetRevision = env._CV else . end)
    ' "$f"
  fi
}

# --- confirm --------------------------------------------------------------
confirm() {
  (( YES )) && return 0
  cat <<MSG

WARNING: 'update' will…
  · overwrite secrets/cluster.yaml + any configured apps/*.yaml files
    with latest versions (comments WILL NOT SURVIVE unless yq is mikefarah v4)
  · run 'talosctl upgrade' on every node, one at a time - each node reboots
  · re-run the MetalLB / Argo CD / Sealed Secrets installers
  · hard-refresh every Argo CD Application and restart all deployments using :latest images

Review the diff before committing. Type 'yes' to continue.
MSG
  read -r -p "> " reply
  [[ "$reply" == "yes" ]] || die "aborted."
}

# --- version discovery ----------------------------------------------------
GH_HEADERS=(-H 'Accept: application/vnd.github+json')
[[ -n "${GITHUB_TOKEN:-}" ]] && GH_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# All lookups warn + return 1 (never die) so a rate-limit / missing index skips
# just that component - the rest of the update still runs.
gh_latest_tag() {
  local owner="$1" repo="$2" tag
  tag="$(curl -fsSL "${GH_HEADERS[@]}" "https://api.github.com/repos/${owner}/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')" || true
  [[ -n "$tag" ]] || { warn "could not resolve latest release for ${owner}/${repo} (rate-limited? set GITHUB_TOKEN) - skipping"; return 1; }
  printf '%s' "$tag"
}

# Latest vX.Y.Z app tag from the tags API. Needed for repos whose
# /releases/latest points at something else - e.g. metallb, where it returns the
# Helm chart release ("metallb-chart-0.16.1") and the app tags have no release
# object at all. Filtered to plain semver so pre-releases/chart tags are ignored.
gh_latest_semver_tag() {
  local owner="$1" repo="$2" tag
  tag="$(curl -fsSL "${GH_HEADERS[@]}" "https://api.github.com/repos/${owner}/${repo}/tags?per_page=100" 2>/dev/null \
          | jq -r '.[].name' \
          | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)" || true
  [[ -n "$tag" ]] || { warn "could not resolve latest semver tag for ${owner}/${repo} - skipping"; return 1; }
  printf '%s' "$tag"
}

helm_chart_latest() {
  # index.yaml entries are pre-sorted newest-first by semver; take [0]. Do NOT
  # re-sort in the shell - some repos (csi-driver-nfs) mix v-prefixed and bare
  # tags, which breaks sort -V. Skip pre-releases (versions containing "-").
  local index_url="$1" chart="$2" ver
  ver="$(curl -fsSL "${index_url%/}/index.yaml" 2>/dev/null \
          | yq -r "[.entries.\"${chart}\"[]? | select((.version | test(\"-\")) | not) | .version][0] // empty")" || true
  [[ -n "$ver" ]] || { warn "could not resolve latest chart version for ${chart} from ${index_url} - skipping"; return 1; }
  printf '%s' "$ver"
}

# Core-component targets. Left "" when a lookup is skipped or the service is
# disabled, so the conditional writes below and `set -u` stay safe.
TALOS_NEW="" ; TALOS_OLD=""
ARGOCD_NEW="" ; ARGOCD_OLD=""
METALLB_NEW="" ; METALLB_OLD=""
SEALED_NEW="" ; SEALED_OLD=""
LONGHORN_NEW="" ; LONGHORN_OLD=""
# Discovered Helm charts:  each entry is  appfile;chart;repoURL;oldRev;newRev
CHART_PLAN=()

fetch_versions() {
  log "Fetching latest upstream versions…"
  local v

  # Talos + Argo CD always apply (argocd stays "stable" unless PIN_ARGOCD=1).
  if v="$(gh_latest_tag siderolabs talos)"; then TALOS_NEW="$v"; fi
  if [[ "${PIN_ARGOCD:-0}" == "1" ]]; then
    if v="$(gh_latest_tag argoproj argo-cd)"; then ARGOCD_NEW="$v"; fi
  else
    ARGOCD_NEW="stable"
  fi
  # MetalLB - only if enabled. Uses the tags API (its /releases/latest is the
  # chart release, not the app tag).
  if [[ "$(cfg '.metallb.enabled')" == "true" ]]; then
    if v="$(gh_latest_semver_tag metallb metallb)"; then METALLB_NEW="$v"; fi
  fi
  # Sealed Secrets - only if enabled. cluster.yaml stores the version without v.
  if [[ "$(cfg '.sealedSecrets.enabled')" == "true" ]]; then
    if v="$(gh_latest_tag bitnami-labs sealed-secrets)"; then SEALED_NEW="${v#v}"; fi
  fi

  TALOS_OLD="$(cfg '.versions.talos')"
  ARGOCD_OLD="$(cfg '.versions.argocd')"
  METALLB_OLD="$(cfg '.versions.metallb')"
  SEALED_OLD="$(cfg '.sealedSecrets.version')"
  LONGHORN_OLD="$(cfg '.versions.longhorn')"

  # Helm charts, discovered from apps/*.yaml rather than hardcoded.
  local appfile chart repoURL oldrev newrev
  while IFS=';' read -r appfile chart repoURL oldrev; do
    [[ -n "$chart" ]] || continue
    if newrev="$(helm_chart_latest "$repoURL" "$chart")"; then
      CHART_PLAN+=("$appfile;$chart;$repoURL;$oldrev;$newrev")
      # Keep .versions.longhorn (read by 09-longhorn.sh for logging/validation)
      # in sync with the chart it deploys.
      [[ "$chart" == "longhorn" ]] && LONGHORN_NEW="$newrev"
    fi
  done < <(chart_apps)
}

print_plan() {
  log "Version plan:"
  [[ -n "$TALOS_NEW"    ]] && printf '  %-16s %-14s -> %s\n' talos          "${TALOS_OLD:-<unset>}"    "$TALOS_NEW"
  [[ -n "$ARGOCD_NEW"   ]] && printf '  %-16s %-14s -> %s\n' argocd         "${ARGOCD_OLD:-<unset>}"   "$ARGOCD_NEW"
  [[ -n "$METALLB_NEW"  ]] && printf '  %-16s %-14s -> %s\n' metallb        "${METALLB_OLD:-<unset>}"  "$METALLB_NEW"
  [[ -n "$SEALED_NEW"   ]] && printf '  %-16s %-14s -> %s\n' sealed-secrets "${SEALED_OLD:-<unset>}"   "$SEALED_NEW"
  local row appfile chart repoURL oldrev newrev
  for row in "${CHART_PLAN[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS=';' read -r appfile chart repoURL oldrev newrev <<<"$row"
    printf '  %-16s %-14s -> %s  (%s)\n' "$chart" "${oldrev:-<unset>}" "$newrev" "$appfile"
  done
}

# --- YAML rewrites --------------------------------------------------------
bump_cluster_yaml() {
  log "Rewriting $CONFIG"
  export TALOS_NEW ARGOCD_NEW LONGHORN_NEW METALLB_NEW SEALED_NEW
  # Only assign keys that were resolved (env var != ""), and gate metallb /
  # sealed-secrets on their enable flags.
  if (( YQ_MIKEFARAH )); then
    yq_write '
        (with(select(env(TALOS_NEW)    != ""); .versions.talos      = env(TALOS_NEW)))
      | (with(select(env(ARGOCD_NEW)   != ""); .versions.argocd     = env(ARGOCD_NEW)))
      | (with(select(env(LONGHORN_NEW) != ""); .versions.longhorn   = env(LONGHORN_NEW)))
      | (with(select(.metallb.enabled == true and env(METALLB_NEW)      != ""); .versions.metallb      = env(METALLB_NEW)))
      | (with(select(.sealedSecrets.enabled == true and env(SEALED_NEW) != ""); .sealedSecrets.version = env(SEALED_NEW)))
    ' "$CONFIG"
  else
    yq_write '
        (if env.TALOS_NEW    != "" then .versions.talos    = env.TALOS_NEW    else . end)
      | (if env.ARGOCD_NEW   != "" then .versions.argocd   = env.ARGOCD_NEW   else . end)
      | (if env.LONGHORN_NEW != "" then .versions.longhorn = env.LONGHORN_NEW else . end)
      | (if (.metallb.enabled == true)       and env.METALLB_NEW != "" then .versions.metallb      = env.METALLB_NEW else . end)
      | (if (.sealedSecrets.enabled == true) and env.SEALED_NEW  != "" then .sealedSecrets.version = env.SEALED_NEW  else . end)
    ' "$CONFIG"
  fi
}

bump_chart_yamls() {
  # Bump every discovered chart source (CHART_PLAN built by fetch_versions).
  local row appfile chart repoURL oldrev newrev
  for row in "${CHART_PLAN[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS=';' read -r appfile chart repoURL oldrev newrev <<<"$row"
    bump_chart_rev "$appfile" "$chart" "$newrev"
  done
}

# --- Talos upgrade --------------------------------------------------------
upgrade_talos_nodes() {
  [[ -n "$TALOS_NEW" ]] || { warn "Talos version not resolved - skipping node upgrades"; return 0; }
  local sid; sid="$(schematic_id)"
  [[ -n "$sid" ]] || die "no schematic id at $OUT_DIR/schematic-id.txt - run scripts/01-schematic.sh first"
  local installer="factory.talos.dev/installer/${sid}:${TALOS_NEW}"
  local ep; ep="$(cp_endpoint)"; [[ -n "$ep" ]] || die "no control-plane endpoint"
  talosctl config endpoint "$ep"

  upgrade_one() {
    local ip="$1" host="$2"
    log "Upgrading Talos on ${host} (${ip}) -> ${TALOS_NEW}"
    talosctl -n "$ip" upgrade --preserve --wait --image "$installer"
    wait_for "$host Ready after upgrade" 900 \
      "kubectl get node $host -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q '^True$'"
  }

  while IFS=';' read -r ip host _ _; do [[ -n "$ip" ]] && upgrade_one "$ip" "$host"; done < <(control_planes)
  while IFS=';' read -r ip host _ _; do [[ -n "$ip" ]] && upgrade_one "$ip" "$host"; done < <(workers)

  local ht; ht="$(cfg '.timeouts.health')"; ht="${ht:-10m}"
  talosctl health --wait-timeout "$ht" || warn "post-upgrade cluster health reported issues"
}

upgrade_kubernetes() {
  local k8s; k8s="$(cfg '.versions.kubernetes')"
  if [[ -z "$k8s" ]]; then
    log "versions.kubernetes is blank - skipping upgrade-k8s (Talos ships the bundled k8s)"
    return 0
  fi
  local cp1; cp1="$(first_cp_ip)"
  log "Upgrading Kubernetes -> ${k8s}"
  talosctl -n "$cp1" upgrade-k8s --to "$k8s"
}Longhorn
# (09-longhorn.sh) is deliberately EXCLUDED: it's Argo-managed via apps/longhorn.yaml,
# and running it would `kubectl apply` the locally-bumped file into the cluster
# before the git commit - the app-of-apps root (tracking main + selfHeal) would then
# revert it, causing a version flip-flop. Instead the longhorn bump flows through git
# like every other chart: commit + push, and Argo syncs it. See bump_chart_yamls.

# --- Re-apply cluster services (idempotent) -------------------------------
# Only the imperatively-installed services are re-applied here.
reapply_cluster_services() {
  for s in 07-metallb.sh 08-argocd.sh 10-sealed-secrets.sh; do
    log "Re-applying scripts/${s}"
    bash "$REPO_ROOT/scripts/$s"
  done
}

# --- Argo CD refresh ------------------------------------------------------
refresh_argocd_apps() {
  log "Hard-refreshing every Argo CD Application"
  local apps
  apps="$(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null || true)"
  if [[ -n "$apps" ]]; then
    while IFS= read -r a; do
      [[ -n "$a" ]] && kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    done <<<"$apps"
  else
    warn "no Argo CD Applications found"
  fi

  log "Discovering :latest deployments to restart"
  # Auto-discover all deployments with :latest images across all namespaces
  local latest_deploys
  latest_deploys="$(kubectl get deploy -A -o json 2>/dev/null | \
    jq -r '.items[] |
      select(.spec.template.spec.containers[]?.image | test(":latest$")) |
      "\(.metadata.namespace);\(.metadata.name)"' 2>/dev/null || true)"

  if [[ -z "$latest_deploys" ]]; then
    log "No :latest deployments found - skipping restart"
    return 0
  fi

  log "Restarting :latest deployments so Argo re-pulls image tags"
  while IFS=';' read -r ns dep; do
    [[ -n "$ns" ]] || continue
    kubectl -n "$ns" rollout restart "deploy/$dep" 2>/dev/null || warn "$ns/$dep not present"
  done <<<"$latest_deploys"

  while IFS=';' read -r ns dep; do
    [[ -n "$ns" ]] || continue
    kubectl -n "$ns" rollout status "deploy/$dep" --timeout=300s 2>/dev/null || true
  done <<<"$latest_deploys"
}

# --- Verification snapshot ------------------------------------------------
verify() {
  log "Post-update snapshot:"
  kubectl get nodes -o wide || true
  echo
  kubectl -n argocd get applications.argoproj.io || true
  echo
  printf 'argocd-server         : '; kubectl -n argocd         get deploy argocd-server             -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || echo '?'
  printf 'longhorn-manager      : '; kubectl -n longhorn-system get ds     longhorn-manager          -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || echo '?'
  printf 'metallb controller    : '; kubectl -n metallb-system  get deploy controller                -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || echo '?'
  printf 'sealed-secrets ctrl   : '; kubectl -n kube-system     get deploy sealed-secrets-controller -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || echo '?'
}

# --- Driver ---------------------------------------------------------------
confirm
fetch_versions
print_plan
bump_cluster_yaml
bump_chart_yamls
upgrade_talos_nodes
upgrade_kubernetes
reapply_cluster_services
refresh_argocd_apps
verify
log "Update complete. Review 'git diff secrets/cluster.yaml apps/' and commit."

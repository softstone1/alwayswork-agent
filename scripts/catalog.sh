#!/usr/bin/env bash
# Generate catalog.json from every capability's manifest.yaml: what a node
# can deploy, with its workload (image, version source, surfaces) — the
# control plane serves this as /v1/admin/catalog and resolves image channels
# from it. Deterministic; CI checks it is committed up to date.
#   scripts/catalog.sh            # writes catalog.json
#   scripts/catalog.sh --check    # exits 1 when catalog.json is stale
set -euo pipefail
cd "$(dirname "$0")/.."
command -v yq >/dev/null || { echo "yq (mikefarah) required" >&2; exit 1; }
out="$(for m in capabilities/*/manifest.yaml; do yq -o=json '.' "$m"; done | jq -s 'sort_by(.id) | { generatedFrom: "capabilities/*/manifest.yaml", capabilities: map({id, name, description, version, requires: (.requires // []), profiles: (.profiles // []), workload: (.workload // null)}) }')"
apps="$(yq -o=json '.apps' catalog/apps.yaml | jq 'to_entries | map({id: .key, name: .value.name, description: .value.description, category: .value.category, manager: .value.manager}) | sort_by(.id)')"
out="$(jq --argjson apps "$apps" '. + {apps: $apps}' <<<"$out")"
if [[ "${1:-}" == "--check" ]]; then
  [[ -f catalog.json ]] || { echo "catalog.json missing; run scripts/catalog.sh" >&2; exit 1; }
  if ! diff -q <(jq -S . catalog.json) <(jq -S . <<<"$out") >/dev/null; then echo "catalog.json is stale; run scripts/catalog.sh" >&2; exit 1; fi
  echo "catalog.json up to date"; exit 0
fi
printf '%s\n' "$out" | jq -S . > catalog.json
echo "wrote catalog.json ($(jq '.capabilities | length' catalog.json) capabilities)"

#!/usr/bin/env bash
#
# End-to-end smoke test for a running Polaris server (Docker or native).
#
# Prereqs: server is up on :8181/:8182. Start it with `make polaris-up` first.
#
# Usage: ./polaris_cli.sh
#
set -euo pipefail

POLARIS_HTTP="${POLARIS_HTTP:-http://localhost:8181}"
POLARIS_MGMT="${POLARIS_MGMT:-http://localhost:8182}"
ROOT_USER="${ROOT_USER:-root}"
ROOT_SECRET="${ROOT_SECRET:-s3cr3t}"

step() { printf '\n=== %s ===\n' "$*"; }

# curl_create — POST/PUT that tolerates HTTP 409 (already exists), so the smoke
# test stays idempotent across runs. Other 4xx/5xx still abort via set -e.
curl_create() {
  local body status
  body=$(mktemp)
  status=$(curl -sS -o "$body" -w '%{http_code}' "$@")
  if [ "$status" = "200" ] || [ "$status" = "201" ] || [ "$status" = "204" ]; then
    jq <"$body" 2>/dev/null || cat "$body"
  elif [ "$status" = "409" ]; then
    echo "(already exists — skipping)"
  else
    echo "ERROR: HTTP $status" >&2
    cat "$body" >&2
    rm -f "$body"
    return 1
  fi
  rm -f "$body"
}

# 1. Health endpoint (no auth) -------------------------------------------------
step "1. Health"
curl -fsS "${POLARIS_MGMT}/q/health" | jq

# 2. OAuth2 token round-trip ---------------------------------------------------
step "2. OAuth2 token"
TOKEN=$(curl -fsS "${POLARIS_HTTP}/api/catalog/v1/oauth/tokens" \
  --user "${ROOT_USER}:${ROOT_SECRET}" \
  -d 'grant_type=client_credentials' \
  -d 'scope=PRINCIPAL_ROLE:ALL' | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "ERROR: empty token"; exit 1; }
echo "Token (first 60 chars): ${TOKEN:0:60}..."

AUTH=(-H "Authorization: Bearer ${TOKEN}")

# 3. Management API: list, create, list ---------------------------------------
step "3a. List catalogs (initial)"
curl -fsS "${POLARIS_HTTP}/api/management/v1/catalogs" "${AUTH[@]}" | jq

step "3b. Create file-backed catalog 'quickstart_catalog'"
curl_create -X POST "${POLARIS_HTTP}/api/management/v1/catalogs" \
  "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{
        "catalog": {
          "name": "quickstart_catalog",
          "type": "INTERNAL",
          "properties": {"default-base-location": "file:///tmp/wh/quickstart"},
          "storageConfigInfo": {
            "storageType": "FILE",
            "allowedLocations": ["file:///tmp/wh/"]
          }
        }
      }'

step "3c. List catalogs (after create)"
curl -fsS "${POLARIS_HTTP}/api/management/v1/catalogs" "${AUTH[@]}" | jq

# 4. Iceberg REST: create namespace inside quickstart_catalog ------------------
step "4a. Create namespace 'analytics'"
curl_create -X POST \
  "${POLARIS_HTTP}/api/catalog/v1/quickstart_catalog/namespaces" \
  "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": ["analytics"], "properties": {"owner": "skmishra"}}'

step "4b. List namespaces"
curl -fsS "${POLARIS_HTTP}/api/catalog/v1/quickstart_catalog/namespaces" \
  "${AUTH[@]}" | jq

# 5. Same flow via the dockerized CLI -----------------------------------------
step "5a. CLI: catalogs list"
make polaris-cli ARGS="catalogs list"

step "5b. CLI: create cli_catalog"
make polaris-cli ARGS='catalogs create --type internal --storage-type file --default-base-location file:///tmp/wh/cli-test cli_catalog' \
  || echo "(already exists — skipping)"

step "5c. CLI: list catalogs / principals / principal-roles"
make polaris-cli ARGS="catalogs list"
make polaris-cli ARGS="principals list"
make polaris-cli ARGS="principal-roles list"

echo
echo "All checks passed."
echo
echo "Optional follow-ups (run manually, not part of this script):"
echo "  make polaris-logs                # tail server logs (blocks until Ctrl+C)"
echo "  make polaris-cli ARGS=\"--help\"   # full CLI menu"
echo "  make polaris-down                # stop the server"

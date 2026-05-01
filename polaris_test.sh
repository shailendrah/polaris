#!/usr/bin/env bash
#
# Inspect the running Polaris server and emit SQLcl DEFINE lines for the
# Iceberg tables in s3_catalog.demo:
#   1. List tables in <catalog>.<namespace>
#   2. Pretty-print full Iceberg metadata for one table
#   3. Show namespace metadata
#   4. Print DEFINE <name>_meta = '<https-metadata-url>' lines ready to paste
#      into polaris_test.sql
#
# Prereq: server is up (`make polaris-up`) with the s3_catalog created and
# tables written via `python src/generate_iceberg_tables.py`.
#
# Usage: ./polaris_test.sh
#
set -euo pipefail

POLARIS_HTTP="${POLARIS_HTTP:-http://localhost:8181}"
ROOT_USER="${ROOT_USER:-root}"
ROOT_SECRET="${ROOT_SECRET:-s3cr3t}"
CATALOG="${CATALOG:-s3_catalog}"
NAMESPACE="${NAMESPACE:-demo}"
TABLE="${TABLE:-users}"
S3_REGION="${S3_REGION:-${AWS_REGION:-us-west-1}}"
TABLES="${TABLES:-users orders products}"

step() { printf '\n=== %s ===\n' "$*"; }

# Get an OAuth2 access token.
TOKEN=$(curl -fsS "${POLARIS_HTTP}/api/catalog/v1/oauth/tokens" \
  --user "${ROOT_USER}:${ROOT_SECRET}" \
  -d 'grant_type=client_credentials' \
  -d 'scope=PRINCIPAL_ROLE:ALL' | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "ERROR: empty token"; exit 1; }

AUTH=(-H "Authorization: Bearer ${TOKEN}")

# 1. List tables in <catalog>.<namespace> -----------------------------------
step "1. Tables in ${CATALOG}.${NAMESPACE}"
curl -fsS "${POLARIS_HTTP}/api/catalog/v1/${CATALOG}/namespaces/${NAMESPACE}/tables" \
  "${AUTH[@]}" | jq

# 2. Full metadata of one table --------------------------------------------
step "2. Metadata for ${CATALOG}.${NAMESPACE}.${TABLE}"
curl -fsS "${POLARIS_HTTP}/api/catalog/v1/${CATALOG}/namespaces/${NAMESPACE}/tables/${TABLE}" \
  "${AUTH[@]}" | jq '
    .metadata | {
      table_uuid,
      location,
      current_snapshot_id,
      schema: (.schemas[0].fields | map({(.name): .type}) | add),
      snapshot_count: (.snapshots | length),
      latest_snapshot: (.snapshots[-1] | {snapshot_id, timestamp_ms, summary})
    }'

# 3. Namespace metadata -----------------------------------------------------
step "3. Namespace ${CATALOG}.${NAMESPACE}"
curl -fsS "${POLARIS_HTTP}/api/catalog/v1/${CATALOG}/namespaces/${NAMESPACE}" \
  "${AUTH[@]}" | jq

# 4. DEFINE lines for polaris_test.sql --------------------------------------
# Virtual-hosted-style URLs: https://<bucket>.s3.<region>.amazonaws.com/<key>.
# Path-style fails the iceberg engine on ADW with `Invalid URL [iceberg:...]`,
# so the bucket has to be in the host.
step "4. SQLcl DEFINE lines (paste into polaris_test.sql)"
for t in ${TABLES}; do
  loc=$(curl -fsS "${POLARIS_HTTP}/api/catalog/v1/${CATALOG}/namespaces/${NAMESPACE}/tables/${t}" \
    "${AUTH[@]}" | jq -r '.["metadata-location"]')
  https=$(echo "$loc" | sed -E "s|^s3://([^/]+)/(.*)$|https://\\1.s3.${S3_REGION}.amazonaws.com/\\2|")
  printf "DEFINE %-13s = '%s'\n" "${t}_meta" "$https"
done

echo
echo "Done."

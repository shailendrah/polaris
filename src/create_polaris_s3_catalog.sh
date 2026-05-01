#!/usr/bin/env bash
#
# Idempotently create a Polaris catalog of type INTERNAL with storageType=S3,
# pointing at OCI Object Storage's S3-compatible endpoint. We continue using
# storageType=S3 (not GCS/AZURE) because OCI Object Storage exposes an
# S3-compat API. Uses --no-sts so Polaris does not vend short-lived STS
# tokens; clients supply their own OCI Customer Secret Keys.
#
# Prereqs:
#   * Polaris is running on http://localhost:8181 (`make polaris-up`).
#   * OCI_NAMESPACE, OCI_REGION, OCI_BUCKET exported in the shell.
#
set -euo pipefail

POLARIS_HTTP="${POLARIS_HTTP:-http://localhost:8181}"
ROOT_USER="${ROOT_USER:-root}"
ROOT_SECRET="${ROOT_SECRET:-s3cr3t}"

CATALOG_NAME="${CATALOG_NAME:-s3_catalog}"
: "${OCI_NAMESPACE:?OCI_NAMESPACE not set}"
: "${OCI_REGION:?OCI_REGION not set}"
: "${OCI_BUCKET:?OCI_BUCKET not set}"
S3_PREFIX="${S3_PREFIX:-polaris-iceberg}"
WAREHOUSE="s3://${OCI_BUCKET}/${S3_PREFIX}"
# vhcompat endpoint (Feb 2026 release) has a wildcard cert; lets virtual-
# hosted-style addressing work without TLS errors. Bucket must have been
# created via the S3 API (see create_oci_bucket.sh) to be eligible.
S3_ENDPOINT="https://vhcompat.objectstorage.${OCI_REGION}.oci.customer-oci.com"
# Placeholder role ARN — never actually assumed because stsEnabled=false below.
ROLE_ARN="${ROLE_ARN:-arn:aws:iam::000000000000:role/polaris-placeholder}"

TOKEN=$(curl -fsS "${POLARIS_HTTP}/api/catalog/v1/oauth/tokens" \
  --user "${ROOT_USER}:${ROOT_SECRET}" \
  -d 'grant_type=client_credentials' \
  -d 'scope=PRINCIPAL_ROLE:ALL' | jq -r .access_token)

# If the catalog already exists, we're done.
if curl -fsS "${POLARIS_HTTP}/api/management/v1/catalogs/${CATALOG_NAME}" \
     -H "Authorization: Bearer ${TOKEN}" >/dev/null 2>&1; then
  echo "Catalog '${CATALOG_NAME}' already exists. Done."
  exit 0
fi

curl -fsS -X POST "${POLARIS_HTTP}/api/management/v1/catalogs" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d @- <<EOF | jq
{
  "catalog": {
    "name": "${CATALOG_NAME}",
    "type": "INTERNAL",
    "properties": {
      "default-base-location": "${WAREHOUSE}",
      "s3.endpoint": "${S3_ENDPOINT}"
    },
    "storageConfigInfo": {
      "storageType": "S3",
      "allowedLocations": ["${WAREHOUSE}"],
      "roleArn": "${ROLE_ARN}",
      "region": "${OCI_REGION}",
      "endpoint": "${S3_ENDPOINT}",
      "stsEnabled": false
    }
  }
}
EOF

echo "Created catalog '${CATALOG_NAME}' → ${WAREHOUSE} via ${S3_ENDPOINT}."

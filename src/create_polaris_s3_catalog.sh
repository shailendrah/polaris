#!/usr/bin/env bash
#
# Idempotently create a Polaris catalog of type INTERNAL with storageType=S3,
# pointing at s3://${S3_BUCKET}/${S3_PREFIX}/. Uses --no-sts so Polaris
# does not vend short-lived STS tokens; clients supply their own AWS creds.
#
# Prereq: Polaris is running on http://localhost:8181 (`make polaris-up`).
#
set -euo pipefail

POLARIS_HTTP="${POLARIS_HTTP:-http://localhost:8181}"
ROOT_USER="${ROOT_USER:-root}"
ROOT_SECRET="${ROOT_SECRET:-s3cr3t}"

CATALOG_NAME="${CATALOG_NAME:-s3_catalog}"
S3_BUCKET="${S3_BUCKET:-skmawsbucket1}"
S3_PREFIX="${S3_PREFIX:-polaris-iceberg}"
WAREHOUSE="s3://${S3_BUCKET}/${S3_PREFIX}"
AWS_REGION="${AWS_REGION:-us-west-1}"
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
      "s3.region": "${AWS_REGION}"
    },
    "storageConfigInfo": {
      "storageType": "S3",
      "allowedLocations": ["${WAREHOUSE}"],
      "roleArn": "${ROLE_ARN}",
      "region": "${AWS_REGION}",
      "stsEnabled": false
    }
  }
}
EOF

echo "Created catalog '${CATALOG_NAME}' → ${WAREHOUSE} (region ${AWS_REGION})."

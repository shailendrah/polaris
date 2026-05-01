#!/usr/bin/env bash
#
# Create an OCI Object Storage bucket via the S3-compat API. Buckets created
# this way (rather than via OCI Console/CLI) are eligible for the new
# vhcompat endpoint, which serves a wildcard cert covering bucket subdomains
# and lets virtual-hosted-style URLs work without TLS errors.
#
set -euo pipefail

: "${OCI_NAMESPACE:?OCI_NAMESPACE not set}"
: "${OCI_REGION:?OCI_REGION not set}"
: "${OCI_ACCESS_KEY:?OCI_ACCESS_KEY not set}"
: "${OCI_SECRET_ACCESS_KEY:?OCI_SECRET_ACCESS_KEY not set}"

BUCKET="${1:-polaris-iceberg}"
ENDPOINT="https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com"

AWS_ACCESS_KEY_ID="$OCI_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$OCI_SECRET_ACCESS_KEY" AWS_REGION="$OCI_REGION" AWS_DEFAULT_REGION="$OCI_REGION" aws s3api create-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$OCI_REGION" --create-bucket-configuration "LocationConstraint=$OCI_REGION"

echo "Bucket created: $BUCKET"

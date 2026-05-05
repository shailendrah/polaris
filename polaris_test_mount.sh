#!/usr/bin/env bash
#
# Fetch a Polaris OAuth bearer token via the ngrok tunnel, then run
# polaris_test_mount.sql so ADW mounts Polaris as an iceberg-REST catalog
# (auto-refresh path — DBMS_CATALOG.MOUNT_ICEBERG, no DEFINE-line copying).
#
# Required env vars:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  — for AWS_S3_CRED on ADW
#   ADW_ADMIN_PWD                              — ADMIN password for ADW
#   ADW_CONNECT_ALIAS                          — tnsnames alias
#   NGROK_HOST                                 — host only, no scheme/path
#                                                e.g. overstate-setback-going.ngrok-free.dev
#
# Optional env vars:
#   ROOT_USER (default: root), ROOT_SECRET (default: s3cr3t)
#
# Usage: ./polaris_test_mount.sh
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?must be set}"
: "${AWS_SECRET_ACCESS_KEY:?must be set}"
: "${ADW_ADMIN_PWD:?must be set}"
: "${ADW_CONNECT_ALIAS:?must be set}"
: "${NGROK_HOST:?must be set (host only, no scheme)}"

ROOT_USER="${ROOT_USER:-root}"
ROOT_SECRET="${ROOT_SECRET:-s3cr3t}"

# Strip any accidental scheme / trailing slash from NGROK_HOST.
NGROK_HOST="${NGROK_HOST#https://}"
NGROK_HOST="${NGROK_HOST#http://}"
NGROK_HOST="${NGROK_HOST%/}"

echo ">>> Fetching Polaris OAuth token via https://${NGROK_HOST}"
TOKEN=$(curl -fsS -X POST "https://${NGROK_HOST}/api/catalog/v1/oauth/tokens" \
  --user "${ROOT_USER}:${ROOT_SECRET}" \
  -d 'grant_type=client_credentials' \
  -d 'scope=PRINCIPAL_ROLE:ALL' | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "ERROR: empty token"; exit 1; }
echo ">>> token OK (${#TOKEN} chars)"

# SQLcl's CLI parser chokes on positional args that start with '-' (JWTs can
# contain URL-safe base64 chars). Feed the @script invocation through stdin
# to bypass SQLCliOptions entirely.
echo ">>> Running polaris_test_mount.sql"
sql /nolog <<SQL
@polaris_test_mount.sql "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" "${ADW_ADMIN_PWD}" "${ADW_CONNECT_ALIAS}" "${NGROK_HOST}" "${TOKEN}"
SQL

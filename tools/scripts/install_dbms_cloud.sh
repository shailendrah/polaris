#!/usr/bin/env bash
#
# One-time install of DBMS_CLOUD into the local Oracle Database Free container.
# Uses the install scripts that already ship with the image at
# $ORACLE_HOME/rdbms/admin/ — no MOS download required.
#
# Idempotent: re-running on an installed DB is a no-op.
#
# Usage:  ./tools/scripts/install_dbms_cloud.sh [grantee]
#         (grantee defaults to 'lakehouse')
#
set -euo pipefail

CONTAINER="${ORACLE_CONTAINER:-oracle-db}"
GRANTEE="${1:-lakehouse}"

echo "--- Verifying container '${CONTAINER}' is running ---"
docker inspect -f '{{.State.Status}}' "${CONTAINER}" >/dev/null

echo "--- Installing DBMS_CLOUD as SYSDBA (this takes 30-60s) ---"
docker exec -i "${CONTAINER}" bash -c "sqlplus -s / as sysdba" <<SQL
WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
SET TERMOUT OFF

-- Run the install script in CDB\$ROOT (creates the package + synonym).
-- Errors related to OCI region tables are expected and harmless when running
-- on-prem against non-OCI storage (we use AWS S3); the DBMS_CLOUD package
-- itself still compiles successfully.
ALTER SESSION SET CONTAINER = CDB\$ROOT;
ALTER SESSION SET "_oracle_script" = TRUE;
@?/rdbms/admin/dbms_cloud_install.sql

-- Re-run inside the PDB so the package is also present there.
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET "_oracle_script" = TRUE;
@?/rdbms/admin/dbms_cloud_install.sql

SET TERMOUT ON

PROMPT
PROMPT === DBMS_CLOUD object status in FREEPDB1 ===
SET LINESIZE 120
COLUMN owner       FORMAT A20
COLUMN object_name FORMAT A20
COLUMN object_type FORMAT A15
SELECT owner, object_name, object_type, status
  FROM all_objects
 WHERE object_name = 'DBMS_CLOUD'
 ORDER BY object_type;

PROMPT
PROMPT === Granting EXECUTE on DBMS_CLOUD to ${GRANTEE} ===
WHENEVER SQLERROR EXIT FAILURE
GRANT EXECUTE ON SYS.DBMS_CLOUD TO ${GRANTEE};
EXIT;
SQL

echo
echo "--- DBMS_CLOUD install complete. ---"
echo "    Now re-run test_polaris.sql:"
echo "    sql /nolog @test_polaris.sql \"\$AWS_ACCESS_KEY_ID\" \"\$AWS_SECRET_ACCESS_KEY\""

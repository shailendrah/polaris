#!/usr/bin/env bash
#
# Provision (or reset) the POLARIS_SCHEMA user on Oracle Autonomous Data
# Warehouse (ADW) so that the Polaris server can use it as its catalog
# metastore. Connects as ADMIN over mTLS using the downloaded wallet.
#
# Idempotent: drops POLARIS_SCHEMA CASCADE if present, then recreates with the
# minimum privileges Polaris needs to bootstrap and run the schema-v4 DDL.
#
# Required environment (typically exported in ~/.zshrc):
#   TNS_ADMIN             - wallet directory (e.g. ~/.oracle/wallets/adw)
#   ADW_ADMIN_PWD         - ADMIN password
#   ADW_CONNECT_ALIAS     - tnsnames alias to use (e.g. q2jm1ek29mprcr96_tp)
#
# Optional:
#   POLARIS_SCHEMA_PWD    - password to set on POLARIS_SCHEMA
#                           (default: Polaris#2026Schema — meets ADW password rules)
#
# Usage: ./tools/scripts/setup_polaris_on_adw.sh
#
set -euo pipefail

: "${TNS_ADMIN:?Set TNS_ADMIN to the unzipped wallet directory}"
: "${ADW_ADMIN_PWD:?Set ADW_ADMIN_PWD (the ADMIN password from OCI)}"
: "${ADW_CONNECT_ALIAS:?Set ADW_CONNECT_ALIAS (a tnsnames alias from the wallet)}"
POLARIS_SCHEMA_PWD="${POLARIS_SCHEMA_PWD:-Polaris#2026Schema}"

if [ ! -f "$TNS_ADMIN/tnsnames.ora" ]; then
  echo "ERROR: $TNS_ADMIN/tnsnames.ora not found. Did you unzip the wallet?" >&2
  exit 1
fi

if ! grep -q "^${ADW_CONNECT_ALIAS}" "$TNS_ADMIN/tnsnames.ora"; then
  echo "ERROR: alias '${ADW_CONNECT_ALIAS}' not in $TNS_ADMIN/tnsnames.ora" >&2
  echo "Available aliases:" >&2
  grep -E '^[a-z0-9_]+ *=' "$TNS_ADMIN/tnsnames.ora" | awk '{print "  "$1}' >&2
  exit 1
fi

echo "--- Resetting POLARIS_SCHEMA on ${ADW_CONNECT_ALIAS} ---"
sql /nolog <<SQL
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF FEEDBACK ON VERIFY OFF

CONNECT admin/"${ADW_ADMIN_PWD}"@${ADW_CONNECT_ALIAS}

-- Drop existing POLARIS_SCHEMA (if any). Ignore ORA-01918 (user not found).
DECLARE
  e_user_missing EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_user_missing, -1918);
BEGIN
  EXECUTE IMMEDIATE 'DROP USER POLARIS_SCHEMA CASCADE';
EXCEPTION
  WHEN e_user_missing THEN NULL;
END;
/

-- Recreate with a real password (required since Polaris connects as this user)
CREATE USER POLARIS_SCHEMA IDENTIFIED BY "${POLARIS_SCHEMA_PWD}";

-- Minimum privileges to bootstrap and run schema-v4 DDL + DML.
-- Note: there is no standalone CREATE INDEX system privilege — owning a
-- table implicitly grants the right to create indexes on it, and CREATE
-- TABLE covers both. UNLIMITED TABLESPACE is required because ADW doesn't
-- assign a default quota on the user's schema.
GRANT CREATE SESSION  TO POLARIS_SCHEMA;
GRANT CREATE TABLE    TO POLARIS_SCHEMA;
GRANT UNLIMITED TABLESPACE TO POLARIS_SCHEMA;

PROMPT --- POLARIS_SCHEMA ready ---
SELECT username, account_status FROM dba_users WHERE username = 'POLARIS_SCHEMA';

EXIT;
SQL

echo
echo "--- POLARIS_SCHEMA provisioned. Next:"
echo "    1. make polaris-down && make polaris-up"
echo "    2. make polaris-logs   # watch auto-bootstrap fire schema-v4 against ADW"

-- ----------------------------------------------------------------------------
-- polaris_test.sql — direct-file path (AWS S3 only on this branch)
--
-- Provisions the LAKEHOUSE user and registers the three Iceberg tables as
-- Oracle external tables by passing each metadata.json URL directly to
-- DBMS_CLOUD.CREATE_EXTERNAL_TABLE.
--
-- IMPORTANT: This script targets the AWS S3 demo. The `oos` branch's OCI
-- demo uses polaris_test_mount.sql (DBMS_CATALOG.MOUNT_ICEBERG via Polaris)
-- which works end-to-end against rewritten avros. The direct-file path
-- doesn't yet work for OCI because the commit hook rewrites avros only —
-- not the on-disk metadata.json. When that lands, this script will need an
-- OCI variant pointing at <orig>.oci.metadata.json siblings.
--
-- Provisions the LAKEHOUSE user and registers the three Iceberg tables in
-- s3://skmawsbucket1/polaris-iceberg/ as Oracle external tables. After this,
-- you can SELECT from demo_users / demo_orders / demo_products in any Oracle
-- SQL client connected as lakehouse.
--
-- Run this file with sqlcl or sqlplus from the host. Command-line args:
--
--   sql /nolog @polaris_test.sql \
--     "$OCI_ACCESS_KEY"            \  # &1 — Customer Secret Key access ID
--     "$OCI_SECRET_ACCESS_KEY"     \  # &2 — Customer Secret Key secret
--     "$ADW_ADMIN_PWD"             \  # &3 (DBA password — ADMIN on ADW)
--     "$ADW_CONNECT_ALIAS"         \  # &4 — tnsnames alias from the wallet
--
-- (All of these are in your ~/.zshrc.)
--
-- Target environment is selected by the DEFINE block below (db_alias / dba_user).
-- Defaults are set for ADB; flip the comments to switch to local Oracle.
--
-- ----------------------------------------------------------------------------
-- TARGET: Oracle Autonomous Database (ADB) on OCI. The Iceberg `protocol_type`
-- is part of ADB's bundled DBMS_CLOUD; the on-prem 26ai Free build does NOT
-- include it, so this script is intended for ADB.
--
-- WHEN TO RE-RUN: any time you re-run `python src/generate_iceberg_tables.py`
-- (which writes a new snapshot, hence a new metadata.json). Update the three
-- &..._meta variables below first by running:
--
--   ./polaris_test.sh
--
-- and copy the three "DEFINE x_meta = '...'" lines from step 4 of the output
-- into the DEFINE block below, replacing the existing values.
--
-- ----------------------------------------------------------------------------

SET ECHO ON
SET FEEDBACK ON
SET TIMING OFF
SET DEFINE ON
SET VERIFY OFF                       -- suppress old/new echo so secrets don't leak
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- Positional args from the command line (`sql ... @file ARG1 ARG2 ARG3 ARG4`).
DEFINE aws_key       = '&1'
DEFINE aws_secret    = '&2'
DEFINE dba_password  = '&3'
DEFINE db_alias      = '&4'

DEFINE dba_user = 'admin'

-- Object-store host for the iceberg data. The DBMS_CLOUD iceberg engine uses
-- a separate code path from the regular CREATE_EXTERNAL_TABLE, and that path
-- does NOT auto-grant the network ACL via the credential — we have to
-- APPEND_HOST_ACE explicitly. This is OCI Object Storage's vhcompat host
-- with the bucket as a subdomain.
DEFINE s3_host = 'polaris-iceberg.vhcompat.objectstorage.us-sanjose-1.oci.customer-oci.com'
--   Local Oracle (uncomment if needed):
-- DEFINE db_alias = '//localhost:1521/FREEPDB1'
-- DEFINE dba_user = 'skmishra'

-- LAKEHOUSE password. ADB's mandatory profile rules:
--   * uppercase + lowercase + digit, >= 12 chars
--   * must NOT contain the username "lakehouse" (case-insensitive)
--   * cannot reuse any previous password (PASSWORD_REUSE_TIME/MAX)
-- So bump this string each time you have to rotate.
DEFINE lakehouse_pwd = 'Lh0use#2026Demo'

-- Current metadata.json URLs for the three Iceberg tables — OCI vhcompat
-- virtual-hosted-style. Refresh by running ./polaris_test.sh and pasting
-- the new "DEFINE x_meta = '...'" lines here.
DEFINE users_meta    = 'https://polaris-iceberg.vhcompat.objectstorage.us-sanjose-1.oci.customer-oci.com/polaris-iceberg/demo/users/metadata/00001-952b22e2-1d5f-48d5-a899-d497b9a91b21.metadata.json'
DEFINE orders_meta   = 'https://polaris-iceberg.vhcompat.objectstorage.us-sanjose-1.oci.customer-oci.com/polaris-iceberg/demo/orders/metadata/00001-bf31b861-6ad4-43b6-a0b1-483300a02326.metadata.json'
DEFINE products_meta = 'https://polaris-iceberg.vhcompat.objectstorage.us-sanjose-1.oci.customer-oci.com/polaris-iceberg/demo/products/metadata/00001-2f7edad3-4823-4c7f-8acd-882673fce1be.metadata.json'

-- ============================================================================
-- A. Provision the LAKEHOUSE user (as DBA &dba_user). Idempotent.
-- ============================================================================
PROMPT
PROMPT === A. Connecting as &dba_user to provision LAKEHOUSE ===
CONNECT &dba_user/&dba_password@&db_alias

-- Create LAKEHOUSE if missing. If it already exists we leave the password
-- alone: ADB's mandatory profile rejects reusing a previous password
-- (ORA-28007), so an unconditional ALTER would fail on every re-run after
-- the first. To rotate the password, set ROTATE_LAKEHOUSE_PWD=Y at sqlcl
-- (`DEFINE rotate_lakehouse_pwd=Y`) before running, AND bump
-- &lakehouse_pwd above to a value never used before.
DEFINE rotate_lakehouse_pwd = 'N'

DECLARE
  e_user_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_user_exists, -1920);
  l_user_existed BOOLEAN := FALSE;
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'CREATE USER lakehouse IDENTIFIED BY "&lakehouse_pwd"';
  EXCEPTION
    WHEN e_user_exists THEN l_user_existed := TRUE;
  END;

  IF l_user_existed AND UPPER('&rotate_lakehouse_pwd') = 'Y' THEN
    EXECUTE IMMEDIATE 'ALTER USER lakehouse IDENTIFIED BY "&lakehouse_pwd"';
  END IF;
END;
/

GRANT CREATE SESSION, CREATE TABLE, UNLIMITED TABLESPACE TO lakehouse;

-- DBMS_CLOUD access. On ADB the package lives in C##CLOUD$SERVICE (not SYS)
-- and access is granted via the DWROLE role — ADMIN cannot grant EXECUTE on
-- it directly. On local Oracle Free, DBMS_CLOUD is installed into SYS by
-- tools/scripts/install_dbms_cloud.sh and DWROLE doesn't exist, so we grant
-- EXECUTE there directly. We try DWROLE first; if it doesn't exist (ORA-1919)
-- we fall back to the SYS.DBMS_CLOUD grant.
DECLARE
  e_role_missing  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_role_missing, -1919);
  e_obj_missing   EXCEPTION;  PRAGMA EXCEPTION_INIT(e_obj_missing,  -4042);
BEGIN
  EXECUTE IMMEDIATE 'GRANT DWROLE TO lakehouse';
EXCEPTION
  WHEN e_role_missing THEN
    BEGIN
      EXECUTE IMMEDIATE 'GRANT EXECUTE ON SYS.DBMS_CLOUD TO lakehouse';
    EXCEPTION
      WHEN e_obj_missing THEN
        RAISE_APPLICATION_ERROR(-20100,
          'Neither DWROLE nor SYS.DBMS_CLOUD found. On local Oracle, run '
          || 'tools/scripts/install_dbms_cloud.sh first.');
    END;
END;
/

-- Outbound HTTPS ACL for the iceberg engine. The regular DBMS_CLOUD path
-- auto-grants ACLs from the credential, but the iceberg path (CREATE_EXTERNAL
-- _TABLE with protocol_type=iceberg) bypasses that and would otherwise fail
-- with ORA-24247. APPEND_HOST_ACE is idempotent. Skipped on local Oracle
-- where DBMS_NETWORK_ACL_ADMIN often isn't usable from the app schema; the
-- iceberg engine isn't available there anyway, so the ACL doesn't matter.
DECLARE
  e_pkg_missing EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_pkg_missing, -6550);  -- "PLS-00201: identifier ... must be declared"
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => '&s3_host',
    lower_port => 443,
    upper_port => 443,
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'LAKEHOUSE',
                    principal_type => xs_acl.ptype_db));
EXCEPTION
  WHEN e_pkg_missing THEN NULL;
END;
/

-- ============================================================================
-- B. As LAKEHOUSE, create the AWS credential. Idempotent (drop-then-create).
-- ============================================================================
PROMPT
PROMPT === B. Connecting as LAKEHOUSE to create AWS credential and tables ===
CONNECT lakehouse/&lakehouse_pwd@&db_alias

BEGIN
  DBMS_CLOUD.DROP_CREDENTIAL(credential_name => 'AWS_S3_CRED');
EXCEPTION
  WHEN OTHERS THEN
    -- 20003 (older DBMS_CLOUD) and 20004 (26ai bundled) both mean
    -- "credential not found"; ignore them so re-runs are idempotent.
    IF SQLCODE NOT IN (-20003, -20004) THEN RAISE; END IF;
END;
/

BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'AWS_S3_CRED',
    username        => '&aws_key',
    password        => '&aws_secret'
  );
END;
/

-- ============================================================================
-- C. Register the three Iceberg tables as Oracle external tables.
--    Drop-then-create so re-running refreshes them against the latest
--    metadata.json (handy after `python src/generate_iceberg_tables.py`).
-- ============================================================================

-- Helper: drop a table if it exists, ignore ORA-00942 if not.
PROMPT >>> Dropping existing externals (ignore "table or view does not exist")
BEGIN
  FOR r IN (
    SELECT 'DEMO_USERS'    AS t FROM dual UNION ALL
    SELECT 'DEMO_ORDERS'   FROM dual UNION ALL
    SELECT 'DEMO_PRODUCTS' FROM dual
  ) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP TABLE ' || r.t || ' PURGE';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
    END;
  END LOOP;
END;
/

PROMPT >>> Creating DEMO_USERS
BEGIN
  DBMS_CLOUD.CREATE_EXTERNAL_TABLE(
    table_name      => 'DEMO_USERS',
    credential_name => 'AWS_S3_CRED',
    file_uri_list   => '&users_meta',
    format          => '{"access_protocol":{"protocol_type":"iceberg"}}');
END;
/

PROMPT >>> Creating DEMO_ORDERS
BEGIN
  DBMS_CLOUD.CREATE_EXTERNAL_TABLE(
    table_name      => 'DEMO_ORDERS',
    credential_name => 'AWS_S3_CRED',
    file_uri_list   => '&orders_meta',
    format          => '{"access_protocol":{"protocol_type":"iceberg"}}');
END;
/

PROMPT >>> Creating DEMO_PRODUCTS
BEGIN
  DBMS_CLOUD.CREATE_EXTERNAL_TABLE(
    table_name      => 'DEMO_PRODUCTS',
    credential_name => 'AWS_S3_CRED',
    file_uri_list   => '&products_meta',
    format          => '{"access_protocol":{"protocol_type":"iceberg"}}');
END;
/

-- ============================================================================
-- D. Smoke-test the externals.
-- ============================================================================
PROMPT
PROMPT === D. Smoke tests ===

PROMPT >>> Row counts
SELECT 'users'    AS table_name, COUNT(*) AS row_count FROM demo_users
UNION ALL SELECT 'orders',    COUNT(*) FROM demo_orders
UNION ALL SELECT 'products',  COUNT(*) FROM demo_products;

PROMPT >>> Sample users
SELECT id, name, email, signed_up_at FROM demo_users FETCH FIRST 5 ROWS ONLY;

PROMPT >>> Order counts by status
SELECT status, COUNT(*) AS n, ROUND(AVG(amount), 2) AS avg_amount
  FROM demo_orders
 GROUP BY status
 ORDER BY n DESC;

PROMPT >>> Average price by category
SELECT category, COUNT(*) AS n, ROUND(AVG(price), 2) AS avg_price
  FROM demo_products
 GROUP BY category
 ORDER BY n DESC;

PROMPT
PROMPT === Done. To re-enter the lakehouse session: ===
PROMPT   sql lakehouse/&lakehouse_pwd@&db_alias

EXIT;

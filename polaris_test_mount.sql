-- ----------------------------------------------------------------------------
-- polaris_test_mount.sql — auto-refresh variant
--
-- Uses DBMS_CATALOG.MOUNT_ICEBERG so ADW asks Polaris (via ngrok) for the
-- current metadata-location on every query. With this approach, re-running
-- `python src/generate_iceberg_tables.py` produces a new snapshot, Polaris
-- updates its pointer, and ADW sees fresh data on the next query — no need
-- to copy DEFINE x_meta lines into a SQL file like the direct-file path does.
--
-- Architecture:
--   ADW ──(REST via ngrok)──▶ Polaris       — catalog state
--   ADW ──(HTTPS direct)──▶  AWS S3         — data files (parquet, manifests)
--
-- Run:
--   sql /nolog @polaris_test_mount.sql \
--     "$AWS_ACCESS_KEY_ID"        \  # &1
--     "$AWS_SECRET_ACCESS_KEY"    \  # &2
--     "$ADW_ADMIN_PWD"            \  # &3
--     "$ADW_CONNECT_ALIAS"        \  # &4
--     "<ngrok-host>"              \  # &5 — e.g. abc-1-2.ngrok-free.dev
--     "<polaris-bearer-token>"    \  # &6 — fetch via curl OAuth (see below)
--
-- Token fetch (separate step before running):
--   TOKEN=$(curl -fsS https://<ngrok-host>/api/catalog/v1/oauth/tokens \
--     --user root:s3cr3t \
--     -d 'grant_type=client_credentials' \
--     -d 'scope=PRINCIPAL_ROLE:ALL' | jq -r .access_token)
--
-- Tokens expire after 1 hour. Re-fetch and re-run sections B+C+D after
-- expiry. (Direct-file polaris_test.sql is the fallback that doesn't need
-- ngrok or token rotation — pick the right one for your demo cadence.)
-- ----------------------------------------------------------------------------

SET ECHO ON
SET FEEDBACK ON
SET TIMING OFF
SET DEFINE ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE aws_key       = '&1'
DEFINE aws_secret    = '&2'
DEFINE dba_password  = '&3'
DEFINE db_alias      = '&4'
DEFINE ngrok_host    = '&5'
DEFINE polaris_token = '&6'

DEFINE dba_user           = 'admin'
DEFINE polaris_catalog    = 's3_catalog'
DEFINE iceberg_namespace  = 'demo'
DEFINE adw_catalog        = 'POLARIS_S3'
DEFINE lakehouse_pwd      = 'Lh0use#2026Demo'

-- AWS S3 host that holds the actual data files. Must match the bucket your
-- Polaris catalog is rooted at.
DEFINE s3_host = 'skmawsbucket1.s3.us-west-1.amazonaws.com'
DEFINE aws_region = 'us-west-1'

-- ============================================================================
-- A. As ADMIN: provision LAKEHOUSE, grant DWROLE, ACL the two egress hosts.
-- ============================================================================
PROMPT
PROMPT === A. ADMIN: provision LAKEHOUSE and grant ACLs ===
CONNECT &dba_user/&dba_password@&db_alias

DECLARE
  e_user_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_user_exists, -1920);
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER lakehouse IDENTIFIED BY "&lakehouse_pwd"';
EXCEPTION WHEN e_user_exists THEN NULL;
END;
/

GRANT CREATE SESSION, CREATE TABLE, UNLIMITED TABLESPACE TO lakehouse;
GRANT DWROLE TO lakehouse;

-- Egress to Polaris via ngrok (catalog REST) and AWS S3 (data files).
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => '&ngrok_host',
    lower_port => 443, upper_port => 443,
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'LAKEHOUSE',
                    principal_type => xs_acl.ptype_db));

  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => '&s3_host',
    lower_port => 443, upper_port => 443,
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'LAKEHOUSE',
                    principal_type => xs_acl.ptype_db));
END;
/

-- ============================================================================
-- B. As LAKEHOUSE: create credentials and mount Polaris.
-- ============================================================================
PROMPT
PROMPT === B. LAKEHOUSE: credentials and MOUNT_ICEBERG ===
CONNECT lakehouse/&lakehouse_pwd@&db_alias

-- Polaris bearer token (literal). MOUNT_ICEBERG sends `Authorization: Bearer
-- <password>`; it doesn't run an OAuth client_credentials flow itself — so
-- the password must already be a valid access_token.
BEGIN
  DBMS_CLOUD.DROP_CREDENTIAL(credential_name => 'POLARIS_REST_CRED');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE NOT IN (-20003,-20004) THEN RAISE; END IF;
END;
/
BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'POLARIS_REST_CRED',
    username        => 'token',
    password        => '&polaris_token');
END;
/

-- AWS S3 credentials for fetching data files.
BEGIN
  DBMS_CLOUD.DROP_CREDENTIAL(credential_name => 'AWS_S3_CRED');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE NOT IN (-20003,-20004) THEN RAISE; END IF;
END;
/
BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'AWS_S3_CRED',
    username        => '&aws_key',
    password        => '&aws_secret');
END;
/

-- Unmount any prior version so this re-runs cleanly.
BEGIN DBMS_CATALOG.UNMOUNT(catalog_name => '&adw_catalog');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

PROMPT >>> Mounting Polaris as iceberg-REST catalog
DECLARE
  cfg SYS.JSON_OBJECT_T := SYS.JSON_OBJECT_T();
BEGIN
  cfg.put('bucketRegion',    '&aws_region');
  cfg.put('isPublicCatalog', FALSE);

  DBMS_CATALOG.MOUNT_ICEBERG(
    catalog_name            => '&adw_catalog',
    -- /v1/<warehouse> path is the iceberg-REST scope ADW uses.
    endpoint                => 'https://&ngrok_host/api/catalog/v1/&polaris_catalog',
    catalog_credential       => 'POLARIS_REST_CRED',
    data_storage_credential => 'AWS_S3_CRED',
    configuration           => cfg,
    catalog_type            => 'ICEBERG_POLARIS');
END;
/

-- ============================================================================
-- C. Trigger a fetch and create synchronized views.
-- ============================================================================
PROMPT
PROMPT === C. Populate cache and create views ===

BEGIN DBMS_CATALOG.FLUSH_CATALOG_CACHE('&adw_catalog'); END;
/

PROMPT >>> Catalog metadata as ADW sees it (forces a fetch)
SELECT * FROM TABLE(DBMS_CATALOG.GET_SCHEMAS(catalog_name => '&adw_catalog'));
SELECT * FROM TABLE(DBMS_CATALOG.GET_TABLES(catalog_name => '&adw_catalog'));

-- CREATE_SYNCHRONIZED_VIEWS reports success but creates nothing on this
-- ADW build (silent no-op when iceberg name case-folds via Oracle's
-- identifier handling). Workaround: GENERATE_TABLE_SELECT yields the right
-- ORACLE_BIGDATA external-table query, which we wrap in a manual
-- CREATE OR REPLACE VIEW. The view's SELECT goes through the catalog mount
-- each time it's queried, so re-running PyIceberg writes is visible to ADW
-- on the next query — no DEFINE-line refresh, no view re-creation.
PROMPT >>> Materializing demo_users / demo_orders / demo_products as views
DECLARE
  v_sql CLOB;
BEGIN
  FOR r IN (SELECT 'users' AS iceberg_name, 'demo_users' AS view_name FROM dual UNION ALL
            SELECT 'orders',                'demo_orders'              FROM dual UNION ALL
            SELECT 'products',              'demo_products'            FROM dual) LOOP
    v_sql := DBMS_CATALOG.GENERATE_TABLE_SELECT(
               catalog_name => '&adw_catalog',
               schema_name  => '"&iceberg_namespace"',
               table_name   => '"' || r.iceberg_name || '"');
    EXECUTE IMMEDIATE 'CREATE OR REPLACE VIEW ' || r.view_name || ' AS ' || v_sql;
  END LOOP;
END;
/

-- ============================================================================
-- D. Smoke-test the externals.
-- ============================================================================
PROMPT
PROMPT === D. Smoke tests ===

PROMPT >>> Row counts
SELECT 'users' AS table_name, COUNT(*) AS row_count FROM demo_users
UNION ALL SELECT 'orders',   COUNT(*) FROM demo_orders
UNION ALL SELECT 'products', COUNT(*) FROM demo_products;

PROMPT >>> Sample users
SELECT id, name, email, signed_up_at FROM demo_users FETCH FIRST 5 ROWS ONLY;

PROMPT >>> Order counts by status
SELECT status, COUNT(*) AS n, ROUND(AVG(amount), 2) AS avg_amount
  FROM demo_orders GROUP BY status ORDER BY n DESC;

PROMPT >>> Average price by category
SELECT category, COUNT(*) AS n, ROUND(AVG(price), 2) AS avg_price
  FROM demo_products GROUP BY category ORDER BY n DESC;

PROMPT
PROMPT === Done. After each PyIceberg run, just FLUSH the catalog cache: ===
PROMPT   EXEC DBMS_CATALOG.FLUSH_CATALOG_CACHE('&adw_catalog');
PROMPT === No URL copying needed — Polaris vends fresh metadata-location.   ===

EXIT;

-- ----------------------------------------------------------------------------
-- polaris_test_mount.sql
--
-- OCI-Object-Storage variant. Uses DBMS_CATALOG.MOUNT_ICEBERG so ADW talks
-- to Polaris's iceberg-REST endpoint (over an ngrok tunnel from the laptop)
-- to resolve table → metadata-location, then fetches the actual data files
-- from OCI Object Storage directly via the vhcompat S3-compat URL.
--
-- Run:
--   sql /nolog @polaris_test_mount.sql \
--     "$OCI_ACCESS_KEY"            \  # &1 — Customer Secret Key access ID
--     "$OCI_SECRET_ACCESS_KEY"     \  # &2 — Customer Secret Key secret
--     "$ADW_ADMIN_PWD"             \  # &3
--     "$ADW_CONNECT_ALIAS"         \  # &4
--     "<ngrok-host>"               \  # &5 — e.g. overstate-setback-going.ngrok-free.dev
--
-- Refresh the ngrok host argument every time you restart `ngrok http 8181`
-- (free tier rotates the subdomain).
--
-- ----------------------------------------------------------------------------

SET ECHO ON
SET FEEDBACK ON
SET TIMING OFF
SET DEFINE ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE oci_key       = '&1'
DEFINE oci_secret    = '&2'
DEFINE dba_password  = '&3'
DEFINE db_alias      = '&4'
DEFINE ngrok_host    = '&5'

DEFINE dba_user           = 'admin'
DEFINE polaris_client_id  = 'root'
DEFINE polaris_secret     = 's3cr3t'
DEFINE polaris_catalog    = 's3_catalog'
DEFINE iceberg_namespace  = 'demo'
DEFINE adw_catalog        = 'POLARIS_OCI'

-- OCI Object Storage host that holds the actual data files. Polaris vends
-- s3:// URIs which ADW resolves against the s3.endpoint Polaris also returns
-- in the iceberg-REST loadTable response (vhcompat host with bucket subdomain).
DEFINE oci_storage_host = 'polaris-iceberg.vhcompat.objectstorage.us-sanjose-1.oci.customer-oci.com'

-- LAKEHOUSE password (mandatory profile rules — see polaris_test.sql comments).
DEFINE lakehouse_pwd = 'Lh0use#2026Demo'

-- ============================================================================
-- A. As ADMIN: provision LAKEHOUSE, grant DWROLE, ACL the two egress hosts.
-- ============================================================================
PROMPT
PROMPT === A. ADMIN: provision LAKEHOUSE and grant network ACLs ===
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

-- Egress to Polaris via ngrok (catalog REST calls) and OCI Object Storage
-- (data file fetches). APPEND_HOST_ACE is idempotent.
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => '&ngrok_host',
    lower_port => 443, upper_port => 443,
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'LAKEHOUSE',
                    principal_type => xs_acl.ptype_db));

  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host       => '&oci_storage_host',
    lower_port => 443, upper_port => 443,
    ace        => xs$ace_type(
                    privilege_list => xs$name_list('http'),
                    principal_name => 'LAKEHOUSE',
                    principal_type => xs_acl.ptype_db));
END;
/

-- ============================================================================
-- B. As LAKEHOUSE: create the two credentials and mount Polaris.
-- ============================================================================
PROMPT
PROMPT === B. LAKEHOUSE: credentials and MOUNT_ICEBERG ===
CONNECT lakehouse/&lakehouse_pwd@&db_alias

-- Polaris REST OAuth2 client credentials. Polaris's /v1/oauth/tokens endpoint
-- expects them as the username/password of basic-auth → we pass them through.
BEGIN
  DBMS_CLOUD.DROP_CREDENTIAL(credential_name => 'POLARIS_REST_CRED');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE NOT IN (-20003,-20004) THEN RAISE; END IF;
END;
/
BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'POLARIS_REST_CRED',
    username        => '&polaris_client_id',
    password        => '&polaris_secret');
END;
/

-- OCI Object Storage credentials (Customer Secret Keys), used by ADW for
-- HTTPS GETs to the vhcompat host that Polaris's catalog config advertises.
BEGIN
  DBMS_CLOUD.DROP_CREDENTIAL(credential_name => 'OCI_STORAGE_CRED');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE NOT IN (-20003,-20004) THEN RAISE; END IF;
END;
/
BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'OCI_STORAGE_CRED',
    username        => '&oci_key',
    password        => '&oci_secret');
END;
/

-- Unmount any prior version of POLARIS_OCI catalog so this re-runs cleanly.
BEGIN
  DBMS_CATALOG.UNMOUNT(catalog_name => '&adw_catalog');
EXCEPTION WHEN OTHERS THEN NULL;  -- ignore "not mounted"
END;
/

PROMPT >>> Mounting Polaris as iceberg-REST catalog
BEGIN
  DBMS_CATALOG.MOUNT_ICEBERG(
    catalog_name            => '&adw_catalog',
    -- Polaris is a multi-warehouse REST catalog. Per ngrok logs, ADW
    -- doesn't perform the iceberg-REST /v1/config handshake to learn the
    -- prefix; it just appends /namespaces directly. So the endpoint must
    -- already include /v1/<warehouse>.
    endpoint                => 'https://&ngrok_host/api/catalog/v1/&polaris_catalog',
    catalog_credential       => 'POLARIS_REST_CRED',
    data_storage_credential => 'OCI_STORAGE_CRED',
    catalog_type            => 'ICEBERG_POLARIS');
END;
/

-- ============================================================================
-- C. Materialise the catalog's tables as ADW views.
--    CREATE_SYNCHRONIZED_VIEWS reads the iceberg-REST catalog and creates a
--    view in the current schema for every table in the namespace. View names
--    default to the iceberg table names (users, orders, products) — we add a
--    DEMO_ prefix for clarity.
-- ============================================================================
PROMPT >>> CREATE_SYNCHRONIZED_VIEWS for namespace &iceberg_namespace
BEGIN
  DBMS_CATALOG.CREATE_SYNCHRONIZED_VIEWS(
    catalog_name     => '&adw_catalog',
    schema_name      => '&iceberg_namespace',
    view_prefix      => 'DEMO_',
    replace_existing => TRUE,
    ignore_errors    => FALSE);
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
PROMPT === Done. Catalog refreshes from Polaris on every query — ===
PROMPT === re-running PyIceberg writers does NOT require re-mounting. ===

EXIT;

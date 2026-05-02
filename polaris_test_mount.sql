-- ----------------------------------------------------------------------------
-- polaris_test_mount.sql — OCI Object Storage demo (mount path)
--
-- Uses DBMS_CATALOG.MOUNT_ICEBERG so ADW talks to Polaris (via ngrok) for
-- the catalog state and fetches the rewritten avros + parquet directly
-- from OCI Object Storage's NATIVE URL form.
--
-- Architecture (works because of the polaris-extensions-storage-oci hook):
--   ADW ── REST via ngrok ──▶ Polaris       (catalog state, returns
--                                            metadata.json with native OCI URLs)
--   ADW ── HTTPS direct  ──▶ OCI Object     (.oci.avro siblings + parquet
--                              Storage      via objectstorage.<region>.
--                                            oraclecloud.com/n/<ns>/b/...)
--
-- Run (eight positional args):
--   sql /nolog @polaris_test_mount.sql \
--     "$ADW_ADMIN_PWD"          \  # &1
--     "$ADW_CONNECT_ALIAS"      \  # &2
--     "<ngrok-host>"            \  # &3
--     "$TOKEN"                  \  # &4 — Polaris OAuth access_token (curl)
--     "$OCI_USER_OCID"          \  # &5
--     "$OCI_TENANCY_OCID"       \  # &6
--     "$OCI_FINGERPRINT"        \  # &7
--     "$OCI_PRIVATE_KEY_BODY"   \  # &8 — single-line base64 (no headers)
--
-- Helper one-liner to harvest OCI native auth from ~/.oci before invoking:
--   USER_OCID=$(awk -F= '/^user=/{print $2}' ~/.oci/config)
--   TENANCY=$(awk -F= '/^tenancy=/{print $2}' ~/.oci/config)
--   FP=$(awk -F= '/^fingerprint=/{print $2}' ~/.oci/config)
--   PEM=$(awk '/-----BEGIN/{f=1;next}/-----END/{f=0}f' ~/.oci/oci_api_key.pem | tr -d '\n')
--   TOKEN=$(curl -fsS https://<ngrok>/api/catalog/v1/oauth/tokens \
--     --user root:s3cr3t -d 'grant_type=client_credentials' \
--     -d 'scope=PRINCIPAL_ROLE:ALL' | jq -r .access_token)
--   sql /nolog @polaris_test_mount.sql "$ADW_ADMIN_PWD" "$ADW_CONNECT_ALIAS" \
--     "<ngrok>" "$TOKEN" "$USER_OCID" "$TENANCY" "$FP" "$PEM"
-- ----------------------------------------------------------------------------

SET ECHO ON
SET FEEDBACK ON
SET TIMING OFF
SET DEFINE ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE dba_password    = '&1'
DEFINE db_alias        = '&2'
DEFINE ngrok_host      = '&3'
DEFINE polaris_token   = '&4'
DEFINE oci_user_ocid   = '&5'
DEFINE oci_tenancy     = '&6'
DEFINE oci_fingerprint = '&7'
DEFINE oci_private_key = '&8'

DEFINE dba_user          = 'admin'
DEFINE polaris_catalog   = 's3_catalog'
DEFINE iceberg_namespace = 'demo'
DEFINE adw_catalog       = 'POLARIS_OCI'
DEFINE lakehouse_pwd     = 'Lh0use#2026Demo'

-- The host ADW reads data files from. Native OCI Object Storage URL form;
-- Polaris's OCI hook rewrites s3:// URIs in metadata + avros to point here.
DEFINE oci_storage_host  = 'objectstorage.us-sanjose-1.oraclecloud.com'

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

-- Egress to Polaris via ngrok (catalog REST) and to OCI native objectstorage
-- (data + avro fetches). APPEND_HOST_ACE is idempotent.
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
-- B. As LAKEHOUSE: create credentials and mount Polaris.
-- ============================================================================
PROMPT
PROMPT === B. LAKEHOUSE: credentials and MOUNT_ICEBERG ===
CONNECT lakehouse/&lakehouse_pwd@&db_alias

-- Polaris OAuth bearer token. MOUNT_ICEBERG sends this literally as
-- `Authorization: Bearer <password>`; Polaris validates the JWT.
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

-- OCI Object Storage credential — native API-key auth (NOT Customer Secret
-- Keys / HMAC). Required because the URLs ADW now follows are native form
-- (https://objectstorage.<region>.oraclecloud.com/n/...) which uses OCI
-- request-signing, not S3 SigV4.
BEGIN
  DBMS_CLOUD.DROP_CREDENTIAL(credential_name => 'OCI_STORAGE_CRED');
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE NOT IN (-20003,-20004) THEN RAISE; END IF;
END;
/
BEGIN
  DBMS_CLOUD.CREATE_CREDENTIAL(
    credential_name => 'OCI_STORAGE_CRED',
    user_ocid       => '&oci_user_ocid',
    tenancy_ocid    => '&oci_tenancy',
    private_key     => '&oci_private_key',
    fingerprint     => '&oci_fingerprint');
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
  cfg.put('isPublicCatalog', FALSE);

  DBMS_CATALOG.MOUNT_ICEBERG(
    catalog_name            => '&adw_catalog',
    endpoint                => 'https://&ngrok_host/api/catalog/v1/&polaris_catalog',
    catalog_credential      => 'POLARIS_REST_CRED',
    data_storage_credential => 'OCI_STORAGE_CRED',
    configuration           => cfg,
    catalog_type            => 'ICEBERG_POLARIS');
END;
/

-- ============================================================================
-- C. Trigger a fetch and create views over the catalog tables.
-- ============================================================================
PROMPT
PROMPT === C. Populate cache and create views ===

BEGIN DBMS_CATALOG.FLUSH_CATALOG_CACHE('&adw_catalog'); END;
/

PROMPT >>> Catalog metadata as ADW sees it (forces a fetch)
SELECT * FROM TABLE(DBMS_CATALOG.GET_SCHEMAS(catalog_name => '&adw_catalog'));
SELECT * FROM TABLE(DBMS_CATALOG.GET_TABLES(catalog_name => '&adw_catalog'));

PROMPT >>> Materializing demo_users / demo_orders / demo_products as views
DECLARE
  v_sql CLOB;
BEGIN
  FOR r IN (SELECT 'users'   AS iceberg_name, 'demo_users'    AS view_name FROM dual UNION ALL
            SELECT 'orders',                  'demo_orders'              FROM dual UNION ALL
            SELECT 'products',                'demo_products'            FROM dual) LOOP
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
PROMPT === The Polaris OCI hook handles avro rewriting; the views auto-refresh ===

EXIT;

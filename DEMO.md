# Polaris on ADB + S3 Iceberg — End-to-End Demo

This walkthrough provisions an Iceberg lakehouse from scratch:

1. **Apache Polaris** runs in Docker, serving the Iceberg REST catalog.
2. **Oracle Autonomous Database (ADB)** stores Polaris's catalog metadata
   *and* doubles as the SQL query engine via `DBMS_CLOUD` external tables.
3. **AWS S3** holds the actual parquet/manifest/metadata files.
4. **PyIceberg** writes fake demo data (users / orders / products) and commits
   the snapshots through Polaris.

```
   PyIceberg ──REST commit──▶  Polaris  ──JDBC──▶  ADB (POLARIS_SCHEMA)
       │                                              │
       └──parquet+manifests──▶  S3  ◀──HTTPS──── ADB (LAKEHOUSE, DBMS_CLOUD)
```

---

## 0. Prerequisites

Tools on your laptop:

- Docker / Docker Compose
- Java 21 + Gradle (only needed to build the Polaris image)
- Python 3.10+ with a venv at `../.venv`
- `sqlcl` (for the SQL script)
- `aws` CLI, `curl`, `jq`

Accounts:

- AWS account with an S3 bucket (default: `skmawsbucket1`, region `us-west-1`)
- OCI account with an Autonomous Database. **Workload type matters**: only
  **Data Warehouse (ADW)** ships the Iceberg engine in `DBMS_CLOUD`. ATPs and
  the newer "Lakehouse" workload type both report `main_workload_type = OLTP`
  in `v$parameter` and reject `protocol_type=iceberg` with
  `ORA-20000: Invalid URL [iceberg:https://...]`. Verify with
  `SELECT name, value FROM v$parameter WHERE name LIKE '%workload%'` —
  expect `DW`. Always Free allows up to 2 ADBs total in any combination.
- Downloaded mTLS wallet zip from the ADW, unzipped into `$TNS_ADMIN`.

Environment variables (export in `~/.zshrc`):

```bash
# AWS — used by both PyIceberg (writer) and ADB external tables
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-west-1

# ADB — wallet path, admin password, tnsnames alias
export TNS_ADMIN=$HOME/.oracle/wallets/adw        # unzipped wallet dir
export ADW_ADMIN_PWD='...'                         # ADMIN password from OCI
export ADW_CONNECT_ALIAS=q2jm1ek29mprcr96_tp       # any alias from tnsnames.ora

# OCI Object Storage (S3-compatible API)
export OCI_NAMESPACE=axydmvgg0v5v
export OCI_REGION=us-sanjose-1
export OCI_BUCKET=polaris-iceberg
export OCI_ACCESS_KEY=...                          # Customer Secret Key access ID
export OCI_SECRET_ACCESS_KEY=...                   # Customer Secret Key secret

# IMPORTANT: the bucket must be created via the S3 API (see
# create_oci_bucket.sh), not the OCI Console — only S3-API-created buckets
# are reachable via the vhcompat endpoint that carries a wildcard cert for
# bucket subdomains. Without that, AWS SDK virtual-hosted addressing fails
# TLS verification.
```

Verify the wallet is unzipped:

```
ls $TNS_ADMIN/{tnsnames.ora,cwallet.sso,sqlnet.ora}
```

---

## 1. Provision `POLARIS_SCHEMA` on ADB

This creates the user that Polaris will use as its catalog metastore.

```
make adw-reset
```

Idempotent — drops + recreates `POLARIS_SCHEMA` with the minimum privileges
(`CREATE SESSION`, `CREATE TABLE`, `UNLIMITED TABLESPACE`).

---

## 2. Build the Polaris image

```
make build-polaris-images
```

This compiles the Quarkus app and packages it as a Docker image.

---

## 3. Bring Polaris up

```
make polaris-up
make polaris-logs    # in another terminal
```

`docker-compose.yml` bind-mounts `$HOME/.oracle/wallets/adw` to `/wallet` and
points Polaris at `jdbc:oracle:thin:@${ADW_CONNECT_ALIAS}?TNS_ADMIN=/wallet`.
On first boot, Polaris auto-bootstraps schema-v4 inside `POLARIS_SCHEMA` —
look for `schema-v4 applied` in the logs before continuing.

Health check:

```
curl -fsS http://localhost:8181/q/health | jq
```

---

## 4. Create the Polaris S3 catalog

```
./src/create_polaris_s3_catalog.sh
```

This calls Polaris's REST API to create a catalog named `s3_catalog` of type
`INTERNAL`/`S3` rooted at `s3://skmawsbucket1/polaris-iceberg`.

Smoke-test the server:

```
./polaris_cli.sh
```

Lists catalogs, principals, and principal roles.

---

## 5. Generate Iceberg tables from PyIceberg

```
source ../.venv/bin/activate
pip install "pyiceberg[s3fs,sql-sqlite,pyarrow]" faker pyarrow boto3
python src/generate_iceberg_tables.py
```

What this does:

- Creates the `demo` namespace via Polaris REST.
- Generates 1000 users, 3000 orders, 250 products with `faker`.
- Writes parquet + manifests directly to S3.
- **Commits each snapshot to Polaris** via
  `POST /v1/s3_catalog/namespaces/demo/tables/{name}` with `requirements` +
  `updates`.

Verify:

```
aws s3 ls s3://skmawsbucket1/polaris-iceberg/demo/ --recursive | head
./polaris_test.sh
```

`polaris_test.sh` lists the tables, projects metadata for one, shows the
namespace, and prints three `DEFINE x_meta = 'https://...'` lines using
**virtual-hosted-style** URLs (`https://<bucket>.s3.<region>.amazonaws.com/<key>`).
Path-style URLs (`https://s3.<region>.amazonaws.com/<bucket>/<key>`) fail with
`ORA-20000: Invalid URL [iceberg:...]` even though they're the same bucket —
the iceberg engine seems to require virtual-hosted form.

---

## 6. Wire Polaris's metadata.json URLs into the SQL script

Copy the three `DEFINE` lines from step 4 of `polaris_test.sh` output into the
DEFINE block in `polaris_test.sql` (replaces the previous values).

These URLs change every time you re-run `generate_iceberg_tables.py` — each
write produces a new `metadata.json`, and ADB pins to a specific URL at table
creation time, so the externals must be recreated.

---

## 7. Register the Iceberg tables as Oracle external tables

```
sql /nolog @polaris_test.sql \
  "$OCI_ACCESS_KEY"           \
  "$OCI_SECRET_ACCESS_KEY"    \
  "$ADW_ADMIN_PWD"            \
  "$ADW_CONNECT_ALIAS"
```

The script:

- **A.** Connects as `ADMIN` to ADB, creates user `LAKEHOUSE` (or resets its
  password), grants it `DWROLE` (which carries `EXECUTE` on
  `C##CLOUD$SERVICE.DBMS_CLOUD`), and **`APPEND_HOST_ACE`** for the S3 host.
  The iceberg path is a separate code path inside DBMS_CLOUD — unlike the
  regular external-table path it does **not** auto-grant network ACLs from
  the credential, so without this ACE you get `ORA-24247: network access
  denied by access control list (ACL)`.
- **B.** Reconnects as `LAKEHOUSE`, creates `AWS_S3_CRED` from the AWS keys.
  *(ADB has to fetch S3 objects directly — Polaris doesn't proxy data.)*
- **C.** Drops + creates `DEMO_USERS`, `DEMO_ORDERS`, `DEMO_PRODUCTS` as
  external tables with
  `format => '{"access_protocol":{"protocol_type":"iceberg"}}'`, pointed at
  the metadata.json URLs.
- **D.** Smoke tests: row counts, sample users, order status breakdown,
  average price by category.

---

## 8. Query the lakehouse

```
sql lakehouse/'Lh0use#2026Demo'@$ADW_CONNECT_ALIAS

SQL> SELECT COUNT(*) FROM demo_users;
SQL> SELECT u.name, COUNT(o.id) AS order_count, ROUND(SUM(o.amount), 2) AS total
       FROM demo_users u
       JOIN demo_orders o ON o.user_id = u.id
      GROUP BY u.name
      ORDER BY total DESC
      FETCH FIRST 10 ROWS ONLY;
```

---

## Re-running after a data refresh

When you re-run `python src/generate_iceberg_tables.py`:

1. New parquet files land in S3.
2. Polaris commits a new snapshot → `metadata-location` advances.
3. ADB external tables still point at the **old** metadata.json (DBMS_CLOUD
   pins, doesn't auto-refresh).
4. Re-run `./polaris_test.sh`, copy the new `DEFINE` lines into
   `polaris_test.sql`, then re-run section C of the SQL script.

---

## Tearing down

```
make polaris-down                 # stop the server
make adw-reset                    # wipe POLARIS_SCHEMA on ADB

# In ADB as ADMIN, optional:
DROP USER lakehouse CASCADE;

# In AWS:
aws s3 rm s3://skmawsbucket1/polaris-iceberg --recursive
```

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `ORA-17957 SSO KeyStore not available` in Polaris logs | `oraclepki` not on classpath — confirm `runtimeOnly(libs.oracle.pki)` in `runtime/server/build.gradle.kts`. |
| `OAuth2 token 500` | Polaris hasn't auto-bootstrapped — confirm `POLARIS_PERSISTENCE_AUTO_BOOTSTRAP_TYPES=relational-jdbc` in compose. |
| `CREATE_TABLE_DIRECT_WITH_WRITE_DELEGATION 403` from PyIceberg | Add `"header.X-Iceberg-Access-Delegation": ""` to the catalog config (already set in `generate_iceberg_tables.py`). |
| `ORA-20000 Invalid URL [iceberg:https://...]` | One of: (a) instance is ATP / Lakehouse-OLTP, not ADW — only ADW ships the iceberg engine; (b) URL is path-style (`s3.<region>.amazonaws.com/<bucket>/...`) — switch to virtual-hosted (`<bucket>.s3.<region>.amazonaws.com/...`); (c) on-prem Oracle Free, which doesn't ship the `iceberg` protocol_type at all. Sanity check: `SELECT name, value FROM v$parameter WHERE name LIKE '%workload%'` should return `DW`. |
| `ORA-24247 network access denied by access control list (ACL)` from `DBMS_CLOUD.CREATE_EXTERNAL_TABLE` | Iceberg path doesn't auto-grant ACLs from the credential. Run `DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE` for the S3 host (already wired into `polaris_test.sql` section A). |
| `ORA-28219 Password contains the username` on `CREATE USER lakehouse IDENTIFIED BY 'Lakehouse#...'` | ADB's mandatory password profile forbids the username (case-insensitive) anywhere in the password. Use a value without `lakehouse` in it. |
| `ORA-28007 The password cannot be reused` on `ALTER USER lakehouse IDENTIFIED BY ...` | ADB enforces password history. The script avoids hitting this on re-runs by ALTERing only when `rotate_lakehouse_pwd='Y'`; to actually rotate, also bump `&lakehouse_pwd` to a brand-new value. |
| ADB external table returns 0 rows after a fresh PyIceberg run | Externals are pinned to the old metadata.json — re-run sections 6–7. |

"""
Generate fake data with Faker and write it as Apache Iceberg tables to AWS S3.

Three tables under the `demo` namespace:
  • users    — id, name, email, address, signed_up_at
  • orders   — id, user_id, amount, status, placed_at
  • products — id, name, category, price

Catalog: Apache Polaris (REST) by default; persists table metadata in
Polaris's Oracle ADW metastore. Set USE_POLARIS=false to fall back to a
local SQLite catalog. Data + manifests + snapshot files live in S3.

Prereqs (one-time, in the venv at ../.venv):
    source ../.venv/bin/activate
    pip install "pyiceberg[s3fs,sql-sqlite,pyarrow]" faker pyarrow boto3

Run:
    source ../.venv/bin/activate
    # All of these come from ~/.zshrc:
    #   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
    python src/generate_iceberg_tables.py
"""

from __future__ import annotations

import os
import random
import sys
from datetime import timezone
from pathlib import Path

import pyarrow as pa
from faker import Faker
from pyiceberg.catalog import load_catalog
from pyiceberg.catalog.sql import SqlCatalog


# ---- Config ---------------------------------------------------------------


def _require_env(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        sys.stderr.write(f"ERROR: {name} is not set in the environment.\n")
        sys.exit(1)
    return val


AWS_ACCESS_KEY_ID = _require_env("AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY = _require_env("AWS_SECRET_ACCESS_KEY")
AWS_REGION = os.environ.get("AWS_REGION", "us-west-1")

BUCKET = os.environ.get("S3_BUCKET", "skmawsbucket1")
S3_PREFIX = os.environ.get("S3_PREFIX", "polaris-iceberg")
WAREHOUSE = f"s3://{BUCKET}/{S3_PREFIX}"

ROWS = int(os.environ.get("ROWS_PER_TABLE", "1000"))
NAMESPACE = ("demo",)

# Persist the catalog metadata in a SQLite file under the project root so
# subsequent runs see existing tables (idempotent overwrite, not duplicate).
LOCAL_METADATA_DB = (Path(__file__).parent / ".iceberg-catalog.db").resolve()


# ---- Fake data generation -------------------------------------------------

faker = Faker()
faker.seed_instance(42)
random.seed(42)


def gen_users(n: int) -> pa.Table:
    rows = [
        {
            "id": i + 1,
            "name": faker.name(),
            "email": faker.unique.email(),
            "address": faker.address().replace("\n", ", "),
            "signed_up_at": faker.date_time_between(
                start_date="-3y", end_date="now", tzinfo=timezone.utc
            ),
        }
        for i in range(n)
    ]
    return pa.Table.from_pylist(rows)


def gen_orders(n: int, n_users: int) -> pa.Table:
    statuses = ["pending", "paid", "shipped", "delivered", "refunded"]
    rows = [
        {
            "id": i + 1,
            "user_id": random.randint(1, n_users),
            "amount": round(random.uniform(5.0, 999.99), 2),
            "status": random.choice(statuses),
            "placed_at": faker.date_time_between(
                start_date="-1y", end_date="now", tzinfo=timezone.utc
            ),
        }
        for i in range(n)
    ]
    return pa.Table.from_pylist(rows)


def gen_products(n: int) -> pa.Table:
    categories = ["electronics", "clothing", "books", "toys", "home", "sports"]
    rows = [
        {
            "id": i + 1,
            "name": faker.unique.catch_phrase()[:64],
            "category": random.choice(categories),
            "price": round(random.uniform(1.99, 499.99), 2),
        }
        for i in range(n)
    ]
    return pa.Table.from_pylist(rows)


# ---- Catalog setup --------------------------------------------------------


USE_POLARIS = os.environ.get("USE_POLARIS", "true").lower() in ("true", "1", "yes")

POLARIS_URL = os.environ.get("POLARIS_URL", "http://localhost:8181")
POLARIS_CATALOG = os.environ.get("POLARIS_CATALOG", "s3_catalog")
POLARIS_CLIENT_ID = os.environ.get("POLARIS_CLIENT_ID", "root")
POLARIS_CLIENT_SECRET = os.environ.get("POLARIS_CLIENT_SECRET", "s3cr3t")


def make_catalog():
    """By default uses Apache Polaris as the REST catalog (set USE_POLARIS=false
    to fall back to a local SQLite catalog). Iceberg metadata lives in Polaris
    (which persists it in Oracle); data + manifests + snapshots go to S3 under
    {WAREHOUSE}/{namespace}/{table}/."""
    s3_io = {
        "s3.region": AWS_REGION,
        "s3.access-key-id": AWS_ACCESS_KEY_ID,
        "s3.secret-access-key": AWS_SECRET_ACCESS_KEY,
    }

    if USE_POLARIS:
        return load_catalog(
            "polaris",
            **{
                "type": "rest",
                "uri": f"{POLARIS_URL}/api/catalog",
                "warehouse": POLARIS_CATALOG,
                "credential": f"{POLARIS_CLIENT_ID}:{POLARIS_CLIENT_SECRET}",
                "scope": "PRINCIPAL_ROLE:ALL",
                # Disable PyIceberg's default `X-Iceberg-Access-Delegation:
                # vended-credentials` header. Polaris is configured with
                # SKIP_CREDENTIAL_SUBSCOPING_INDIRECTION=true and we use our
                # own AWS creds for S3 IO, so we don't want to ask Polaris to
                # vend. Asking would force the
                # CREATE_TABLE_DIRECT_WITH_WRITE_DELEGATION authz path,
                # which the default catalog_admin role doesn't grant.
                "header.X-Iceberg-Access-Delegation": "",
                **s3_io,
            },
        )

    # Fallback: local SQLite catalog (no Polaris dependency).
    return SqlCatalog(
        "demo",
        **{
            "uri": f"sqlite:///{LOCAL_METADATA_DB}",
            "warehouse": WAREHOUSE,
            **s3_io,
        },
    )


# ---- Main -----------------------------------------------------------------


def write_table(catalog, name: str, arrow_table: pa.Table) -> None:
    ident = (*NAMESPACE, name)
    print(f"\n--- {'.'.join(ident)} (rows={arrow_table.num_rows}) ---")

    if catalog.table_exists(ident):
        iceberg_table = catalog.load_table(ident)
        print("  table exists — overwriting (replaces previous snapshot)")
        iceberg_table.overwrite(arrow_table)
    else:
        iceberg_table = catalog.create_table(
            identifier=ident,
            schema=arrow_table.schema,
        )
        print(f"  created at {iceberg_table.location()}")
        iceberg_table.append(arrow_table)

    print(f"  rows after write: {iceberg_table.scan().to_arrow().num_rows}")


def main() -> None:
    catalog = make_catalog()
    catalog.create_namespace_if_not_exists(NAMESPACE)
    print(f"Namespace ensured: {'.'.join(NAMESPACE)}")
    print(f"Warehouse:         {WAREHOUSE}")
    print(f"Catalog metadata:  {LOCAL_METADATA_DB}")

    write_table(catalog, "users", gen_users(ROWS))
    write_table(catalog, "orders", gen_orders(ROWS * 3, n_users=ROWS))
    write_table(catalog, "products", gen_products(max(ROWS // 4, 1)))

    print("\nDone.")
    print(f"Browse S3 with:   aws s3 ls s3://{BUCKET}/{S3_PREFIX}/ --recursive")


if __name__ == "__main__":
    main()

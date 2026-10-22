"""Load the stores database through the RDS Data API.

Creates the StoresDB.stores table, upserts stores_records.json, creates (or re-syncs) the
read-only MySQL user from its Secrets Manager secret, then proves that user can read but not
write. Runs anywhere with AWS credentials (CloudShell, CI): no VPC access or MySQL driver needed.

Usage:
  python3 load_stores_data_api.py --from-terraform 6_deploy/infra/agentcore-backends
  python3 load_stores_data_api.py --cluster-arn ARN --admin-secret-arn ARN --reader-secret-arn ARN

Without flags, STORES_DB_CLUSTER_ARN, STORES_DB_ADMIN_SECRET_ARN and STORES_DB_SECRET_ARN are used.
Safe to re-run: every step is idempotent.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

DEFAULT_DB_NAME = "StoresDB"
RECORDS_FILE = Path(__file__).resolve().parent / "stores_records.json"

COLUMNS = ["store_id", "name", "address", "city", "state", "zip_code",
           "latitude", "longitude", "has_drive_thru", "hours_start", "hours_end"]

CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS stores (
    store_id       VARCHAR(50) PRIMARY KEY,
    name           VARCHAR(100),
    address        VARCHAR(200),
    city           VARCHAR(100),
    state          VARCHAR(50),
    zip_code       VARCHAR(20),
    latitude       FLOAT,
    longitude      FLOAT,
    has_drive_thru BOOLEAN,
    hours_start    TIME,
    hours_end      TIME
)
"""

UPSERT = (
    "INSERT INTO stores (" + ", ".join(COLUMNS) + ") "
    "VALUES (" + ", ".join(f":{c}" for c in COLUMNS) + ") AS new "
    "ON DUPLICATE KEY UPDATE "
    + ", ".join(f"{c} = new.{c}" for c in COLUMNS if c != "store_id")
)

_SAFE_USERNAME = re.compile(r"^[A-Za-z0-9_]{1,32}$")
_SAFE_PASSWORD = re.compile(r"^[A-Za-z0-9]{16,128}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--from-terraform", metavar="DIR",
                        help="read the ARNs from `terraform output` in this directory")
    parser.add_argument("--cluster-arn", default=os.environ.get("STORES_DB_CLUSTER_ARN"))
    parser.add_argument("--admin-secret-arn", default=os.environ.get("STORES_DB_ADMIN_SECRET_ARN"))
    parser.add_argument("--reader-secret-arn", default=os.environ.get("STORES_DB_SECRET_ARN"))
    parser.add_argument("--database", default=os.environ.get("STORES_DB_NAME", DEFAULT_DB_NAME))
    parser.add_argument("--region", default=os.environ.get("REGION") or os.environ.get("AWS_REGION") or "eu-central-1")
    args = parser.parse_args()

    if args.from_terraform:
        result = subprocess.run(["terraform", f"-chdir={args.from_terraform}", "output", "-json"],
                                check=True, capture_output=True, text=True)
        outputs = {k: v["value"] for k, v in json.loads(result.stdout).items()}
        args.cluster_arn = outputs["stores_db_cluster_arn"]
        args.admin_secret_arn = outputs["stores_db_admin_secret_arn"]
        args.reader_secret_arn = outputs["stores_db_reader_secret_arn"]
        args.database = outputs.get("stores_db_name", args.database)

    missing = [n for n in ("cluster_arn", "admin_secret_arn", "reader_secret_arn") if not getattr(args, n)]
    if missing:
        parser.error("missing " + ", ".join("--" + m.replace("_", "-") for m in missing))
    return args


class DataApi:
    """Thin wrapper over rds-data with a retry for a cluster that is resuming."""

    def __init__(self, client, cluster_arn: str, database: str):
        self.client = client
        self.cluster_arn = cluster_arn
        self.database = database

    def _call(self, method: str, **kwargs):
        delays = [5, 10, 20]
        while True:
            try:
                return getattr(self.client, method)(
                    resourceArn=self.cluster_arn, database=self.database, **kwargs)
            except ClientError as e:
                if e.response["Error"]["Code"] == "DatabaseResumingException" and delays:
                    wait = delays.pop(0)
                    print(f"  database is resuming; retrying in {wait}s")
                    time.sleep(wait)
                    continue
                raise

    def execute(self, secret_arn: str, sql: str, parameters=None, as_json: bool = False):
        kwargs = {"secretArn": secret_arn, "sql": sql}
        if parameters:
            kwargs["parameters"] = parameters
        if as_json:
            kwargs["formatRecordsAs"] = "JSON"
        return self._call("execute_statement", **kwargs)

    def batch(self, secret_arn: str, sql: str, parameter_sets):
        return self._call("batch_execute_statement", secretArn=secret_arn, sql=sql,
                          parameterSets=parameter_sets)


def _value(value):
    if value is None:
        return {"isNull": True}
    if isinstance(value, bool):
        return {"booleanValue": value}
    if isinstance(value, int):
        return {"longValue": value}
    if isinstance(value, float):
        return {"doubleValue": value}
    return {"stringValue": str(value)}


def _time(value: str) -> str:
    """'07:00' -> '07:00:00' (Data API TIME values need seconds)."""
    return value if value.count(":") == 2 else f"{value}:00"


def store_parameters(store: dict) -> list:
    params = []
    for column in COLUMNS:
        value = store[column]
        param = {"name": column}
        if column in ("hours_start", "hours_end"):
            param["value"] = {"stringValue": _time(value)}
            param["typeHint"] = "TIME"
        elif column in ("latitude", "longitude"):
            param["value"] = {"doubleValue": float(value)}
        else:
            param["value"] = _value(value)
        params.append(param)
    return params


def reader_credentials(secrets_client, secret_arn: str) -> tuple:
    secret = json.loads(secrets_client.get_secret_value(SecretId=secret_arn)["SecretString"])
    username, password = secret["username"], secret["password"]
    # Both are embedded in CREATE/ALTER USER, so only allow characters that need no quoting
    if not _SAFE_USERNAME.match(username) or not _SAFE_PASSWORD.match(password):
        sys.exit("Reader secret must hold an alphanumeric username and a 16-128 character "
                 "alphanumeric password (the Terraform stack generates one).")
    return username, password


def main() -> None:
    args = parse_args()
    records = json.loads(RECORDS_FILE.read_text(encoding="utf-8"))
    api = DataApi(boto3.client("rds-data", region_name=args.region), args.cluster_arn, args.database)
    secrets = boto3.client("secretsmanager", region_name=args.region)

    print(f"Cluster:  {args.cluster_arn}\nDatabase: {args.database}")

    print("1/4 Creating table stores (if missing)...")
    api.execute(args.admin_secret_arn, CREATE_TABLE)

    print(f"2/4 Upserting {len(records)} stores...")
    api.batch(args.admin_secret_arn, UPSERT, [store_parameters(s) for s in records])

    print("3/4 Creating/updating the read-only user...")
    username, password = reader_credentials(secrets, args.reader_secret_arn)
    account = f"'{username}'@'%'"
    api.execute(args.admin_secret_arn, f"CREATE USER IF NOT EXISTS {account} IDENTIFIED BY '{password}'")
    api.execute(args.admin_secret_arn, f"ALTER USER {account} IDENTIFIED BY '{password}'")
    api.execute(args.admin_secret_arn, f"GRANT SELECT ON {args.database}.stores TO {account}")

    print("4/4 Verifying with the reader credentials...")
    result = api.execute(args.reader_secret_arn, "SELECT COUNT(*) AS store_count FROM stores", as_json=True)
    count = json.loads(result["formattedRecords"])[0]["store_count"]
    if count < len(records):
        sys.exit(f"Expected at least {len(records)} stores, the reader sees {count}.")
    try:
        api.execute(args.reader_secret_arn, "DELETE FROM stores WHERE 1 = 0")
        sys.exit("The reader user can write to stores; it must be read-only.")
    except ClientError as e:
        if "denied" not in str(e).lower():
            raise
    print(f"Done: {count} stores readable by {username}; writes are denied as expected.")


if __name__ == "__main__":
    main()

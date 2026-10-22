# stores_agents.py — Specialty Bakeries & Pastry Cafés
#
# Store data comes from the StoresDB.stores table in Aurora MySQL. Two access paths:
#   - RDS Data API (production): set STORES_DB_CLUSTER_ARN and STORES_DB_SECRET_ARN (Terraform
#     stack 6_deploy/infra/agentcore-backends). HTTPS + IAM, so the runtime needs no VPC access.
#   - MySQL driver (legacy lab): discovers a cluster named spbc-aurora-cluster* and reads the
#     spbc-aurora-db-credentials secret. Needs a network path (VPC mode) to the cluster.
import os
import re
import json
import time
import pymysql
import boto3
import codecs
import traceback
from datetime import timedelta
from botocore.exceptions import ClientError
from strands import Agent, tool
from strands.models import BedrockModel

STORES_KNOWLEDGE_BASE_ID = os.environ["STORES_KNOWLEDGE_BASE_ID"]
REGION = os.environ["REGION"]
MODEL_ARN = os.environ["MODEL_ARN"]

DB_NAME = os.environ.get("STORES_DB_NAME", "StoresDB")
DB_CLUSTER_ARN = os.environ.get("STORES_DB_CLUSTER_ARN", "").strip()
DB_SECRET_ARN = os.environ.get("STORES_DB_SECRET_ARN", "").strip()
USE_DATA_API = bool(DB_CLUSTER_ARN and DB_SECRET_ARN)

# Legacy discovery
DB_CLUSTER_PREFIX = "spbc-aurora-cluster"
DB_SECRET_ID = "spbc-aurora-db-credentials"

# Must match the table created by 2_data_strategy/stores/ (load_stores_data_api.py or
# stores_load_helper_script.py).
_STORE_COLUMNS = (
    "store_id, name, address, city, state, zip_code, "
    "latitude, longitude, has_drive_thru, hours_start, hours_end"
)

bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)
_rds_data = boto3.client('rds-data', region_name=REGION) if USE_DATA_API else None

print(f"Stores data source: {'RDS Data API' if USE_DATA_API else 'MySQL driver (legacy discovery)'}")


# ── RDS Data API ──────────────────────────────────────────────────────────────

def _data_api_rows(sql: str, params: dict) -> list:
    """Run a read-only statement through the Data API and return rows as dicts."""
    parameters = [{"name": k, "value": {"stringValue": str(v)}} for k, v in params.items()]
    delays = [2, 5, 10]
    while True:
        try:
            kwargs = {"resourceArn": DB_CLUSTER_ARN, "secretArn": DB_SECRET_ARN,
                      "database": DB_NAME, "sql": sql, "formatRecordsAs": "JSON"}
            if parameters:
                kwargs["parameters"] = parameters
            response = _rds_data.execute_statement(**kwargs)
            return json.loads(response.get("formattedRecords") or "[]")
        except ClientError as e:
            # A paused Serverless v2 cluster answers with DatabaseResumingException for ~15 s
            if e.response["Error"]["Code"] == "DatabaseResumingException" and delays:
                time.sleep(delays.pop(0))
                continue
            raise


# ── MySQL driver (legacy) ─────────────────────────────────────────────────────

# Module-level cache — populated lazily inside get_conn(), never at import time.
_host: str | None = None
_db_user: str | None = None
_db_pass: str | None = None


def _resolve_credentials() -> tuple[str, str, str]:
    """Fetch Aurora endpoint and DB credentials on first use (not at import time)."""
    global _host, _db_user, _db_pass
    if _host and _db_user and _db_pass:
        return _host, _db_user, _db_pass

    print("Fetching Aurora endpoint...")
    rds = boto3.client('rds', region_name=REGION)
    clusters = rds.describe_db_clusters()
    host = next(
        (c['Endpoint'] for c in clusters['DBClusters']
         if c['DBClusterIdentifier'].startswith(DB_CLUSTER_PREFIX)),
        None,
    )
    if not host:
        raise RuntimeError(
            f"No Aurora cluster whose identifier starts with '{DB_CLUSTER_PREFIX}' exists in {REGION}"
        )
    print(f"Aurora endpoint resolved: {host}")

    print("Fetching DB credentials from Secrets Manager...")
    secrets_client = boto3.client('secretsmanager', region_name=REGION)
    secret_value = secrets_client.get_secret_value(SecretId=DB_SECRET_ID)
    raw = secret_value['SecretString']
    clean = codecs.decode(raw, 'unicode_escape')
    credentials = json.loads(clean)

    _host = host
    _db_user = credentials['username']
    _db_pass = credentials['password']
    print(f"DB user resolved: {_db_user}")
    return _host, _db_user, _db_pass


def _clear_credentials() -> None:
    global _host, _db_user, _db_pass
    _host = _db_user = _db_pass = None


def get_conn():
    host, db_user, db_pass = _resolve_credentials()
    try:
        conn = pymysql.connect(
            host=host,
            user=db_user,
            password=db_pass,
            database=DB_NAME,
            connect_timeout=5
        )
        print("Successfully connected to the database.")
        return conn
    except pymysql.MySQLError:
        print("Failed to connect to DB:")
        traceback.print_exc()
        raise


def _serialize(value):
    return str(value) if isinstance(value, timedelta) else value


def _driver_rows(sql: str, params: dict) -> list:
    """Run a read-only statement with pymysql and always close the connection."""
    driver_sql = re.sub(r":(\w+)", r"%(\1)s", sql)  # :name -> %(name)s
    for attempt in (1, 2):
        try:
            conn = get_conn()
        except pymysql.err.OperationalError as e:
            # 1045 = access denied: the cached password may have been rotated; refetch once
            if e.args and e.args[0] == 1045 and attempt == 1:
                _clear_credentials()
                continue
            raise
        try:
            with conn.cursor() as cursor:
                cursor.execute(driver_sql, params)
                rows = cursor.fetchall()
                columns = [col[0] for col in cursor.description]
            return [dict(zip(columns, [_serialize(v) for v in row])) for row in rows]
        finally:
            conn.close()
    return []


def _rows(sql: str, params: dict | None = None) -> list:
    """Query the stores table with named (:name) parameters via the configured access path."""
    params = params or {}
    return _data_api_rows(sql, params) if USE_DATA_API else _driver_rows(sql, params)


# ── Tools ─────────────────────────────────────────────────────────────────────

@tool(name="stores_kb_retrieve", description="A tool to retrieve data from the bakery stores knowledge base")
def stores_kb_retrieve(query: str) -> str:
    print(f"Running stores_kb_retrieve with query: {query}")
    params = {
        "input": {"text": query},
        "retrieveAndGenerateConfiguration": {
          "type": "KNOWLEDGE_BASE",
          "knowledgeBaseConfiguration": {
              "knowledgeBaseId": STORES_KNOWLEDGE_BASE_ID,
              "modelArn": MODEL_ARN,
              "retrievalConfiguration": {
                  "vectorSearchConfiguration": {
                      "numberOfResults": 7,
                      "overrideSearchType": "HYBRID"
                  }
              }
          }
      }
    }
    try:
        response = bedrock_runtime.retrieve_and_generate(**params)
        print("stores_kb_retrieve response received.")
        return response.get("output", {}).get("text", "No relevant information found in the knowledge base.")
    except Exception as e:
        print("Failed in stores_kb_retrieve:")
        traceback.print_exc()
        return f"Failed to retrieve information: {str(e)}"


@tool(name="list_stores", description="A tool to retrieve the list of Specialty Bakeries & Pastry Cafés locations")
def list_stores(query: str = "") -> list:
    print("Running list_stores...")
    try:
        stores = _rows(f"SELECT {_STORE_COLUMNS} FROM stores")
        print(f"Fetched {len(stores)} stores.")
        return stores
    except Exception as e:
        print("Error in list_stores:")
        traceback.print_exc()
        return [{"error": str(e)}]


@tool(name="get_store_by_id", description="A tool to find a bakery location by its ID")
def get_store_by_id(store_id: str) -> dict:
    print(f"Running get_store_by_id with store_id: {store_id}")
    try:
        stores = _rows(f"SELECT {_STORE_COLUMNS} FROM stores WHERE store_id = :store_id",
                       {"store_id": store_id})
        if not stores:
            print("Store not found.")
            return {"message": "Store not found"}
        return stores[0]
    except Exception as e:
        print("Error in get_store_by_id:")
        traceback.print_exc()
        return {"error": str(e)}


@tool(name="search_store_by_name", description="A tool to find a bakery location by name or city")
def search_store_by_name(name: str) -> list:
    print(f"Running search_store_by_name with name like: %{name}%")
    try:
        pattern = f"%{name}%"
        stores = _rows(
            f"SELECT {_STORE_COLUMNS} FROM stores WHERE name LIKE :name_pattern OR city LIKE :city_pattern",
            {"name_pattern": pattern, "city_pattern": pattern},
        )
        print(f"Found {len(stores)} matching stores.")
        return stores
    except Exception as e:
        print("Error in search_store_by_name:")
        traceback.print_exc()
        return [{"error": str(e)}]


stores_agent = Agent(
    model=BedrockModel(model_id=os.environ["MODEL_ID"], region_name=REGION),
    system_prompt="""
        - You are 'Stores Assistant' for Specialty Bakeries & Pastry Cafés, expert in finding our bakery locations across Germany, Austria, and Switzerland.
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentence answers only. Be brief.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about bakery locations or store policies.
        - For queries not related to stores, respond with 'Sorry, I cannot answer this question'.
        - If answering requires location data, use the tools: list_stores, get_store_by_id, or search_store_by_name.
        - Only if necessary and after trying all other tools, use stores_kb_retrieve to check the knowledge base.
        - If nothing relevant is found, ask clarifying questions or refer to contact support.
    """,
    tools=[stores_kb_retrieve, list_stores, get_store_by_id, search_store_by_name],
)

print("Stores agent setup complete.")

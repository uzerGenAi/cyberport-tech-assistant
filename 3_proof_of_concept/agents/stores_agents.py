"""Stores agent for Specialty Bakeries & Pastry Cafés — store locations and policies.

Store data comes from the StoresDB.stores table in Aurora MySQL. Two access paths:
  - RDS Data API (production): set STORES_DB_CLUSTER_ARN and STORES_DB_SECRET_ARN (outputs of the
    Terraform stack 6_deploy/infra/agentcore-backends; setup_env.sh exports them). HTTPS + IAM,
    so no network path to the cluster is needed.
  - MySQL driver (legacy lab): discovers a cluster named spbc-aurora-cluster* and reads the
    spbc-aurora-db-credentials secret. Needs a network path to the cluster.
"""
import os
import re
import json
import time
import codecs
import traceback
from datetime import timedelta

import pymysql
import boto3
from botocore.exceptions import BotoCoreError, ClientError
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error

from model_config import REGION, MODEL_ID, MODEL_ARN  # pylint: disable=import-error

STORES_KNOWLEDGE_BASE_ID = os.environ.get("STORES_KNOWLEDGE_BASE_ID", "")

DB_NAME = os.environ.get("STORES_DB_NAME", "").strip() or "StoresDB"
DB_CLUSTER_ARN = os.environ.get("STORES_DB_CLUSTER_ARN", "").strip()
DB_SECRET_ARN = os.environ.get("STORES_DB_SECRET_ARN", "").strip()
USE_DATA_API = bool(DB_CLUSTER_ARN and DB_SECRET_ARN)

# Legacy discovery
DB_CLUSTER_PREFIX = "spbc-aurora-cluster"
DB_SECRET_ID = "spbc-aurora-db-credentials"

# Errors a tool turns into an {"error": ...} result instead of failing the whole turn
_DB_ERRORS = (RuntimeError, ValueError, pymysql.MySQLError, ClientError, BotoCoreError)

bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)
_rds_data = boto3.client('rds-data', region_name=REGION) if USE_DATA_API else None

print(f"Stores data source: {'RDS Data API' if USE_DATA_API else 'MySQL driver (legacy discovery)'}")


# ── RDS Data API ──────────────────────────────────────────────────────────────

def _data_api_rows(sql: str, params: dict) -> list:
    """Run a read-only statement through the Data API and return rows as dicts."""
    parameters = [{"name": k, "value": {"stringValue": str(v)}} for k, v in params.items()]
    kwargs = {"resourceArn": DB_CLUSTER_ARN, "secretArn": DB_SECRET_ARN,
              "database": DB_NAME, "sql": sql, "formatRecordsAs": "JSON"}
    if parameters:
        kwargs["parameters"] = parameters
    delays = [2, 5, 10]
    while True:
        try:
            response = _rds_data.execute_statement(**kwargs)
            return json.loads(response.get("formattedRecords") or "[]")
        except ClientError as e:
            # A paused Serverless v2 cluster answers with DatabaseResumingException for ~15 s
            if e.response["Error"]["Code"] == "DatabaseResumingException" and delays:
                time.sleep(delays.pop(0))
                continue
            raise


# ── MySQL driver (legacy) ─────────────────────────────────────────────────────

def _get_aurora_host() -> str:
    """Resolve Aurora cluster endpoint at call time (not at import time)."""
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
    return host


def _get_db_credentials() -> tuple:
    """Fetch DB credentials from Secrets Manager at call time, so a rotated password is picked up."""
    secrets_client = boto3.client('secretsmanager', region_name=REGION)
    secret_value = secrets_client.get_secret_value(SecretId=DB_SECRET_ID)
    raw = secret_value['SecretString']
    clean = codecs.decode(raw, 'unicode_escape')
    credentials = json.loads(clean)
    return credentials['username'], credentials['password']


def get_conn():
    """Open a fresh DB connection, resolving host and credentials on demand."""
    try:
        host = _get_aurora_host()
        db_user, db_pass = _get_db_credentials()
        conn = pymysql.connect(
            host=host,
            user=db_user,
            password=db_pass,
            database=DB_NAME,
            connect_timeout=5
        )
        return conn
    except Exception as e:  # pylint: disable=broad-except
        traceback.print_exc()
        raise RuntimeError(f"Failed to connect to database: {str(e)}") from e


def _query(sql: str, params=()) -> tuple:
    """Run a read-only query and always close the connection (no leaked Aurora connections)."""
    conn = get_conn()
    try:
        with conn.cursor() as cursor:
            cursor.execute(sql, params)
            rows = cursor.fetchall()
            columns = [col[0] for col in cursor.description]
        return rows, columns
    finally:
        conn.close()


def serialize_row(row, columns):
    """Serialize a DB row, converting timedelta to string."""
    def serialize(value):
        return str(value) if isinstance(value, timedelta) else value
    return dict(zip(columns, [serialize(v) for v in row]))


def _driver_rows(sql: str, params: dict) -> list:
    """Run a statement written with :name parameters through pymysql."""
    driver_sql = re.sub(r":(\w+)", r"%(\1)s", sql)  # :name -> %(name)s
    rows, columns = _query(driver_sql, params)
    return [serialize_row(row, columns) for row in rows]


def _rows(sql: str, params: dict = None) -> list:
    """Query the stores table with named (:name) parameters via the configured access path."""
    params = params or {}
    return _data_api_rows(sql, params) if USE_DATA_API else _driver_rows(sql, params)


# Must match the table created by 2_data_strategy/stores/ (load_stores_data_api.py or
# stores_load_helper_script.py).
_STORE_COLUMNS = (
    "store_id, name, address, city, state, zip_code, "
    "latitude, longitude, has_drive_thru, hours_start, hours_end"
)


@tool(name="stores_kb_retrieve",
      description="A tool to retrieve data from the bakery stores knowledge base")
def stores_kb_retrieve(query: str) -> str:
    """Search the stores knowledge base using retrieve_and_generate."""
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
        return response.get("output", {}).get(
            "text", "No relevant information found in the knowledge base.")
    except Exception as e:  # pylint: disable=broad-except
        traceback.print_exc()
        return f"Failed to retrieve information: {str(e)}"


@tool(name="list_stores", description="A tool to retrieve the list of all bakery locations")
def list_stores(query: str = "") -> list:  # pylint: disable=unused-argument
    """Return all store locations from the database."""
    try:
        return _rows(f"SELECT {_STORE_COLUMNS} FROM stores")
    except _DB_ERRORS as e:
        traceback.print_exc()
        return [{"error": str(e)}]


@tool(name="get_store_by_id", description="A tool to find a bakery location by its store ID")
def get_store_by_id(store_id: str) -> dict:
    """Return a single store record by store ID."""
    try:
        stores = _rows(f"SELECT {_STORE_COLUMNS} FROM stores WHERE store_id = :store_id",
                       {"store_id": store_id})
        if not stores:
            return {"message": "Store not found"}
        return stores[0]
    except _DB_ERRORS as e:
        traceback.print_exc()
        return {"error": str(e)}


@tool(name="search_store_by_name",
      description="A tool to find a bakery location by name or city")
def search_store_by_name(name: str) -> list:
    """Search stores by partial name or city match."""
    try:
        pattern = f"%{name}%"
        return _rows(
            f"SELECT {_STORE_COLUMNS} FROM stores "
            "WHERE name LIKE :name_pattern OR city LIKE :city_pattern",
            {"name_pattern": pattern, "city_pattern": pattern},
        )
    except _DB_ERRORS as e:
        traceback.print_exc()
        return [{"error": str(e)}]


stores_agent = Agent(
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt="""
        - You are 'Stores Assistant' for Specialty Bakeries & Pastry Cafés, an expert in
          our bakery locations and store policies.
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentence answers only. Be brief.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if it is about a bakery location or store policy.
        - For queries not related to stores or locations, respond with 'Sorry, I cannot answer this question'.
        - For store or location queries, use: list_stores, get_store_by_id, or search_store_by_name.
        - Only if necessary and after trying all other tools, use stores_kb_retrieve for policy questions.
        - If nothing relevant is found, ask clarifying questions or refer to support.
    """,
    tools=[stores_kb_retrieve, list_stores, get_store_by_id, search_store_by_name],
)

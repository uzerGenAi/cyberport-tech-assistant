"""Script to load store data into Aurora MySQL database."""

import codecs
import json
import os
import sys

import boto3
import pymysql
from tabulate import tabulate

# Check for display-only mode (data already pre-loaded during bootstrap)
display_only = '--display-only' in sys.argv

if display_only:
    # Data pre-loaded during bootstrap — display directly from local JSON
    # without making any AWS API calls or DB connections
    with open("stores_records.json", encoding="utf-8") as f:
        stores = json.load(f)
    rows = [
        (s["store_id"], s["name"], s["address"], s["city"], s["state"],
         s["zip_code"], s["latitude"], s["longitude"], s["has_drive_thru"],
         s["hours_start"], s["hours_end"])
        for s in stores[:10]
    ]
    headers = ["store_id", "name", "address", "city", "state", "zip_code",
               "latitude", "longitude", "has_drive_thru", "hours_start", "hours_end"]
    print(tabulate(rows, headers=headers, tablefmt="grid"))
    print("Data load complete.")
    sys.exit(0)

# Get resource names from environment variables
db_cluster_name = os.environ.get('DB_CLUSTER_NAME')
db_secret_name = os.environ.get('DB_SECRET_NAME')

# Fallback to discovery if environment variables not set
if not db_cluster_name:
    print("Warning: DB_CLUSTER_NAME not set, trying to discover cluster...")
    rds = boto3.client('rds')
    clusters = rds.describe_db_clusters()
    
    # Find the cluster with error handling - try multiple possible names
    possible_prefixes = [
        'spbc-aurora-cluster',
        'pastrycafe-aurora-cluster',
        'test-aurora-cluster'
    ]
    
    matching_clusters = []
    for prefix in possible_prefixes:
        matching_clusters = [
            c for c in clusters['DBClusters']
            if c['DBClusterIdentifier'].startswith(prefix)
        ]
        if matching_clusters:
            break
    
    if not matching_clusters:
        print("Error: No DB cluster found with expected identifiers")
        print("Available clusters:")
        for cluster in clusters['DBClusters']:
            print(f"  - {cluster['DBClusterIdentifier']}")
        sys.exit(1)
    
    db_cluster_name = matching_clusters[0]['DBClusterIdentifier']
    host = matching_clusters[0]['Endpoint']
else:
    # Use environment variable to get cluster info
    rds = boto3.client('rds')
    try:
        cluster_info = rds.describe_db_clusters(DBClusterIdentifier=db_cluster_name)
        host = cluster_info['DBClusters'][0]['Endpoint']
    except Exception as e:
        print(f"Error: Could not find cluster {db_cluster_name}: {e}")
        sys.exit(1)

print(f"Using DB cluster: {db_cluster_name}")

# Fetch DB credentials from Secrets Manager
if not db_secret_name:
    print("Warning: DB_SECRET_NAME not set, trying to discover secret...")
    secrets_client = boto3.client('secretsmanager')
    
    # Try to find the secret by name pattern
    try:
        secrets_client.describe_secret(SecretId='spbc-aurora-db-credentials')
        db_secret_name = 'spbc-aurora-db-credentials'
        print(f"Found secret: {db_secret_name}")
    except secrets_client.exceptions.ResourceNotFoundException:
        print("Error: Database credentials secret 'spbc-aurora-db-credentials' not found")
        sys.exit(1)
    except Exception as e:
        print(f"Error checking secret: {e}")
        sys.exit(1)
else:
    secrets_client = boto3.client('secretsmanager')

try:
    secret_value = secrets_client.get_secret_value(SecretId=db_secret_name)
except Exception as e:
    print(f"Error accessing secret {db_secret_name}: {e}")
    sys.exit(1)

raw = secret_value['SecretString']
clean = codecs.decode(raw, 'unicode_escape')
credentials = json.loads(clean)

db_user = credentials['username']
db_pass = credentials['password']

# Connect to DB
conn = pymysql.connect(
    host=host,
    user=db_user,
    password=db_pass,
    connect_timeout=5
)

# Create DB and table
with conn.cursor() as cur:
    cur.execute("CREATE DATABASE IF NOT EXISTS StoresDB")
    conn.select_db("StoresDB")
    cur.execute("""
        CREATE TABLE IF NOT EXISTS stores (
            store_id VARCHAR(50) PRIMARY KEY,
            name VARCHAR(100),
            address VARCHAR(200),
            city VARCHAR(100),
            state VARCHAR(50),
            zip_code VARCHAR(20),
            latitude FLOAT,
            longitude FLOAT,
            has_drive_thru BOOLEAN,
            hours_start TIME,
            hours_end TIME
        )
    """)
    conn.commit()

# Load JSON and insert records
with open("stores_records.json", encoding="utf-8") as f:
    stores = json.load(f)

QUERY = """
INSERT INTO stores (
    store_id, name, address, city, state, zip_code,
    latitude, longitude, has_drive_thru, hours_start, hours_end
) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON DUPLICATE KEY UPDATE name=VALUES(name)
"""
with conn:
    with conn.cursor() as cur:
        for s in stores:
            cur.execute(QUERY, (
                s["store_id"],
                s["name"],
                s["address"],
                s["city"],
                s["state"],
                s["zip_code"],
                s["latitude"],
                s["longitude"],
                s["has_drive_thru"],
                s["hours_start"],
                s["hours_end"]
            ))
        conn.commit()

    with conn.cursor() as cur:
        cur.execute("SELECT * FROM stores LIMIT 10")
        rows = cur.fetchall()
        headers = [desc[0] for desc in cur.description]
        print(tabulate(rows, headers=headers, tablefmt="grid"))

print("Data load complete.")
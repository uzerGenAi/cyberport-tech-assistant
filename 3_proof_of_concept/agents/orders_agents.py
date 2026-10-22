"""Orders agent for Specialty Bakeries & Pastry Cafés — order queries and operations."""
import json
import os
import re
import time
import uuid
from datetime import datetime

import boto3
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error

from model_config import REGION, MODEL_ID, MODEL_ARN  # pylint: disable=import-error

ORDERS_KNOWLEDGE_BASE_ID = os.environ.get("ORDERS_KNOWLEDGE_BASE_ID", "")

table = boto3.resource("dynamodb", region_name=REGION).Table("spbc-orders-table")
bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)


@tool(name="orders_kb_retrieve",
      description="A tool to retrieve data from the orders knowledge base")
def orders_kb_retrieve(query: str) -> str:
    """Search the orders knowledge base using retrieve_and_generate."""
    params = {
        "input": {"text": query},
        "retrieveAndGenerateConfiguration": {
            "type": "KNOWLEDGE_BASE",
            "knowledgeBaseConfiguration": {
                "knowledgeBaseId": ORDERS_KNOWLEDGE_BASE_ID,
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
    except (KeyError, ValueError, ConnectionError) as e:
        return f"Failed to retrieve information: {str(e)}"


@tool(name="get_recent_order",
      description="A tool to retrieve data about an existing order for a customer")
def get_recent_order(user_id: str) -> dict:
    """Retrieve the most recent order for a given user ID."""
    resp = table.query(
        KeyConditionExpression="user_id = :uid",
        ExpressionAttributeValues={":uid": user_id},
        ScanIndexForward=False,
        Limit=1
    )
    if not (items := resp.get("Items", [])):
        return {"message": "No recent order found."}
    o = items[0]
    return {
        "order_id": o.get("order_id", ""),
        "status": o.get("status", ""),
        "items": json.loads(o.get("items", "[]")),
        "total_amount": float(o.get("total_amount", 0))
    }


def _get_menu_data():
    """Helper to retrieve bakery menu data from S3."""
    bucket = os.environ.get("CLOUDAGE_S3_BUCKET", os.environ.get("S3_BUCKET_NAME", ""))
    key = "menu/menu_records.json"
    s3 = boto3.client("s3", region_name=REGION)
    data = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
    return json.loads(data)


def _get_month_name(month_num):
    """Return month name from number."""
    month_names = {
        1: "January", 2: "February", 3: "March", 4: "April",
        5: "May", 6: "June", 7: "July", 8: "August",
        9: "September", 10: "October", 11: "November", 12: "December"
    }
    return month_names[month_num]


@tool(name="validate_seasonal_items",
      description="Validate if seasonal bakery items in the order are currently available")
def validate_seasonal_items(items: list) -> dict:
    """Check if all seasonal items in the order are currently available."""
    try:
        menu_data = _get_menu_data()
        current_month = datetime.now().month
        unavailable_items = []

        for order_item in items:
            item_name = order_item.get("name", "").lower()
            for menu_item in menu_data:
                if menu_item["name"].lower() == item_name:
                    attrs = menu_item.get("attributes_json", {})
                    if attrs.get("seasonal", False):
                        season_months = attrs.get("season_months", [])
                        if current_month not in season_months:
                            next_months = [m for m in season_months if m > current_month]
                            next_month = (min(next_months) if next_months
                                          else min(season_months))
                            unavailable_items.append({
                                "name": menu_item["name"],
                                "available_in": _get_month_name(next_month)
                            })
                    break

        if unavailable_items:
            return {
                "valid": False,
                "unavailable_items": unavailable_items,
                "message": "Some seasonal items are not currently available"
            }
        return {"valid": True, "message": "All items are available"}
    except (KeyError, ValueError, ConnectionError) as e:
        return {"valid": False, "message": f"Unable to validate seasonal items: {str(e)}"}


@tool(name="process_order", description="Process a new bakery order from order details string")
def process_order(order_details: str) -> dict:
    """Process a new order from a natural-language order details string."""
    try:
        name_match = re.search(r'(?:for|customer:?)\s+([A-Za-z]+)', order_details, re.IGNORECASE)
        customer_name = name_match.group(1) if name_match else f"customer_{int(time.time())}"

        amount_match = re.search(r'[€$]?(\d+\.?\d*)', order_details)
        total_amount = float(amount_match.group(1)) if amount_match else 5.00

        items = [{"name": "Order Item", "details": order_details}]
        return place_order(customer_name, "SPBC-STORE-001", items, total_amount)
    except (ValueError, AttributeError) as e:
        return {"message": f"Error processing order: {str(e)}. Please provide order details clearly."}


@tool(name="place_order", description="A tool to place new bakery orders")
def place_order(user_id: str, store_id: str, items: list, total_amount: float) -> dict:
    """Place a new order after validating seasonal item availability."""
    try:
        validation = validate_seasonal_items(items)
        if not validation.get("valid", False):
            unavailable = validation.get("unavailable_items", [])
            if unavailable:
                unavailable_list = ", ".join(
                    [f"{item['name']} (available in {item['available_in']})"
                     for item in unavailable])
                return {
                    "message": (
                        f"Sorry, these seasonal items are not currently available: "
                        f"{unavailable_list}. Please modify your order or wait until "
                        "they return to our menu."
                    )
                }

        order_id = str(uuid.uuid4())
        ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
        table.put_item(Item={
            "user_id": str(user_id),
            "order_timestamp": ts,
            "order_id": order_id,
            "status": "Placed",
            "items": json.dumps(items),
            "store_id": str(store_id),
            "total_amount": str(total_amount)
        })
    except (ValueError, ConnectionError, KeyError) as e:
        return {"message": f"Error placing order: {str(e)}. Please try again or contact support."}

    return {
        "message": (
            f"Order placed successfully with ID: {order_id}. "
            "Your order will be prepared fresh. Please collect from the counter "
            "when your name or number is called!"
        )
    }


orders_agent = Agent(
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt="""
        - You are 'Orders Assistant' for Specialty Bakeries & Pastry Cafés, an expert in checking
          order status, placing new orders, and answering questions about orders.
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentences answers only. Be brief.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about a bakery order.
        - For queries not related to orders, respond with 'Sorry, I cannot answer this question'.
        - For existing order queries, use the get_recent_order tool. Ask the customer for their
          name or order reference if needed.
        - For new order requests, use the process_order tool with the order details string.
        - IMPORTANT: Seasonal pastries are only available during specific months. If a customer
          tries to order a seasonal item that is not currently available, inform them when it will return.
        - For user_id: accept any string identifier (Pastry Rewards ID, name, or generated ID).
          Use store_id "SPBC-STORE-001" as default.
        - Only if a query cannot be answered using the above tools, search the orders knowledge base
          using orders_kb_retrieve.
        - If nothing relevant is found, ask clarifying questions or refer to support.
    """,
    tools=[orders_kb_retrieve, get_recent_order, place_order, validate_seasonal_items, process_order],
)

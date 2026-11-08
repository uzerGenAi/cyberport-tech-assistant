"""Orders agent for the Cyberport Tech Assistant — order status, click & collect orders, policies."""
import json
import os
import re
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Attr, Key
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error

from model_config import REGION, MODEL_ID, MODEL_ARN  # pylint: disable=import-error
import menu_agents  # pylint: disable=import-error

ORDERS_KNOWLEDGE_BASE_ID = os.environ.get("ORDERS_KNOWLEDGE_BASE_ID", "")

table = boto3.resource("dynamodb", region_name=REGION).Table("spbc-orders-table")
bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)

_STORE_ID = re.compile(r"^spbc-(de|at)-\d{3}$")


@tool(name="orders_kb_retrieve",
      description="A tool to retrieve order, delivery, returns and warranty policies from the orders knowledge base")
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


@tool(name="get_order_status",
      description=("A tool to look up one existing order. Requires both the customer's name or "
                   "customer ID (user_id) and the order ID."))
def get_order_status(user_id: str, order_id: str) -> dict:
    """Return one order only when the order ID belongs to the given user_id."""
    user_id, order_id = str(user_id).strip(), str(order_id).strip()
    if not user_id or not order_id:
        return {"message": "Both the customer name or ID and the order ID are required."}
    query = {"KeyConditionExpression": Key("user_id").eq(user_id),
             "FilterExpression": Attr("order_id").eq(order_id)}
    while True:
        resp = table.query(**query)
        items = resp.get("Items", [])
        if items or "LastEvaluatedKey" not in resp:
            break
        query["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    if not items:
        # Same answer whether the user or the order is unknown: no account enumeration.
        return {"message": "No order found for that customer and order ID."}
    o = items[0]
    return {
        "order_id": o.get("order_id", ""),
        "order_date": o.get("order_timestamp", ""),
        "status": o.get("status", ""),
        "fulfilment": o.get("fulfilment", ""),
        "store_id": o.get("store_id", ""),
        "items": json.loads(o.get("items", "[]")),
        "total_amount": float(o.get("total_amount", 0))
    }


@tool(name="place_order",
      description=("A tool to place a new click & collect order. Input: user_id (customer name or "
                   "ID), store_id (for example 'spbc-de-001') and items (each with 'item', "
                   "'quantity' and, for smartphones, 'variant'). The total is calculated by this "
                   "tool from the catalog."))
def place_order(user_id: str, store_id: str, items: list) -> dict:
    """Place a click & collect order, priced from the catalog rather than by the model."""
    user_id, store_id = str(user_id).strip(), str(store_id).strip().lower()
    if not user_id:
        return {"message": "A customer name or customer ID is required."}
    if not _STORE_ID.match(store_id):
        return {"message": f"Unknown store_id '{store_id}'. Look up the store ID first, "
                           "for example 'spbc-de-001'."}
    pricing = menu_agents.price_items(items)
    if "error" in pricing:
        return {"message": f"Could not price the order: {pricing['error']}"}
    if pricing.get("unpriced"):
        return {"message": "The order was not placed because some items could not be priced: "
                           f"{json.dumps(pricing['unpriced'])}. Please clarify them."}
    try:
        order_id = f"ord_{uuid.uuid4().hex[:12]}"
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        table.put_item(Item={
            "user_id": user_id,
            "order_timestamp": ts,
            "order_id": order_id,
            "status": "PROCESSING",
            "items": json.dumps(pricing["line_items"]),
            "store_id": store_id,
            "fulfilment": "click_and_collect",
            "total_amount": Decimal(str(pricing["total_amount"]))
        })
    except (ValueError, ConnectionError, KeyError) as e:
        return {"message": f"Error placing order: {str(e)}. Please try again or contact support."}

    return {
        "message": (
            f"Order placed successfully with ID: {order_id}. Total: {pricing['total_cost']}. "
            f"Collect it at store {store_id} when the status is READY_FOR_PICKUP."
        )
    }


orders_agent = Agent(
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt="""
        - You are 'Orders Assistant' for the Cyberport Tech Assistant, an expert in checking
          order status, placing new click & collect orders, and answering questions about
          delivery, cancellation, returns and warranty.
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentences answers only. Be brief.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about an order, delivery, returns or warranty.
        - For queries not related to orders, respond with 'Sorry, I cannot answer this question'.
        - For existing orders, use the get_order_status tool. It needs BOTH the customer's name or
          customer ID and the order ID; ask for whichever is missing. Never guess them.
        - For new orders, use the place_order tool with the customer name or ID, the store_id and
          the items. Use store_id "spbc-de-001" only if the customer has no preference. Report the
          order ID and the total the tool returns.
        - For policy questions (cancellation, delivery, returns, the 14-day withdrawal right,
          warranty), search the orders knowledge base using orders_kb_retrieve.
        - If nothing relevant is found, ask clarifying questions or refer to support.
    """,
    tools=[orders_kb_retrieve, get_order_status, place_order],
)

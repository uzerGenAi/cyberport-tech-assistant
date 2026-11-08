import os
import json
import boto3
import place_order
from boto3.dynamodb.conditions import Attr, Key
from strands import Agent, tool
from strands.models import BedrockModel

ORDERS_KNOWLEDGE_BASE_ID = os.environ["ORDERS_KNOWLEDGE_BASE_ID"]
REGION = os.environ["REGION"]
MODEL_ARN = os.environ["MODEL_ARN"]

table = boto3.resource("dynamodb", region_name=REGION).Table("spbc-orders-table")
bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)

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
        return response.get("output", {}).get("text", "No relevant information found in the knowledge base.")
    except (KeyError, ValueError, ConnectionError) as e:
        return f"Failed to retrieve information: {str(e)}"

@tool(name="get_order_status",
      description=("A tool to look up one existing order. Requires both the customer's name or "
                   "customer ID (user_id) and the order ID."))
def get_order_status(user_id: str, order_id: str) -> dict:
    """Return one order, only when the order ID belongs to the given user_id.

    Requiring both values (like order tracking with an order number plus surname) stops
    anyone from reading another customer's latest order just by typing their name.
    """
    user_id, order_id = str(user_id).strip(), str(order_id).strip()
    if not user_id or not order_id:
        return {"message": "Both the customer name or ID and the order ID are required."}
    try:
        query = {
            "KeyConditionExpression": Key("user_id").eq(user_id),
            "FilterExpression": Attr("order_id").eq(order_id),
        }
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
    except (KeyError, ValueError) as e:
        return {"error": str(e)}

orders_agent = Agent(
    model=BedrockModel(model_id=os.environ["MODEL_ID"], region_name=REGION),
    system_prompt="""
        - You are 'Orders Assistant' for the Cyberport Tech Assistant, an expert in checking order status, placing new click & collect orders, and answering questions about delivery, cancellation, returns and warranty.
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentences answers only. Be brief.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about an order, delivery, returns or warranty.
        - For queries not related to orders, respond with 'Sorry, I cannot answer this question'.
        - For existing orders, use get_order_status. It needs BOTH the customer's name or customer ID and the order ID; if either is missing, ask for it. Never guess or reuse another customer's details.
        - For new orders, use the place_order tool with the customer name or ID, the store_id and the items (product, quantity, and storage variant for smartphones). The tool calculates the total; report the order ID and the total it returns.
        - For policy questions (cancellation, delivery times, returns, the 14-day withdrawal right, warranty, damaged deliveries), search the knowledge base using orders_kb_retrieve.
        - If nothing relevant is found, ask clarifying questions or refer to customer service.
    """,
    tools=[orders_kb_retrieve, get_order_status, place_order],
)

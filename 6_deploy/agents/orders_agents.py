import os
import json
import boto3
import place_order
from boto3.dynamodb.conditions import Key
from strands import Agent, tool
from strands.models import BedrockModel

ORDERS_KNOWLEDGE_BASE_ID = os.environ["ORDERS_KNOWLEDGE_BASE_ID"]
REGION = os.environ["REGION"]
MODEL_ARN = os.environ["MODEL_ARN"]

table = boto3.resource("dynamodb", region_name=REGION).Table("spbc-orders-table")
bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)

@tool(name="orders_kb_retrieve", description="A tool to retrieve data from orders knowledge base")
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

@tool(name="get_recent_order", description="A tool to retrieve data about existing orders")
def get_recent_order(user_id: str) -> dict:
    """Retrieve the most recent order for a given user_id."""
    try:
        resp = table.query(
            KeyConditionExpression=Key("user_id").eq(user_id),
            ScanIndexForward=False,
            Limit=1
        )
        items = resp.get("Items", [])
        if not items:
            return {"message": "No recent order found."}
        o = items[0]
        return {
            "order_id": o.get("order_id", ""),
            "status": o.get("status", ""),
            "items": json.loads(o.get("items", "[]")),
            "total_amount": float(o.get("total_amount", 0))
        }
    except (KeyError, ValueError) as e:
        return {"error": str(e)}

orders_agent = Agent(
    model=BedrockModel(model_id=os.environ["MODEL_ID"], region_name=REGION),
    system_prompt="""
        - You are 'Orders Assistant' for Specialty Bakeries & Pastry Cafés, an expert in checking order status, placing new orders and answering questions about orders.
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentences answers only. Be brief.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about a bakery order.
        - For queries not related to orders, respond with 'Sorry, I cannot answer this question'.
        - For existing order related queries, fetch the order using the get_recent_order tool. Ask the user for their user_id if needed.
        - For new order related queries, use the place_order tool to place new orders.
        - Only if the query cannot be answered using get_recent_order or place_order, search the knowledge base using orders_kb_retrieve.
        - If nothing relevant is found, ask clarifying questions or refer to contact support.
    """,
    tools=[orders_kb_retrieve, get_recent_order, place_order],
)

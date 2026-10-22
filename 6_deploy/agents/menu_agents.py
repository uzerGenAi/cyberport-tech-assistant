# menu_agents.py — Specialty Bakeries & Pastry Cafés
import os
import json
import boto3
from strands import Agent, tool
from strands.models import BedrockModel

MENU_KNOWLEDGE_BASE_ID = os.environ["MENU_KNOWLEDGE_BASE_ID"]
REGION = os.environ["REGION"]
MODEL_ARN = os.environ["MODEL_ARN"]

bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)

# === Tools ===
@tool(name="menu_kb_retrieve", description="A tool to retrieve data from the bakery menu knowledge base")
def menu_kb_retrieve(query: str) -> str:
    """Search the menu knowledge base using retrieve_and_generate."""
    params = {
        "input": {"text": query},
        "retrieveAndGenerateConfiguration": {
          "type": "KNOWLEDGE_BASE",
          "knowledgeBaseConfiguration": {
              "knowledgeBaseId": MENU_KNOWLEDGE_BASE_ID,
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
    except Exception as e:
        return f"Failed to retrieve information: {str(e)}"

@tool(name="get_menu")
def get_menu() -> dict:
    """Fetch menu JSON from S3 and return as parsed object."""
    bucket = os.environ["S3_BUCKET_NAME"]
    key = "menu/menu_records.json"
    s3 = boto3.client("s3", region_name=REGION)
    data = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
    return json.loads(data)

@tool(
    name="calculate_order_total",
    description=(
        "Calculate total cost in EUR based on bakery pricing rules. "
        "Expected input: items: [{\"type\": \"coffee|pastry|bread|cake\", "
        "\"size\": \"small|medium|large\", \"customizations\": [\"oat_milk\", \"extra_shot\"]}]"
    ),
)
def calculate_order_total(items: list) -> dict:
    """
    Calculate total cost in EUR based on bakery pricing rules:
    - Coffee: €2.80 (small), €3.50 (medium), €4.20 (large) + €0.30 per customisation
    - Pastry (croissant, éclair, macaron, etc.): €2.50 each
    - Bread / loaf: €4.50 each
    - Cake slice: €5.50 each
    """
    print(items)
    try:
        total_cost = 0.0
        for item in items:
            item_type = item.get("type", "").lower()
            if item_type == "coffee":
                base_price = {"small": 2.80, "medium": 3.50, "large": 4.20}.get(
                    item.get("size", "medium").lower(), 3.50
                )
                customisation_cost = len(item.get("customizations", [])) * 0.30
                total_cost += base_price + customisation_cost
            elif item_type == "pastry":
                total_cost += 2.50
            elif item_type == "bread":
                total_cost += 4.50
            elif item_type == "cake":
                total_cost += 5.50
        return {"total_cost": f"€{total_cost:.2f}"}
    except (KeyError, TypeError, ValueError) as e:
        return {"error": str(e)}

# === Agent Definition ===

menu_agent = Agent(
    model=BedrockModel(model_id=os.environ["MODEL_ID"], region_name=REGION),
    system_prompt="""
        - You are 'Menu Assistant' for Specialty Bakeries & Pastry Cafés.
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentences answers only.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about the bakery menu.
        - For queries not related to the menu, respond with 'Sorry, I cannot answer this question'.
        - For menu-related queries, first fetch S3 menu data using the get_menu tool.
        - For pricing related queries, use the calculate_order_total tool. All prices are in EUR (€).
        - Only for menu-related queries that cannot be answered from S3 menu data, check the knowledge base using menu_kb_retrieve.
        - If nothing relevant is found using either tool, ask clarifying questions or refer to contact support.
        """,
    tools=[menu_kb_retrieve, get_menu, calculate_order_total],
)
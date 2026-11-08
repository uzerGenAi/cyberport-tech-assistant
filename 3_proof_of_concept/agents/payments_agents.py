"""Payments agent for the Cyberport Tech Assistant — order totals, payment and financing policies."""
import os
import json
import boto3
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error
from strands_tools import calculator  # pylint: disable=import-error

from model_config import REGION, MODEL_ID, MODEL_ARN  # pylint: disable=import-error
import menu_agents  # pylint: disable=import-error

PAYMENTS_KNOWLEDGE_BASE_ID = os.environ.get("PAYMENTS_KNOWLEDGE_BASE_ID", "")

bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)


# === Tools ===
@tool(name="payments_kb_retrieve",
      description="A tool to retrieve payment, financing, refund and invoice policies from the payments knowledge base")
def payments_kb_retrieve(query: str) -> str:
    """Search the payments knowledge base using retrieve_and_generate."""
    params = {
        "input": {"text": query},
        "retrieveAndGenerateConfiguration": {
            "type": "KNOWLEDGE_BASE",
            "knowledgeBaseConfiguration": {
                "knowledgeBaseId": PAYMENTS_KNOWLEDGE_BASE_ID,
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


@tool(
    name="calculate_order_total",
    description=(
        "Calculate the total cost of an order in EUR from the product catalog. "
        "Expected input: items list with each item having 'item' (product name or item_id), "
        "optional 'quantity', and for smartphones an optional 'variant' (storage size, "
        "for example '128GB'). Returns a per-line breakdown and any items it could not price."
    )
)
def calculate_order_total(items: list) -> dict:
    """Price an order from the catalog (menu_agents.price_items), never from a hard-coded table."""
    return menu_agents.price_items(items)


# === Agent ===
payments_agent = Agent(
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt="""
        - You are 'Payments Assistant' for the Cyberport Tech Assistant, an expert in
          calculating order totals and answering questions about payment methods, 0% financing,
          refunds, invoices and gift cards.
        - All prices are in Euros (€).
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentences answers only.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about the cost of an order or about payments.
        - For queries not related to cost or payments, respond with 'Sorry, I cannot answer this question'.
        - For price calculation or order total questions, always use the calculate_order_total tool.
          If it reports unpriced items, ask the customer to clarify them instead of quoting a total.
        - For questions about payment methods, financing, refunds, invoices or gift cards, use the
          payments_kb_retrieve tool to check the knowledge base.
        - You may explain how financing works, but never tell a customer whether they will be
          approved or whether they should take credit.
        - Never ask for or repeat card numbers, CVV codes, PINs, passwords or IBANs.
        - If nothing relevant is found in the knowledge base, ask clarifying questions or refer to support.
        """,
    tools=[payments_kb_retrieve, calculator, calculate_order_total],
)

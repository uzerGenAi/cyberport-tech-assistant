"""Payments agent for Specialty Bakeries & Pastry Cafés — pricing and payment policies."""
import os
import json
import boto3
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error
from strands_tools import calculator  # pylint: disable=import-error

from model_config import REGION, MODEL_ID, MODEL_ARN  # pylint: disable=import-error

PAYMENTS_KNOWLEDGE_BASE_ID = os.environ.get("PAYMENTS_KNOWLEDGE_BASE_ID", "")

bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)


# === Tools ===
@tool(name="payments_kb_retrieve",
      description="A tool to retrieve data from the payments and pricing knowledge base")
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
        "Calculate total cost of a bakery order. "
        "Expected input: items list with each item having "
        "'type' (item_id from menu), 'size' (where applicable), "
        "'customizations' list, and optional 'quantity'. "
        "All prices in EUR (€)."
    )
)
def calculate_order_total(items: list) -> dict:
    """
    Calculate total cost with bakery-specific pricing (all prices in EUR):

    Viennoiserie:
      croissant_plain / croissant_almond / pain_au_chocolat — single: €2.80, box_of_4: €10.50
    Breads:
      sourdough_loaf / brioche_loaf / rye_bread — half_loaf: €4.50, full_loaf: €8.50
    Patisserie:
      eclair_chocolate / eclair_vanilla — single: €4.20
      fruit_tart / lemon_tart — individual: €4.80, large_6inch: €18.00
      macaron_assorted — single: €2.50, box_of_6: €13.50, box_of_12: €25.00
    Cakes:
      opera_cake_slice / black_forest_slice — slice: €5.50
      custom_celebration_cake — 6inch: €45.00, 8inch: €65.00, 10inch: €90.00
    Savoury:
      quiche_lorraine — slice: €4.50, whole_8inch: €22.00
      spinach_feta_pastry — single: €3.80
    Coffee:
      espresso — single: €2.00, double: €3.00
      cappuccino / flat_white — small: €3.20, large: €4.00
      latte / filter_coffee — small: €3.00, medium: €3.80, large: €4.50
    Hot drinks:
      hot_chocolate / chai_latte / matcha_latte — small: €3.50, large: €4.50
    Seasonal:
      stollen_slice — slice: €3.80
      hot_cross_bun — single: €2.20, box_of_6: €11.00
      galette_des_rois — slice: €5.00, whole_8inch: €24.00
      strawberry_mille_feuille — individual: €5.80
      pumpkin_spice_brioche — single: €3.20, box_of_4: €11.50
    Milk customisation surcharge: €0.30 per drink
    """
    # Pricing tables (EUR)
    viennoiserie_prices = {
        "croissant_plain":   {"single": 2.80, "box_of_4": 10.50},
        "croissant_almond":  {"single": 3.20, "box_of_4": 12.00},
        "pain_au_chocolat":  {"single": 3.00, "box_of_4": 11.00},
    }
    bread_prices = {
        "sourdough_loaf": {"half_loaf": 4.50, "full_loaf": 8.50},
        "brioche_loaf":   {"half_loaf": 5.00, "full_loaf": 9.50},
        "rye_bread":      {"half_loaf": 4.00, "full_loaf": 7.50},
    }
    patisserie_prices = {
        "eclair_chocolate":  {"single": 4.20},
        "eclair_vanilla":    {"single": 4.20},
        "fruit_tart":        {"individual": 4.80, "large_6inch": 18.00},
        "lemon_tart":        {"individual": 4.80, "large_6inch": 18.00},
        "macaron_assorted":  {"single": 2.50, "box_of_6": 13.50, "box_of_12": 25.00},
    }
    cake_prices = {
        "opera_cake_slice":       {"slice": 5.50},
        "black_forest_slice":     {"slice": 5.50},
        "custom_celebration_cake": {"6inch": 45.00, "8inch": 65.00, "10inch": 90.00},
    }
    savoury_prices = {
        "quiche_lorraine":     {"slice": 4.50, "whole_8inch": 22.00},
        "spinach_feta_pastry": {"single": 3.80},
    }
    coffee_prices = {
        "espresso":     {"single": 2.00, "double": 3.00},
        "cappuccino":   {"small": 3.20, "large": 4.00},
        "flat_white":   {"small": 3.20, "large": 4.00},
        "latte":        {"small": 3.00, "medium": 3.80, "large": 4.50},
        "filter_coffee":{"small": 3.00, "medium": 3.80, "large": 4.50},
    }
    hot_drink_prices = {
        "hot_chocolate": {"small": 3.50, "large": 4.50},
        "chai_latte":    {"small": 3.50, "large": 4.50},
        "matcha_latte":  {"small": 3.50, "large": 4.50},
    }
    seasonal_prices = {
        "stollen_slice":            {"slice": 3.80},
        "hot_cross_bun":            {"single": 2.20, "box_of_6": 11.00},
        "galette_des_rois":         {"slice": 5.00, "whole_8inch": 24.00},
        "strawberry_mille_feuille": {"individual": 5.80},
        "pumpkin_spice_brioche":    {"single": 3.20, "box_of_4": 11.50},
    }

    all_prices = {
        **viennoiserie_prices,
        **bread_prices,
        **patisserie_prices,
        **cake_prices,
        **savoury_prices,
        **coffee_prices,
        **hot_drink_prices,
        **seasonal_prices,
    }

    MILK_CUSTOMISATION_SURCHARGE = 0.30
    DRINK_ITEMS = set(coffee_prices.keys()) | set(hot_drink_prices.keys())

    try:
        total_cost = 0.0
        for item in items:
            item_type = item.get("type", "").lower().replace(" ", "_")
            size = item.get("size", "single").lower()
            quantity = int(item.get("quantity", 1))
            customizations = item.get("customizations", [])

            if item_type not in all_prices:
                return {
                    "error": (
                        f"Item '{item.get('type')}' is not on our menu. "
                        "Please check with the menu assistant for available items."
                    )
                }

            size_prices = all_prices[item_type]
            if size not in size_prices:
                # Fall back to first available size
                size = next(iter(size_prices))

            base_price = size_prices[size]

            # Milk customisation surcharge for drinks
            milk_options = {'oat_milk', 'almond_milk', 'soy_milk',
                            'oat milk', 'almond milk', 'soy milk'}
            if item_type in DRINK_ITEMS:
                milk_surcharge = sum(
                    MILK_CUSTOMISATION_SURCHARGE
                    for c in customizations
                    if c.lower() in milk_options
                )
            else:
                milk_surcharge = 0.0

            item_total = (base_price + milk_surcharge) * quantity
            total_cost += item_total

        return {"total_cost": f"€{total_cost:.2f}"}
    except (KeyError, ValueError, TypeError) as e:
        return {"error": str(e)}


# === Agent ===
payments_agent = Agent(
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt="""
        - You are 'Payments Assistant' for Specialty Bakeries & Pastry Cafés, an expert in
          calculating order totals and answering payment policy questions.
        - All prices are in Euros (€).
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentences answers only.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about cost or payment for a bakery order.
        - For queries not related to cost or payments, respond with 'Sorry, I cannot answer this question'.
        - For price calculation or order total questions, always use the calculate_order_total tool.
        - For questions about payment methods, refunds, invoices, or catering payment, use the
          payments_kb_retrieve tool to check the knowledge base.
        - If nothing relevant is found in the knowledge base, ask clarifying questions or refer to support.
        """,
    tools=[payments_kb_retrieve, calculator, calculate_order_total],
)

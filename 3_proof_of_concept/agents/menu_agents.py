"""Product catalog agent for the Cyberport Tech Assistant — product questions, stock and pricing.

The "menu" name is kept from the original project layout: the S3 key (menu/menu_records.json)
and MENU_KNOWLEDGE_BASE_ID are unchanged; the content is the smartphone and laptop catalog.
price_items() is shared with the payments and orders agents, so every total is computed from
the catalog and never by the model.
"""
import json
import os
import re

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error

from model_config import REGION, MODEL_ID, MODEL_ARN  # pylint: disable=import-error

MENU_KNOWLEDGE_BASE_ID = os.environ.get("MENU_KNOWLEDGE_BASE_ID", "")

bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)


# === Tools ===
@tool(name="menu_kb_retrieve",
      description="A tool to retrieve buying advice from the product buying-guide knowledge base")
def menu_kb_retrieve(query: str) -> str:
    """Search the buying-guide knowledge base using retrieve_and_generate."""
    if not MENU_KNOWLEDGE_BASE_ID:
        return "Product knowledge base is not configured. Please contact support."

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
        return response.get("output", {}).get(
            "text", "No relevant information found in the knowledge base.")
    except (KeyError, ValueError, ConnectionError) as e:
        return f"Failed to retrieve information: {str(e)}"


def load_catalog() -> list:
    """Fetch the product catalog JSON from S3."""
    bucket = os.environ.get("CLOUDAGE_S3_BUCKET",
                            os.environ.get("S3_BUCKET_NAME", ""))
    key = "menu/menu_records.json"
    s3 = boto3.client("s3", region_name=REGION)
    data = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
    return json.loads(data)


@tool(name="get_menu",
      description="Fetch the full product catalog (smartphones and laptops) with prices, specs and stock")
def get_menu() -> list:
    """Fetch the product catalog JSON from S3 and return it as a parsed object."""
    return load_catalog()


# Variant (storage, colour) and filler words stripped before matching, so
# "a black iPhone 14 with 256GB" still resolves to "Apple iPhone 14".
_NOISE = {
    "a", "an", "the", "one", "some", "please", "new", "with", "and", "in", "of",
    "phone", "smartphone", "mobile", "laptop", "notebook", "gb", "tb", "storage",
    "black", "white", "blue", "gray", "grey", "green", "purple", "red", "pink", "silver",
    "gold", "yellow", "orange", "midnight", "starlight", "graphite", "platinum",
}
_STORAGE_IN_TEXT = re.compile(r"(\d+)\s?(GB|TB)\b", re.IGNORECASE)


def _norm(text) -> str:
    return "".join(ch for ch in str(text).lower() if ch.isalnum())


def _tokens(text) -> set:
    # Plain numbers are kept: in "iPhone 14" or "Galaxy S23" the number is the model.
    return {t for t in re.split(r"[^a-z0-9]+", str(text).lower())
            if t and t not in _NOISE and not re.match(r"^\d+(gb|tb)$", t)}


def find_product(catalog: list, requested: str):
    """Match a product by id or name: exact, then substring, then tokens.

    A request containing a full name picks the longest contained name ("iPhone 14 Pro Max 256GB"
    → Pro Max); a request that is part of names picks the shortest ("iPhone 14" → iPhone 14).
    """
    key = _norm(requested)
    if not key:
        return None
    for record in catalog:
        if key in (_norm(record.get("item_id", "")), _norm(record.get("name", ""))):
            return record
    names = [(record, _norm(record.get("name", ""))) for record in catalog]
    contained = [rn for rn in names if rn[1] and rn[1] in key]
    if contained:
        return max(contained, key=lambda rn: len(rn[1]))[0]
    containing = [rn for rn in names if rn[1] and key in rn[1]]
    if containing:
        return min(containing, key=lambda rn: len(rn[1]))[0]
    wanted = _tokens(requested)
    best, best_rank = None, (0, 0)
    for record in catalog:
        have = _tokens(record.get("name", "")) | _tokens(record.get("item_id", ""))
        if have and (have <= wanted or wanted <= have):
            rank = (len(have & wanted), -len(have - wanted))
            if rank[0] > 0 and (best is None or rank > best_rank):
                best, best_rank = record, rank
    return best


def _size_key(text) -> str:
    return re.sub(r"\s+", "", str(text)).upper()


def price_items(items: list, catalog: list | None = None) -> dict:
    """Price items from the catalog. Unknown products or variants are listed in 'unpriced'."""
    try:
        catalog = catalog if catalog is not None else load_catalog()
    except (BotoCoreError, ClientError, KeyError, ValueError) as e:
        return {"error": f"Could not load the catalog: {str(e)}"}
    if not isinstance(items, list) or not items:
        return {"error": "Provide a non-empty list of items to price."}

    lines, unpriced, total = [], [], 0.0
    for entry in items:
        entry = {"item": entry} if isinstance(entry, str) else entry
        if not isinstance(entry, dict):
            unpriced.append({"requested": str(entry), "reason": "unrecognised item format"})
            continue
        requested = entry.get("item") or entry.get("name") or entry.get("item_id") or entry.get("type", "")
        variant = entry.get("variant") or entry.get("size") or entry.get("storage")
        if not variant and (found := _STORAGE_IN_TEXT.search(str(requested))):
            variant = f"{found.group(1)}{found.group(2).upper()}"
        try:
            quantity = max(int(entry.get("quantity", 1)), 1)
        except (TypeError, ValueError):
            quantity = 1

        record = find_product(catalog, requested)
        if record is None:
            unpriced.append({"requested": requested, "reason": "not in the catalog"})
            continue
        by_size = record.get("prices_by_size_eur") or {}
        if by_size:
            if variant:
                match = next((k for k in by_size if _size_key(k) == _size_key(variant)), None)
                if match is None:
                    unpriced.append({"requested": f"{requested} {variant}",
                                     "reason": f"variant not available; available: {', '.join(by_size)}"})
                    continue
            else:
                match = min(by_size, key=lambda k: float(by_size[k]))   # the "from" price
            unit = float(by_size[match])
        else:
            match, unit = None, float(record["price_eur"])
        line_total = round(unit * quantity, 2)
        total += line_total
        line = {"item": record["name"], "item_id": record["item_id"], "quantity": quantity,
                "unit_price": f"€{unit:.2f}", "line_total": f"€{line_total:.2f}"}
        if match:
            line["variant"] = match
        lines.append(line)

    result = {"line_items": lines, "total_cost": f"€{total:.2f}", "total_amount": round(total, 2)}
    if unpriced:
        result["unpriced"] = unpriced
        result["note"] = ("Some items could not be priced and are excluded from the total. "
                          "Ask the customer to clarify these before confirming the order.")
    return result


@tool(name="check_store_stock",
      description=("Check whether a product is in stock. Input: item (product name or item_id) and, "
                   "optionally, store_id (for example 'spbc-de-001'). Without a store_id it lists "
                   "every store that has the product."))
def check_store_stock(item: str, store_id: str = "") -> dict:
    """Look up per-store stock for one product from the catalog's stock_by_store field."""
    try:
        record = find_product(load_catalog(), item)
    except (BotoCoreError, ClientError, KeyError, ValueError) as e:
        return {"error": f"Could not load the catalog: {str(e)}"}
    if record is None:
        return {"item": item, "error": "Product not found in the catalog."}
    stock = record.get("attributes_json", {}).get("stock_by_store", {})
    if store_id:
        units = int(stock.get(store_id.strip().lower(), 0))
        return {"item": record["name"], "store_id": store_id, "units_in_stock": units,
                "in_stock": units > 0}
    return {"item": record["name"], "stores_with_stock": stock}


# === Agent Definition ===
menu_agent = Agent(
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt="""
        - You are 'Product Expert' for the Cyberport Tech Assistant, an expert in our smartphone
          and laptop range: everyday, business, premium, gaming and refurbished laptops.
        - Always wrap your answer in <answer> tags.
        - Give 1-3 sentence answers only.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, determine if the question is about our products.
        - For queries not related to our products, respond with 'Sorry, I cannot answer this question'.
        - For product questions and recommendations, first fetch the catalog with the get_menu tool
          and compare products on their specs (cpu, ram_gb, storage, gpu, screen_inches, segment,
          condition). Recommend at most three products and say why each fits.
        - IMPORTANT: Only confirm a product can be ordered if it exists in the catalog. Smartphones
          have one price per storage size (prices_by_size_eur); name the sizes that exist.
        - For stock questions, use the check_store_stock tool with the store_id you were given.
        - Only for general buying advice the catalog cannot answer (for example how much RAM someone
          needs), use the menu_kb_retrieve tool to check the knowledge base.
        - If nothing relevant is found using any tool, clearly state the product is not in our range.
        """,
    tools=[menu_kb_retrieve, get_menu, check_store_stock],
)

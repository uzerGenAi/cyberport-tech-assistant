# menu_agents.py — Specialty Bakeries & Pastry Cafés
import os
import re
import json
import boto3
from botocore.exceptions import ClientError
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


# Each item in menu_records.json carries its own price_eur (and prices_by_size_eur
# where sizes differ). Pricing is per item, not per category, so the total reflects
# what the customer actually ordered. The menu is cached per warm invocation to
# avoid re-fetching from S3 for every line in a multi-item order.
_MENU_CACHE = None


def _load_priced_menu() -> list:
    global _MENU_CACHE
    if _MENU_CACHE is None:
        _MENU_CACHE = get_menu()
    return _MENU_CACHE


# Words customers attach to an item that describe a size/variant rather than the item
# itself ("a large latte", "espresso double"). Stripped before matching so "large latte"
# still resolves to "Café Latte". Common filler articles are dropped too.
_MATCH_NOISE_WORDS = {
    "small", "medium", "large", "single", "double", "half", "full", "slice", "whole",
    "individual", "box", "of", "loaf", "inch", "a", "an", "the", "one", "some", "please",
    "cafe", "caf",
}


def _normalise(text: str) -> str:
    return "".join(ch for ch in str(text).lower() if ch.isalnum())


def _match_tokens(text: str) -> set:
    """Significant word tokens of an item phrase, with size/variant/filler words removed."""
    raw = re.split(r"[^a-z0-9]+", str(text).lower())
    return {t for t in raw if t and t not in _MATCH_NOISE_WORDS and not t.isdigit()}


def _find_menu_item(menu: list, requested: str):
    """Match a requested item to a menu record, tolerating size words and word order.

    Tries, in order: exact id/name match, substring match, then a token-overlap match that
    ignores size/variant words so "large latte" resolves to "Café Latte" and
    "almond croissant" to "Almond Croissant".
    """
    key = _normalise(requested)
    if not key:
        return None

    # 1) Exact match on id or name.
    for record in menu:
        if _normalise(record.get("item_id", "")) == key or _normalise(record.get("name", "")) == key:
            return record

    # 2) Substring either way (handles punctuation/accents already normalised out).
    for record in menu:
        name = _normalise(record.get("name", ""))
        if name and (key in name or name in key):
            return record

    # 3) Token overlap, size/filler words removed. Pick the record whose significant words
    #    are all present in the request (or vice versa), preferring the most specific match.
    req_tokens = _match_tokens(requested)
    if req_tokens:
        best = None
        best_score = 0
        for record in menu:
            name_tokens = _match_tokens(record.get("name", "")) | _match_tokens(record.get("item_id", ""))
            if not name_tokens:
                continue
            overlap = req_tokens & name_tokens
            # Require the menu item's distinctive words to be covered by the request.
            if name_tokens <= req_tokens or req_tokens <= name_tokens:
                score = len(overlap)
                if score > best_score:
                    best, best_score = record, score
        if best is not None:
            return best
    return None


def _unit_price(record: dict, size):
    """Price for a specific size when given and available, else the item's default price_eur."""
    by_size = record.get("prices_by_size_eur") or {}
    if size:
        want = str(size).lower()
        for size_key, price in by_size.items():
            if size_key.lower() == want:
                return float(price), size_key
    default = record.get("price_eur")
    if default is not None:
        return float(default), None
    # Last resort: any listed size price.
    if by_size:
        size_key, price = next(iter(by_size.items()))
        return float(price), size_key
    return None, None


@tool(
    name="calculate_order_total",
    description=(
        "Calculate the total cost of an order in EUR using real per-item menu prices. "
        "Expected input: items: a list of "
        "[{\"item\": \"<menu item name or item_id, e.g. 'Almond Croissant'>\", "
        "\"quantity\": <int, default 1>, \"size\": \"<optional size, e.g. 'single', 'large', '8inch'>\"}]. "
        "Returns a per-line breakdown, the total in EUR, and any items it could not price."
    ),
)
def calculate_order_total(items: list) -> dict:
    """Price an order from the authoritative per-item menu prices in menu_records.json.

    Every line is matched to a menu record; the size-specific price is used when a size is
    given and available, otherwise the item's default price_eur. Items that cannot be matched
    are reported in `unpriced` rather than silently counted as zero, so the total is never a
    quiet undercharge.
    """
    try:
        menu = _load_priced_menu()
    except (KeyError, ValueError, OSError, ClientError) as e:
        return {"error": f"Could not load the menu to price this order: {str(e)}"}

    if not isinstance(items, list) or not items:
        return {"error": "Provide a non-empty list of items to price."}

    line_items = []
    unpriced = []
    total_cost = 0.0

    for entry in items:
        if isinstance(entry, str):
            entry = {"item": entry}
        if not isinstance(entry, dict):
            unpriced.append({"requested": str(entry), "reason": "unrecognised item format"})
            continue

        requested = entry.get("item") or entry.get("name") or entry.get("item_id") or entry.get("type", "")
        size = entry.get("size")
        try:
            quantity = int(entry.get("quantity", 1))
        except (TypeError, ValueError):
            quantity = 1
        if quantity < 1:
            quantity = 1

        record = _find_menu_item(menu, requested)
        if record is None:
            unpriced.append({"requested": requested, "reason": "not on the menu"})
            continue

        unit_price, matched_size = _unit_price(record, size)
        if unit_price is None:
            unpriced.append({"requested": requested, "reason": "no price on record"})
            continue

        line_total = round(unit_price * quantity, 2)
        total_cost += line_total
        line = {
            "item": record.get("name"),
            "item_id": record.get("item_id"),
            "quantity": quantity,
            "unit_price": f"€{unit_price:.2f}",
            "line_total": f"€{line_total:.2f}",
        }
        if matched_size:
            line["size"] = matched_size
        line_items.append(line)

    result = {
        "line_items": line_items,
        "total_cost": f"€{round(total_cost, 2):.2f}",
    }
    if unpriced:
        # Surface this so the agent asks the customer to clarify instead of quoting a wrong total.
        result["unpriced"] = unpriced
        result["note"] = ("Some items could not be priced and are excluded from the total. "
                           "Ask the customer to clarify these before confirming the order.")
    return result

# === Agent Definition ===

menu_agent = Agent(
    model=BedrockModel(model_id=os.environ["MODEL_ID"], region_name=REGION),
    system_prompt="""
        - You are 'Menu Assistant' for Specialty Bakeries & Pastry Cafés — a full café serving
          breakfast, egg dishes, savoury plates, salads, small plates, viennoiserie and pastries,
          coffee, hot drinks, tea, cold drinks, and desserts/ice cream. ALL of these are on the
          menu and in scope — not only bakery/pastry items.
        - Always wrap your answer in <answer> tags.
        - Give 1-2 sentences answers only.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - When you receive a query, treat anything that could be a café menu item, its price, its
          ingredients/allergens, or an order total as in scope. The authoritative list of items is
          whatever get_menu returns — do not assume an item is unavailable just because it is not a
          classic bakery product; check get_menu / calculate_order_total first.
        - Only for a query that is clearly NOT about the café's food, drinks, menu, or an order
          (for example weather or politics) respond with 'Sorry, I cannot answer this question'.
        - For menu-related queries, first fetch S3 menu data using the get_menu tool.
        - For any pricing or order-total query, use the calculate_order_total tool with the item
          name(s), quantity, and size when given. Each item has its own price; never estimate a
          price yourself. All prices are in EUR (€). Quote every price exactly as the tool
          returns it, including both decimal places (for example €2.80, not €2.8). If the tool
          reports unpriced items, ask the customer to clarify rather than guessing.
        - Only for menu-related queries that cannot be answered from S3 menu data, check the knowledge base using menu_kb_retrieve.
        - If nothing relevant is found using either tool, ask clarifying questions or refer to contact support.
        """,
    tools=[menu_kb_retrieve, get_menu, calculate_order_total],
)
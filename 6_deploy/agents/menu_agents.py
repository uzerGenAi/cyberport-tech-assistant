# menu_agents.py — product catalog agent for the Cyberport Tech Assistant.
# The "menu" name is kept from the original project layout: the domain key, S3 key
# (menu/menu_records.json) and MENU_KNOWLEDGE_BASE_ID are unchanged, the content is the catalog.
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
@tool(name="menu_kb_retrieve",
      description="A tool to retrieve buying advice from the product buying-guide knowledge base")
def menu_kb_retrieve(query: str) -> str:
    """Search the buying-guide knowledge base using retrieve_and_generate."""
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

@tool(name="get_menu",
      description="Return the full product catalog (all smartphones and laptops with specs and prices). Use it to look up or compare specific products by name. NOT for laptop recommendations or 'best laptop under a budget' questions: call find_laptops for those.")
def get_menu() -> dict:
    """Fetch the product catalog JSON from S3 and return it as a parsed object."""
    bucket = os.environ["S3_BUCKET_NAME"]
    key = "menu/menu_records.json"
    s3 = boto3.client("s3", region_name=REGION)
    data = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
    return json.loads(data)


# Each product in menu_records.json carries its own price_eur, and smartphones carry
# prices_by_size_eur with one price per storage size. Pricing is per product and variant,
# so the total reflects what the customer actually chose. The catalog is cached per warm
# invocation to avoid re-fetching from S3 for every line in a multi-item order.
_MENU_CACHE = None


def _load_priced_menu() -> list:
    global _MENU_CACHE
    if _MENU_CACHE is None:
        _MENU_CACHE = get_menu()
    return _MENU_CACHE


# Words customers attach to a product that describe a variant (storage, colour) or are
# filler rather than part of the product name. Stripped before matching so "a black
# iPhone 14 with 256GB" still resolves to "Apple iPhone 14".
_MATCH_NOISE_WORDS = {
    "a", "an", "the", "one", "some", "please", "new", "with", "and", "in", "of",
    "phone", "smartphone", "mobile", "laptop", "notebook", "gb", "tb", "storage",
    "black", "white", "blue", "gray", "grey", "green", "purple", "red", "pink", "silver",
    "gold", "yellow", "orange", "midnight", "starlight", "graphite", "platinum",
}
_STORAGE_TOKEN = re.compile(r"^\d+(gb|tb)$")
_STORAGE_IN_TEXT = re.compile(r"(\d+)\s?(GB|TB)\b", re.IGNORECASE)


def _normalise(text: str) -> str:
    return "".join(ch for ch in str(text).lower() if ch.isalnum())


def _match_tokens(text: str) -> set:
    """Significant word tokens of a product phrase, with variant and filler words removed.

    Plain numbers are kept: in "iPhone 14" or "Galaxy S23" the number is the model.
    """
    raw = re.split(r"[^a-z0-9]+", str(text).lower())
    return {t for t in raw if t and t not in _MATCH_NOISE_WORDS and not _STORAGE_TOKEN.match(t)}


def _find_menu_item(menu: list, requested: str):
    """Match a requested product to a catalog record, tolerating variant words and word order.

    Tries, in order: exact id/name match, substring match, then a token-overlap match that
    ignores storage, colour and filler words so "iPhone 14 256GB black" resolves to
    "Apple iPhone 14" (not the iPhone 14 Plus, Pro or Pro Max).
    """
    key = _normalise(requested)
    if not key:
        return None

    # 1) Exact match on id or name.
    for record in menu:
        if _normalise(record.get("item_id", "")) == key or _normalise(record.get("name", "")) == key:
            return record

    names = [(record, _normalise(record.get("name", ""))) for record in menu]
    # 2a) The request contains a full product name ("Apple iPhone 14 Pro Max 256GB"): the
    #     longest contained name is the most specific, so "iPhone 14 Pro Max" beats "iPhone 14".
    contained = [(record, name) for record, name in names if name and name in key]
    if contained:
        return max(contained, key=lambda rn: len(rn[1]))[0]
    # 2b) The request is part of a product name ("iPhone 14"): the shortest such name is the
    #     closest, so "iPhone 14" resolves to "Apple iPhone 14", not "Apple iPhone 14 Pro Max".
    containing = [(record, name) for record, name in names if name and key in name]
    if containing:
        return min(containing, key=lambda rn: len(rn[1]))[0]

    # 3) Token overlap, variant/filler words removed. Pick the record whose significant words
    #    are all present in the request (or vice versa), preferring the most overlap and then
    #    the fewest extra words.
    req_tokens = _match_tokens(requested)
    if req_tokens:
        best = None
        best_rank = (0, 0)
        for record in menu:
            name_tokens = _match_tokens(record.get("name", "")) | _match_tokens(record.get("item_id", ""))
            if not name_tokens:
                continue
            # Require the product's distinctive words to be covered by the request.
            if name_tokens <= req_tokens or req_tokens <= name_tokens:
                rank = (len(req_tokens & name_tokens), -len(name_tokens - req_tokens))
                if rank[0] > 0 and (best is None or rank > best_rank):
                    best, best_rank = record, rank
        if best is not None:
            return best
    return None


def _size_key(text) -> str:
    return re.sub(r"\s+", "", str(text)).upper()


def _unit_price(record: dict, size):
    """Price for a specific variant when given and available, else the product's price_eur."""
    by_size = record.get("prices_by_size_eur") or {}
    if size:
        want = _size_key(size)
        for size_key, price in by_size.items():
            if _size_key(size_key) == want:
                return float(price), size_key
    if by_size:
        # No variant chosen: the cheapest variant, which is what price_eur ("from" price) shows.
        size_key, price = min(by_size.items(), key=lambda kv: float(kv[1]))
        return float(price), size_key
    default = record.get("price_eur")
    if default is not None:
        return float(default), None
    return None, None


def price_items(items: list) -> dict:
    """Price an order from the authoritative per-product prices in menu_records.json.

    Shared by calculate_order_total and place_order, so the total that is stored with an
    order is always recomputed from the catalog and never taken from the model.

    Every line is matched to a catalog record. The variant price is used when a variant is
    given (or written in the item text, e.g. "iPhone 14 256GB") and exists; otherwise the
    product's lowest price applies. Items that cannot be matched, or variants that do not
    exist, are reported in `unpriced` rather than silently counted, so the total is never a
    quiet undercharge.
    """
    try:
        menu = _load_priced_menu()
    except (KeyError, ValueError, OSError, ClientError) as e:
        return {"error": f"Could not load the catalog to price this order: {str(e)}"}

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
        size = entry.get("variant") or entry.get("size") or entry.get("storage")
        if not size:
            found = _STORAGE_IN_TEXT.search(str(requested))
            if found:
                size = f"{found.group(1)}{found.group(2).upper()}"
        try:
            quantity = int(entry.get("quantity", 1))
        except (TypeError, ValueError):
            quantity = 1
        if quantity < 1:
            quantity = 1

        record = _find_menu_item(menu, requested)
        if record is None:
            unpriced.append({"requested": requested, "reason": "not in the catalog"})
            continue

        by_size = record.get("prices_by_size_eur") or {}
        if size and by_size and _size_key(size) not in {_size_key(k) for k in by_size}:
            unpriced.append({"requested": f"{requested} {size}",
                             "reason": f"variant not available; available: {', '.join(by_size)}"})
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
            line["variant"] = matched_size
        line_items.append(line)

    result = {
        "line_items": line_items,
        "total_cost": f"€{round(total_cost, 2):.2f}",
        "total_amount": round(total_cost, 2),
    }
    if unpriced:
        # Surface this so the agent asks the customer to clarify instead of quoting a wrong total.
        result["unpriced"] = unpriced
        result["note"] = ("Some items could not be priced and are excluded from the total. "
                           "Ask the customer to clarify these before confirming the order.")
    return result


_CPU_TIERS = [            # (pattern, score): coarse performance tiers, best first
    (r"\bi9\b|ryzen 9", 6), (r"apple m[23]|\bi7\b|ryzen 7", 5), (r"apple m1|\bi5\b|ryzen 5", 4),
    (r"\bi3\b|ryzen 3", 2), (r"pentium|celeron|athlon|amd 30[12]\d|mediatek", 1),
]
_USE_CASE_CATEGORIES = {
    "student":  ["everyday_laptops", "business_laptops", "premium_laptops"],
    "everyday": ["everyday_laptops", "business_laptops", "premium_laptops"],
    "business": ["business_laptops", "premium_laptops"],
    "gaming":   ["gaming_laptops"],
    "creative": ["premium_laptops", "gaming_laptops"],
}


def _laptop_score(attrs: dict) -> float:
    cpu = str(attrs.get("cpu", "")).lower()
    cpu_score = next((s for p, s in _CPU_TIERS if re.search(p, cpu)), 3)
    ram = float(attrs.get("ram_gb") or 0)
    storage = str(attrs.get("storage", "")).upper()
    size = _STORAGE_IN_TEXT.search(storage)
    gb = int(size.group(1)) * (1024 if size and size.group(2).upper() == "TB" else 1) if size else 0
    ssd = 1 if "SSD" in storage else 0
    return cpu_score * 3 + min(ram, 32) / 4 + min(gb, 1024) / 256 + ssd * 2


def shortlist_laptops(max_price_eur, use_case="everyday", include_refurbished=False) -> dict:
    """Deterministic laptop shortlist: filter by budget and use case, rank by spec score.

    Used by find_laptops (products agent) and laptop_recommendation_tool (orchestrator).
    """
    try:
        budget = float(max_price_eur)
    except (TypeError, ValueError):
        return {"error": "max_price_eur must be a number in euros"}
    use = (use_case or "everyday").strip().lower()
    categories = list(_USE_CASE_CATEGORIES.get(use, _USE_CASE_CATEGORIES["everyday"]))
    if include_refurbished:
        categories.append("refurbished_laptops")
    candidates = []
    for item in _load_priced_menu():
        attrs = item.get("attributes_json") or {}
        price = item.get("price_eur")
        if item.get("category") not in categories or price is None or float(price) > budget:
            continue
        if use == "student" and float(attrs.get("ram_gb") or 0) < 8:
            continue                          # students need 8GB RAM or more
        candidates.append((_laptop_score(attrs), float(price), item, attrs))
    candidates.sort(key=lambda c: (-c[0], c[1]))     # best specs first, cheaper wins a tie
    top = [{
        "name": item["name"], "price_eur": round(price, 2), "category": item["category"],
        "cpu": attrs.get("cpu"), "ram_gb": attrs.get("ram_gb"), "storage": attrs.get("storage"),
        "gpu": attrs.get("gpu"), "screen_inches": attrs.get("screen_inches"),
        "condition": attrs.get("condition", "New"),
    } for _, price, item, attrs in candidates[:3]]
    if not top:
        return {"results": [], "message": f"No {use} laptop under €{budget:.2f} in the catalog."}
    return {"use_case": use, "budget_eur": budget, "results": top}


@tool(
    name="find_laptops",
    description="Shortlist the best laptops within a budget for a use case (student, everyday, "
                "business, gaming, creative). Ranks by specs (CPU, RAM, SSD), not by lowest price. "
                "Use this for every 'best laptop under €X' or 'laptop for <use>' recommendation.",
)
def find_laptops(max_price_eur: float, use_case: str = "everyday", include_refurbished: bool = False) -> dict:
    """Deterministic laptop shortlist (see shortlist_laptops)."""
    return shortlist_laptops(max_price_eur, use_case, include_refurbished)


@tool(
    name="calculate_order_total",
    description=(
        "Calculate the total cost of an order in EUR using real per-product catalog prices. "
        "Expected input: items: a list of "
        "[{\"item\": \"<product name or item_id, e.g. 'Apple iPhone 14'>\", "
        "\"quantity\": <int, default 1>, \"variant\": \"<optional storage size, e.g. '128GB', '256GB'>\"}]. "
        "Returns a per-line breakdown, the total in EUR, and any items it could not price."
    ),
)
def calculate_order_total(items: list) -> dict:
    """Price an order from the catalog. See price_items."""
    return price_items(items)


@tool(
    name="check_store_stock",
    description=(
        "Check whether a product is in stock. Input: item (product name or item_id) and, "
        "optionally, store_id (for example 'spbc-de-001'). With a store_id it returns the units "
        "in that store; without one it lists every store that has the product."
    ),
)
def check_store_stock(item: str, store_id: str = "") -> dict:
    """Look up per-store stock for one product from the catalog's stock_by_store field."""
    try:
        menu = _load_priced_menu()
    except (KeyError, ValueError, OSError, ClientError) as e:
        return {"error": f"Could not load the catalog: {str(e)}"}
    record = _find_menu_item(menu, item)
    if record is None:
        return {"item": item, "error": "Product not found in the catalog."}
    stock = (record.get("attributes_json") or {}).get("stock_by_store") or {}
    result = {"item": record.get("name"), "item_id": record.get("item_id")}
    names = _store_names()
    if store_id and names and store_id.strip().lower() not in names:
        resolved = _resolve_store(store_id)
        if resolved:
            store_id = resolved
    if store_id and names and store_id.strip().lower() not in names:
        # Never report stock for a store that does not exist (the model once guessed "spbc-de-010")
        return {"error": f"Unknown store_id '{store_id}'. Use one of these stores.",
                "stores": [{"store_id": k, "store_name": v} for k, v in sorted(names.items())]}
    if store_id:
        units = int(stock.get(store_id.strip().lower(), 0))
        result.update({"store_id": store_id, "units_in_stock": units, "in_stock": units > 0})
        if names.get(store_id.strip().lower()):
            result["store_name"] = names[store_id.strip().lower()]
        if units <= 0:
            # Give the customer somewhere to go: the stores that do have it, most units first
            result["other_stores_with_stock"] = [
                {"store_id": s, "store_name": names.get(s, s), "units": n}
                for s, n in sorted(((s, int(n)) for s, n in stock.items() if int(n) > 0), key=lambda kv: -kv[1])]
    else:
        result["stores_with_stock"] = stock
    return result

def _resolve_store(text: str) -> str:
    try:
        import stores_agents  # pylint: disable=import-outside-toplevel
        return stores_agents.resolve_store(text)
    except Exception:  # pylint: disable=broad-exception-caught
        return ""


def _store_names() -> dict:
    """Store names for customer-facing replies (the stores agent owns the database access)."""
    try:
        import stores_agents  # pylint: disable=import-outside-toplevel
        return stores_agents.store_names()
    except Exception:  # pylint: disable=broad-exception-caught
        return {}


# === Agent Definition ===

menu_agent = Agent(
    model=BedrockModel(model_id=os.environ["MODEL_ID"], region_name=REGION),
    system_prompt="""
        - You are 'Product Expert' for the Cyberport Tech Assistant. The catalog covers
          smartphones and laptops: everyday, business, premium, gaming and refurbished laptops.
        - Always wrap your answer in <answer> tags.
        - Give 1-3 sentence answers only.
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - Treat anything about a product in the catalog, its specs, price, variants, colours,
          stock, or an order total as in scope. The authoritative list of products is whatever
          get_menu returns: check it before saying a product is not available.
        - Only for a query that is clearly NOT about our products or an order (for example
          weather or politics) respond with 'Sorry, I cannot answer this question'.
        - For product questions and recommendations, first fetch the catalog with get_menu and
          compare products on their specs (cpu, ram_gb, storage, gpu, screen_inches, segment,
          condition). Recommend at most three products and say why each fits.
        - For any laptop recommendation ("best laptop under €X", "a laptop for studying, work or
          gaming"), call find_laptops with the budget and the use case (student, everyday,
          business, gaming, creative). Recommend its results in its order, with each price and
          the specs it returns; do not swap in cheaper products from get_menu. Without a budget,
          ask for one.
        - When describing a single product, always include its price (per storage variant for
          smartphones) along with its specs.
        - When comparing products, state only attributes the catalog returns (price per storage
          variant, segment, colours, RAM, CPU, storage, GPU, screen size when listed). If an
          attribute such as the chip, camera or battery is not in the catalog, say it is not
          listed; never fill it in from your own knowledge.
        - For any pricing or order-total query, use the calculate_order_total tool with the
          product name(s), quantity, and the storage variant when the customer gave one. Each
          product has its own price and smartphones have one price per storage size; never
          estimate a price yourself. All prices are in EUR (€). Quote every price exactly as the
          tool returns it, including both decimal places (for example €1009.00). If the tool
          reports unpriced items, ask the customer to clarify rather than guessing.
        - For stock questions, use check_store_stock. If the product is not in stock at the
          requested store, say so and list the other stores that have it (other_stores_with_stock)
          with their units, so the customer can choose another store. Name stores by their
          store_name (for example "Cyberport Store Berlin"), never by the store_id code alone. Use the store_id you were given (for
          example 'spbc-de-001'); if you only have a city or store name, pass that as store_id: the tool resolves it.
        - For general buying advice that the catalog cannot answer (for example what RAM or
          storage someone needs), use menu_kb_retrieve.
        - If nothing relevant is found using any tool, ask clarifying questions or refer to customer service.
        """,
    tools=[menu_kb_retrieve, get_menu, find_laptops, calculate_order_total, check_store_stock],
)

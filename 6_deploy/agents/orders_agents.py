import os
import re
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
    return lookup_order(user_id, order_id)


def lookup_order(user_id: str, order_id: str) -> dict:
    """Plain-function order lookup shared by get_order_status and check_cancellation."""
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

# Policies decided in code, not summarised by a model: the knowledge base holds both return
# policies with the same words ("return", "14 days", "receipt"), and a generated summary mixed
# them up (online orders were told they must be unopened). Same text as orders_policies_kb_faqs.txt.
_CONTACT = ("customer service via the contact form on the Cyberport website (Contact link at the top "
            "of every page) or at the service desk in any Cyberport store")
_RETURN_POLICIES = {
    "online": ("Online orders: you have 14 days from receiving the goods to withdraw from the purchase "
               "(EU right of withdrawal), without giving a reason. The product does not need to be "
               "unopened: you may unpack and test it. If it was used beyond testing, its value may be "
               "reduced. Return it in any Cyberport store or with a free return label from your account; "
               "the refund goes to the original payment method once the return is checked."),
    "store": ("Store purchases: EU law gives no withdrawal right for purchases made in a store. As a "
              "goodwill policy, unopened products in their original packaging can be returned within 14 "
              "days of purchase with the receipt. Opened products are exchanged or refunded only if "
              "they are faulty."),
}
_CANCELLABLE = {"PROCESSING"}


@tool(name="return_policy",
      description="The exact return policy. purchase_channel is 'online' (ordered online or through the "
                  "Tech Assistant) or 'store' (bought in person in a Cyberport store). Use it for every "
                  "returns question; when the channel is unknown, pass 'unknown' to get both.")
def return_policy(purchase_channel: str = "unknown") -> dict:
    """Return the policy text for one channel, or both clearly labelled."""
    channel = (purchase_channel or "").strip().lower()
    if channel in _RETURN_POLICIES:
        return {"channel": channel, "policy": _RETURN_POLICIES[channel]}
    return {"channel": "unknown", "online": _RETURN_POLICIES["online"], "store": _RETURN_POLICIES["store"],
            "note": "Ask where it was bought if it matters, and never apply the store rule to an online order."}


@tool(name="check_cancellation",
      description="Check whether one existing order can still be cancelled, and what the customer should "
                  "do next. Requires both the customer's name or customer ID (user_id) and the order ID.")
def check_cancellation(user_id: str, order_id: str) -> dict:
    """Apply the cancellation policy to the order's real status (no model judgement involved)."""
    order = lookup_order(user_id, order_id)
    status = order.get("status") if isinstance(order, dict) else None
    if not status:
        return order                      # missing ids or no matching order: pass the message on
    if status in _CANCELLABLE:
        return {"order_id": order["order_id"], "status": status, "can_cancel": True,
                "answer": (f"Order {order['order_id']} is {status}, so it can still be cancelled free of "
                           f"charge. The Tech Assistant cannot cancel orders itself: contact {_CONTACT} with "
                           "the order ID and the name or customer number on the order, and a staff member "
                           "will confirm and process the cancellation.")}
    if status == "CANCELLED":
        return {"order_id": order["order_id"], "status": status, "can_cancel": False,
                "answer": f"Order {order['order_id']} is already cancelled; nothing else needs to be done."}
    return {"order_id": order["order_id"], "status": status, "can_cancel": False,
            "answer": (f"Order {order['order_id']} is {status}, so it can no longer be cancelled. Once you "
                       f"have it, you can return it instead. {_RETURN_POLICIES['online']}")}


# Finding an order without its ID, the way a shop does it: the name on the order plus what was
# bought (and, when that is vague, the store or the date). A name alone never lists orders.
_GENERIC_WORDS = {
    "a", "an", "the", "my", "me", "i", "it", "one", "of", "for", "and", "with", "from", "that", "this",
    "order", "ordered", "orders", "bought", "purchase", "purchased", "new", "item", "product", "device",
    "laptop", "laptops", "notebook", "notebooks", "phone", "phones", "smartphone", "smartphones",
    "mobile", "computer", "pc", "gb", "tb",
}
_MAX_LISTED = 3


def _words(text) -> list:
    return re.findall(r"[a-z0-9]+", str(text).lower())


def _catalog_categories() -> dict:
    """item_id -> category ("gaming_laptops"), so "gaming laptop" matches; {} if unavailable."""
    try:
        import menu_agents  # pylint: disable=import-outside-toplevel
        return {r.get("item_id"): r.get("category", "") for r in menu_agents._load_priced_menu()}  # pylint: disable=protected-access
    except Exception:  # pylint: disable=broad-exception-caught
        return {}


def _order_text(order: dict, categories: dict) -> str:
    try:
        items = json.loads(order.get("items", "[]"))
    except (TypeError, ValueError):
        items = []
    parts = []
    for it in items:
        parts += [it.get("item", ""), it.get("name", ""), it.get("item_id", ""),
                  categories.get(it.get("item_id"), "").replace("_", " ")]
    return " ".join(parts).lower()


def _product_matches(hint_words: list, text: str) -> bool:
    """At least half of the specific words (brand, model, type like 'gaming') appear in the order."""
    specific = [w for w in hint_words if w not in _GENERIC_WORDS]
    if not specific:
        return False
    squashed = re.sub(r"[^a-z0-9]", "", text)
    text_words = set(_words(text))
    hits = sum(1 for w in specific if w in text_words or (len(w) >= 4 and w in squashed))
    return hits >= 1 and hits * 2 >= len(specific)


def _resolve_store(text: str) -> str:
    try:
        import stores_agents  # pylint: disable=import-outside-toplevel
        return stores_agents.resolve_store(text) or ""
    except Exception:  # pylint: disable=broad-exception-caught
        return ""


def _store_label(store_id: str) -> str:
    try:
        import stores_agents  # pylint: disable=import-outside-toplevel
        return stores_agents.store_names().get(store_id, store_id)
    except Exception:  # pylint: disable=broad-exception-caught
        return store_id


def search_orders(name_on_order: str, product: str, store: str = "", order_date: str = "") -> dict:
    """Plain-function order search; see find_orders."""
    name, product = str(name_on_order or "").strip(), str(product or "").strip()
    store, order_date = str(store or "").strip(), str(order_date or "").strip()
    not_found = {"message": (
        "No order matches that name and description. Please check the name used on the order and "
        "what was ordered. The order ID (it starts with ord_) is in the order confirmation; if you "
        f"cannot find it, {_CONTACT} can look the order up after checking your identity.")}
    if not name:
        return {"message": "Ask for the name or customer number used on the order."}
    hint_words = _words(product)
    if not hint_words:
        return {"message": "Ask what was ordered (for example the brand or model)."}
    vague = not [w for w in hint_words if w not in _GENERIC_WORDS]
    store_id = _resolve_store(store) if store else ""
    if vague and not (store_id or order_date):
        return {"message": ("If an order ID for this customer was placed or mentioned earlier in this "
                            "conversation, do not ask the customer anything: check that order ID instead. "
                            "Otherwise the description is too general to identify the order safely: ask for "
                            "the brand or model, or for the collection store or the order date.")}
    try:
        query = {"KeyConditionExpression": Key("user_id").eq(name)}
        orders = []
        while True:
            resp = table.query(**query)
            orders += resp.get("Items", [])
            if "LastEvaluatedKey" not in resp:
                break
            query["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    except (KeyError, ValueError) as e:
        return {"error": str(e)}
    categories = _catalog_categories()
    matches = []
    for o in orders:
        text = _order_text(o, categories)
        if vague:
            # "a laptop" / "my phone": match the product type; store or date (checked below) narrow it
            ok = any(w in text for w in hint_words if w in _GENERIC_WORDS and len(w) >= 5)
        else:
            ok = _product_matches(hint_words, text)
        if ok and store_id and o.get("store_id") != store_id:
            ok = False
        if ok and order_date and not str(o.get("order_timestamp", "")).startswith(order_date[:10]):
            ok = False
        if ok:
            matches.append(o)
    if not matches:
        return not_found                  # same answer for an unknown name and a wrong description
    matches.sort(key=lambda o: o.get("order_timestamp", ""), reverse=True)
    if len(matches) > _MAX_LISTED:
        return {"message": (f"Several orders match. Ask for the collection store or the order date "
                            "to narrow it down.")}
    found = []
    for o in matches:
        try:
            items = json.loads(o.get("items", "[]"))
        except (TypeError, ValueError):
            items = []
        found.append({
            "order_id": o.get("order_id", ""),
            "order_date": str(o.get("order_timestamp", ""))[:10],
            "status": o.get("status", ""),
            "store": _store_label(o.get("store_id", "")),
            "items": [it.get("item") or it.get("name") or it.get("item_id") for it in items],
            "total_amount": float(o.get("total_amount", 0)) if o.get("total_amount") is not None else None,
        })
    return {"orders": found,
            "note": "Give the customer the order ID so they can use it next time."}


@tool(name="find_orders",
      description=("Find a customer's order when they do not know the order ID and NO order ID (ord_...) "
                   "appears anywhere in this conversation. NEVER call this when an order ID was placed, "
                   "checked or mentioned earlier in this chat, even if the customer now describes the order "
                   "by product (e.g. 'the laptop order'): use that order ID with orders_agent_tool instead. "
                   "Needs the name or customer "
                   "number used on the order AND what was ordered (brand, model or type, e.g. 'ASUS gaming "
                   "laptop'). If the description is general ('a laptop'), also pass the collection store or "
                   "the order date (YYYY-MM-DD)."))
def find_orders(name_on_order: str, product: str, store: str = "", order_date: str = "") -> dict:
    """Look up orders by name plus product (and store or date), never by name alone.

    Args:
        name_on_order: The customer name or Cyberport customer number the order was placed with.
        product: What was ordered, in the customer's words (brand, model or type).
        store: Optional collection store name, city or store_id.
        order_date: Optional order date, YYYY-MM-DD.
    """
    return search_orders(name_on_order, product, store, order_date)


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
        - For existing orders, use get_order_status. It needs BOTH the customer's name or customer ID and the order ID. If the customer does not know the order ID, use find_orders with the name and what was ordered (and the store or date when the description is general). Never guess or reuse another customer's details.
        - For new orders, use the place_order tool with the customer name or ID, the store_id and the items (product, quantity, and storage variant for smartphones). The tool calculates the total; report the order ID and the total it returns.
        - For cancellation requests: you cannot cancel orders yourself, and never claim you did. With both the order ID and the customer name or ID, call check_cancellation and give its answer as returned (it already says whether the order can still be cancelled and what to do next). If either is missing, ask for it.
        - For every returns question, call return_policy and give its policy text without adding conditions. purchase_channel: 'online' when the customer ordered online, through the Tech Assistant, had it delivered or mentions an order or order ID; 'store' only when they bought it in person in a store; otherwise 'unknown'. Never apply the store rule (unopened, receipt) to an online order.
        - For other policy questions (delivery times, warranty, damaged deliveries, address changes, contacting customer service), search the knowledge base using orders_kb_retrieve.
        - If nothing relevant is found, ask clarifying questions or refer to customer service.
    """,
    tools=[orders_kb_retrieve, get_order_status, check_cancellation, find_orders, return_policy, place_order],
)

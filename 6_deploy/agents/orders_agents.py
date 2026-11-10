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
        - For cancellation requests: you cannot cancel orders yourself, and never claim you did. With both the order ID and the customer name or ID, call check_cancellation and give its answer as returned (it already says whether the order can still be cancelled and what to do next). If either is missing, ask for it.
        - For every returns question, call return_policy and give its policy text without adding conditions. purchase_channel: 'online' when the customer ordered online, through the Tech Assistant, had it delivered or mentions an order or order ID; 'store' only when they bought it in person in a store; otherwise 'unknown'. Never apply the store rule (unopened, receipt) to an online order.
        - For other policy questions (delivery times, warranty, damaged deliveries, address changes, contacting customer service), search the knowledge base using orders_kb_retrieve.
        - If nothing relevant is found, ask clarifying questions or refer to customer service.
    """,
    tools=[orders_kb_retrieve, get_order_status, check_cancellation, return_policy, place_order],
)

"""Order-admin tools for the harness-manager AgentCore harness (behind an AgentCore Gateway).

Two tools, dispatched by the Gateway tool name ("<target>___<tool>"):
  get_order(user_id, order_id)                 -> the order, if BOTH keys match
  cancel_order(user_id, order_id, reason)      -> sets status CANCELLED, if allowed

Safety lives here, not in the prompt:
  * an order is only found when user_id AND order_id both match (no scans, no guessing)
  * only PROCESSING orders (just placed, not yet prepared further) can be cancelled; every other
    order has to be escalated to the team, and the tool results say so
    (see 2_data_strategy/orders/orders_policies_kb_faqs.txt)
  * the update is conditional on the status read, so a concurrent change is never overwritten
  * orders are never deleted: the status changes and an audit trail is written on the item
"""
import json
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Attr, Key
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE = boto3.resource("dynamodb").Table(os.environ["ORDERS_TABLE"])
CANCELLABLE = {"PROCESSING"}
# An already cancelled order needs nothing; any other status has moved on and goes to the team
ESCALATE_MESSAGE = ("It has already moved past processing, so it cannot be cancelled here. "
                    "Escalate it to the team (fulfilment and customer service).")
MAX_KEY_LEN = 64
MAX_REASON_LEN = 200


def _clean(value, limit=MAX_KEY_LEN):
    return value.strip()[:limit] if isinstance(value, str) else ""


def _jsonable(obj):
    if isinstance(obj, Decimal):
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    if isinstance(obj, dict):
        return {k: _jsonable(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_jsonable(v) for v in obj]
    return obj


def _find(user_id, order_id):
    """The single order matching both keys, or None. Pages through the customer's orders."""
    kwargs = {"KeyConditionExpression": Key("user_id").eq(user_id),
              "FilterExpression": Attr("order_id").eq(order_id)}
    while True:
        page = TABLE.query(**kwargs)
        if page.get("Items"):
            return page["Items"][0]
        if "LastEvaluatedKey" not in page:
            return None
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def _summary(item):
    items = item.get("items", "[]")
    try:
        items = json.loads(items) if isinstance(items, str) else items
    except ValueError:
        pass
    return _jsonable({
        "user_id": item["user_id"], "order_id": item.get("order_id"), "status": item.get("status"),
        "order_timestamp": item.get("order_timestamp"), "store_id": item.get("store_id"),
        "fulfilment": item.get("fulfilment"), "total_amount": item.get("total_amount"), "items": items,
    })


def get_order(args):
    user_id, order_id = _clean(args.get("user_id")), _clean(args.get("order_id"))
    if not user_id or not order_id:
        return {"found": False, "message": "Both user_id and order_id are required."}
    item = _find(user_id, order_id)
    if not item:
        return {"found": False, "message": "No order matches that user_id and order_id."}
    order = _summary(item)
    order["cancellable"] = order["status"] in CANCELLABLE
    if order["cancellable"]:
        order["next_step"] = "cancel_order"
    elif order["status"] == "CANCELLED":
        order["next_step"] = "none: the order is already cancelled"
    else:
        order["next_step"] = "escalate_to_team"
    return {"found": True, "order": order}


def cancel_order(args, request_id):
    user_id, order_id = _clean(args.get("user_id")), _clean(args.get("order_id"))
    reason = _clean(args.get("reason"), MAX_REASON_LEN) or "not given"
    if not user_id or not order_id:
        return {"cancelled": False, "message": "Both user_id and order_id are required."}
    item = _find(user_id, order_id)
    if not item:
        return {"cancelled": False, "message": "No order matches that user_id and order_id."}
    status = item.get("status")
    if status not in CANCELLABLE:
        message = (f"Order is {status}; it is already cancelled." if status == "CANCELLED"
                   else f"Order is {status}; only {sorted(CANCELLABLE)} orders can be cancelled. {ESCALATE_MESSAGE}")
        return {"cancelled": False, "status": status, "escalate_to_team": status != "CANCELLED",
                "message": message}
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        TABLE.update_item(
            Key={"user_id": item["user_id"], "order_timestamp": item["order_timestamp"]},
            UpdateExpression="SET #s = :cancelled, cancelled_at = :now, cancel_reason = :reason, "
                             "cancelled_by = :by, previous_status = :prev",
            # Only if nothing changed since the read: never cancel an order that just shipped
            ConditionExpression="#s = :prev AND order_id = :oid",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":cancelled": "CANCELLED", ":now": now, ":reason": reason,
                                       ":by": f"harness-manager/{request_id}", ":prev": status,
                                       ":oid": order_id},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return {"cancelled": False, "message": "The order changed while it was being cancelled; look it up again."}
        raise
    logger.info("Cancelled order %s for %s (was %s; request %s)", order_id, user_id, status, request_id)
    return {"cancelled": True, "user_id": user_id, "order_id": order_id, "previous_status": status,
            "status": "CANCELLED", "cancelled_at": now}


def handler(event, context):
    custom = getattr(getattr(context, "client_context", None), "custom", None) or {}
    full_name = custom.get("bedrockAgentCoreToolName", "")
    tool = full_name.split("___", 1)[-1]
    request_id = custom.get("bedrockAgentCoreAwsRequestId", getattr(context, "aws_request_id", ""))
    args = event if isinstance(event, dict) else {}
    try:
        if tool == "get_order":
            return get_order(args)
        if tool == "cancel_order":
            return cancel_order(args, request_id)
        return {"error": f"Unknown tool '{full_name}'"}
    except Exception:  # pylint: disable=broad-exception-caught
        logger.exception("Tool %s failed", full_name)
        return {"error": "The order service failed; nothing was changed. Try again later."}

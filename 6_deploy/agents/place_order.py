import re
import uuid
import json
import os
import boto3
from datetime import datetime, timezone
from decimal import Decimal
from botocore.exceptions import ClientError
from typing import Any
from strands.types.tools import ToolResult, ToolUse

import menu_agents  # price_items: the order total is recomputed from the catalog

ORDERS_KNOWLEDGE_BASE_ID = os.environ["ORDERS_KNOWLEDGE_BASE_ID"]
REGION = os.environ["REGION"]
MODEL_ARN = os.environ["MODEL_ARN"]

try:
    table = boto3.resource("dynamodb", region_name=REGION).Table("spbc-orders-table")
except Exception as e:
    print(f"Error initializing DynamoDB: {e}")
    table = None

# Click & collect orders go to one of the demo stores (2_data_strategy/stores/stores_records.json).
_STORE_ID = re.compile(r"^spbc-(de|at)-\d{3}$")


TOOL_SPEC = {
    "name": "place_order",
    "description": ("A tool to place a new click & collect order. The total is calculated from the "
                    "catalog by this tool; it is returned in the confirmation."),
    "inputSchema": {
        "json": {
            "type": "object",
            "properties": {
                "user_id": {
                    "type": "string",
                    "description": "The customer's name or Cyberport customer number."
                },
                "store_id": {
                    "type": "string",
                    "description": "The collection store's ID (for example 'spbc-de-001'), or its city or name (for example 'Berlin')."
                },
                "items": {
                    "type": "array",
                    "description": ("The products being ordered. Each item is an object with 'item' "
                                    "(product name or item_id), 'quantity' and, for smartphones, "
                                    "'variant' (storage size, for example '256GB')."),
                    "items": {
                        "type": "object"
                    }
                },
                "total_amount": {
                    "type": "number",
                    "description": ("Optional. The total quoted to the customer. The tool recalculates "
                                    "the total from the catalog and stores that value.")
                }
            },
            "required": ["user_id", "store_id", "items"]
        }
    }
}


def _resolves(text: str) -> bool:
    try:
        import stores_agents  # pylint: disable=import-outside-toplevel
        return bool(stores_agents.resolve_store(text))
    except Exception:  # pylint: disable=broad-exception-caught
        return False


def _error(tool_use_id: str, text: str) -> ToolResult:
    return {"toolUseId": tool_use_id, "status": "error", "content": [{"text": text}]}


# The function name must match the tool name in the spec
def place_order(tool: ToolUse, **kwargs: Any) -> ToolResult:
    """A tool to place new orders."""
    tool_use_id = tool["toolUseId"]

    # Check if DynamoDB table is available
    if not table:
        return _error(tool_use_id, "Database connection is not available.")

    # Extract input parameters from the tool object
    try:
        user_id = str(tool["input"]["user_id"]).strip()
        store_id = str(tool["input"]["store_id"]).strip().lower()
        items = tool["input"]["items"]
    except KeyError as e:
        return _error(tool_use_id, f"Missing required parameter: {e}")
    quoted_total = tool["input"].get("total_amount")

    if not user_id:
        return _error(tool_use_id, "A customer name or customer ID is required.")
    if not _STORE_ID.match(store_id) and not _resolves(store_id):
        return _error(tool_use_id, f"Unknown store_id '{store_id}'. Look up the store's ID "
                                   "(for example 'spbc-de-001') before placing the order.")
    try:
        import stores_agents  # pylint: disable=import-outside-toplevel
        known = stores_agents.store_names()
    except Exception:  # pylint: disable=broad-exception-caught
        known = {}
    if known and store_id not in known:
        resolved = stores_agents.resolve_store(tool["input"]["store_id"])
        if resolved:
            store_id = resolved
    if known and store_id not in known:
        # The pattern alone accepts stores that do not exist (the model once guessed "spbc-de-010")
        listing = ", ".join(f"{v} ({k})" for k, v in sorted(known.items()))
        return _error(tool_use_id, f"Unknown store_id '{store_id}'. Valid stores: {listing}.")

    # Never trust a total from the model: price every line from the catalog.
    pricing = menu_agents.price_items(items)
    if "error" in pricing:
        return _error(tool_use_id, f"Could not price the order: {pricing['error']}")
    if pricing.get("unpriced"):
        return _error(tool_use_id, "The order was not placed because some items could not be priced: "
                                   f"{json.dumps(pricing['unpriced'])}. Ask the customer to clarify them.")
    total_amount = pricing["total_amount"]

    # Generate a unique order ID and timestamp
    order_id = f"ord_{uuid.uuid4().hex[:12]}"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        # Place the order by putting an item into the DynamoDB table.
        # Using Decimal is recommended for currency to avoid floating-point inaccuracies.
        table.put_item(Item={
            "user_id": user_id,
            "order_timestamp": ts,
            "order_id": order_id,
            "status": "PROCESSING",
            "items": json.dumps(pricing["line_items"]),  # Storing complex objects as JSON strings
            "store_id": store_id,
            "fulfilment": "click_and_collect",
            "total_amount": Decimal(str(total_amount))
        })

        try:
            import stores_agents  # pylint: disable=import-outside-toplevel
            store_label = stores_agents.store_names().get(store_id, store_id)
        except Exception:  # pylint: disable=broad-exception-caught
            store_label = store_id
        message = (f"Order placed successfully with ID: {order_id}. Total: €{total_amount:.2f}. "
                   f"Collect it at {store_label} ({store_id}) when the status is READY_FOR_PICKUP.")
        try:
            if quoted_total is not None and abs(float(quoted_total) - total_amount) > 0.005:
                message += (f" Note: the quoted total €{float(quoted_total):.2f} differed from the "
                            f"catalog total, so €{total_amount:.2f} was used.")
        except (TypeError, ValueError):
            pass
        return {"toolUseId": tool_use_id, "status": "success", "content": [{"text": message}]}

    except ClientError as e:
        # Handle potential AWS errors (e.g., access denied, validation errors)
        error_message = e.response['Error']['Message']
        return _error(tool_use_id, f"Failed to place order due to a database error: {error_message}")
    except Exception as e:
        # Handle other unexpected errors
        return _error(tool_use_id, f"An unexpected error occurred: {str(e)}")

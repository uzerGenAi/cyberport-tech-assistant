import uuid
import json
import os
import boto3
from datetime import datetime
from decimal import Decimal
from botocore.exceptions import ClientError
from typing import Any
from strands.types.tools import ToolResult, ToolUse 

ORDERS_KNOWLEDGE_BASE_ID = os.environ["ORDERS_KNOWLEDGE_BASE_ID"]
REGION = os.environ["REGION"]
MODEL_ARN = os.environ["MODEL_ARN"]

try:
    table = boto3.resource("dynamodb", region_name=REGION).Table("spbc-orders-table")
    bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)
except Exception as e:
    print(f"Error initializing DynamoDB: {e}")
    table = None



TOOL_SPEC = {
    "name": "place_order",
    "description": "A tool to place new orders for a user.",
    "inputSchema": {
        "json": {
            "type": "object",
            "properties": {
                "user_id": {
                    "type": "string",
                    "description": "The unique identifier for the user placing the order."
                },
                "store_id": {
                    "type": "string",
                    "description": "The unique identifier for the store where the order is placed."
                },
                "items": {
                    "type": "array",
                    "description": "A list of items being ordered. Each item should be an object with details like item ID and quantity.",
                    "items": {
                        "type": "object"
                    }
                },
                "total_amount": {
                    "type": "number",
                    "description": "The total monetary value of the order."
                }
            },
            "required": ["user_id", "store_id", "items", "total_amount"]
        }
    }
}

# The function name must match the tool name in the spec
def place_order(tool: ToolUse, **kwargs: Any) -> ToolResult:
    """A tool to place new orders."""
    tool_use_id = tool["toolUseId"]
    
    # Check if DynamoDB table is available
    if not table:
        return {
            "toolUseId": tool_use_id,
            "status": "error",
            "content": [{"text": "Database connection is not available."}]
        }

    # Extract input parameters from the tool object
    try:
        print(tool["input"])
        user_id = tool["input"]["user_id"]
        store_id = tool["input"]["store_id"]
        items = tool["input"]["items"]
        total_amount = tool["input"]["total_amount"]
    except KeyError as e:
        return {
            "toolUseId": tool_use_id,
            "status": "error",
            "content": [{"text": f"Missing required parameter: {e}"}]
        }

    # Generate a unique order ID and timestamp
    order_id = str(uuid.uuid4())
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        # Place the order by putting an item into the DynamoDB table.
        # Using Decimal is recommended for currency to avoid floating-point inaccuracies.
        table.put_item(Item={
            "user_id": user_id,
            "order_timestamp": ts,
            "order_id": order_id,
            "status": "Placed",
            "items": json.dumps(items), # Storing complex objects as JSON strings
            "store_id": store_id,
            "total_amount": Decimal(str(total_amount))
        })
        
        # Return a success message
        return {
            "toolUseId": tool_use_id,
            "status": "success",
            "content": [{"text": f"Order placed successfully with ID: {order_id}"}]
        }

    except ClientError as e:
        # Handle potential AWS errors (e.g., access denied, validation errors)
        error_message = e.response['Error']['Message']
        return {
            "toolUseId": tool_use_id,
            "status": "error",
            "content": [{"text": f"Failed to place order due to a database error: {error_message}"}]
        }
    except Exception as e:
        # Handle other unexpected errors
        return {
            "toolUseId": tool_use_id,
            "status": "error",
            "content": [{"text": f"An unexpected error occurred: {str(e)}"}]
        }
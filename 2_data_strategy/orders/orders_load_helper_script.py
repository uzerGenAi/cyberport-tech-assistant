#PrimaryKey:user_id; SecondaryKey:order_timestamp
import boto3
import json
from datetime import datetime
import os

region = boto3.Session().region_name or os.environ['AWS_REGION']

# DynamoDB client
client = boto3.client('dynamodb', region_name=region)

def load_orders():
    with open('orders_records.json') as f:
        orders = json.load(f)

    for order in orders:
        item = {
            'user_id': {'S': order['user_id']},
            'order_timestamp': {'S': order['order_timestamp']},
            'order_id': {'S': order['order_id']},
            'status': {'S': order['status']},
            'items': {'S': json.dumps(order['items'])},
            'store_id': {'S': order['store_id']},
            'total_amount': {'N': str(order['total_amount'])}
        }
        # Same table the agent runtime reads and writes (orders_agents.py, place_order.py)
        client.put_item(TableName='spbc-orders-table', Item=item)
    print("Orders transactions loaded in to DynamoDB table successfully.")

# If running as a script (e.g., for local testing)
if __name__ == '__main__':
    load_orders()

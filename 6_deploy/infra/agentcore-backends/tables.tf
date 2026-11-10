# DynamoDB table used by the agents.
#
#   spbc-orders-table    read and written by the orders agent and the order-admin Lambda
#                        (user_id + order_timestamp, newest first).
# Conversation history lives in AgentCore Memory, so there is no sessions table.

resource "aws_dynamodb_table" "orders" {
  name         = "${var.name_prefix}-orders-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "order_timestamp"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "order_timestamp"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = var.dynamodb_deletion_protection
}

# DynamoDB tables used by the agents.
#
#   spbc-orders-table    read and written by the orders agent (user_id + order_timestamp,
#                        newest first).
#   spbc-sessions-table  conversation memory of the proof-of-concept CLI
#                        (3_proof_of_concept/agents/tech_assistant_agent.py). The production
#                        runtime does not use it; the CLI keeps working without it, so it can be
#                        dropped if you only run the AgentCore runtime.

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

resource "aws_dynamodb_table" "sessions" {
  name         = "${var.name_prefix}-sessions-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"

  attribute {
    name = "session_id"
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

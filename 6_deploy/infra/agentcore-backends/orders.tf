# Orders table, only when this stack owns it (create_orders_table = true).
# Same schema as the EKS stack's table: the agents query by user_id, newest order_timestamp first.

resource "aws_dynamodb_table" "orders" {
  count = var.create_orders_table ? 1 : 0

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

  deletion_protection_enabled = true
}

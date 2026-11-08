output "stores_db_cluster_arn" {
  description = "Aurora cluster ARN (STORES_DB_CLUSTER_ARN for the runtime)."
  value       = aws_rds_cluster.stores.arn
}

output "stores_db_cluster_identifier" {
  value = aws_rds_cluster.stores.cluster_identifier
}

output "stores_db_name" {
  value = local.db_name
}

output "stores_db_admin_secret_arn" {
  description = "RDS-managed master secret. Only the data loader uses it."
  value       = aws_rds_cluster.stores.master_user_secret[0].secret_arn
}

output "stores_db_reader_secret_arn" {
  description = "Read-only credentials (STORES_DB_SECRET_ARN for the runtime)."
  value       = aws_secretsmanager_secret.stores_reader.arn
}

output "promotions_api_url" {
  description = "PROMOS_API_URL for the runtime."
  value       = "${trimsuffix(aws_apigatewayv2_stage.prod.invoke_url, "/")}/promotions"
}

output "promotions_api_invoke_arn" {
  description = "Resource for execute-api:Invoke in the runtime's IAM policy."
  value       = "${aws_apigatewayv2_api.promotions.execution_arn}/${local.promotions_stage}/GET/promotions"
}

output "orders_table_name" {
  value = aws_dynamodb_table.orders.name
}

output "sessions_table_name" {
  value = aws_dynamodb_table.sessions.name
}

output "agentcore_runtime_env" {
  description = "Environment variables to add to the AgentCore runtime."
  value = {
    STORES_DB_CLUSTER_ARN = aws_rds_cluster.stores.arn
    STORES_DB_SECRET_ARN  = aws_secretsmanager_secret.stores_reader.arn
    STORES_DB_NAME        = local.db_name
    PROMOS_API_URL        = "${trimsuffix(aws_apigatewayv2_stage.prod.invoke_url, "/")}/promotions"
  }
}

output "agentcore_runtime_backends_policy_json" {
  description = "Inline policy for the runtime's execution role (name it SPBC-AgentCore-Backends)."
  value       = data.aws_iam_policy_document.runtime_backends.json
}

data "aws_iam_policy_document" "runtime_backends" {
  statement {
    sid       = "StoresDataApi"
    actions   = ["rds-data:ExecuteStatement"]
    resources = [aws_rds_cluster.stores.arn]
  }

  statement {
    sid       = "StoresReaderSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.stores_reader.arn]
  }

  statement {
    sid       = "PromotionsApi"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_apigatewayv2_api.promotions.execution_arn}/${local.promotions_stage}/GET/promotions"]
  }
}

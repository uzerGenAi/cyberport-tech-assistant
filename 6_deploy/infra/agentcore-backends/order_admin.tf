# Order-admin Lambda: the get_order / cancel_order tools of the harness-manager AgentCore harness.
# The harness reaches it through an AgentCore Gateway (created by 6_deploy/harness/deploy_harness.py),
# so the function's only caller is that gateway's service role. All cancellation rules live in
# lambda/order_admin/handler.py; this role can read and update the orders table and nothing else
# (no DeleteItem, no Scan, no other tables).

data "archive_file" "order_admin" {
  type        = "zip"
  output_path = "${path.module}/.build/order_admin.zip"
  source {
    content  = file("${path.module}/lambda/order_admin/handler.py")
    filename = "handler.py"
  }
}

resource "aws_cloudwatch_log_group" "order_admin_lambda" {
  name              = "/aws/lambda/${var.name_prefix}-order-admin"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "order_admin_lambda" {
  name               = "${var.name_prefix}-order-admin-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "order_admin_lambda" {
  name = "orders-read-update-logs"
  role = aws_iam_role.order_admin_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OrdersReadAndCancel"
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.orders.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.order_admin_lambda.arn}:*"
      },
      {
        Sid      = "Tracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "order_admin" {
  function_name    = "${var.name_prefix}-order-admin"
  description      = "get_order / cancel_order tools for the harness-manager AgentCore harness"
  role             = aws_iam_role.order_admin_lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.order_admin.output_path
  source_code_hash = data.archive_file.order_admin.output_base64sha256
  memory_size      = 128
  timeout          = 10

  environment {
    variables = {
      ORDERS_TABLE = aws_dynamodb_table.orders.name
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.order_admin_lambda, aws_iam_role_policy.order_admin_lambda]
}

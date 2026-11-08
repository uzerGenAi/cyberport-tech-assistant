# Promotions API: HTTP API "spbcPromotionsAPI", route GET /promotions, IAM (SigV4) authorization.
# A Lambda function serves the promotions bundled from 2_data_strategy/promos/promos_records.json
# and returns only those whose validity window contains today's date.
# To change promotions, edit that file and run terraform apply.

locals {
  promotions_api_name  = "spbcPromotionsAPI"
  promotions_stage     = "prod"
  promotions_route     = "GET /promotions"
  promotions_data_file = "${path.module}/../../../2_data_strategy/promos/promos_records.json"
}

data "archive_file" "promotions" {
  type        = "zip"
  output_path = "${path.module}/.build/promotions.zip"

  source {
    content  = file("${path.module}/lambda/promotions/handler.py")
    filename = "handler.py"
  }

  source {
    content  = file(local.promotions_data_file)
    filename = "promos_records.json"
  }
}

resource "aws_cloudwatch_log_group" "promotions_lambda" {
  name              = "/aws/lambda/${var.name_prefix}-promotions-api"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "promotions_lambda" {
  name               = "${var.name_prefix}-promotions-api-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "promotions_lambda" {
  name = "logs-and-tracing"
  role = aws_iam_role.promotions_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.promotions_lambda.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "promotions" {
  function_name    = "${var.name_prefix}-promotions-api"
  description      = "GET /promotions for the SPBC Tech Assistant"
  role             = aws_iam_role.promotions_lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.promotions.output_path
  source_code_hash = data.archive_file.promotions.output_base64sha256
  memory_size      = 128
  timeout          = 5

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.promotions_lambda, aws_iam_role_policy.promotions_lambda]
}

resource "aws_apigatewayv2_api" "promotions" {
  name          = local.promotions_api_name
  description   = "SPBC promotions API. IAM-authorized; called by the AgentCore runtime."
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "promotions" {
  api_id                 = aws_apigatewayv2_api.promotions.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.promotions.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 6000
}

resource "aws_apigatewayv2_route" "get_promotions" {
  api_id             = aws_apigatewayv2_api.promotions.id
  route_key          = local.promotions_route
  target             = "integrations/${aws_apigatewayv2_integration.promotions.id}"
  authorization_type = "AWS_IAM"
}

resource "aws_cloudwatch_log_group" "promotions_api_access" {
  name              = "/aws/apigateway/${local.promotions_api_name}/${local.promotions_stage}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.promotions.id
  name        = local.promotions_stage
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit    = var.promotions_api_rate_limit
    throttling_burst_limit   = var.promotions_api_burst_limit
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.promotions_api_access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      requestTime      = "$context.requestTime"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLength   = "$context.responseLength"
      callerArn        = "$context.identity.userArn"
      sourceIp         = "$context.identity.sourceIp"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "promotions_api" {
  statement_id  = "AllowSpbcPromotionsApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.promotions.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.promotions.execution_arn}/${local.promotions_stage}/GET/promotions"
}

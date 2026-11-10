# Promotions API: HTTP API "spbcPromotionsAPI", route GET /promotions, IAM (SigV4) authorization.
# A Lambda function reads the promotions file from S3 and returns only those promotions whose
# validity window contains today's date.
#
# To change promotions, an admin uploads a new promos_records.json (a JSON list; [] means none):
#   aws s3 cp promos_records.json s3://<promotions_bucket_name>/promotions/promos_records.json
# No Terraform run is needed; the change shows up within PROMOTIONS_CACHE_SECONDS (60 s).
#
# Terraform uploads 2_data_strategy/promos/promos_records.json once as the starting file and then
# never overwrites it (ignore_changes = all), so applies cannot undo an admin upload. The same
# file is also bundled inside the Lambda, but only used when no bucket is configured.

locals {
  promotions_api_name  = "spbcPromotionsAPI"
  promotions_stage     = "prod"
  promotions_route     = "GET /promotions"
  promotions_data_file = "${path.module}/../../../2_data_strategy/promos/promos_records.json"
  promotions_s3_key    = "promotions/promos_records.json"
}

# ── Promotions file bucket ────────────────────────────────────────────────────

resource "aws_s3_bucket" "promotions" {
  bucket = "${var.name_prefix}-promotions-${data.aws_caller_identity.current.account_id}"
  # The bucket only holds the promotions file (versions included); the repo keeps the seed copy
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "promotions" {
  bucket                  = aws_s3_bucket.promotions.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "promotions" {
  bucket = aws_s3_bucket.promotions.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Versioning lets an admin restore the previous file after a bad upload
resource "aws_s3_bucket_versioning" "promotions" {
  bucket = aws_s3_bucket.promotions.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "promotions" {
  bucket = aws_s3_bucket.promotions.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "promotions" {
  bucket = aws_s3_bucket.promotions.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  depends_on = [aws_s3_bucket_versioning.promotions]
}

data "aws_iam_policy_document" "promotions_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.promotions.arn, "${aws_s3_bucket.promotions.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "promotions" {
  bucket = aws_s3_bucket.promotions.id
  policy = data.aws_iam_policy_document.promotions_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.promotions]
}

# Starting file only: created once, never overwritten by Terraform afterwards
resource "aws_s3_object" "promotions_seed" {
  bucket       = aws_s3_bucket.promotions.id
  key          = local.promotions_s3_key
  source       = local.promotions_data_file
  content_type = "application/json"

  lifecycle {
    ignore_changes = all
  }

  depends_on = [aws_s3_bucket_versioning.promotions]
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
        # Read-only, and only the one promotions file
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.promotions.arn}/${local.promotions_s3_key}"
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
  memory_size      = 256 # boto3 (S3 read) makes cold starts slower at 128 MB
  timeout          = 5

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      PROMOTIONS_BUCKET        = aws_s3_bucket.promotions.id
      PROMOTIONS_KEY           = local.promotions_s3_key
      PROMOTIONS_CACHE_SECONDS = "60"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.promotions_lambda,
    aws_iam_role_policy.promotions_lambda,
    aws_s3_object.promotions_seed,
  ]
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

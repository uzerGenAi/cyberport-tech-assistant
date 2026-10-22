# The stores database lives in private subnets with no route to the internet. The agents reach
# it through the RDS Data API (HTTPS + IAM), so the AgentCore runtime needs no VPC attachment.

locals {
  create_vpc = length(var.existing_subnet_ids) == 0
  vpc_id     = local.create_vpc ? aws_vpc.backends[0].id : var.existing_vpc_id
  subnet_ids = local.create_vpc ? aws_subnet.db[*].id : var.existing_subnet_ids
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "backends" {
  count = local.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-agentcore-backends"
  }
}

resource "aws_subnet" "db" {
  count = local.create_vpc ? 3 : 0

  vpc_id            = aws_vpc.backends[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.name_prefix}-db-${data.aws_availability_zones.available.names[count.index]}"
  }
}

# Strip the default security group's allow-all rules (CIS AWS Foundations 5.4)
resource "aws_default_security_group" "backends" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.backends[0].id
}

resource "aws_security_group" "stores_db" {
  name        = "${var.name_prefix}-stores-db"
  description = "Aurora stores database. No ingress by default: the agents use the Data API."
  vpc_id      = local.vpc_id

  lifecycle {
    precondition {
      condition     = local.create_vpc || var.existing_vpc_id != ""
      error_message = "Set existing_vpc_id when existing_subnet_ids is set."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "stores_db" {
  for_each = toset(var.db_ingress_security_group_ids)

  security_group_id            = aws_security_group.stores_db.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "MySQL from ${each.value}"
}

# ── Flow logs ─────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = local.create_vpc && var.enable_vpc_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name_prefix}-agentcore-backends/flow-logs"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    # Confused-deputy protection
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = local.create_vpc && var.enable_vpc_flow_logs ? 1 : 0

  name               = "${var.name_prefix}-agentcore-backends-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  count = local.create_vpc && var.enable_vpc_flow_logs ? 1 : 0

  name = "write-flow-logs"
  role = aws_iam_role.flow_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      }
    ]
  })
}

resource "aws_flow_log" "backends" {
  count = local.create_vpc && var.enable_vpc_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.backends[0].id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
}

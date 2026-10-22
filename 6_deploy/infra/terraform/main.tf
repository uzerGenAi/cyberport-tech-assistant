terraform {
  backend "s3" {
    bucket         = "spbc-tfstate-eu-central-1"
    key            = "prod/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "spbc-tfstate-lock"
    encrypt        = true
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.app_name}-${var.environment}-vpc"
  cidr = "10.10.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24", "10.10.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = false # one NAT GW per AZ for HA
  one_nat_gateway_per_az = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                         = var.cluster_name
  cluster_version                      = "1.29"
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.eks_public_access_cidrs

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 3
      desired_size   = var.desired_node_count
    }
  }
}

resource "aws_ecr_repository" "app" {
  name                 = "${var.app_name}-${var.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

data "aws_route53_zone" "this" {
  count   = var.route53_zone_id == "" ? 0 : 1
  zone_id = var.route53_zone_id
}

resource "aws_acm_certificate" "app" {
  count = var.route53_zone_id == "" ? 0 : 1

  domain_name       = local.app_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.route53_zone_id == "" ? {} : {
    for dvo in aws_acm_certificate.app[0].domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}

resource "aws_acm_certificate_validation" "app" {
  count = var.route53_zone_id == "" ? 0 : 1

  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_route53_record" "app" {
  count = var.route53_zone_id == "" ? 0 : 1

  zone_id = var.route53_zone_id
  name    = local.app_fqdn
  type    = "A"

  dynamic "alias" {
    for_each = var.route53_alias_name != "" && var.route53_alias_zone_id != "" ? [1] : []
    content {
      name                   = var.route53_alias_name
      zone_id                = var.route53_alias_zone_id
      evaluate_target_health = true
    }
  }
}

locals {
  app_fqdn = format("%s.%s", var.app_subdomain, var.domain_name)
}

# ── DynamoDB tables with Point-in-Time Recovery ──────────────────────────────

resource "aws_dynamodb_table" "orders" {
  name         = "spbc-orders-table"
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

  tags = {
    Application = var.app_name
    Environment = var.environment
  }
}

resource "aws_dynamodb_table" "sessions" {
  name         = "spbc-sessions-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"

  attribute {
    name = "session_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Application = var.app_name
    Environment = var.environment
  }
}

# ── Cluster Autoscaler IRSA role ─────────────────────────────────────────────
# Created by Terraform so no manual pre-provision step is needed.

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "eks" {
  url = module.eks.cluster_oidc_issuer_url
}

locals {
  ca_irsa_role_name       = "${var.app_name}-cluster-autoscaler"
  ca_oidc_provider_arn    = data.aws_iam_openid_connect_provider.eks.arn
  ca_oidc_provider_id     = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
  ca_service_account_name = "cluster-autoscaler"
}

resource "aws_iam_role" "cluster_autoscaler" {
  name = local.ca_irsa_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.ca_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.ca_oidc_provider_id}:sub" = "system:serviceaccount:kube-system:${local.ca_service_account_name}"
          "${local.ca_oidc_provider_id}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Application = var.app_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "${var.app_name}-cluster-autoscaler-policy"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      }
    ]
  })
}

# ── EKS Cluster Autoscaler (Helm) ─────────────────────────────────────────────

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.37.0"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cluster_autoscaler.arn
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = local.ca_service_account_name
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }

  depends_on = [module.eks, aws_iam_role_policy.cluster_autoscaler]
}

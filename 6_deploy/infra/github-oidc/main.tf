data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Default sub pattern tolerates GitHub's immutable numeric ids in the claim
  # (repo:<owner>@<id>/<repo>@<id>:...) by wildcarding after each name. Override with a pinned
  # value in production.
  sub_claim = var.github_sub_claim != "" ? var.github_sub_claim : "repo:${var.github_owner}*/${var.github_repo}*:*"

  oidc_provider_arn = var.manage_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn

  # Expand the role name patterns to full ARNs in this account/partition.
  role_arns = [for p in var.execution_role_name_patterns : "arn:${local.partition}:iam::${local.account_id}:role/${p}"]
  # PassRole shouldn't target the service-linked role path; keep it to real roles.
  pass_role_arns = [for a in local.role_arns : a if !can(regex("/aws-service-role/", a))]
}

# GitHub Actions OIDC identity provider. GitHub's token is signed by a well-known CA; the
# thumbprints are advisory for modern IAM but kept current here. Both the current and the
# previous GitHub thumbprints are listed so a rotation in flight doesn't break assume-role.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.manage_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
    "6938fd4d98bab03faadb97b34396831e3780aea1",
  ]
}

# Trust policy: only GitHub Actions from this repo, only the sts audience.
data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.sub_claim]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.role_name
  description          = "Role GitHub Actions assumes via OIDC to deploy the SPBC Pastry Concierge."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# Permissions policy — mirrors the live SPBC-Deploy-Permissions inline policy. Service actions
# are broad on "*" (this is a single-project deploy role), but the sensitive IAM role management
# and PassRole are scoped to this project's role-name patterns only.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid    = "Identity"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "iam:ListRoles", "iam:GetRole", "iam:ListRolePolicies", "iam:GetRolePolicy",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "BedrockModelsKnowledgeBasesGuardrails"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream",
      "bedrock:Retrieve", "bedrock:RetrieveAndGenerate", "bedrock:ApplyGuardrail",
      "bedrock:GetInferenceProfile", "bedrock:ListInferenceProfiles",
      "bedrock:GetFoundationModel", "bedrock:ListFoundationModels",
      "bedrock:CreateGuardrail", "bedrock:CreateGuardrailVersion", "bedrock:GetGuardrail",
      "bedrock:ListGuardrails", "bedrock:DeleteGuardrail",
      "bedrock:CreateKnowledgeBase", "bedrock:GetKnowledgeBase", "bedrock:ListKnowledgeBases",
      "bedrock:DeleteKnowledgeBase", "bedrock:CreateDataSource", "bedrock:GetDataSource",
      "bedrock:ListDataSources", "bedrock:StartIngestionJob", "bedrock:GetIngestionJob",
      "bedrock:ListIngestionJobs", "bedrock:TagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AgentCoreRuntime"
    effect    = "Allow"
    actions   = ["bedrock-agentcore:*"]
    resources = ["*"]
  }

  statement {
    sid       = "VectorStore"
    effect    = "Allow"
    actions   = ["aoss:*"]
    resources = ["*"]
  }

  statement {
    sid       = "StoresDatabase"
    effect    = "Allow"
    actions   = ["rds:*", "rds-data:*"]
    resources = ["*"]
  }

  statement {
    sid       = "NetworkForTheDatabase"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  statement {
    sid       = "PromotionsApiAndTools"
    effect    = "Allow"
    actions   = ["lambda:*", "apigateway:*", "execute-api:Invoke"]
    resources = ["*"]
  }

  statement {
    sid       = "Secrets"
    effect    = "Allow"
    actions   = ["secretsmanager:*"]
    resources = ["*"]
  }

  statement {
    sid       = "DataStores"
    effect    = "Allow"
    actions   = ["dynamodb:*", "s3:*"]
    resources = ["*"]
  }

  statement {
    sid       = "FrontendAndAuth"
    effect    = "Allow"
    actions   = ["cognito-idp:*", "cognito-identity:*", "amplify:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ContainersAndClusters"
    effect    = "Allow"
    actions   = ["ecr:*", "eks:*", "codebuild:*", "cloudformation:*"]
    resources = ["*"]
  }

  statement {
    sid    = "Observability"
    effect = "Allow"
    actions = [
      "logs:*", "cloudwatch:*", "xray:*",
      "ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter", "ssm:DescribeParameters",
    ]
    resources = ["*"]
  }

  # Sensitive: scoped to this project's role-name patterns, never "*".
  statement {
    sid    = "ManageOnlyThisProjectsRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:CreateServiceLinkedRole",
    ]
    resources = local.role_arns
  }

  statement {
    sid       = "PassOnlyThisProjectsRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.pass_role_arns
  }
}

resource "aws_iam_role_policy" "permissions" {
  name   = "SPBC-Deploy-Permissions"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Expand the role name patterns to full ARNs in this account/partition.
  role_arns = [for p in var.execution_role_name_patterns : "arn:${local.partition}:iam::${local.account_id}:role/${p}"]
  # PassRole shouldn't target the service-linked role path; keep it to real roles.
  pass_role_arns = [for a in local.role_arns : a if !can(regex("/aws-service-role/", a))]

  artifact_bucket_name = var.artifact_bucket_name != "" ? var.artifact_bucket_name : "spbc-pipeline-artifacts-${local.account_id}-${var.aws_region}"
}

# CodeBuild service role. Both CodeBuild projects (deploy + ci) assume this role; CI needs only
# a subset (read + logs) that the deploy permissions are a superset of.
data "aws_iam_policy_document" "codebuild_trust" {
  statement {
    sid     = "CodeBuildAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_deploy" {
  name               = var.codebuild_role_name
  description        = "Role CodeBuild assumes to validate and deploy the SPBC Tech Assistant."
  assume_role_policy = data.aws_iam_policy_document.codebuild_trust.json
}

# CodePipeline service role.
data "aws_iam_policy_document" "codepipeline_trust" {
  statement {
    sid     = "CodePipelineAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = var.codepipeline_role_name
  description        = "Role CodePipeline assumes to orchestrate the SPBC Tech Assistant pipeline."
  assume_role_policy = data.aws_iam_policy_document.codepipeline_trust.json
}

# Permissions policy — ported VERBATIM from 6_deploy/infra/github-oidc/main.tf
# (data.aws_iam_policy_document.permissions). Service actions are broad on "*" (this is a
# single-project deploy role), but the sensitive IAM role management and PassRole are scoped to
# this project's role-name patterns only. The OIDC provider / tls provider / trust doc from the
# github-oidc stack are intentionally NOT ported; CodeBuild trust is codebuild.amazonaws.com.
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
    sid       = "ContainerBuilds"
    effect    = "Allow"
    actions   = ["ecr:*", "codebuild:*", "cloudformation:*"]
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
  role   = aws_iam_role.codebuild_deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

# Orchestration policy (new, NOT in the ported deploy document): CloudWatch Logs scoped to the
# two explicit CodeBuild log groups, and S3 read/write on the artifact bucket so CodeBuild can
# exchange pipeline artifacts.
data "aws_iam_policy_document" "codebuild_logs_artifacts" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/codebuild/${var.deploy_project_name}:*",
      "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/codebuild/${var.ci_project_name}:*",
    ]
  }

  statement {
    sid    = "ArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [
      "arn:${local.partition}:s3:::${local.artifact_bucket_name}",
      "arn:${local.partition}:s3:::${local.artifact_bucket_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "codebuild_logs_artifacts" {
  name   = "SPBC-CodeBuild-Logs-Artifacts"
  role   = aws_iam_role.codebuild_deploy.id
  policy = data.aws_iam_policy_document.codebuild_logs_artifacts.json
}

# CodePipeline orchestration policy: pull from CodeCommit, start the CodeBuild projects,
# exchange artifacts on S3, and publish approval notifications.
data "aws_iam_policy_document" "codepipeline_permissions" {
  statement {
    sid    = "SourceCodeCommit"
    effect = "Allow"
    actions = [
      "codecommit:GetBranch",
      "codecommit:GetCommit",
      "codecommit:UploadArchive",
      "codecommit:GetUploadArchiveStatus",
      "codecommit:CancelUploadArchive",
    ]
    resources = [aws_codecommit_repository.this.arn]
  }

  statement {
    sid    = "RunCodeBuild"
    effect = "Allow"
    actions = [
      "codebuild:StartBuild",
      "codebuild:BatchGetBuilds",
    ]
    resources = [
      aws_codebuild_project.ci.arn,
      aws_codebuild_project.deploy.arn,
    ]
  }

  statement {
    sid    = "ArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  statement {
    sid       = "ApprovalNotifications"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.approvals.arn]
  }
}

resource "aws_iam_role_policy" "codepipeline_permissions" {
  name   = "SPBC-CodePipeline-Permissions"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline_permissions.json
}

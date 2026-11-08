# All-AWS CI/CD stack for the SPBC Tech Assistant.
#
# Replaces the retired GitHub Actions + github-oidc path with CodeCommit + CodePipeline +
# CodeBuild. Codifies the source repository, the V2 pipeline (Source -> Validate -> Approve ->
# Deploy), the two CodeBuild projects and their log groups, the artifact bucket, the approval
# SNS topic, and the CodeBuild / CodePipeline IAM roles. Independent of the other stacks, with
# its own state key.
#
# Apply once per account before the first pipeline run:
#   terraform -chdir=6_deploy/infra/codepipeline init \
#     -backend-config="bucket=spbc-tfstate-$(aws sts get-caller-identity --query Account --output text)"
#   terraform -chdir=6_deploy/infra/codepipeline apply
#
# See README.md for bootstrap order, pushing to CodeCommit, and the deploy toggles.

terraform {
  required_version = ">= 1.10.0"

  # Reuses the project state bucket (spbc-tfstate-<account-id>, created by make backend-setup).
  # The bucket is not set here: pass -backend-config="bucket=<name>" at init.
  backend "s3" {
    key          = "prod/codepipeline.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "CyberportTechAssistant"
      Component   = "CodePipelineDeploy"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

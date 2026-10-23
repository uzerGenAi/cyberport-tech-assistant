# All-AWS CI/CD stack for the SPBC Pastry Concierge.
#
# Replaces the retired GitHub Actions + github-oidc path with CodeCommit + CodePipeline +
# CodeBuild. Codifies the source repository, the V2 pipeline (Source -> Validate -> Approve ->
# Deploy), the two CodeBuild projects and their log groups, the artifact bucket, the approval
# SNS topic, and the CodeBuild / CodePipeline IAM roles. Independent of the other stacks, with
# its own state key.
#
# Apply once per account before the first pipeline run:
#   terraform -chdir=6_deploy/infra/codepipeline init
#   terraform -chdir=6_deploy/infra/codepipeline apply
#
# See README.md for bootstrap order, pushing to CodeCommit, and the deploy toggles.

terraform {
  required_version = ">= 1.10.0"

  # Reuses the project state bucket. Override at init with
  # -backend-config="bucket=<name>" if your account uses a different one.
  backend "s3" {
    bucket       = "spbc-tfstate-eu-central-1"
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
      Project     = "SpecialtyBakeriesCafe"
      Component   = "CodePipelineDeploy"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

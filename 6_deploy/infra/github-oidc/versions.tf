# GitHub Actions OIDC deploy role for the SPBC Pastry Concierge.
#
# Codifies what was first created by hand while bringing the CI deploy pipeline up: the GitHub
# OIDC identity provider, the role GitHub Actions assumes (SPBC-GitHubActions-Deploy), its trust
# policy, and its permissions policy. Independent of the other stacks, with its own state.
#
# Apply once per account before the first pipeline run:
#   terraform -chdir=6_deploy/infra/github-oidc init
#   terraform -chdir=6_deploy/infra/github-oidc apply \
#     -var 'github_owner=huraisturkey-lang' -var 'github_repo=spbc-pastry-concierge'
#
# Then set the repo variable AWS_DEPLOY_ROLE_ARN to this stack's deploy_role_arn output.

terraform {
  required_version = ">= 1.10.0"

  # Reuses the project state bucket. Override at init with
  # -backend-config="bucket=<name>" if your account uses a different one.
  backend "s3" {
    bucket       = "spbc-tfstate-eu-central-1"
    key          = "prod/github-oidc.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SpecialtyBakeriesCafe"
      Component   = "GitHubOIDCDeploy"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

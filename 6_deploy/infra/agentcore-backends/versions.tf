# Backends for the AgentCore Pastry Concierge runtime: the stores database (Aurora MySQL,
# queried through the RDS Data API), the promotions API and, optionally, the orders table.
# Independent of the EKS stack in ../terraform, with its own state.

terraform {
  required_version = ">= 1.10.0"

  # The bucket can be overridden at init: -backend-config="bucket=<name>" (agentcore_backends.sh
  # passes TF_STATE_BUCKET). S3 native locking replaces the deprecated dynamodb_table setting.
  backend "s3" {
    bucket       = "spbc-tfstate-eu-central-1"
    key          = "prod/agentcore-backends.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SpecialtyBakeriesCafe"
      Component   = "AgentCoreBackends"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

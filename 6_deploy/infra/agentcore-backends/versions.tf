# Backends for the AgentCore Tech Assistant runtime: the stores database (Aurora MySQL,
# queried through the RDS Data API), the promotions API, the orders table and the order-admin Lambda.
# Has its own state, independent of the pipeline stack in ../codepipeline.

terraform {
  # NOTE: `terraform test` on this stack can hit a known Terraform 1.16.x engine bug
  # ("value has marks, so it cannot be serialized as JSON") when marshalling a marked/
  # sensitive value. It is not reproducible on the installed 1.16.6 here, so the bound
  # below is intentionally NOT raised (bumping required_version would break CI on the
  # only installed version). ci_checks.sh guards that specific panic as a visible skip.
  # RECOMMENDED (UNVERIFIED): run CI on a Terraform build without this bug.
  required_version = ">= 1.10.0"

  # The bucket is deliberately not set here (bucket names are global): init supplies it with
  # -backend-config="bucket=spbc-tfstate-<account-id>" (agentcore_backends.sh does this; TF_STATE_BUCKET
  # overrides the name). S3 native locking replaces the deprecated dynamodb_table setting.
  backend "s3" {
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
      Project     = "CyberportTechAssistant"
      Component   = "AgentCoreBackends"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

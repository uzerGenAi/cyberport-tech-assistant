variable "aws_region" {
  description = "Region for the deploy role and its resources (IAM is global, but the provider needs a region)."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "production"
}

variable "github_owner" {
  description = "GitHub org/user that owns the repository (e.g. huraisturkey-lang)."
  type        = string
}

variable "github_repo" {
  description = "Repository name the deploy role trusts (e.g. spbc-pastry-concierge)."
  type        = string
}

# GitHub's OIDC subject claim now embeds immutable numeric ids: the real sub looks like
#   repo:<owner>@<ownerId>/<repo>@<repoId>:<ref-or-environment>
# rather than the older repo:<owner>/<repo>:<ref>. The default trust condition therefore
# matches repo:<owner>*/<repo>*:* so it works whether or not the ids are present. Pin it
# exactly with github_sub_claim below once you know your account's ids (recommended for prod).
variable "github_sub_claim" {
  description = <<-EOT
    StringLike pattern for token.actions.githubusercontent.com:sub. Leave empty to derive
    repo:<owner>*/<repo>*:* from github_owner/github_repo. Set explicitly to pin the numeric
    ids, e.g. repo:huraisturkey-lang@277442410/spbc-pastry-concierge@1430159845:*
  EOT
  type        = string
  default     = ""
}

variable "role_name" {
  description = "Name of the deploy role GitHub Actions assumes."
  type        = string
  default     = "SPBC-GitHubActions-Deploy"
}

variable "execution_role_name_patterns" {
  description = <<-EOT
    IAM role name patterns the deploy role may create/update/pass. Covers every role the
    deploy path touches: this project's roles (both hyphen and underscore spellings), the
    Cognito identity-pool roles, the Bedrock KB execution role, the EKS stack roles, and the
    AgentCore starter-toolkit CodeBuild role the zip/container launch auto-creates.
  EOT
  type        = list(string)
  default = [
    "SPBC-*",
    "SPBC_*",
    "spbc-*",
    "Cognito_*",
    "AmazonBedrockExecutionRoleForKnowledgeBase_*",
    "AmazonBedrockAgentCore*",
    "pastrycafe-*",
  ]
}

variable "manage_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider in this stack. Set false if the account already has a
    token.actions.githubusercontent.com provider managed elsewhere; then pass its ARN via
    existing_oidc_provider_arn.
  EOT
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of a pre-existing GitHub OIDC provider to use when manage_oidc_provider = false."
  type        = string
  default     = ""
}

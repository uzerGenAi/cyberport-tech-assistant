variable "aws_region" {
  description = "Region for the pipeline and its resources."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "production"
}

variable "repository_name" {
  description = "CodeCommit repository name and the pipeline source."
  type        = string
  default     = "spbc-tech-assistant"
}

variable "branch_name" {
  description = "Source branch the pipeline tracks."
  type        = string
  default     = "main"
}

variable "codebuild_role_name" {
  description = "Name of the CodeBuild service role (must match an SPBC-* pattern)."
  type        = string
  default     = "SPBC-CodeBuild-Deploy"
}

variable "codepipeline_role_name" {
  description = "Name of the CodePipeline service role (must match an SPBC-* pattern)."
  type        = string
  default     = "SPBC-CodePipeline-Deploy"
}

variable "deploy_project_name" {
  description = "CodeBuild project that runs the deploy buildspec."
  type        = string
  default     = "spbc-deploy"
}

variable "ci_project_name" {
  description = "CodeBuild project that runs the validate (make ci) buildspec."
  type        = string
  default     = "spbc-ci"
}

variable "execution_role_name_patterns" {
  description = <<-EOT
    IAM role name patterns the deploy role may create/update/pass. Covers every role the
    deploy path touches: this project's roles (both hyphen and underscore spellings), the
    Cognito identity-pool roles, the Bedrock KB execution role, and the AgentCore
    starter-toolkit CodeBuild role the zip/container launch auto-creates.
  EOT
  type        = list(string)
  default = [
    "SPBC-*",
    "SPBC_*",
    "spbc-*",
    "Cognito_*",
    "AmazonBedrockExecutionRoleForKnowledgeBase_*",
    "AmazonBedrockAgentCore*",
  ]
}

variable "artifact_bucket_name" {
  description = <<-EOT
    Artifact store bucket. Empty derives spbc-pipeline-artifacts-<account_id>-<region>
    (globally unique, account-agnostic). Set to use a specific name, mirroring the
    TF_STATE_BUCKET override the repo uses for the state bucket.
  EOT
  type        = string
  default     = ""
}

variable "codebuild_image" {
  description = "CodeBuild build image."
  type        = string
  default     = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
}

variable "codebuild_compute_type" {
  description = "CodeBuild compute size."
  type        = string
  default     = "BUILD_GENERAL1_MEDIUM"
}

variable "log_retention_days" {
  description = "Retention on the two explicit CodeBuild log groups."
  type        = number
  default     = 30
}

variable "enable_manual_approval" {
  description = "Insert the Approve stage between Validate and Deploy."
  type        = bool
  default     = true
}

variable "approval_email" {
  description = "Optional email subscribed to the approvals SNS topic. Empty creates no subscription."
  type        = string
  default     = ""
}

variable "toggle_provision_backends" {
  description = "Default for the deploy env var: apply the stores DB + promotions API stack."
  type        = bool
  default     = false
}

variable "toggle_setup_knowledge_bases" {
  description = "Default for the deploy env var: create/sync the vector store and knowledge bases."
  type        = bool
  default     = false
}

variable "toggle_deploy_agent" {
  description = "Default for the deploy env var: deploy Cognito, the AgentCore runtime and the frontend."
  type        = bool
  default     = true
}

variable "toggle_smoke" {
  description = "Default for the deploy env var: run the frontend smoke test (requires smoke_test_url)."
  type        = bool
  default     = false
}

variable "cognito_admin_username" {
  description = "Passed through to post_deploy.sh; empty (with the secret id) selects --skip-user."
  type        = string
  default     = ""
}

variable "cognito_admin_password_secret_id" {
  description = "Secrets Manager id holding the admin password; empty (with the username) selects --skip-user."
  type        = string
  default     = ""
}

variable "smoke_test_url" {
  description = "Frontend URL the smoke test targets. Empty disables the smoke step regardless of the toggle."
  type        = string
  default     = ""
}

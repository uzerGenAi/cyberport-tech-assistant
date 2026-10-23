output "deploy_role_arn" {
  description = "ARN of the deploy role. Set the repo variable AWS_DEPLOY_ROLE_ARN to this."
  value       = aws_iam_role.deploy.arn
}

output "deploy_role_name" {
  description = "Name of the deploy role."
  value       = aws_iam_role.deploy.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider in use (created here or pre-existing)."
  value       = local.oidc_provider_arn
}

output "trusted_sub_claim" {
  description = "The token sub pattern this role trusts."
  value       = local.sub_claim
}

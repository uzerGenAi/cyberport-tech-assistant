output "codecommit_repository_name" {
  description = "Name of the CodeCommit source repository."
  value       = aws_codecommit_repository.this.repository_name
}

output "codecommit_clone_url_http" {
  description = "HTTPS clone URL for the CodeCommit repository (use with the AWS CLI credential helper)."
  value       = aws_codecommit_repository.this.clone_url_http
}

output "codecommit_clone_url_grc" {
  description = "git-remote-codecommit remote for the repository (SigV4, no stored git password)."
  value       = "codecommit::${var.aws_region}://${var.repository_name}"
}

output "pipeline_name" {
  description = "Name of the CodePipeline pipeline."
  value       = aws_codepipeline.this.name
}

output "codebuild_deploy_role_arn" {
  description = "ARN of the CodeBuild service role carrying SPBC-Deploy-Permissions."
  value       = aws_iam_role.codebuild_deploy.arn
}

output "codepipeline_role_arn" {
  description = "ARN of the CodePipeline service role."
  value       = aws_iam_role.codepipeline.arn
}

output "artifact_bucket" {
  description = "Name of the pipeline artifact bucket."
  value       = local.artifact_bucket_name
}

output "approvals_topic_arn" {
  description = "ARN of the manual-approval SNS topic."
  value       = aws_sns_topic.approvals.arn
}

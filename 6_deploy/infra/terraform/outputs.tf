output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "app_fqdn" {
  value = local.app_fqdn
}

output "certificate_arn" {
  value = try(aws_acm_certificate.app[0].arn, "")
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN used by the Cluster Autoscaler service account"
  value       = aws_iam_role.cluster_autoscaler.arn
}

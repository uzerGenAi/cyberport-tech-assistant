variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "pastrycafe-prod"
}

variable "app_name" {
  description = "Application name"
  type        = string
  default     = "pastrycafe"
}

variable "domain_name" {
  description = "Top-level domain managed in Route 53"
  type        = string
  default     = "cloudageglobal.com"
}

variable "app_subdomain" {
  description = "Subdomain used for the application"
  type        = string
  default     = "pastrycafe"
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for the domain"
  type        = string
  default     = ""
}

variable "route53_alias_name" {
  description = "Alias target DNS name for the app Route 53 record"
  type        = string
  default     = ""
}

variable "route53_alias_zone_id" {
  description = "Alias target hosted zone ID for the app Route 53 record"
  type        = string
  default     = ""
}

variable "node_instance_type" {
  description = "EKS node group instance type"
  type        = string
  default     = "t3.medium"
}

variable "desired_node_count" {
  description = "Desired number of EKS nodes"
  type        = number
  default     = 2
}

variable "eks_public_access_cidrs" {
  description = <<-EOT
    CIDRs permitted to reach the EKS public API endpoint.
    MUST be restricted before production use.
    Run `bash 6_deploy/scripts/terraform_backend_setup.sh` to auto-detect your current
    outbound IP and write this value into terraform.tfvars automatically.
    Example: ["203.0.113.10/32", "198.51.100.0/24"]
  EOT
  type        = list(string)
  # No default — operator must supply this value explicitly.
  # terraform_backend_setup.sh writes it to terraform.tfvars automatically.
}

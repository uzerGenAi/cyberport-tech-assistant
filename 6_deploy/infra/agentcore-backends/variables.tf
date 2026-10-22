variable "aws_region" {
  description = "Region for every backend resource. Must match the AgentCore runtime's Region."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Deployment environment tag."
  type        = string
  default     = "prod"
}

variable "name_prefix" {
  description = "Prefix for resource names. The agents and setup_env.sh expect the default."
  type        = string
  default     = "spbc"
}

variable "log_retention_days" {
  description = "Retention for the CloudWatch log groups this stack creates."
  type        = number
  default     = 30
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR of the isolated VPC created for the stores database (no internet gateway, no NAT). Ignored when existing_subnet_ids is set."
  type        = string
  default     = "10.30.0.0/24"
}

variable "existing_vpc_id" {
  description = "Use an existing VPC for the database instead of creating an isolated one. Set together with existing_subnet_ids."
  type        = string
  default     = ""
}

variable "existing_subnet_ids" {
  description = "Private subnets (at least two AZs) in existing_vpc_id for the database."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.existing_subnet_ids) == 0 || length(var.existing_subnet_ids) >= 2
    error_message = "Aurora needs subnets in at least two Availability Zones."
  }
}

variable "db_ingress_security_group_ids" {
  description = "Security groups allowed to reach MySQL (3306) directly. The agents use the Data API, which needs no network path, so leave empty unless a VPC-attached client needs it."
  type        = list(string)
  default     = []
}

variable "enable_vpc_flow_logs" {
  description = "Send flow logs of the created VPC to CloudWatch Logs."
  type        = bool
  default     = true
}

# ── Stores database (Aurora MySQL Serverless v2) ─────────────────────────────

variable "aurora_engine_version" {
  description = "Aurora MySQL engine version, e.g. 8.0.mysql_aurora.3.08.2. Empty selects the latest MySQL 8.0-compatible (3.x) version; the Data API needs 3.07 or later."
  type        = string
  default     = ""
}

variable "aurora_min_acu" {
  description = "Minimum Aurora Serverless v2 capacity (ACU). 0 lets idle instances pause (non-production cost saver; Aurora MySQL 3.08+): the first query after a pause waits about 15 s while the agents retry."
  type        = number
  default     = 0.5

  validation {
    condition     = var.aurora_min_acu >= 0 && var.aurora_min_acu <= 256
    error_message = "aurora_min_acu must be between 0 and 256."
  }
}

variable "aurora_seconds_until_auto_pause" {
  description = "Idle seconds before an instance pauses. Only used when aurora_min_acu is 0."
  type        = number
  default     = 300

  validation {
    condition     = var.aurora_seconds_until_auto_pause >= 300 && var.aurora_seconds_until_auto_pause <= 86400
    error_message = "aurora_seconds_until_auto_pause must be between 300 and 86400."
  }
}

variable "aurora_max_acu" {
  description = "Maximum Aurora Serverless v2 capacity (ACU)."
  type        = number
  default     = 4

  validation {
    condition     = var.aurora_max_acu >= 1 && var.aurora_max_acu <= 256
    error_message = "aurora_max_acu must be between 1 and 256."
  }
}

variable "aurora_instance_count" {
  description = "Number of Serverless v2 instances. 2 gives a standby in another AZ (production default); 1 halves the cost."
  type        = number
  default     = 2

  validation {
    condition     = var.aurora_instance_count >= 1 && var.aurora_instance_count <= 3
    error_message = "aurora_instance_count must be 1, 2 or 3."
  }
}

variable "aurora_backup_retention_days" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7

  validation {
    condition     = var.aurora_backup_retention_days >= 1 && var.aurora_backup_retention_days <= 35
    error_message = "aurora_backup_retention_days must be between 1 and 35."
  }
}

variable "aurora_deletion_protection" {
  description = "Protect the cluster from deletion. Set to false and apply before running terraform destroy."
  type        = bool
  default     = true
}

# ── Promotions API ────────────────────────────────────────────────────────────

variable "promotions_api_rate_limit" {
  description = "Steady-state requests per second allowed on the promotions API."
  type        = number
  default     = 10
}

variable "promotions_api_burst_limit" {
  description = "Burst requests allowed on the promotions API."
  type        = number
  default     = 20
}

# ── Orders table ──────────────────────────────────────────────────────────────

variable "create_orders_table" {
  description = "Create spbc-orders-table here. Leave false if the EKS stack (make provision) already created it; two stacks can't own the same table."
  type        = bool
  default     = false
}

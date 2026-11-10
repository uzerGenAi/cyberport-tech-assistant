# Stores database: Aurora MySQL Serverless v2 with the RDS Data API enabled.
#
# Credentials:
#   - admin  : master user, password generated and rotated by RDS in Secrets Manager. Used only by
#              2_data_strategy/stores/load_stores_data_api.py to create the schema and load data.
#   - reader : stores_reader, SELECT on StoresDB.stores only. Its secret is what the agents use.
#              The loader creates/updates the MySQL user from this secret.

data "aws_caller_identity" "current" {}

locals {
  cluster_identifier = "${var.name_prefix}-aurora-cluster" # agents' legacy discovery uses this prefix
  db_name            = "StoresDB"
  reader_username    = "stores_reader"
}

data "aws_rds_engine_version" "stores" {
  engine  = "aurora-mysql"
  version = var.aurora_engine_version != "" ? var.aurora_engine_version : "8.0"
  latest  = var.aurora_engine_version == ""
}

resource "aws_db_subnet_group" "stores" {
  name        = "${var.name_prefix}-stores-db"
  description = "Private subnets for the stores database"
  subnet_ids  = local.subnet_ids
}

resource "aws_rds_cluster_parameter_group" "stores" {
  name        = "${var.name_prefix}-stores-db"
  family      = data.aws_rds_engine_version.stores.parameter_group_family
  description = "Stores database: TLS required"

  parameter {
    name  = "require_secure_transport"
    value = "ON"
  }
}

resource "aws_rds_cluster" "stores" {
  cluster_identifier = local.cluster_identifier
  engine             = "aurora-mysql"
  engine_mode        = "provisioned"
  engine_version     = data.aws_rds_engine_version.stores.version
  database_name      = local.db_name

  master_username             = "spbc_admin"
  manage_master_user_password = true

  # RDS Data API: HTTPS + IAM access, so clients need no network path or DB driver
  enable_http_endpoint = true

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
    # RDS accepts an auto-pause delay only with a 0 ACU minimum
    seconds_until_auto_pause = var.aurora_min_acu == 0 ? var.aurora_seconds_until_auto_pause : null
  }

  db_subnet_group_name            = aws_db_subnet_group.stores.name
  vpc_security_group_ids          = [aws_security_group.stores_db.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.stores.name

  storage_encrypted               = true
  backup_retention_period         = var.aurora_backup_retention_days
  preferred_backup_window         = "02:00-03:00"
  preferred_maintenance_window    = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot           = true
  deletion_protection             = var.aurora_deletion_protection
  skip_final_snapshot             = var.aurora_skip_final_snapshot
  final_snapshot_identifier       = "${local.cluster_identifier}-final"
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]
  apply_immediately               = false

  lifecycle {
    # Minor versions are upgraded by RDS during maintenance; don't fight that on the next plan
    ignore_changes = [engine_version]

    precondition {
      condition     = var.aurora_min_acu <= var.aurora_max_acu
      error_message = "aurora_min_acu must not exceed aurora_max_acu."
    }
  }
}

resource "aws_rds_cluster_instance" "stores" {
  count = var.aurora_instance_count

  identifier         = "${local.cluster_identifier}-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.stores.id
  engine             = aws_rds_cluster.stores.engine
  engine_version     = aws_rds_cluster.stores.engine_version
  instance_class     = "db.serverless"

  publicly_accessible          = false
  auto_minor_version_upgrade   = true
  performance_insights_enabled = true

  lifecycle {
    ignore_changes = [engine_version]
  }
}

# ── Least-privilege reader credentials used by the agents ─────────────────────

resource "random_password" "stores_reader" {
  length  = 32
  special = false # alphanumeric only: the loader embeds it in CREATE/ALTER USER
}

resource "aws_secretsmanager_secret" "stores_reader" {
  name                    = "${var.name_prefix}-stores-db-reader"
  description             = "Read-only MySQL user for the stores agent (Data API)"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "stores_reader" {
  secret_id = aws_secretsmanager_secret.stores_reader.id
  secret_string = jsonencode({
    engine              = "mysql"
    username            = local.reader_username
    password            = random_password.stores_reader.result
    dbClusterIdentifier = aws_rds_cluster.stores.cluster_identifier
    dbname              = local.db_name
  })
}

# Source repository, artifact store, and approval topic.

resource "aws_codecommit_repository" "this" {
  repository_name = var.repository_name
  default_branch  = "main"
  description     = "SPBC Pastry Concierge source. Push to ${var.branch_name} to trigger the pipeline."
}

resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifact_bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # Expire artifacts to bound storage cost; the artifact store is not a long-term archive.
  rule {
    id     = "expire-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}

resource "aws_sns_topic" "approvals" {
  name = "spbc-pipeline-approvals"
}

resource "aws_sns_topic_subscription" "approval_email" {
  count = var.approval_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.approvals.arn
  protocol  = "email"
  endpoint  = var.approval_email
}

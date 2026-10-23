# CodeBuild projects and their log groups. The log groups are created explicitly (not left to
# CodeBuild's auto-creation) so retention is bounded and the ARNs are deterministic for the
# SPBC-CodeBuild-Logs-Artifacts policy in iam.tf.

resource "aws_cloudwatch_log_group" "deploy" {
  name              = "/aws/codebuild/${var.deploy_project_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "ci" {
  name              = "/aws/codebuild/${var.ci_project_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_codebuild_project" "deploy" {
  name          = var.deploy_project_name
  description   = "Runs the SPBC Pastry Concierge deploy buildspec."
  service_role  = aws_iam_role.codebuild_deploy.arn
  build_timeout = 120

  source {
    type      = "CODEPIPELINE"
    buildspec = "6_deploy/codepipeline/buildspec-deploy.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    image                       = var.codebuild_image
    compute_type                = var.codebuild_compute_type
    privileged_mode             = false
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TOGGLE_PROVISION_BACKENDS"
      value = var.toggle_provision_backends ? "true" : "false"
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "TOGGLE_SETUP_KNOWLEDGE_BASES"
      value = var.toggle_setup_knowledge_bases ? "true" : "false"
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "TOGGLE_DEPLOY_AGENT"
      value = var.toggle_deploy_agent ? "true" : "false"
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "TOGGLE_DEPLOY_EKS"
      value = var.toggle_deploy_eks ? "true" : "false"
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "TOGGLE_SMOKE"
      value = var.toggle_smoke ? "true" : "false"
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "COGNITO_ADMIN_USERNAME"
      value = var.cognito_admin_username
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "COGNITO_ADMIN_PASSWORD_SECRET_ID"
      value = var.cognito_admin_password_secret_id
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "SMOKE_TEST_URL"
      value = var.smoke_test_url
      type  = "PLAINTEXT"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.deploy.name
    }
  }
}

resource "aws_codebuild_project" "ci" {
  name          = var.ci_project_name
  description   = "Runs the SPBC Pastry Concierge validate buildspec (make ci)."
  service_role  = aws_iam_role.codebuild_deploy.arn
  build_timeout = 120

  source {
    type      = "CODEPIPELINE"
    buildspec = "6_deploy/codepipeline/buildspec-ci.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    image                       = var.codebuild_image
    compute_type                = var.codebuild_compute_type
    privileged_mode             = false
    image_pull_credentials_type = "CODEBUILD"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.ci.name
    }
  }
}

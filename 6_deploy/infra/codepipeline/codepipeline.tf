# V2 pipeline: Source (CodeCommit) -> Validate (make ci) -> Approve (manual, optional) ->
# Deploy. The deploy toggles are exposed as pipeline-level variables so a single run can flip
# them at release time; the Deploy action passes them through as EnvironmentVariables that
# override the CodeBuild project defaults.

resource "aws_codepipeline" "this" {
  name          = var.repository_name
  pipeline_type = "V2"
  role_arn      = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  variable {
    name          = "TOGGLE_PROVISION_BACKENDS"
    default_value = var.toggle_provision_backends ? "true" : "false"
    description   = "Apply the stores DB + promotions API stack."
  }

  variable {
    name          = "TOGGLE_SETUP_KNOWLEDGE_BASES"
    default_value = var.toggle_setup_knowledge_bases ? "true" : "false"
    description   = "Create/sync the vector store and knowledge bases."
  }

  variable {
    name          = "TOGGLE_DEPLOY_AGENT"
    default_value = var.toggle_deploy_agent ? "true" : "false"
    description   = "Deploy Cognito, the AgentCore runtime and the frontend."
  }

  variable {
    name          = "TOGGLE_SMOKE"
    default_value = var.toggle_smoke ? "true" : "false"
    description   = "Run the frontend smoke test (requires SMOKE_TEST_URL)."
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName       = var.repository_name
        BranchName           = var.branch_name
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Validate"

    action {
      name            = "Validate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = var.ci_project_name
      }
    }
  }

  dynamic "stage" {
    for_each = var.enable_manual_approval ? [1] : []

    content {
      name = "Approve"

      action {
        name     = "Approve"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"

        configuration = {
          NotificationArn = aws_sns_topic.approvals.arn
        }
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = var.deploy_project_name
        EnvironmentVariables = jsonencode([
          { name = "TOGGLE_PROVISION_BACKENDS", value = "#{variables.TOGGLE_PROVISION_BACKENDS}", type = "PLAINTEXT" },
          { name = "TOGGLE_SETUP_KNOWLEDGE_BASES", value = "#{variables.TOGGLE_SETUP_KNOWLEDGE_BASES}", type = "PLAINTEXT" },
          { name = "TOGGLE_DEPLOY_AGENT", value = "#{variables.TOGGLE_DEPLOY_AGENT}", type = "PLAINTEXT" },
          { name = "TOGGLE_SMOKE", value = "#{variables.TOGGLE_SMOKE}", type = "PLAINTEXT" },
        ])
      }
    }
  }
}

# Offline plan tests (no AWS credentials needed): terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
    }
  }

  mock_data "aws_rds_engine_version" {
    defaults = {
      version                = "8.0.mysql_aurora.3.10.0"
      parameter_group_family = "aurora-mysql8.0"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_rds_cluster" {
    defaults = {
      arn = "arn:aws:rds:eu-central-1:111111111111:cluster:spbc-aurora-cluster"
      master_user_secret = [{
        kms_key_id    = "alias/aws/secretsmanager"
        secret_arn    = "arn:aws:secretsmanager:eu-central-1:111111111111:secret:rds!cluster-abc-AbCdEf"
        secret_status = "active"
      }]
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      execution_arn = "arn:aws:execute-api:eu-central-1:111111111111:abc123"
    }
  }

  mock_resource "aws_apigatewayv2_stage" {
    defaults = {
      invoke_url = "https://abc123.execute-api.eu-central-1.amazonaws.com/prod"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:eu-central-1:111111111111:secret:spbc-stores-db-reader-AbCdEf"
    }
  }

  # ARN-typed attributes are validated, so mocked values must look like real ARNs
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/mock-role"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-central-1:111111111111:log-group:mock"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:eu-central-1:111111111111:function:spbc-promotions-api"
      invoke_arn = "arn:aws:apigateway:eu-central-1:lambda:path/2015-03-31/functions/arn:aws:lambda:eu-central-1:111111111111:function:spbc-promotions-api/invocations"
    }
  }
}

run "defaults_create_isolated_vpc_and_data_api_cluster" {
  command = apply

  assert {
    condition     = length(aws_vpc.backends) == 1 && length(aws_subnet.db) == 3
    error_message = "An isolated VPC with three subnets should be created by default."
  }

  assert {
    condition     = aws_rds_cluster.stores.enable_http_endpoint && aws_rds_cluster.stores.storage_encrypted
    error_message = "The cluster must have the Data API and storage encryption enabled."
  }

  assert {
    condition     = aws_rds_cluster.stores.cluster_identifier == "spbc-aurora-cluster" && aws_rds_cluster.stores.deletion_protection
    error_message = "Cluster identifier or deletion protection is wrong."
  }

  assert {
    condition     = length(aws_rds_cluster_instance.stores) == 2
    error_message = "Two Serverless v2 instances are expected by default."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.stores_db) == 0
    error_message = "The database must have no network ingress by default."
  }

  assert {
    condition     = aws_apigatewayv2_route.get_promotions.authorization_type == "AWS_IAM"
    error_message = "The promotions route must require IAM authorization."
  }

  assert {
    condition     = output.promotions_api_url == "https://abc123.execute-api.eu-central-1.amazonaws.com/prod/promotions"
    error_message = "Unexpected promotions_api_url: ${output.promotions_api_url}"
  }

  assert {
    condition     = output.promotions_api_invoke_arn == "arn:aws:execute-api:eu-central-1:111111111111:abc123/prod/GET/promotions"
    error_message = "Unexpected promotions_api_invoke_arn: ${output.promotions_api_invoke_arn}"
  }

  assert {
    condition     = output.agentcore_runtime_env["STORES_DB_NAME"] == "StoresDB" && length(output.agentcore_runtime_env) == 4
    error_message = "agentcore_runtime_env must expose the four runtime variables."
  }

  assert {
    condition     = length(aws_dynamodb_table.orders) == 0 && length(aws_flow_log.backends) == 1
    error_message = "Orders table must be opt-in and flow logs on by default."
  }
}

run "existing_vpc_skips_network_creation" {
  command = plan

  variables {
    existing_vpc_id               = "vpc-0123456789abcdef0"
    existing_subnet_ids           = ["subnet-aaa", "subnet-bbb"]
    db_ingress_security_group_ids = ["sg-0123456789abcdef0"]
  }

  assert {
    condition     = length(aws_vpc.backends) == 0 && length(aws_flow_log.backends) == 0
    error_message = "No VPC or flow log should be created when an existing VPC is supplied."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.stores_db) == 1
    error_message = "One ingress rule per supplied security group is expected."
  }
}

run "existing_subnets_require_vpc_id" {
  command = plan

  variables {
    existing_subnet_ids = ["subnet-aaa", "subnet-bbb"]
  }

  expect_failures = [aws_security_group.stores_db]
}

run "orders_table_is_opt_in" {
  command = plan

  variables {
    create_orders_table = true
  }

  assert {
    condition     = aws_dynamodb_table.orders[0].hash_key == "user_id" && aws_dynamodb_table.orders[0].range_key == "order_timestamp"
    error_message = "Orders table key schema must match what the agents query."
  }
}

run "auto_pause_only_with_zero_min_capacity" {
  command = plan

  variables {
    aurora_min_acu        = 0
    aurora_instance_count = 1
  }

  assert {
    condition     = aws_rds_cluster.stores.serverlessv2_scaling_configuration[0].seconds_until_auto_pause == 300
    error_message = "A 0 ACU minimum must set the auto-pause delay."
  }
}

run "no_auto_pause_by_default" {
  command = plan

  # (seconds_until_auto_pause is provider-computed when unset, so only the minimum is asserted)
  assert {
    condition     = aws_rds_cluster.stores.serverlessv2_scaling_configuration[0].min_capacity == 0.5
    error_message = "The production default keeps a 0.5 ACU minimum (no auto-pause)."
  }
}

run "rejects_min_above_max" {
  command = plan

  variables {
    aurora_min_acu = 8
    aurora_max_acu = 4
  }

  expect_failures = [aws_rds_cluster.stores]
}

run "rejects_too_many_instances" {
  command = plan

  variables {
    aurora_instance_count = 5
  }

  expect_failures = [var.aurora_instance_count]
}

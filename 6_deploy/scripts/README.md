# Deployment Scripts

Deployment assets for the SPBC Tech Assistant. All of these run without a terminal, so they
can be driven by the CodePipeline Deploy stage via
[6_deploy/codepipeline/buildspec-deploy.yml](../codepipeline/buildspec-deploy.yml).

## AgentCore and data backends
- `agentcore_backends.sh`: Terraform stack `6_deploy/infra/agentcore-backends` (stores database through the RDS Data API + IAM-authorized promotions API): `plan`, `apply` (applies exactly the reviewed plan; `AUTO_APPROVE=1` to skip the prompt), `seed`, `check`, `env`, `policy`, `validate`, guarded `destroy`. Run `bash agentcore_backends.sh help`.
- `post_deploy.sh`: Cognito → AgentCore runtime → Amplify. `--force` redeploys even when the config files are populated; `--skip-user` / `--non-interactive` are passed through to the Cognito script.
- `setup_cognito_auth.sh`: User Pool, Identity Pool and IAM role. The sign-in user comes from `COGNITO_ADMIN_USERNAME` plus `COGNITO_ADMIN_PASSWORD_SECRET_ID` or `COGNITO_ADMIN_PASSWORD`; `--skip-user` creates none. It prompts only when a terminal is attached.

## Infrastructure
- `terraform_backend_setup.sh`: creates the S3 bucket that holds the Terraform state (versioned, encrypted, non-public). Idempotent and non-interactive; `TF_STATE_BUCKET` overrides the name.
- `ci_checks.sh`: local CI (`make ci`): Python compile, Terraform fmt/validate on both stacks, and the mocked `terraform test` suite for the backends.

## Verification
- `smoke_test.sh`: requires `SMOKE_TEST_URL` and checks the response body is this app, so a 200 from a holding page fails. `SMOKE_EXPECT`, `SMOKE_RETRIES` and `SMOKE_TIMEOUT` tune it.

## Frontend
- `amplify-deploy.sh`: creates or reuses the Amplify app and deploys `6_deploy/web-app`.


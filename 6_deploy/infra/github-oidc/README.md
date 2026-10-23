# GitHub Actions OIDC deploy role

Terraform for the IAM the CI deploy pipeline (`.github/workflows/deploy.yml`) needs:

- the **GitHub OIDC identity provider** (`token.actions.githubusercontent.com`),
- the **deploy role** `SPBC-GitHubActions-Deploy` with a trust policy restricted to this
  repository, and
- its **permissions policy** `SPBC-Deploy-Permissions`.

These were originally created by hand while bringing the pipeline up. This stack captures
them so a fresh account is reproducible and the live policy doesn't silently drift.

## Apply

```bash
cd 6_deploy/infra/github-oidc
cp terraform.tfvars.example terraform.tfvars   # edit github_owner / github_repo
terraform init
terraform apply
```

Then set the repository variable `AWS_DEPLOY_ROLE_ARN` to the `deploy_role_arn` output
(Settings → Secrets and variables → Actions → Variables).

## Adopting the existing hand-made resources

If the role and provider already exist in the account (as in the original deployment), import
them instead of recreating:

```bash
terraform import aws_iam_role.deploy SPBC-GitHubActions-Deploy
terraform import aws_iam_role_policy.permissions SPBC-GitHubActions-Deploy:SPBC-Deploy-Permissions
terraform import 'aws_iam_openid_connect_provider.github[0]' \
  arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
terraform plan   # should show no changes, or only tag/thumbprint drift to reconcile
```

If another stack already manages the OIDC provider, set `manage_oidc_provider = false` and
pass `existing_oidc_provider_arn`.

## Security notes

- Service actions are broad (`*` resources) because this is a single-project deploy role, but
  the sensitive parts — `iam:CreateRole`, `iam:PassRole`, `iam:UpdateAssumeRolePolicy`, etc. —
  are scoped to this project's role-name patterns (`execution_role_name_patterns`), never `*`.
- The trust `sub` pattern tolerates GitHub's immutable numeric ids by default. For production,
  set `github_sub_claim` to the exact pinned value (see `terraform.tfvars.example`).
- The patterns include `AmazonBedrockAgentCore*`, the role the AgentCore starter toolkit
  auto-creates during a runtime launch; without it the launch fails with AccessDenied.

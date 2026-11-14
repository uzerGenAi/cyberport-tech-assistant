# CodePipeline deploy stack

All-AWS CI/CD for the SPBC Tech Assistant: a CodeCommit source repository, a V2 CodePipeline
(`Source` → `Validate` → `Approve` → `Deploy`), two CodeBuild projects (`spbc-ci` runs
`make ci`, `spbc-deploy` runs the deploy buildspec), an artifact S3 bucket, a manual-approval
SNS topic, and the CodeBuild / CodePipeline IAM roles. This replaces the retired GitHub Actions
workflows and the `github-oidc` role stack.

The buildspecs live under [`6_deploy/codepipeline/`](../../codepipeline/):
`buildspec-ci.yml` and `buildspec-deploy.yml`.

## 1. Apply order / bootstrap

The Terraform state bucket `spbc-tfstate-<account-id>` (derived from your AWS account, because bucket names are global) must exist **before** `terraform init`
(the same chicken-and-egg as the agentcore-backends stack). Create it with:

```sh
make backend-setup
```

That runs `6_deploy/scripts/terraform_backend_setup.sh`: it creates a versioned, encrypted,
non-public bucket, prompts for nothing, and does nothing if the bucket already exists. Both
stacks lock their state with an S3 lock file, so no DynamoDB lock table is needed.

Then apply this stack:

```sh
terraform -chdir=6_deploy/infra/codepipeline init \
  -backend-config="bucket=spbc-tfstate-$(aws sts get-caller-identity --query Account --output text)"
terraform -chdir=6_deploy/infra/codepipeline apply
```
The bucket is not written in `versions.tf`; pass it at init as above (use your `TF_STATE_BUCKET` name instead if you set one).

The **artifact** bucket is a separate resource with its own knob: set
`artifact_bucket_name` to pin a name, otherwise it derives
`spbc-pipeline-artifacts-<account_id>-<region>`.

## 2. Push the repo to CodeCommit

Two options. `git-remote-codecommit` (GRC) is recommended for IAM users without git
credentials — it signs with SigV4 from the current AWS identity, so there is no stored git
password:

```sh
pip install git-remote-codecommit
git remote add codecommit codecommit::eu-central-1://spbc-tech-assistant
git push codecommit main
```

Alternatively, clone/push over HTTPS using the `codecommit_clone_url_http` output together with
the AWS CLI git credential helper (`git config --global credential.helper '!aws codecommit
credential-helper $@'` and `credential.UseHttpPath true`).

## 3. Trigger and approve

Pushing to `main` starts the pipeline (CodePipeline manages the EventBridge rule on the repo;
`PollForSourceChanges` is `false`):

- **Validate** runs `make ci` in `spbc-ci`.
- **Approve** (present when `enable_manual_approval = true`) pauses the pipeline and notifies
  the `spbc-pipeline-approvals` SNS topic. Approve in the console, or:

  ```sh
  aws codepipeline put-approval-result \
    --pipeline-name spbc-tech-assistant \
    --stage-name Approve \
    --action-name Approve \
    --result summary="ok",status=Approved \
    --token <token-from-get-pipeline-state>
  ```

- **Deploy** runs the deploy buildspec in `spbc-deploy`.

Subscribe an address to the approvals topic by setting `approval_email`, or add it in SNS after
apply.

## 4. Toggle env vars

The deploy buildspec is gated by four toggles, exposed as pipeline-level variables (defaults
come from the matching `toggle_*` Terraform variables) and passed into the Deploy action as
`EnvironmentVariables`:

| Pipeline variable | Default | Effect |
|---|---|---|
| `TOGGLE_PROVISION_BACKENDS` | `false` | Apply the backends stack (stores DB, promotions API, orders table, order-admin Lambda), seed, and check. |
| `TOGGLE_SETUP_KNOWLEDGE_BASES` | `false` | Bootstrap the vector store and create/sync the knowledge bases. |
| `TOGGLE_DEPLOY_AGENT` | `true` | Deploy Cognito, the AgentCore runtime, the frontend, then verify the agent. |
| `TOGGLE_SMOKE` | `false` | Run the frontend smoke test. |

Only `TOGGLE_DEPLOY_AGENT` is on by default. Override per run by editing the pipeline variable
values when you start the execution.

The deploy stage runs `./deploy.sh` (the same command used by hand) and maps the toggles to
`SKIP_STEPS`. `DEMO_USERNAME` (Terraform variable `demo_username`, default `enterprise`) names the
default sign-in user; its password lives only in Secrets Manager (`spbc-demo-user`) and is never
printed in the build log. Read it afterwards with `make demo-user`. The smoke step runs only
when `TOGGLE_SMOKE` is true **and** `SMOKE_TEST_URL` is set.

## 5. Security note

Same posture as the retired `github-oidc` README. The `SPBC-Deploy-Permissions` policy on the
CodeBuild role is ported verbatim from that stack: service actions are deliberately broad on
`*` (this is a single-project deploy role), while the sensitive IAM role management and
`iam:PassRole` are scoped to this project's role-name patterns (`SPBC-*`, `Cognito_*`, the
Bedrock KB execution role, the AgentCore starter-toolkit role) and never
`*`.

The role is assumed by CodeBuild directly (`codebuild.amazonaws.com`) — there is no OIDC
federation. The policy's scoped role-management set includes patterns that can match the
pipeline's own roles; that self/sibling role-modify capability is carried forward unchanged
from the github-oidc policy. In normal operation the deploy role never runs `terraform apply`
on this `codepipeline` stack (that is an operator bootstrap action), so it does not exercise
that capability.

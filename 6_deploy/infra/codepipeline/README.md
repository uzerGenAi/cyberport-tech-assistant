# CodePipeline deploy stack

All-AWS CI/CD for the SPBC Pastry Concierge: a CodeCommit source repository, a V2 CodePipeline
(`Source` → `Validate` → `Approve` → `Deploy`), two CodeBuild projects (`spbc-ci` runs
`make ci`, `spbc-deploy` runs the deploy buildspec), an artifact S3 bucket, a manual-approval
SNS topic, and the CodeBuild / CodePipeline IAM roles. This replaces the retired GitHub Actions
workflows and the `github-oidc` role stack.

The buildspecs live under [`6_deploy/codepipeline/`](../../codepipeline/):
`buildspec-ci.yml` and `buildspec-deploy.yml`.

## 1. Apply order / bootstrap

The Terraform state bucket `spbc-tfstate-eu-central-1` must exist **before** `terraform init`
(the same chicken-and-egg as the other stacks). Two ways to create it — pick knowingly:

**Recommended for this stack — create the state bucket directly.** This stack only needs the
bucket to exist, and this avoids the EKS-stack side effects of the alternative below:

```sh
aws s3api create-bucket \
  --bucket spbc-tfstate-eu-central-1 \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

aws s3api put-bucket-versioning \
  --bucket spbc-tfstate-eu-central-1 \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket spbc-tfstate-eu-central-1 \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

**Or reuse `make backend-setup`** (what the other stacks' docs point at) — but note two real
behaviours of `terraform_backend_setup.sh`:

- The CIDR is **not** "any value". With no `--cidr` / `EKS_PUBLIC_ACCESS_CIDRS` it attempts
  outbound-IP auto-detection and **errors out** if that fails; it refuses `0.0.0.0/0` without
  `--allow-open`.
- It **rewrites `6_deploy/infra/terraform/terraform.tfvars`** (the EKS stack's vars) as a side
  effect.

  So run it with an explicit placeholder to skip detection, and be aware it mutates the EKS
  stack's tfvars:

  ```sh
  EKS_PUBLIC_ACCESS_CIDRS=<your-ip>/32 make backend-setup
  ```

Then apply this stack:

```sh
terraform -chdir=6_deploy/infra/codepipeline init
terraform -chdir=6_deploy/infra/codepipeline apply
```

Override the **state** bucket at init if your account uses a different one (same
`-backend-config` / `TF_STATE_BUCKET` pattern as the other stacks):

```sh
terraform -chdir=6_deploy/infra/codepipeline init \
  -backend-config="bucket=<your-state-bucket>"
```

The **artifact** bucket is a separate resource with its own knob: set
`artifact_bucket_name` to pin a name, otherwise it derives
`spbc-pipeline-artifacts-<account_id>-<region>`.

## 2. Push the repo to CodeCommit

Two options. `git-remote-codecommit` (GRC) is recommended for IAM users without git
credentials — it signs with SigV4 from the current AWS identity, so there is no stored git
password:

```sh
pip install git-remote-codecommit
git remote add codecommit codecommit::eu-central-1://spbc-pastry-concierge
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
    --pipeline-name spbc-pastry-concierge \
    --stage-name Approve \
    --action-name Approve \
    --result summary="ok",status=Approved \
    --token <token-from-get-pipeline-state>
  ```

- **Deploy** runs the deploy buildspec in `spbc-deploy`.

Subscribe an address to the approvals topic by setting `approval_email`, or add it in SNS after
apply.

## 4. Toggle env vars

The deploy buildspec is gated by five toggles, exposed as pipeline-level variables (defaults
come from the matching `toggle_*` Terraform variables) and passed into the Deploy action as
`EnvironmentVariables`:

| Pipeline variable | Default | Effect |
|---|---|---|
| `TOGGLE_PROVISION_BACKENDS` | `false` | Apply the stores DB + promotions API stack, seed, and check. |
| `TOGGLE_SETUP_KNOWLEDGE_BASES` | `false` | Bootstrap the vector store and create/sync the knowledge bases. |
| `TOGGLE_DEPLOY_AGENT` | `true` | Deploy Cognito, the AgentCore runtime, the frontend, then verify the agent. |
| `TOGGLE_DEPLOY_EKS` | `false` | Build the web image and do a blue/green rollout onto EKS. |
| `TOGGLE_SMOKE` | `false` | Run the frontend smoke test. |

Only `TOGGLE_DEPLOY_AGENT` is on by default. Override per run by editing the pipeline variable
values when you start the execution.

`COGNITO_ADMIN_USERNAME` and `COGNITO_ADMIN_PASSWORD_SECRET_ID` are plumbed through to
`post_deploy.sh`: if either is empty the deploy passes `--skip-user` (infrastructure only). The
smoke step runs only when `TOGGLE_SMOKE` is true **and** `SMOKE_TEST_URL` is set.

## 5. Security note

Same posture as the retired `github-oidc` README. The `SPBC-Deploy-Permissions` policy on the
CodeBuild role is ported verbatim from that stack: service actions are deliberately broad on
`*` (this is a single-project deploy role), while the sensitive IAM role management and
`iam:PassRole` are scoped to this project's role-name patterns (`SPBC-*`, `Cognito_*`, the
Bedrock KB execution role, the EKS stack roles, the AgentCore starter-toolkit role) and never
`*`.

The role is assumed by CodeBuild directly (`codebuild.amazonaws.com`) — there is no OIDC
federation. The policy's scoped role-management set includes patterns that can match the
pipeline's own roles; that self/sibling role-modify capability is carried forward unchanged
from the github-oidc policy. In normal operation the deploy role never runs `terraform apply`
on this `codepipeline` stack (that is an operator bootstrap action), so it does not exercise
that capability.

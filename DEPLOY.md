# Deploy the Cyberport Tech Assistant

Two roles, two parts:

- **Part A, the developer:** writes the code and pushes it to GitHub.
- **Part B, the deployer:** clones it and deploys it into **their own AWS account**: Terraform first, then `./deploy.sh`.

Nothing in the repository is tied to one AWS account: names that must be unique (the Terraform
state bucket, the documents bucket) are derived from the deployer's account ID at deploy time.

---

## Part A: Developer → GitHub

### A1. Check that nothing private is about to be pushed

```bash
git status                     # review what changed
git ls-files | grep -i -E "\.env$|secret|credential|tfstate|tfvars$|cognito-config|agentcore-config"
```

The last command must print nothing. `.gitignore` already keeps these out of git: Terraform state
and `terraform.tfvars`, the generated web-app configs (`cognito-config.json`,
`agentcore-config.json`), `.bedrock_agentcore.yaml`, `.venv/`, `.deploy-logs/` and `~/environment/env.sh`.
No AWS account ID, password or key is stored in the code.

### A2. Commit and push

```bash
git add <the files you changed>
git commit -m "Describe the change"
git push origin main
```

First push of a new repository:

```bash
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

---

## Part B: Deployer → own AWS account

About 45 minutes the first time, most of it waiting for AWS (Aurora about 10 min, knowledge bases
about 15 min, runtime build about 5 min).

### B1. Prerequisites (once per machine and account)

| Need | How to check | Install |
|---|---|---|
| AWS CLI v2 | `aws --version` | [AWS CLI install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Terraform 1.10 or later | `terraform version` | `brew install hashicorp/tap/terraform` |
| Python 3.10 or later | `python3 --version` | `brew install python` |
| `jq`, `make`, `git` | `jq --version` | `brew install jq` |
| An AWS account with admin rights | `aws sts get-caller-identity` | see B3 |

Docker is **not** needed: the agent container is built in AWS CodeBuild.

### B2. Get the code and the Python environment

```bash
git clone https://github.com/<owner>/<repo>.git
cd <repo>
python3 -m venv .venv
source .venv/bin/activate                     # repeat in every new terminal
pip install -r 6_deploy/agents/requirements-deploy.txt awscurl
```

Always use the virtual environment: a global `pip install` can replace AWS CLI v2 with v1.

### B3. Log in to your AWS account and enable the models

```bash
aws configure                 # access key, secret key, region: eu-central-1, output: json
aws sts get-caller-identity   # must show YOUR account
export AWS_REGION=eu-central-1
```

In the AWS console, region **Europe (Frankfurt) eu-central-1**: **Amazon Bedrock → Model access**,
enable these three:

| Model | Used by |
|---|---|
| Amazon Nova Pro | the Tech Assistant |
| Amazon Nova 2 Lite | harness-manager (staff agent) |
| Amazon Titan Text Embeddings V2 | the knowledge bases |

`./deploy.sh` checks all three in its first step and stops with a clear message if one is missing.

### B4. Terraform: the data backends

Terraform creates the stores database (Aurora MySQL Serverless v2 with its own VPC), the orders
and sessions tables (DynamoDB), the promotions API (API Gateway + Lambda) and the order-admin
Lambda for harness-manager. Its state is stored in an S3 bucket in your account.

**1. Create the state bucket** (named `spbc-tfstate-<your-account-id>`):

```bash
make backend-setup
```

**2. Optional, for a cheaper demo:** one Aurora instance instead of two:

```bash
cp 6_deploy/infra/agentcore-backends/terraform.tfvars.example 6_deploy/infra/agentcore-backends/terraform.tfvars
# edit terraform.tfvars:  aurora_instance_count = 1
```

**3. Plan and apply:**

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cd 6_deploy/infra/agentcore-backends
terraform init -backend-config="bucket=spbc-tfstate-${ACCOUNT_ID}"
terraform plan                 # review: about 33 resources to add
terraform apply                # type "yes"; about 10 minutes (Aurora)
cd ../../..
```

The same with the repository's wrapper (adds retries and a deletion-protection guard):
`make backends-plan`, then `make backends`.

### B5. Deploy everything else

```bash
./deploy.sh
```

It asks you to confirm the account, then runs these steps. Every step is idempotent, so the
Terraform step simply reports "No changes" after B4.

| Step | What it does |
|---|---|
| `preflight` | Tools, versions, credentials and the three models |
| `state` | Terraform state bucket (already there after B4) |
| `ci` | Validates the code and Terraform offline |
| `backends` | Terraform apply (no changes after B4) |
| `seed` | Loads the 9 stores into Aurora and checks the promotions API |
| `orders` | Loads the sample orders |
| `docs` | Creates the documents bucket and uploads the knowledge-base files |
| `kbs` | OpenSearch Serverless vector store and 5 knowledge bases (about 15 min) |
| `role` | IAM role for the agent runtime |
| `guardrail` | Bedrock guardrail |
| `app` | Cognito sign-in, AgentCore Memory, the agent runtime (built in CodeBuild), the website (Amplify) |
| `user` | Creates the default login |
| `harness` | harness-manager: AgentCore harness + MCP gateway |
| `test` | Asks the live assistant one question per area |

The last lines print the website and the login:

```
  URL      : https://main.<app-id>.amplifyapp.com
  Username : demo
  Password : <generated>
```

Show the login again at any time: `make demo-user`. The password is kept in Secrets Manager
(`spbc-demo-user`), never in the code.

### B6. Check it works (optional)

```bash
make eval           # 42 questions with known answers
make e2e            # a real customer journey (sign-in, chat, order) + staff cancellation
make browser-test   # the live website in headless Chrome/Brave: login, streaming, no leaks
```

### B7. Tear down when you are done

OpenSearch Serverless (about $350/month) and Aurora bill while they exist, even when idle.

```bash
./teardown.sh             # dry run: lists everything it would delete
./teardown.sh --execute   # deletes it all (asks you to type the account ID)
./deploy.sh status        # every line should show "missing"
```

The teardown also removes the Terraform resources (it switches deletion protection off first).
Data is not kept: orders and conversation history are deleted.

---

## If something fails

`./deploy.sh` stops, names the step and its log (`.deploy-logs/<step>.log`) and prints the command
to continue, for example `./deploy.sh from kbs`. Finished steps are skipped.

| Symptom | Fix |
|---|---|
| `No working AWS credentials` | `aws configure`, or `export AWS_PROFILE=<profile>` |
| `Bedrock model access is missing ... for: ...` | Enable the listed models (B3), then re-run |
| `Terraform 1.10 or later is needed` | `brew install hashicorp/tap/terraform` |
| `Could not create s3://spbc-tfstate-...` | The name is taken: `export TF_STATE_BUCKET=<unique-name>` and re-run (use the same name for `terraform init`) |
| `terraform init` slow or times out on macOS | Re-run; providers download on first use |
| `Gateway role lacks permission to invoke Lambda` | IAM propagation; the script retries. If it still fails: `./deploy.sh from harness` |
| `pip: command not found` or import errors | `source .venv/bin/activate` |
| Anything else | Read the last 30 lines of the log named in the error |

See what exists in the account at any time: `./deploy.sh status`.

---

## Day-to-day

| Task | Command |
|---|---|
| Ship changed agent code | `FORCE=1 ./deploy.sh` (or `FORCE=1 ./deploy.sh only app` for the runtime only) |
| Ship website changes | `make amplify` |
| Run one step | `./deploy.sh only <step>` (`./deploy.sh list` shows the names) |
| Reset the sample orders | `(cd 2_data_strategy/orders && python3 orders_load_helper_script.py)` |
| Skip the account prompt | `YES=1 ./deploy.sh` |

### harness-manager (staff order cancellation)

A config-defined AgentCore harness: no agent code, no container. It looks orders up through an
AgentCore Gateway (MCP) and requests cancellations through an inline tool, so nothing changes
until a person approves it:

```bash
python3 6_deploy/harness/invoke_harness.py "Cancel order ord_7977_021 for customer_7977"
```

Only PROCESSING orders can be cancelled; the approver's AWS identity is written to the order.

### How the website talks to the assistant

The web app sends `"stream": true` and receives Server-Sent Events: progress lines while tools
run ("Checking current deals…"), then the answer as it is written. Without the flag the runtime
returns plain JSON, which the tests and the CLI use. Memory is the current conversation only;
there is no long-term memory across chats.

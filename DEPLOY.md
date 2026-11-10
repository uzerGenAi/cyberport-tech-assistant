# Deploy the Cyberport Tech Assistant

Copy each block into a terminal, in order; nothing needs editing. Everything is created in
**eu-central-1 (Frankfurt)**, in the AWS account you log in to.

| | |
|---|---|
| Time | About 45 minutes the first time, mostly waiting for AWS |
| Cost | About **$15 a day** while it runs (OpenSearch Serverless about $350 a month, Aurora about $90). Step 8 deletes everything |
| You need | A Mac or Linux machine, an AWS account with administrator access, access to the GitHub repository |
| Not needed | Docker (the agent container is built in AWS CodeBuild), any AWS account ID in the code |

---

## 1. Install the tools (once per machine)

macOS, with [Homebrew](https://brew.sh):

```bash
brew install awscli hashicorp/tap/terraform python jq git
```

On Linux, install the same tools with your package manager: AWS CLI **v2**, Terraform
**1.10 or later**, Python **3.10 or later**, `jq`, `git`, `make`.

Check the versions:

```bash
aws --version && terraform version && python3 --version && jq --version && git --version
```

---

## 2. Log in to your AWS account

```bash
aws configure
```

Enter your access key, your secret key, region `eu-central-1` and output `json`. If you use
named profiles or AWS SSO, run `export AWS_PROFILE=<your-profile>` (and `aws sso login`) instead.

Check that it is the account you want to deploy to:

```bash
aws sts get-caller-identity
```

---

## 3. Get the code

```bash
git clone https://github.com/uzerGenAi/cyberport-tech-assistant.git
cd cyberport-tech-assistant
```

Create the Python environment (it holds the deploy tools):

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r 6_deploy/agents/requirements-deploy.txt awscurl
```

> **New terminal later?** Go back into the folder and run `source .venv/bin/activate` first.
> Always use the virtual environment: a global `pip install` can replace AWS CLI v2 with v1.

---

## 4. Check the account is ready

```bash
./deploy.sh only preflight
```

This checks the tools, your credentials and access to the three Bedrock models the assistant
uses (Amazon Nova Pro, Amazon Nova 2 Lite, Amazon Titan Text Embeddings V2). It creates
nothing. It must end with `✅ preflight done`.

If it reports missing model access: open the AWS console in **Europe (Frankfurt)** →
**Amazon Bedrock → Model access**, enable the models it lists, wait a minute, and run it again.

---

## 5. Terraform: the data backends

Terraform creates the stores database (Aurora MySQL Serverless v2 in its own private VPC), the
orders table (DynamoDB), the promotions API (API Gateway + Lambda) and the order-admin Lambda.
Its state is kept in an S3 bucket in your account, named `spbc-tfstate-<your-account-id>`.

Create the state bucket:

```bash
make backend-setup
```

Optional, for a cheaper demo (one database instance instead of two):

```bash
cp 6_deploy/infra/agentcore-backends/terraform.tfvars.example 6_deploy/infra/agentcore-backends/terraform.tfvars
sed -i.bak 's/^aurora_instance_count *=.*/aurora_instance_count        = 1/' 6_deploy/infra/agentcore-backends/terraform.tfvars
rm -f 6_deploy/infra/agentcore-backends/terraform.tfvars.bak
```

Plan and apply:

```bash
make backends
```

It prints the plan (about 30 resources), then asks you to type `apply`. The apply takes about
10 minutes, most of it the database.

---

## 6. Deploy everything else

```bash
./deploy.sh
```

Type `y` when it asks to confirm the account. It then runs these steps, each logged to
`.deploy-logs/<step>.log`:

| Step | What it does | Time |
|---|---|---|
| `preflight` | Tools, credentials, model access | seconds |
| `state` / `ci` | State bucket (exists after step 5); offline validation | 1 min |
| `backends` | Terraform (reports no changes after step 5) | 1 min |
| `seed` / `orders` | Loads the 9 stores and the sample orders | 1 min |
| `docs` / `kbs` | Documents bucket, vector store, the 5 knowledge bases | 10–15 min |
| `role` / `guardrail` | Runtime role, Bedrock guardrail | 1 min |
| `app` | Sign-in (Cognito), AgentCore Memory and runtime, the website (Amplify) | 5 min |
| `user` | The default login | seconds |
| `harness` | harness-manager, the staff agent (AgentCore harness + MCP gateway) | 2 min |
| `test` | One live question per area | 1–2 min |

It ends with:

```
✅ Deployment complete
  URL      : https://main.<app-id>.amplifyapp.com
  Username : demo
  Password : <generated>
```

If a step fails, it stops and prints the log file and the command to continue, for example
`./deploy.sh from kbs`. Finished steps are skipped. See **If something fails** below.

---

## 7. Use it

Open the URL and sign in. To show the login again at any time:

```bash
make demo-user
```

The password is generated on the first deploy and kept in AWS Secrets Manager (`spbc-demo-user`),
never in the code.

Staff console (harness-manager: looks orders up and cancels only after you approve):

```bash
python3 6_deploy/harness/invoke_harness.py "Cancel order ord_7977_021 for customer_7977"
```

Optional checks against the live deployment:

```bash
make eval           # 42 questions with known answers, each asked 3 times (about 15 min)
make e2e            # a real customer journey + staff cancellation (about 6 min)
make browser-test   # the website in headless Chrome or Brave: login, streaming
```

Answers are generated by a model, so an occasional single check can vary between runs; a
repeated failure of the same check is a real problem.

---

## 8. Tear it down

Everything bills while it exists, even when nobody uses it.

```bash
./teardown.sh             # dry run: lists everything it would delete
./teardown.sh --execute   # deletes it all; asks you to type the account ID
./deploy.sh status        # every line must show "missing"
```

No data is kept: the database, orders, conversation history and documents are deleted.
The teardown takes about 20 minutes (the database is the slow part).

---

## If something fails

| Message | Fix |
|---|---|
| `No working AWS credentials` | `aws configure`, or `export AWS_PROFILE=<profile>` |
| `Bedrock model access is missing ... for: ...` | Enable the listed models (step 4), then re-run |
| `Terraform 1.10 or later is needed` | `brew upgrade hashicorp/tap/terraform` |
| `Python deployment packages are missing` / `No .venv` | `source .venv/bin/activate`, then the `pip install` lines from step 3 |
| `Could not create s3://spbc-tfstate-...` | The name is taken: `export TF_STATE_BUCKET=<a-unique-name>` and re-run from step 5 |
| `TF_STATE_BUCKET contains a different account ID` | Left over from another account: `unset TF_STATE_BUCKET` (and remove it from `~/.zshrc`) |
| `Error acquiring the state lock` | A Terraform run was interrupted. Make sure no other deploy is running, then `cd 6_deploy/infra/agentcore-backends && terraform force-unlock -force <lock-id> && cd -` with the ID from the message |
| `Gateway role lacks permission to invoke Lambda` | IAM propagation delay; re-run `./deploy.sh from harness` |
| Anything else | Read the end of the log it names (`tail -40 .deploy-logs/<step>.log`), fix the cause, then `./deploy.sh from <step>` |

Show what exists in the account at any time: `./deploy.sh status`.

---

## Day-to-day

| Task | Command |
|---|---|
| Ship changed agent code | `FORCE=1 ./deploy.sh only app` |
| Ship website changes | `make amplify` |
| Re-apply the staff agent (prompt or config) | `./deploy.sh only harness` |
| Run one step | `./deploy.sh only <step>` (`./deploy.sh list` shows the names) |
| Reset the sample orders | `(cd 2_data_strategy/orders && python3 orders_load_helper_script.py)` |
| Run without prompts (CI) | `YES=1 AUTO_APPROVE=1 ./deploy.sh` |
| Skip steps | `SKIP_STEPS="kbs harness" ./deploy.sh` |
| Validate offline before pushing | `make ci` |

---

## For developers: pushing changes to GitHub

```bash
make ci                                   # offline checks must pass
git status                                # review what changed
git add <the files you changed>
git commit -m "Describe the change"
git push
```

Nothing private is ever committed: `.gitignore` keeps out Terraform state and
`terraform.tfvars`, the generated web-app configs (`cognito-config.json`, `agentcore-config.json`),
`.bedrock_agentcore.yaml`, `.venv/` and `.deploy-logs/`. The code holds no AWS account ID,
password or key; account-specific names are derived at deploy time.

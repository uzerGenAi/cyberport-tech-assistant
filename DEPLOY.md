# Deploy the Cyberport Tech Assistant

One command deploys everything to AWS `eu-central-1`. It is safe to re-run: finished work is
skipped or harmlessly repeated, and a failure stops with the step name, its log and the exact
command to resume.

## 1. Before you start (once per machine)

| Need | Check |
|---|---|
| AWS credentials for the account you want to deploy to | `aws sts get-caller-identity` shows the right account |
| Bedrock model access: Amazon Nova Pro and Titan Text Embeddings V2 | Bedrock console, Model access (`deploy.sh` also tests this) |
| `aws` (v2), `terraform` (1.10 or later), `jq`, `python3`, `make` | `aws --version`, `terraform version` |
| Python environment | see below |

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r 6_deploy/agents/requirements-deploy.txt awscurl
```

Use the virtual environment, not a global `pip`: it keeps the AWS CLI v2 you already have from being replaced.

## 2. Deploy

```bash
./deploy.sh
```

It asks you to confirm the AWS account, then runs these steps in order (about 30 to 45 minutes
the first time, about 4 minutes when everything already exists):

| Step | What it does | Time (first run) |
|---|---|---|
| `preflight` | Checks tools, credentials and Bedrock model access | seconds |
| `state` | Creates the Terraform state bucket `spbc-tfstate-<account-id>` | seconds |
| `ci` | Validates Python and Terraform locally | 10 s |
| `backends` | Aurora (stores), DynamoDB (orders, sessions), promotions API. Shows the plan and asks you to type `apply` | 10 min |
| `seed` | Loads 9 stores, then checks the database and the API | 1 min |
| `orders` | Loads 24 demo orders | seconds |
| `docs` | Creates the knowledge-base documents bucket and uploads the files | seconds |
| `kbs` | OpenSearch Serverless vector store and 5 knowledge bases | 15 to 20 min |
| `role` | Creates the AgentCore execution role | seconds |
| `guardrail` | Creates the Bedrock guardrail and stores it in Parameter Store | seconds |
| `app` | Cognito, AgentCore Memory, the runtime (container built in CodeBuild) and the Amplify web app | 8 to 10 min |
| `user` | Creates the default web-app login (see section 4) | seconds |
| `harness` | harness-manager: an AgentCore **harness** agent (order lookup and cancellation) with its gateway and IAM roles | 2 to 3 min |
| `test` | Sends one question per domain to the live runtime and prints the web app URL | 1 min |

The final line prints the web app URL.

## 3. If something fails

The script stops and prints the step, the log (`.deploy-logs/<step>.log`) and the resume command.
Fix the cause, then run the command it printed:

```bash
./deploy.sh from <step>
```

| Symptom | Fix |
|---|---|
| `No working AWS credentials` | `aws configure`, or `export AWS_PROFILE=<profile>`, then re-run |
| `Bedrock model access failed` | Enable Nova Pro and Titan Embeddings V2 in Bedrock, Model access |
| `Could not create s3://...` bucket error | The name is taken globally: `export TF_STATE_BUCKET=<unique-name>` and re-run |
| First `terraform` run times out on macOS | Re-run: provider binaries are warmed on the first attempt (`init` also retries 3 times) |
| `python3: command not found: pip` or package errors | Activate the venv: `source .venv/bin/activate` |
| `Gateway role lacks permission to invoke Lambda` | IAM propagation; the script retries for 2 minutes. If it still fails, `./deploy.sh from harness` |
| Anything else | Read the last 30 lines of the log named in the error |

Check what exists in the account at any time:

```bash
./deploy.sh status
```

## 4. Sign-in user

Every deploy creates (or repairs) one default login and prints it at the end:

```
  URL      : https://main.<app-id>.amplifyapp.com
  Username : demo
  Password : <random, 20 characters>
```

Show it again at any time with `make demo-user`. The password is generated on the first deploy and kept in
Secrets Manager (`spbc-demo-user`), never in the repo; later deploys reuse it. A teardown deletes it, so the
next fresh deploy prints a new one. To choose your own: `DEMO_USERNAME=<name> DEMO_PASSWORD='<password>' make demo-user`
(the password needs upper and lower case, a number and a symbol).

## 5. harness-manager (AgentCore harness)

A second, config-defined agent for staff: AgentCore runs its loop, there is no agent code or container.
It looks up orders through an AgentCore Gateway (read-only) and **requests** cancellations with an inline
tool, so nothing changes until a person approves it in the terminal:

```bash
python3 6_deploy/harness/invoke_harness.py "Cancel order ord_7977_021 for customer_7977"
```

The script shows the request and asks `Approve this cancellation? [y/N]`. Only `y` cancels it, and your
AWS identity is written to the order (`cancelled_by`). No terminal, or any other answer, means no change.
Only PROCESSING orders can be cancelled, as the orders policy says. To reset the demo orders afterwards:
`(cd 2_data_strategy/orders && python3 orders_load_helper_script.py)`.

Files: `6_deploy/harness/` (system prompt, deploy and chat scripts; your original prompt is kept as
`harness-manager.prompt.md`) and the `spbc-order-admin` Lambda in `6_deploy/infra/agentcore-backends/`.

## 6. Check answer quality

```bash
make eval
```

Asks the live assistant 25 questions whose correct answers come from the project data (prices,
stock, store hours, order status, return period, promotions active today, refusals, memory) and
runs each 3 times, because answers vary between runs. It also checks the guardrail directly: normal
questions and replies must pass, abuse must be blocked. Results: `.deploy-logs/eval-results.json`.
Run it after every change to prompts, models or the guardrail.

`make e2e` goes further: it signs in as a fresh Cognito customer with the web app's own
credentials, runs a whole conversation (advice, stock, discount, financing, click & collect
order, status, cancellation request, memory on a later visit, abuse), checks the order in
DynamoDB, then has harness-manager cancel that order (declined, approved, re-cancel, shipped
order, missing ID, prompt injection). Transcripts are in `.deploy-logs/`.

`make browser-test` opens the live website in headless Brave or Chrome, signs in as a fresh
customer and records what the chat bubble shows over time: the progress lines ("Checking
current deals…", "Putting your answer together…"), the streamed answer, and that no internal
reasoning ever appears.

**Streaming.** The web app sends `"stream": true` and receives the answer as Server-Sent Events:
`status` while tools run, `delta` text as it is written, `done` with the final cleaned answer.
Without the flag the runtime returns plain JSON, as the tests and CLI use.

## 7. Redeploy after changing code

```bash
FORCE=1 ./deploy.sh
```

`FORCE=1` rebuilds the container and ships the new agent code. Without it, an existing runtime is left as is.

## 8. Useful options

| Variable | Effect |
|---|---|
| `FORCE=1` | Rebuild and redeploy the agent code |
| `YES=1` | Do not ask to confirm the account |
| `SKIP_CI=1` | Skip the local validation step |
| `TF_STATE_BUCKET=<name>` | Use a different Terraform state bucket name |

`./deploy.sh list` shows the step names. `./deploy.sh only <step>` runs one step.

## 9. Cost and tear down

Two resources bill while they exist, even when idle:

- OpenSearch Serverless, about $350 a month (the `kbs` step creates it)
- Aurora Serverless v2, billed per hour

Tear down everything, including harness-manager, with `./teardown.sh` (a dry run that lists what it
would delete) and then `./teardown.sh --execute`. Run `./deploy.sh status` afterwards to confirm nothing
is left. The orders and sessions tables are deleted with their data, so export any orders you need first.

# AgentCore Runtime: Console Deployment Walkthrough

**Project:** Cyberport Tech Assistant (SPBC project prefix), multi-agent electronics shopping and service assistant (client project for Cyberport, running on sample data)
**What you deploy:** the Strands agents in [6_deploy/agents](6_deploy/agents) to **Amazon Bedrock AgentCore Runtime**, plus their knowledge bases and an optional guardrail.
**Region:** `eu-central-1` (Frankfurt), everywhere: console Region selector, CloudShell, every command.
**Architecture and stack:** see [README.md](README.md#technology-stack) for the technology stack, the architecture diagram and the request flow. This guide builds the same system by hand in the console.

| Item | Value |
|---|---|
| Chat model | Amazon Nova Pro through the **EU cross-Region inference profile** `eu.amazon.nova-pro-v1:0`. Frankfurt has no in-Region on-demand capacity for Nova Pro, so the bare ID `amazon.nova-pro-v1:0` fails there. The profile keeps traffic in EU Regions (eu-central-1, eu-north-1, eu-west-1, eu-west-3). |
| Embeddings | Titan Text Embeddings V2 (`amazon.titan-embed-text-v2:0`), 1024 dimensions, in-Region |
| Tools | AWS console + AWS CloudShell (browser shell). Your laptop is only used to zip the project files. |
| Backends | Stores database (Aurora MySQL Serverless v2, read through the RDS Data API), the IAM-authorized promotions API and the orders and sessions DynamoDB tables, all from the Terraform stack [6_deploy/infra/agentcore-backends](6_deploy/infra/agentcore-backends), applied from CloudShell in Step 2 |
| Out of scope | Cognito and Amplify. Step 9 covers the hand-off to them. |

> This guide uses **AgentCore Runtime** (host your own agent code). It does not use the separate managed "AgentCore harness" feature, which has its own console section. Stay in **Runtime**.

## How to use this guide

- Every step ends with a **Gate**. Don't continue until the gate passes; each gate catches a failure that would otherwise only show up at the final test.
- Write values into the worksheet (§0.5) as you go. Later steps paste them.
- Console labels change over time. If a label differs slightly, match it by meaning.
- The same flow is scripted in [deploy_agentcore.sh](deploy_agentcore.sh) (see the parity table at the end).

---

## Step 0: Before you start

### 0.1 Access

1. Sign in with an admin-equivalent identity and select **eu-central-1**.
2. If your organization uses SCPs that restrict Regions, they must also allow Amazon Bedrock in **eu-north-1, eu-west-1 and eu-west-3**. Cross-Region inference sends requests there; a blocking SCP shows up as `AccessDeniedException` on every model call.

### 0.2 What each feature depends on

The runtime **refuses to start** unless the four required knowledge base IDs are set (§7.2). Everything else degrades one feature at a time:

| Feature | Needs | If missing |
|---|---|---|
| Everything | Nova Pro (EU profile), KBs for menu, orders, payments, stores | Container crashes at startup |
| Product catalog lookups | S3 object `menu/menu_records.json` (the catalog keeps the original `menu` domain key) | Product, price and stock answers fail |
| Order status / placing orders | DynamoDB table `spbc-orders-table` | Order lookups and placement fail |
| Store locations and hours | Stores database from Step 2: cluster `spbc-aurora-cluster` with the Data API, table `StoresDB.stores`, reader secret `spbc-stores-db-reader` | Store lookups fail (store FAQ answers still work) |
| Live promotions | Promotions API `spbcPromotionsAPI` from Step 2 (`GET /prod/promotions`, IAM-authorized) | Promos fall back to the promos KB |
| Content safety | Guardrail | Runs without one |

Decide now which features you'll deliver. Step 2 builds or checks each dependency.

### 0.3 Network decision

- **Public (recommended):** the stores agent reads Aurora through the RDS Data API (HTTPS + IAM) and the promotions API is an IAM-authorized public endpoint, so the runtime needs no VPC, subnets or NAT gateway.
- **VPC:** only if your organization requires the runtime's traffic to leave through your VPC, or you reuse an older lab cluster without the Data API (the agent then connects with the MySQL driver). You need at least two **private** subnets whose route table sends `0.0.0.0/0` to a **NAT gateway**, plus a security group for the runtime (Step 2.5).

### 0.4 Existing runtime

AgentCore console → **Runtime**. If `tech_assistant_agent` already exists (a previous deployment, recorded in `6_deploy/web-app/agentcore-config.json` if that file exists, points at one), either update that runtime (Step 10) or choose a new name such as `tech_assistant_agent_v2`. Names start with a letter, use only letters, digits and underscores, and are at most 48 characters.

### 0.5 Values worksheet

| Key | Value | From |
|---|---|---|
| `ACCOUNT_ID` | | Console account menu |
| `STORES_DB_CLUSTER_ARN`, `STORES_DB_SECRET_ARN`, `PROMOS_API_URL` | | Step 2.2 (`agentcore_backends.sh env`) |
| `BUCKET` | `spbc-kb-docs-<ACCOUNT_ID>` | Step 3 |
| `MENU_KB`, `ORDERS_KB`, `PAYMENTS_KB`, `STORES_KB`, `PROMOS_KB` | | Step 4 |
| `GUARDRAIL_ID`, `GUARDRAIL_VERSION` | | Step 5 |
| `ARTIFACT` | S3 URI of the zip, or image URI | Step 6 |
| `SUBNET_IDS`, `RUNTIME_SG` | | Step 2.5 (VPC mode only) |
| `RUNTIME_ID`, `RUNTIME_ARN` | | Step 7 |

### 0.6 Get the project files into CloudShell

1. On your computer, from the project root (local Terraform state, plans and `terraform.tfvars` stay out of the zip):
   ```bash
   zip -r spbc-deploy.zip 2_data_strategy 3_proof_of_concept/knowledge_bases \
     6_deploy/agents 6_deploy/infra 6_deploy/scripts \
     -x '*__pycache__*' '*.DS_Store' '*/.terraform/*' '*/.build/*' '*.tfstate*' '*.tfplan' '*terraform.tfvars'
   ```
2. Console → **CloudShell** (terminal icon in the top bar). Check the Region shown is eu-central-1.
3. **Actions → Upload file** → `spbc-deploy.zip`, then:
   ```bash
   mkdir -p ~/spbc && cd ~/spbc && unzip -oq ~/spbc-deploy.zip
   ```
4. Paste this variables block. **Re-paste it whenever you open a new CloudShell session**, and fill in the KB, guardrail and runtime values as you collect them:
   ```bash
   export AWS_REGION=eu-central-1
   export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   export BUCKET=spbc-kb-docs-$ACCOUNT_ID
   export MODEL_ID=eu.amazon.nova-pro-v1:0
   export MODEL_ARN=arn:aws:bedrock:eu-central-1:$ACCOUNT_ID:inference-profile/eu.amazon.nova-pro-v1:0
   export PATH="$HOME/.local/bin:$PATH"   # terraform and uv live here (Steps 2.1 and 6)
   # After Step 2.2: eval "$(bash ~/spbc/6_deploy/scripts/agentcore_backends.sh env)"
   # export MENU_KB=... ORDERS_KB=... PAYMENTS_KB=... STORES_KB=... PROMOS_KB=...
   # export RUNTIME_ID=... RUNTIME_ARN=...
   ```

**Gate:** all four files exist:
```bash
ls ~/spbc/6_deploy/agents/place_order.py ~/spbc/2_data_strategy/menu/menu_records.json \
   ~/spbc/6_deploy/infra/agentcore-backends/database.tf \
   ~/spbc/3_proof_of_concept/knowledge_bases/bootstrap_vector_store.sh
```

---

## Step 1: Confirm model access

There's no "Model access" page to visit anymore: serverless models (Nova and Titan included) are enabled automatically on first use. Confirm both models answer:

```bash
aws bedrock-runtime converse --region eu-central-1 --model-id eu.amazon.nova-pro-v1:0 \
  --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]' \
  --inference-config '{"maxTokens":5}' --query 'output.message.content[0].text' --output text

aws bedrock get-foundation-model --region eu-central-1 \
  --model-identifier amazon.titan-embed-text-v2:0 --query 'modelDetails.modelId' --output text
```

**Gate:** the first command prints a short reply; the second prints the Titan model ID.
- `AccessDeniedException` → IAM or SCP (§0.1).
- `ValidationException` → wrong model ID or Region.

---

## Step 2: Backends

The stores database and the promotions API come from one Terraform stack, [6_deploy/infra/agentcore-backends](6_deploy/infra/agentcore-backends), applied from CloudShell with [agentcore_backends.sh](6_deploy/scripts/agentcore_backends.sh). Step 2.4 covers the orders table. Skip any part you descoped in §0.2.

| Resource | What the stack creates (eu-central-1) |
|---|---|
| Stores database | Aurora MySQL Serverless v2 cluster `spbc-aurora-cluster`: 2 instances in different AZs, encrypted, TLS required, 7-day backups, deletion protection, a final snapshot on delete, RDS Data API on |
| Credentials | Master password generated and rotated by RDS, used only by the loader. Read-only user `stores_reader` (SELECT on `StoresDB.stores`); the agents use its secret `spbc-stores-db-reader` |
| Network | A VPC with private subnets only (no internet gateway, no NAT) and flow logs. The database has no inbound rule: everything goes through the Data API |
| Promotions API | HTTP API `spbcPromotionsAPI`, route `GET /promotions` with **IAM** authorization, stage `prod`, throttled and access-logged. A Lambda function returns the promotions in [promos_records.json](2_data_strategy/promos/promos_records.json) that are valid today |

> **Cost:** Aurora Serverless v2 bills per ACU-hour, around the clock: by default 0.5 ACU minimum on each of 2 instances. For non-production, set `aurora_instance_count = 1` and `aurora_min_acu = 0` (one instance that pauses when idle; the first question after a pause waits about 15 seconds). The API and the Lambda function bill per request.

### 2.1 Terraform and its state bucket (once per account)

1. Install Terraform into your home directory (CloudShell keeps only `$HOME` between sessions):
   ```bash
   TF_VERSION=1.16.6
   ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
   cd /tmp \
     && curl -fsSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${ARCH}.zip" \
     && curl -fsSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_SHA256SUMS" \
     && grep "_linux_${ARCH}.zip" "terraform_${TF_VERSION}_SHA256SUMS" | sha256sum -c - \
     && mkdir -p ~/.local/bin && unzip -oq "terraform_${TF_VERSION}_linux_${ARCH}.zip" terraform -d ~/.local/bin
   export PATH="$HOME/.local/bin:$PATH" && terraform version
   ```
2. Create the state bucket `spbc-tfstate-<account-id>` (named after your account because bucket names are global; versioned, encrypted, private; state locking uses a lock file in the bucket). The script reuses the bucket if it exists:
   ```bash
   cd ~/spbc && bash 6_deploy/scripts/terraform_backend_setup.sh
   ```
   - The name is derived from your account, so nothing needs exporting. To use another name, export `TF_STATE_BUCKET=<unique-name>` before this and every later `agentcore_backends.sh` command.

**Gate:** `terraform version` prints `v1.16.6` (1.10 or later works), and the script ends with "Terraform backend ready".

### 2.2 Create the stores database and the promotions API

1. Settings (optional): every value has a production default. To change one, copy [terraform.tfvars.example](6_deploy/infra/agentcore-backends/terraform.tfvars.example) to `terraform.tfvars` in the same directory and edit it. Every later apply reads that file; a one-off `-var` flag is forgotten on the next apply.
2. Apply:
   ```bash
   cd ~/spbc && bash 6_deploy/scripts/agentcore_backends.sh apply
   ```
   The script plans, shows the plan, and applies **exactly that plan** only after you type `apply`. Creating the cluster takes about 15 minutes.
3. Load the runtime's values into this shell and record them in the worksheet:
   ```bash
   eval "$(bash 6_deploy/scripts/agentcore_backends.sh env)"
   echo "$STORES_DB_CLUSTER_ARN"; echo "$STORES_DB_SECRET_ARN"; echo "$PROMOS_API_URL"
   ```

**Gate:** the apply ends with `Apply complete!`, and `PROMOS_API_URL` ends in `/prod/promotions`.

Reusing an older lab cluster instead? A cluster named `spbc-aurora-cluster*` with the secret `spbc-aurora-db-credentials` still works when these variables are left unset: the agent then connects with the MySQL driver, which needs VPC mode (Step 2.5) and the legacy permissions in Appendix A.5.

### 2.3 Load the stores data and smoke-test both backends

```bash
cd ~/spbc && bash 6_deploy/scripts/agentcore_backends.sh seed
bash 6_deploy/scripts/agentcore_backends.sh check
```

- `seed` works from CloudShell through the Data API, with no VPC access. It creates `StoresDB.stores`, upserts [stores_records.json](2_data_strategy/stores/stores_records.json), creates or re-syncs `stores_reader` from its secret, then proves the reader can read but not write. Safe to re-run. If it reports that boto3 is missing, run `pip3 install --user boto3` first.
- `check` calls both backends the way the runtime does: a query with the reader secret, an unsigned API request (must be rejected with 403) and a SigV4-signed one (must return promotions).

**Gate:** `seed` ends with `Done: 9 stores readable by stores_reader; writes are denied as expected.` and `check` prints three ✅ lines. `DatabaseResumingException` only means the cluster is waking up: wait 30 seconds and run it again.

### 2.4 Orders table (DynamoDB)
The backends stack from Step 2.2 already created `spbc-orders-table` (and `spbc-sessions-table`, which only the proof-of-concept CLI uses). Skip to the optional seeding step. If you did not apply that stack, create the table in the console instead:
1. DynamoDB → **Create table**.
2. Name `spbc-orders-table`; partition key `user_id` (String); sort key `order_timestamp` (String); capacity **On-demand**. The key names and types must match exactly: the code queries by `user_id`, newest `order_timestamp` first.
3. (Optional) Turn on point-in-time recovery.
4. (Optional) Seed sample orders:
   ```bash
   cd ~/spbc/2_data_strategy/orders && python3 orders_load_helper_script.py
   ```
   If CloudShell reports that boto3 is missing, run `pip3 install --user boto3` first.

**Gate:**
```bash
aws dynamodb describe-table --table-name spbc-orders-table \
  --query '{status:Table.TableStatus,keys:Table.KeySchema}'
```
shows `ACTIVE`, `user_id` as HASH and `order_timestamp` as RANGE.

### 2.5 Network for VPC mode (only if you chose VPC in §0.3)

1. **VPC → Subnets:** pick at least two private subnets whose route table has `0.0.0.0/0 → nat-…`. A route to `igw-…` means the subnet is public, so don't use it. All Frankfurt AZs (euc1-az1/2/3) are supported.
2. **Security groups → Create** `spbc-agentcore-runtime` with outbound HTTPS 443 to `0.0.0.0/0`. The Data API and the promotions API are HTTPS endpoints, so no database port is needed.
3. If that VPC has an `execute-api` interface endpoint with **private DNS** on, requests from the VPC to public APIs such as `spbcPromotionsAPI` fail. Use subnets in a VPC without one, or turn private DNS off on it.
4. Legacy MySQL cluster only: also allow outbound MySQL 3306 to the Aurora security group, and inbound 3306 from `spbc-agentcore-runtime` on the Aurora security group.

**Gate:** subnet IDs and the runtime security group ID are in the worksheet.

---

## Step 3: S3 bucket and data files

1. S3 → **Create bucket** `spbc-kb-docs-<ACCOUNT_ID>` in eu-central-1. Keep **Block all public access** on and default encryption.
2. Upload the files to these **exact** keys. Any other prefix means a knowledge base syncs zero documents, or the catalog agent's `get_menu` tool can't find its file.

| Local file (in `~/spbc/2_data_strategy`) | S3 key | Used by |
|---|---|---|
| `menu/menu_records.json` | `menu/menu_records.json` | Product catalog agent (`menu_agents.py`) `get_menu` tool (not a KB) |
| `menu/menu_items_kb_faqs.txt` | `electronics_menu/menu_items_kb_faqs.txt` | Buying-guide KB (`menu` domain) |
| `orders/orders_policies_kb_faqs.txt` | `electronics_orders/orders_policies_kb_faqs.txt` | Orders KB |
| `payments/payments_policies_kb_faqs.txt` | `electronics_payments/payments_policies_kb_faqs.txt` | Payments KB |
| `stores/store_kb_faqs.txt` | `electronics_stores/store_kb_faqs.txt` | Stores KB |
| `promos/promos_kb_faqs.txt` | `electronics_promos/promos_kb_faqs.txt` | Promos KB |

From CloudShell (creates the bucket and uploads):
```bash
cd ~/spbc/2_data_strategy
aws s3api create-bucket --bucket "$BUCKET" --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1
aws s3 cp menu/menu_records.json                 "s3://$BUCKET/menu/menu_records.json"
aws s3 cp menu/menu_items_kb_faqs.txt            "s3://$BUCKET/electronics_menu/"
aws s3 cp orders/orders_policies_kb_faqs.txt     "s3://$BUCKET/electronics_orders/"
aws s3 cp payments/payments_policies_kb_faqs.txt "s3://$BUCKET/electronics_payments/"
aws s3 cp stores/store_kb_faqs.txt               "s3://$BUCKET/electronics_stores/"
aws s3 cp promos/promos_kb_faqs.txt              "s3://$BUCKET/electronics_promos/"
```

**Gate:** `aws s3 ls "s3://$BUCKET" --recursive` lists exactly those six keys.

---

## Step 4: Knowledge bases

Create **menu, orders, payments, stores** (required) and **promos** (recommended: it's the promos fallback). Use either path; 4A is the one a pipeline can run.

### 4A (recommended): scripted, from CloudShell

```bash
cd ~/spbc
bash 3_proof_of_concept/knowledge_bases/bootstrap_vector_store.sh     # once per account
bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh      # all five domains
```

- `bootstrap_vector_store.sh` creates what the knowledge bases need and nothing in this repo used to create: the OpenSearch Serverless collection `spbc-electronics-vectors` with its encryption, network and data access policies, plus the service role `AmazonBedrockExecutionRoleForKnowledgeBase_eu-central-1`. It records `AOSSENDPOINT`, `OPENSEARCH_COLLECTION_ARN` and `ROLE_ARN` in `~/environment/env.sh`.
- `setup_knowledge_bases.sh` then creates each domain's vector index, knowledge base and S3 data source, syncs it, and **fails if a sync indexes nothing** — so a silent empty knowledge base can't pass. Pass a domain name to do just one, e.g. `setup_knowledge_bases.sh orders`.
- Both are safe to re-run: anything that already exists is reused.
- `awscurl` is needed for index creation (`pip3 install --user awscurl`; it's in [requirements.txt](requirements.txt)).
- The collection endpoint is reachable from the internet, because index creation and `create-knowledge-base` both run outside any VPC. Authorization comes from the data access policy, which names only the Bedrock role and the identity that ran the bootstrap. The Dashboards endpoint stays closed.

### 4B: in the console

For each domain:

1. Amazon Bedrock → **Knowledge Bases** → **Create** → **Knowledge Base with vector store**.
2. Name `spbc-<domain>-knowledge-base`. IAM: **Create and use a new service role**.
3. Data source **Amazon S3**. S3 URI `s3://<BUCKET>/electronics_<domain>/` (trailing slash included). Keep default chunking.
4. Embeddings model **Titan Text Embeddings V2**, **1024** dimensions, floating-point. Don't pick "Titan Embeddings G1 - Text": that is v1 (1536 dimensions).
5. Vector store: **Quick create a new vector store → Amazon OpenSearch Serverless**. The agent code always requests **HYBRID** search, which AWS documents for OpenSearch Serverless; other stores (for example S3 Vectors) may reject it.
6. Create. When it finishes: **Data sources** → select → **Sync**.
7. Record the **Knowledge Base ID** (10 characters).

| Domain | KB name | S3 URI | Gate question |
|---|---|---|---|
| menu | `spbc-menu-knowledge-base` | `s3://<BUCKET>/electronics_menu/` | How much RAM do I need for gaming? |
| orders | `spbc-orders-knowledge-base` | `s3://<BUCKET>/electronics_orders/` | Can I cancel my order after placing it? |
| payments | `spbc-payments-knowledge-base` | `s3://<BUCKET>/electronics_payments/` | Can I pay with PayPal when I order online? |
| stores | `spbc-stores-knowledge-base` | `s3://<BUCKET>/electronics_stores/` | Are you open on public holidays? |
| promos | `spbc-promos-knowledge-base` | `s3://<BUCKET>/electronics_promos/` | How does the trade-in bonus work? |

**Gate (per KB):**
- The sync shows **Completed** with at least 1 document scanned and **0 failed**.
- The call below, which is exactly what the agents do at runtime (EU profile + HYBRID), returns a relevant answer. Set the KB variables first:

```bash
kb_test() {  # usage: kb_test <KB_ID> "<question>"
  aws bedrock-agent-runtime retrieve-and-generate --region eu-central-1 \
    --input "$(jq -cn --arg q "$2" '{text:$q}')" \
    --retrieve-and-generate-configuration "$(jq -cn --arg kb "$1" --arg m "$MODEL_ARN" \
      '{type:"KNOWLEDGE_BASE",knowledgeBaseConfiguration:{knowledgeBaseId:$kb,modelArn:$m,
        retrievalConfiguration:{vectorSearchConfiguration:{numberOfResults:7,overrideSearchType:"HYBRID"}}}}')" \
    --query 'output.text' --output text
}
kb_test "$MENU_KB"     "How much RAM do I need for gaming?"
kb_test "$ORDERS_KB"   "Can I cancel my order after placing it?"
kb_test "$PAYMENTS_KB" "Can I pay with PayPal when I order online?"
kb_test "$STORES_KB"   "Are you open on public holidays?"
kb_test "$PROMOS_KB"   "How does the trade-in bonus work?"
```

> **Cost:** each quick-create OpenSearch Serverless collection bills for capacity every hour it exists, even when idle. Plan the teardown (Step 11).

---

## Step 5: Guardrail (optional, recommended)

The orchestrator applies the guardrail only when both `GUARDRAIL_ID` and `GUARDRAIL_VERSION` are set.

1. Amazon Bedrock → **Guardrails** → **Create guardrail** → name `SPBC-Guardrail`.
2. **Content filters:** hate, insults, sexual, violence, misconduct on High; prompt attacks on High (input).
3. **Denied topics**, each describing what to block (keep them specific; never deny "software" or "IT help" in general, because laptop and phone questions are full of both):
   - `OutOfScopeRequests`: crypto or investment advice, medical, legal or tax advice, politics, travel booking, homework and essay writing.
   - `UnsafeDeviceModification`: opening, puncturing or self-repairing lithium batteries, chargers or mains-powered devices, or disabling safety features.
   - `PiracyAndDRMCircumvention`: pirated software, cracked licences, illegal IPTV, removing copy protection, carrier locks or region locks.
   - `PersonalCreditAdvice`: whether the customer should take credit, or whether a financing application will be approved.
4. **Sensitive information:**
   - Credit/debit card number, card CVV, PIN, IBAN and password → **Block**.
   - Email and phone → **Mask**.
   - **Don't add Name:** the order flow asks for the customer's name.
   - The same policy is scripted in `deploy_agentcore.sh step6-guardrail` and `5_security_rai/create_and_store_guardrail.sh`.
5. **Create version** and record the guardrail ID and the **version number**. A numbered version is immutable; `DRAFT` also works but changes whenever someone edits the guardrail.

**Gate:** in the guardrail's **Test** panel, "Help me with my tax return" and "How do I open my phone battery myself?" are blocked, while "Which laptops do you have for students?", "Can I bring my old phone for recycling?" and "Can I pay for a laptop in instalments?" pass.

---

## Step 6: Package the agent (CloudShell)

Choose **one** option. Option A needs no Docker and is the recommended path.

### Option A (recommended): direct code deployment zip

```bash
cd ~/spbc/6_deploy/agents
python3 -m pip install --user --quiet uv
rm -rf ~/spbc/build ~/spbc/agent.zip
~/.local/bin/uv pip install --quiet --python "$(command -v python3)" --python-version 3.11 \
  --python-platform aarch64-manylinux2014 --only-binary :all: \
  --target ~/spbc/build -r requirements.txt
cp tech_assistant_agent.py menu_agents.py orders_agents.py place_order.py \
   payments_policy_agents.py stores_agents.py promos_agents.py ~/spbc/build/
(cd ~/spbc/build && zip -qr ../agent.zip . -x '*__pycache__*')
ls -lh ~/spbc/agent.zip
KEY=agentcore/agent-$(date +%Y%m%d%H%M).zip
aws s3 cp ~/spbc/agent.zip "s3://$BUCKET/$KEY" && echo "ARTIFACT=s3://$BUCKET/$KEY"
```

This installs the pinned [requirements.txt](6_deploy/agents/requirements.txt) as linux/arm64 wheels for Python 3.11, whatever CloudShell's own Python version is. The `cp` names every module, so a missing file fails here instead of crashing the runtime.

**Gate:** `ls` shows about 50 MB (the limit is 250 MB zipped, 750 MB unzipped). The last line prints the artifact S3 URI; record it.

### Option B: container image

The [Dockerfile](6_deploy/agents/Dockerfile) already handles three things:
- `DOCKER_CONTAINER=1`, without which the server listens on 127.0.0.1 instead of the required 0.0.0.0:8080.
- The arm64 base image from ECR Public, which avoids Docker Hub rate limits.
- An explicit list of modules.

```bash
cd ~/spbc/6_deploy/agents
REPO=spbc-tech-assistant
IMAGE=$ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/$REPO:v$(date +%Y%m%d%H%M)   # unique tag = rollback target
aws ecr describe-repositories --repository-names $REPO >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name $REPO --image-scanning-configuration scanOnPush=true
aws ecr get-login-password | docker login --username AWS --password-stdin ${IMAGE%%/*}
uname -m   # x86_64 → register arm64 emulation first:
docker run --privileged --rm tonistiigi/binfmt --install arm64
docker buildx build --platform linux/arm64 --provenance=false --load -t "$IMAGE" .
# no buildx plugin? use: docker build --platform linux/arm64 -t "$IMAGE" .
docker image inspect --format '{{.Architecture}}' "$IMAGE"   # must print arm64
docker push "$IMAGE" && echo "ARTIFACT=$IMAGE"
```

**Gate:** the inspect line prints `arm64` and the push succeeds.
- `exec format error` during the build means emulation isn't registered.
- If the privileged `binfmt` container is blocked in your CloudShell, use Option A.

---

## Step 7: Create the AgentCore Runtime

### 7.1 Wizard

Amazon Bedrock AgentCore console → **Runtime** → **Create runtime** (or **Host agent**).

| Setting | Value |
|---|---|
| Name | `tech_assistant_agent` (or the name from §0.4) |
| Compute type | Default (serverless). Not *Instances*. |
| Agent source | **Option A:** S3 source → existing object → the zip's S3 URI; runtime **Python 3.11**; entry point `tech_assistant_agent.py`. **Option B:** ECR container → the image URI with its unique tag. |
| Protocol | **HTTP** |
| Inbound auth | **IAM (SigV4)**, the default. Don't choose JWT: the web app signs requests with Cognito identity-pool credentials. |
| Network | **Public** (§0.3), or **VPC** with the subnets and security group from Step 2.5 |
| Security / metadata | Enable **Require MMDSv2** if the wizard offers it (otherwise §7.4) |
| Environment variables | Table in §7.2 |
| Permissions | **Create and use a new service role** (recommended), or a role you built from Appendix A |

Create, then wait for status **Ready**. Record the runtime ID and ARN; the ARN looks like `arn:aws:bedrock-agentcore:eu-central-1:<ACCOUNT_ID>:runtime/tech_assistant_agent-<id>`.

### 7.2 Environment variables

| Key | Value | If missing |
|---|---|---|
| `REGION` | `eu-central-1` | **Container crashes at startup** |
| `MODEL_ID` | `eu.amazon.nova-pro-v1:0` | **Crash** |
| `MODEL_ARN` | `arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:inference-profile/eu.amazon.nova-pro-v1:0` | **Crash** |
| `MENU_KNOWLEDGE_BASE_ID` | Buying-guide KB ID (`menu` domain) | **Crash** |
| `ORDERS_KNOWLEDGE_BASE_ID` | Orders KB ID | **Crash** |
| `PAYMENTS_KNOWLEDGE_BASE_ID` | Payments KB ID | **Crash** |
| `STORES_KNOWLEDGE_BASE_ID` | Stores KB ID | **Crash** |
| `S3_BUCKET_NAME` | `spbc-kb-docs-<ACCOUNT_ID>` | Menu `get_menu` fails per call |
| `DOCKER_CONTAINER` | `1` | Server may bind 127.0.0.1 (the container image sets it too) |
| `STORES_DB_CLUSTER_ARN` + `STORES_DB_SECRET_ARN` | From Step 2.2 (set both or neither) | Store lookups fall back to the legacy MySQL driver, which fails without a VPC path to a legacy cluster |
| `STORES_DB_NAME` | `StoresDB` | Defaults to `StoresDB` |
| `PROMOS_API_URL` | From Step 2.2, ends in `/prod/promotions` | The agent looks the API up by name, which needs extra permissions (Appendix A.5) |
| `PROMOS_KNOWLEDGE_BASE_ID` | Promos KB ID | No promos fallback when the API is missing |
| `GUARDRAIL_ID` + `GUARDRAIL_VERSION` | From Step 5 | Guardrail silently off |
| `GUARDRAIL_TRACE` | `enabled` | Default is already enabled |
| `LOG_LEVEL` | `INFO` | Defaults to INFO. Set `DEBUG` only while troubleshooting: it logs full prompts and responses, which can contain customer data. |

You don't need `AWS_REGION`: the code passes the Region to every client explicitly. `bash 6_deploy/scripts/agentcore_backends.sh env` prints the four backend values.

### 7.3 Attach the app permissions

The wizard's service role covers the runtime basics (image or code access, logs, traces, metrics, workload identity). The agents also call Bedrock models and KBs, the guardrail, S3, DynamoDB, the RDS Data API, Secrets Manager and the promotions API.

1. Open the runtime → the execution role link → IAM.
2. **Add permissions → Create inline policy → JSON**, paste **Appendix A.3** with your values filled in, and name it `SPBC-AgentCore-App`.
3. Add a second inline policy named `SPBC-AgentCore-Backends` with exactly the stack's resources (Appendix A.4). Print it in CloudShell and paste the output:
   ```bash
   cd ~/spbc && bash 6_deploy/scripts/agentcore_backends.sh policy
   ```
   The reader secret uses the AWS managed key, so no KMS permission is needed.
4. If runtime logs never appear in CloudWatch later, compare the role's other policy with **Appendix A.2** and add anything missing.

### 7.4 Require MMDSv2

Since 30 June 2026, AgentCore rejects invocations on runtimes that don't require MMDSv2 (`This runtime is not MMDSv2-enabled`). The create API can't set it, so check it now:

1. On the runtime details page, check the MMDSv2 / metadata setting. If it isn't required: **Edit** → enable **Require MMDSv2** → save. This creates a new version; wait for **Ready**.
2. If the console doesn't show the setting, apply it from CloudShell. The update re-sends the whole current configuration, because an update replaces it:
   ```bash
   aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$RUNTIME_ID" > /tmp/rt.json
   jq --arg id "$RUNTIME_ID" '{agentRuntimeId:$id} + with_entries(select(.key as $k
       | ["agentRuntimeArtifact","roleArn","networkConfiguration","description","authorizerConfiguration",
          "requestHeaderConfiguration","protocolConfiguration","lifecycleConfiguration","environmentVariables",
          "filesystemConfigurations","capacityProviderConfiguration","platformVersion"] | index($k) != null)
       | select(.value != null and .value != "" and .value != {} and .value != []))
       + {metadataConfiguration:{requireMMDSV2:true}}' /tmp/rt.json > /tmp/update.json
   jq -e '.environmentVariables | length > 0' /tmp/update.json \
     && aws bedrock-agentcore-control update-agent-runtime --cli-input-json file:///tmp/update.json
   ```
   If `jq -e` prints `false`, stop: the update would clear the environment variables. Use the console instead.

### 7.5 Gate

```bash
aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$RUNTIME_ID" \
  --query '{status:status,version:agentRuntimeVersion,mmdsv2:metadataConfiguration.requireMMDSV2,network:networkConfiguration.networkMode,env:environmentVariables}'
```

Expect status `READY`, `mmdsv2` `true`, the network mode you chose, every **Crash** key from §7.2 and, with the Step 2 backends, `STORES_DB_CLUSTER_ARN`, `STORES_DB_SECRET_ARN` and `PROMOS_API_URL`.

**READY only proves the configuration is valid.** A container that fails at startup still shows READY and only fails on invoke, so Step 8 is the real gate.

---

## Step 8: Test (go/no-go)

Runtime → **Test** (or CloudShell below). Send one payload per domain. The payload must be JSON with a `prompt` key.

| Domain | Payload | Pass |
|---|---|---|
| Catalog | `{"prompt": "Do you have the Apple iPhone 14 with 128GB, and what does it cost?"}` | Product details and a price in € (€1009.00 in the Kaggle catalog) |
| Stock | `{"prompt": "Is the Apple iPhone 14 in stock at store spbc-de-001?"}` | Units in stock at the Cyberport Store Dresden |
| Orders | `{"prompt": "What is the status of order ord_2055_023 for customer_2055?"}` | SHIPPED from DynamoDB, or "No order found" if you didn't seed |
| Payments | `{"prompt": "Can I pay with PayPal when I order online?"}` | Yes, from the payments KB |
| Promos | `{"prompt": "Is there a student discount on laptops?"}` | 10% off with STUDENT10 (from the API or the promos KB) |
| Stores | `{"prompt": "What are the opening hours of your store in Dresden?"}` | Hours of the Dresden store from the stores database (Cyberport Store Dresden, 10:00–20:00) |

```bash
invoke() {  # usage: invoke "<prompt>"   (session IDs must be ≥ 33 characters)
  aws bedrock-agentcore invoke-agent-runtime --region eu-central-1 \
    --agent-runtime-arn "$RUNTIME_ARN" \
    --runtime-session-id "spbc-test-$(python3 -c 'import uuid; print(uuid.uuid4())')" \
    --content-type application/json --cli-binary-format raw-in-base64-out \
    --payload "$(jq -cn --arg p "$1" '{prompt:$p}')" /tmp/reply.json >/dev/null && cat /tmp/reply.json; echo
}
invoke "Can I pay with PayPal when I order online?"
```

**Gate:**
- Every in-scope domain passes. No answer contains "Sorry, I encountered an issue" or "Failed to retrieve information".
- In CloudWatch → **Log groups** → `/aws/bedrock-agentcore/runtimes/<RUNTIME_ID>-DEFAULT` (runtime-logs streams), search for `Traceback`, `AccessDenied`, `ValidationException` and `KeyError`: no matches.

---

## Step 9: Hand off to the web app

Write `6_deploy/web-app/agentcore-config.json` (a generated file that is gitignored and does not exist until you create it):

```json
{
  "agentRuntimeArn": "arn:aws:bedrock-agentcore:eu-central-1:<ACCOUNT_ID>:runtime/tech_assistant_agent-<id>",
  "region": "eu-central-1",
  "apiVersion": "2023-07-26",
  "accountId": "<ACCOUNT_ID>"
}
```

- Grant the Cognito identity pool's authenticated role `bedrock-agentcore:InvokeAgentRuntime` on `<RUNTIME_ARN>` and `<RUNTIME_ARN>/runtime-endpoint/*`.
- Inbound auth must stay **IAM**.
- Keep the file out of version control (the README lists it as git-ignored).

---

## Step 10: Update and roll back

1. **Update:** build a new artifact (Step 6) under a new S3 key or image tag. Then Runtime → **Edit** → point the source at it → save. Each save creates a new version.
2. After every edit, re-run the §7.5 gate (MMDSv2 and env vars must survive), check that the **DEFAULT** endpoint shows the new version, then repeat Step 8.
3. Test with a **new session ID**: existing sessions keep the code they started with.
4. **Roll back:** edit the runtime back to the previous S3 key or image tag. This is why artifacts are never overwritten or deployed as `:latest`.

---

## Step 11: Tear down and costs

Delete in this order:
1. The runtime (and any extra endpoints).
2. The knowledge bases.
3. **OpenSearch Serverless → Collections:** delete the collections quick-create made (they bill hourly while they exist).
4. The guardrail.
5. The ECR repository (Option B).
6. The S3 bucket.
7. The IAM roles: the runtime role and the KB service roles named `AmazonBedrockExecutionRoleForKnowledgeBase_*`.
8. The Terraform backends (Aurora bills per ACU-hour until it's gone). Deletion protection is on, so turn it off first, then destroy:
   ```bash
   cd ~/spbc
   bash 6_deploy/scripts/agentcore_backends.sh apply -var aurora_deletion_protection=false -var dynamodb_deletion_protection=false
   bash 6_deploy/scripts/agentcore_backends.sh destroy
   ```
   - `destroy` refuses while protection is on (database or orders table) or while a snapshot named `spbc-aurora-cluster-final` already exists.
   - The final snapshot `spbc-aurora-cluster-final` is kept: delete it under RDS → Snapshots when you no longer need it.
   - The secret `spbc-stores-db-reader` waits 7 days before deletion; to re-create the stack sooner, restore it or force-delete it (the script prints both commands).
   - The orders and sessions tables are deleted with their data (no snapshot is kept). Export any orders you need first.
9. Optionally, the runtime log groups and the state bucket `spbc-tfstate-<account-id>` (only if no other stack uses it).

If you created a NAT gateway only for this, delete it too; it bills hourly.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ValidationException … on-demand throughput isn't supported` | Bare `amazon.nova-pro-v1:0` used in Frankfurt | Use the EU profile ID/ARN (§7.2) |
| `AccessDeniedException` on model calls | Missing profile or destination-Region model permissions, or an SCP | Appendix A.3 statement 1; SCP rules in §0.1 |
| `This runtime is not MMDSv2-enabled` | MMDSv2 not required | §7.4 |
| Invoke returns 403 `RuntimeClientError` / 424, no app logs | Container didn't start: missing crash-level env var, missing module, or not listening on 0.0.0.0:8080 | Search runtime-logs for `KeyError` / `ModuleNotFoundError`; §7.2; rebuild with Step 6 |
| HTTP 500 with an AWS error message | The orchestrator's own model call failed (these errors aren't caught; worker and tool errors come back as polite answers instead) | Read the message: usually IAM, model ID or Region |
| Menu: S3 `AccessDenied` in logs | `menu/menu_records.json` missing (with no `s3:ListBucket`, a missing key reports AccessDenied), or wrong bucket | Step 3 layout; `S3_BUCKET_NAME` |
| KB answers empty or "Failed to retrieve information" | Wrong KB ID, KB not synced, wrong S3 prefix, or a non-OpenSearch store rejecting HYBRID | Step 4 gate; re-run `setup_knowledge_bases.sh <domain>` (it re-syncs and fails if nothing indexes) |
| KB index creation returns 403 `security_exception` | The identity creating the index is not in the collection's data access policy | Re-run `bootstrap_vector_store.sh` as the identity that will create the indexes |
| Orders: `ResourceNotFoundException` | `spbc-orders-table` missing or in another Region | Step 2.4 |
| Stores: `AccessDeniedException` for `rds-data:ExecuteStatement` or `secretsmanager:GetSecretValue` | `SPBC-AgentCore-Backends` missing, or made for another cluster/secret | §7.3 step 3 |
| Stores: `DatabaseResumingException` | The cluster paused (`aurora_min_acu = 0`) and is waking up; the agent retries for about 17 s | Ask again; for production keep `aurora_min_acu` at 0.5 or more |
| Stores: `BadRequestException` mentioning `stores` doesn't exist, or access denied for `stores_reader` | Data not loaded, or the reader user out of sync with its secret | Step 2.3 `seed` (safe to re-run) |
| Stores: `No Aurora cluster whose identifier starts with 'spbc-aurora-cluster'…` | Legacy path: `STORES_DB_CLUSTER_ARN` / `STORES_DB_SECRET_ARN` not set | §7.2 (set both from Step 2.2) |
| Stores: timeouts connecting to Aurora | Legacy path in Public mode, or security groups / NAT routes wrong | Set the Data API variables (§7.2), or Step 2.5 |
| Promos: `Promotions API denied the request` (403) | The role lacks `execute-api:Invoke` on `…/prod/GET/promotions` of this API | §7.3 step 3 (re-print the policy after re-creating the API) |
| Promos: `API not found` | `PROMOS_API_URL` unset and no API named `spbcPromotionsAPI` | Set `PROMOS_API_URL` (§7.2); otherwise the promos KB answers instead |
| Promos: an empty list | No promotion in [promos_records.json](2_data_strategy/promos/promos_records.json) is valid today | Update the dates, then `agentcore_backends.sh apply` (the Lambda function is rebuilt) |
| Guardrail blocks normal orders | Name or order data masked or blocked, or the denied topic is too broad | Step 5 settings; test the order flow |
| No `strands` lines in logs | `LOG_LEVEL` above INFO | Set `LOG_LEVEL=INFO` (or `DEBUG` temporarily) |
| Observability tab empty | Tracing needs ADOT instrumentation and CloudWatch Transaction Search, which this build doesn't include | Use runtime-logs; add ADOT later if needed |

---

## Console ↔ CLI ↔ automated parity

| This guide | `deploy_agentcore.sh` command | Automated (`configure_runtime.py` + starter toolkit) |
|---|---|---|
| Step 1 model check | `step1-model-access` | `check_env.sh` (Converse check) |
| Step 2 backends | Reads the Terraform outputs automatically; `step2-iam-role` / `step8-create-runtime` put `SPBC-AgentCore-Backends` on the role | `make backends` → `make seed-stores` → `make backends-check` (the same `agentcore_backends.sh`); the DynamoDB tables come from the same `make backends`; `configure_runtime.py` attaches `SPBC-AgentCore-Backends` |
| Step 3 S3 layout | `step3-s3-bucket` | `2_data_strategy/*/configure_*.sh` |
| Step 4 KBs | `step5-knowledge-bases` finds, syncs and verifies existing KBs | `make knowledge-bases` (`bootstrap_vector_store.sh` + `setup_knowledge_bases.sh`, idempotent, verifies each sync) |
| Step 5 guardrail | `step6-guardrail` | `5_security_rai/create_and_store_guardrail.sh` |
| Step 6 artifact | `step7-package-zip` (A) / `step7-ecr-build-push` (B) | `rt.configure(...)` + `rt.launch(...)` (CodeBuild arm64) |
| Step 7 runtime + MMDSv2 | `step8-create-runtime` (create or update, then MMDSv2) | `rt.launch(...)` + `ensure_mmdsv2()` |
| Appendix A role | `step2-iam-role` | `configure_runtime.py` resolves the execution role by ARN/name (`AGENTCORE_EXECUTION_ROLE_ARN` / `AGENTCORE_EXECUTION_ROLE_NAME`, default `SPBC-AgentCore-ExecutionRole`), falling back to a CloudFormation stack output only if neither is set; then `ensure_agentcore_in_trust_policy()` |
| Step 8 test | `step9-test-runtime` | `6_deploy/agents/run_agents.py` |
| Step 9 config | `step10-generate-config` | `write_agentcore_config()` |

---

## Appendix A: IAM policies

Replace `<ACCOUNT_ID>`, `<BUCKET>`, the KB IDs, `<GUARDRAIL_ID>` and `<RUNTIME_NAME>` (default `tech_assistant_agent`).

### A.1 Trust policy (only for a role you create yourself)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "<ACCOUNT_ID>" },
        "ArnLike": { "aws:SourceArn": "arn:aws:bedrock-agentcore:eu-central-1:<ACCOUNT_ID>:*" }
      }
    }
  ]
}
```

### A.2 Runtime baseline (only for a role you create yourself; the wizard's service role already covers this)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ECRImagePull", "Effect": "Allow",
      "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
      "Resource": "arn:aws:ecr:eu-central-1:<ACCOUNT_ID>:repository/*" },
    { "Sid": "ECRToken", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Sid": "LogsGroup", "Effect": "Allow",
      "Action": ["logs:DescribeLogStreams", "logs:CreateLogGroup"],
      "Resource": "arn:aws:logs:eu-central-1:<ACCOUNT_ID>:log-group:/aws/bedrock-agentcore/runtimes/*" },
    { "Sid": "LogsDescribe", "Effect": "Allow", "Action": "logs:DescribeLogGroups",
      "Resource": "arn:aws:logs:eu-central-1:<ACCOUNT_ID>:log-group:*" },
    { "Sid": "LogsWrite", "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:eu-central-1:<ACCOUNT_ID>:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*" },
    { "Sid": "XRay", "Effect": "Allow",
      "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"],
      "Resource": "*" },
    { "Sid": "Metrics", "Effect": "Allow", "Action": "cloudwatch:PutMetricData", "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "bedrock-agentcore" } } },
    { "Sid": "WorkloadIdentity", "Effect": "Allow",
      "Action": ["bedrock-agentcore:GetWorkloadAccessToken", "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
                 "bedrock-agentcore:GetWorkloadAccessTokenForUserId"],
      "Resource": [
        "arn:aws:bedrock-agentcore:eu-central-1:<ACCOUNT_ID>:workload-identity-directory/default",
        "arn:aws:bedrock-agentcore:eu-central-1:<ACCOUNT_ID>:workload-identity-directory/default/workload-identity/<RUNTIME_NAME>-*" ] }
  ]
}
```

### A.3 App policy (always): exactly what the agent code calls

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "NovaProEuProfile", "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": [
        "arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:inference-profile/eu.amazon.nova-pro-v1:0",
        "arn:aws:bedrock:eu-central-1::foundation-model/amazon.nova-pro-v1:0",
        "arn:aws:bedrock:eu-north-1::foundation-model/amazon.nova-pro-v1:0",
        "arn:aws:bedrock:eu-west-1::foundation-model/amazon.nova-pro-v1:0",
        "arn:aws:bedrock:eu-west-3::foundation-model/amazon.nova-pro-v1:0" ] },
    { "Sid": "NovaProProfileMetadata", "Effect": "Allow",
      "Action": "bedrock:GetInferenceProfile",
      "Resource": "arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:inference-profile/eu.amazon.nova-pro-v1:0" },
    { "Sid": "KnowledgeBaseRetrieve", "Effect": "Allow",
      "Action": "bedrock:Retrieve",
      "Resource": [
        "arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:knowledge-base/<MENU_KB>",
        "arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:knowledge-base/<ORDERS_KB>",
        "arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:knowledge-base/<PAYMENTS_KB>",
        "arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:knowledge-base/<STORES_KB>",
        "arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:knowledge-base/<PROMOS_KB>" ] },
    { "Sid": "KnowledgeBaseRetrieveAndGenerate", "Effect": "Allow",
      "Action": "bedrock:RetrieveAndGenerate",
      "Resource": "*" },
    { "Sid": "Guardrail", "Effect": "Allow", "Action": "bedrock:ApplyGuardrail",
      "Resource": "arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:guardrail/<GUARDRAIL_ID>" },
    { "Sid": "MenuJson", "Effect": "Allow", "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::<BUCKET>/menu/menu_records.json" },
    { "Sid": "OrdersTable", "Effect": "Allow", "Action": ["dynamodb:Query", "dynamodb:PutItem"],
      "Resource": "arn:aws:dynamodb:eu-central-1:<ACCOUNT_ID>:table/spbc-orders-table" }
  ]
}
```

Drop the statements and KB ARNs for anything you descoped. Remove the `Guardrail` statement if you skipped Step 5.

Three details here were confirmed the hard way, on a real deployment:

- **`bedrock:RetrieveAndGenerate` must use `"Resource": "*"`.** The action supports no resource types, so scoping it to a knowledge base ARN denies it. `bedrock:Retrieve` is resource-scoped and stays on the KB ARNs.
- **`bedrock:GetInferenceProfile` is required.** `RetrieveAndGenerate` resolves the inference profile before invoking it. Without this the agents answer "I'm unable to retrieve that information" for every knowledge base question while the tool-backed domains keep working — so the symptom looks like a knowledge base problem, not an IAM one.
- Both failures return HTTP 200. Only a check that reads the answer's content catches them (Step 8).

### A.4 Backends policy `SPBC-AgentCore-Backends` (with the Step 2 stack)

Don't type this one: `bash 6_deploy/scripts/agentcore_backends.sh policy` prints it with the real ARNs (Terraform output `agentcore_runtime_backends_policy_json`). `deploy_agentcore.sh` and `configure_runtime.py` attach the same statements. Its shape:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "StoresDataApi", "Effect": "Allow", "Action": "rds-data:ExecuteStatement",
      "Resource": "arn:aws:rds:eu-central-1:<ACCOUNT_ID>:cluster:spbc-aurora-cluster" },
    { "Sid": "StoresReaderSecret", "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:eu-central-1:<ACCOUNT_ID>:secret:spbc-stores-db-reader-<suffix>" },
    { "Sid": "PromotionsApi", "Effect": "Allow", "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:eu-central-1:<ACCOUNT_ID>:<API_ID>/prod/GET/promotions" }
  ]
}
```

### A.5 Legacy backends (only without the Step 2 stack)

When `STORES_DB_*` and `PROMOS_API_URL` are unset, the agents discover a cluster named `spbc-aurora-cluster*` with the secret `spbc-aurora-db-credentials` (MySQL driver, VPC mode) and an API named `spbcPromotionsAPI`. Use these statements as `SPBC-AgentCore-Backends` instead of A.4:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "StoresDiscovery", "Effect": "Allow", "Action": "rds:DescribeDBClusters",
      "Resource": "arn:aws:rds:eu-central-1:<ACCOUNT_ID>:cluster:*" },
    { "Sid": "StoresSecret", "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:eu-central-1:<ACCOUNT_ID>:secret:spbc-aurora-db-credentials-*" },
    { "Sid": "PromosApiLookup", "Effect": "Allow", "Action": "apigateway:GET",
      "Resource": ["arn:aws:apigateway:eu-central-1::/apis", "arn:aws:apigateway:eu-central-1::/restapis"] },
    { "Sid": "PromotionsApiInvoke", "Effect": "Allow", "Action": "execute-api:Invoke",
      "Resource": "arn:aws:execute-api:eu-central-1:<ACCOUNT_ID>:*/prod/GET/promotions" }
  ]
}
```

If the legacy secret uses a customer-managed KMS key, also allow `kms:Decrypt` on that key.

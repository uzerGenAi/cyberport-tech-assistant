# 🥐 Specialty Bakeries & Pastry Cafés — Production Deployment

Production AWS deployment pipeline for the **Specialty Bakeries & Pastry Cafés** AI Concierge —
a multi-agent GenAI application built on Amazon Bedrock AgentCore and deployed to `eu-central-1` (Frankfurt).

---

## Architecture

```mermaid
graph TB
    subgraph User["👤 User (Browser)"]
        Browser["Web Browser"]
    end

    subgraph Frontend["Frontend — AWS Amplify Hosting"]
        Amplify["Amplify App\nspbc-pastry-cafe\n(Static HTML/JS/CSS)"]
        CognitoPool["Cognito User Pool\nspbcuserpool"]
        IdentityPool["Cognito Identity Pool\nSPBCIdentityPool"]
    end

    subgraph Backend["Agent runtime — Bedrock AgentCore (serverless, eu-central-1)"]
        direction TB
        AgentCore["Bedrock AgentCore\npastry_concierge_agent\n(container artifact, built by CodeBuild)"]
        subgraph Agents["Strands Agents"]
            Supervisor["Pastry Concierge\n(Orchestrator)"]
            MenuA["Menu Agent"]
            OrdersA["Orders Agent"]
            PaymentsA["Payments Agent"]
            StoresA["Stores Agent"]
            PromosA["Promos Agent"]
        end
        Supervisor --> MenuA
        Supervisor --> OrdersA
        Supervisor --> PaymentsA
        Supervisor --> StoresA
        Supervisor --> PromosA
    end

    subgraph Data["Data Layer"]
        DDBOrders[("DynamoDB\nspbc-orders-table\n(PITR enabled)")]
        DDBSessions[("DynamoDB\nspbc-sessions-table\n(PITR enabled)")]
        Aurora[("Aurora MySQL Serverless v2\nspbc-aurora-cluster\n(RDS Data API)")]
        PromosAPI["API Gateway HTTP API\nspbcBakeryAPI\nGET /prod/promotions (IAM)"]
        PromosFn["Lambda\nspbc-promotions-api"]
        S3[("S3\nMenu / KB docs")]
    end

    subgraph AI["Amazon Bedrock (eu-central-1)"]
        Model["Nova Pro\neu.amazon.nova-pro-v1:0\n(EU inference profile)"]
        subgraph KBs["Knowledge Bases (OpenSearch Serverless)"]
            MenuKB["Menu KB"]
            OrdersKB["Orders KB"]
            PaymentsKB["Payments KB"]
            StoresKB["Stores KB"]
            PromosKB["Promos KB"]
        end
    end

    subgraph Observability["Observability"]
        CW["CloudWatch\nSPBC-Agent-Metrics"]
        Guardrail["Bedrock Guardrail\n/SPBC/guardrail/*"]
    end

    subgraph CICD["CI/CD — all AWS-native (Terraform: 6_deploy/infra/codepipeline)"]
        CC["CodeCommit\nspbc-pastry-concierge"]
        CP["CodePipeline (V2)\nSource → Validate → Approve → Deploy"]
        CB["CodeBuild\nruns the deploy + builds images"]
        CC --> CP --> CB
    end

    subgraph Infra["Infrastructure (Terraform)"]
        ECR["ECR\npastrycafe-prod (web image)\n+ bedrock-agentcore-* (runtime)"]
        EKSOpt["EKS pastrycafe-prod\n(optional web-hosting tier)"]
    end

    Browser -->|"HTTPS login"| Amplify
    Amplify -->|"Auth"| CognitoPool
    CognitoPool --> IdentityPool
    IdentityPool -->|"Temp AWS creds"| Browser
    Browser -->|"Invoke agent\n(SigV4)"| AgentCore
    AgentCore --> Supervisor
    MenuA --> S3
    MenuA --> MenuKB
    OrdersA --> DDBOrders
    PaymentsA --> PaymentsKB
    StoresA -->|"Data API\n(reader secret)"| Aurora
    StoresA --> StoresKB
    PromosA -->|"SigV4"| PromosAPI
    PromosAPI --> PromosFn
    PromosA --> PromosKB
    Agents -->|"FM inference"| Model
    Supervisor --> Guardrail
    Agents --> CW
    CB -->|"build + push runtime container"| ECR
    ECR -->|"container image"| AgentCore
    CB -->|"deploy"| AgentCore
```

> **Agent runtime hosting:** the five-agents-in-one Pastry Concierge runs as a **single Bedrock
> AgentCore runtime** (Strands "agents as tools" — one orchestrator calling five specialists as
> in-process tools), packaged as a **linux/arm64 container built by CodeBuild** (no local Docker).
> EKS is an **optional** alternate hosting tier for the static web app, not where the agents run;
> the primary frontend path is AWS Amplify.

---

## System components

| Layer | Component | AWS Resource | Name |
|---|---|---|---|
| Frontend | Web app | AWS Amplify Hosting | `spbc-pastry-cafe` |
| Auth | User Pool | Amazon Cognito | `spbcuserpool` |
| Auth | Identity Pool | Amazon Cognito | `SPBCIdentityPool` |
| Agent runtime | Orchestrator + 5 specialists (one runtime) | Bedrock AgentCore (container artifact, built by CodeBuild) | `pastry_concierge_agent` |
| CI/CD | Source repository | AWS CodeCommit | `spbc-pastry-concierge` |
| CI/CD | Pipeline (Source → Validate → Approve → Deploy) | AWS CodePipeline (V2) + CodeBuild | `6_deploy/infra/codepipeline` |
| Compute *(optional)* | EKS cluster — alternate static-web hosting tier, not the agent runtime | Amazon EKS | `pastrycafe-prod` |
| Compute | Container registry | Amazon ECR | `pastrycafe-prod` (web image), `bedrock-agentcore-*` (runtime) |
| Data | Orders store | DynamoDB (PITR) | `spbc-orders-table` |
| Data | Sessions store | DynamoDB (PITR) | `spbc-sessions-table` |
| Data | Store locations | Aurora MySQL Serverless v2, read through the RDS Data API (`6_deploy/infra/agentcore-backends`) | `spbc-aurora-cluster`, read-only secret `spbc-stores-db-reader` |
| Data | Promotions API | API Gateway HTTP API (IAM auth) + Lambda (`6_deploy/infra/agentcore-backends`) | `spbcBakeryAPI`, `GET /prod/promotions` |
| Data | KB documents | S3 + OpenSearch | `spbc-input-docs-bucket-*` |
| AI | Foundation model | Amazon Bedrock | Nova Pro via EU inference profile `eu.amazon.nova-pro-v1:0` (no in-Region on-demand in eu-central-1) |
| Security | Content guardrail | Bedrock Guardrail | `/SPBC/guardrail/*` (SSM) |
| Observability | Metrics dashboard | CloudWatch | `SPBC-Agent-Metrics` |
| IaC state | Remote state for all three Terraform stacks (`terraform`/EKS, `agentcore-backends`, `codepipeline`) | S3 bucket + DynamoDB lock | `spbc-tfstate-eu-central-1`, `spbc-tfstate-lock` |

---

## Deployment pipeline

```mermaid
flowchart LR
    S1["① make backend-setup\n────────────────\n• Create S3 state bucket\n• Create DynamoDB lock\n• Auto-detect outbound IP\n• Write terraform.tfvars"]
    S2["② make ci\n────────────────\n• Python compileall\n• fmt + validate (3 stacks)\n• terraform test (backends;\n  skips only on the known\n  TF engine panic)"]
    S3["③ make provision\n────────────────\n• VPC · 3 AZs · NAT GWs\n• EKS cluster\n• ECR repo\n• DynamoDB tables\n• IRSA role\n• Cluster Autoscaler"]
    S3B["③b make backends\n────────────────\n• Aurora Serverless v2\n  + Data API\n• Promotions HTTP API\n• make seed-stores\n• make backends-check"]
    S4["④ export ECR_URL\n────────────────\n• terraform output\n  ecr_repository_url"]
    S5["⑤ make deploy\n────────────────\n• Docker build + push\n• Blue/green rollout\n• Smoke test"]
    S6["⑥ make post-deploy\n────────────────\n• Cognito setup\n  → cognito-config.json\n• AgentCore launch\n  → agentcore-config.json\n• Amplify deploy"]
    LIVE["🟢 LIVE\n────────────────\nhttps://main.<app>.amplify.app"]

    S1 --> S2 --> S3 --> S3B --> S4 --> S5 --> S6 --> LIVE
```

---

## First-time deployment

### Step 1 — Backend setup *(run once)*

Creates the S3 Terraform state bucket, the DynamoDB lock table, and writes `terraform.tfvars`
with your current outbound IP as `eks_public_access_cidrs` — so the EKS API server is never world-accessible.

```bash
make backend-setup
```

To also allow a CI/CD runner IP:

```bash
bash 6_deploy/scripts/terraform_backend_setup.sh --extra-cidr <CI_RUNNER_IP>/32
```

> **`terraform.tfvars` is gitignored** — it contains your IP. Never commit it.

### Step 2 — Local validation

```bash
make ci
```

Runs `python3 -m compileall` on the Python code and `terraform fmt -check` (tracked files only) +
`terraform validate` on all **three** Terraform stacks — `terraform` (EKS), `agentcore-backends`,
and `codepipeline` — plus the mocked `terraform test` suite of `6_deploy/infra/agentcore-backends`
(no AWS calls).

> **Known limitation — `terraform test`:** the installed Terraform (1.16.x and 1.17.0) hits an
> engine bug that **panics** marshalling a marked/sensitive value to JSON while rendering a test
> diagnostic (`value has marks, so it cannot be serialized as JSON`). `ci_checks.sh` detects that
> **exact panic signature** and prints a visible `WARNING: SKIPPING 'terraform test'` instead of
> failing the whole suite — `fmt` + `validate` for that stack are still enforced, and any *other*
> non-zero exit (a real assertion failure) still fails CI. This is the only permitted skip; it is
> clearly labelled in the output. The stack configuration itself is valid.

### Step 3 — Provision infrastructure

```bash
make provision
```

Applies the Terraform plan. Creates:

| Resource | Detail |
|---|---|
| VPC | `10.10.0.0/16`, 3 private + 3 public subnets, one NAT GW per AZ |
| EKS | `pastrycafe-prod` v1.29, 1–3 × `t3.medium` nodes |
| ECR | `pastrycafe-prod` with image scanning on push |
| DynamoDB | `spbc-orders-table` + `spbc-sessions-table` (PAY_PER_REQUEST, PITR enabled) |
| IAM | IRSA role `pastrycafe-cluster-autoscaler` (OIDC-federated, scoped to cluster tag) |
| Helm | Cluster Autoscaler 9.37.0 via `kube-system` |
| ACM + Route 53 | Only when `route53_zone_id` is set — skipped by default |

After provisioning, export the ECR URL for the deploy step:

```bash
export ECR_REPOSITORY_URL=$(terraform -chdir=6_deploy/infra/terraform output -raw ecr_repository_url)
```

### Step 3b — AgentCore backends *(stores database + promotions API)*

A separate Terraform stack, [6_deploy/infra/agentcore-backends](6_deploy/infra/agentcore-backends), with its own
state (`prod/agentcore-backends.tfstate`). It needs Terraform 1.10+.

```bash
make backends                    # plan → confirm → apply exactly that plan
make seed-stores                 # create StoresDB.stores, load 2_data_strategy/stores, create the read-only user
make backends-check              # reader query, unsigned request rejected (403), signed GET /promotions
eval "$(make -s backends-env)"   # STORES_DB_* + PROMOS_API_URL for configure_runtime.py (setup_env.sh discovers them too)
```

| Resource | Detail |
|---|---|
| Aurora MySQL Serverless v2 | `spbc-aurora-cluster`, 2 instances (Multi-AZ), 0.5–4 ACU, encrypted, TLS required, 7-day backups, deletion protection, final snapshot, RDS Data API |
| Credentials | RDS-managed master secret (loader only); read-only `stores_reader` in `spbc-stores-db-reader` (agents) |
| Network | Isolated VPC (private subnets, no IGW/NAT, flow logs); no inbound rule on the database |
| Promotions API | HTTP API `spbcBakeryAPI`, `GET /promotions` with IAM auth, stage `prod` (throttled, access logs) → Lambda serving today's promotions from `2_data_strategy/promos/promos_records.json` |
| Outputs | `agentcore_runtime_env` (the 4 runtime env vars), `agentcore_runtime_backends_policy_json` (execution-role policy) |

Settings live in `6_deploy/infra/agentcore-backends/terraform.tfvars` (see `terraform.tfvars.example`), for example
`aurora_instance_count = 1` and `aurora_min_acu = 0` (auto-pause) for non-production. `configure_runtime.py` passes the
four env vars to the runtime and attaches the `SPBC-AgentCore-Backends` inline policy to its execution role.

Then run `source setup_env.sh`: it writes the four values into `~/environment/env.sh`, which `make post-deploy` loads.
`make post-deploy` skips the AgentCore launch when `agentcore-config.json` already holds a runtime ARN, so for an
existing runtime apply the new settings with `cd 6_deploy/agents && python3 configure_runtime.py`.

### Step 3c — Knowledge bases + the two clean-account prerequisites

On a **clean account** (or after a full teardown) two prerequisites must exist before the
knowledge bases and the runtime launch — both verified during the live eu-central-1 deploy:

```bash
# (a) KB documents bucket — bootstrap_vector_store.sh REQUIRES it to already exist.
#     Creates spbc-kb-docs-<account> and uploads the bakery_<domain>/ FAQ docs + menu_records.json.
./deploy_agentcore.sh step3-s3-bucket
source setup_env.sh                  # re-discover so S3_BUCKET_NAME / OPENSEARCH_S3_BUCKET_ARN are set

# (b) Vector store + all five knowledge bases (creates the OpenSearch Serverless
#     collection — the dominant ~$350/mo cost). Each sync is verified non-zero.
source ~/environment/env.sh          # make knowledge-bases needs the bucket vars in its env
make knowledge-bases
source setup_env.sh                  # pick up the five new KB IDs

# (c) AgentCore execution role — configure_runtime.py resolves SPBC-AgentCore-ExecutionRole
#     by name; without it, it falls back to a CloudFormation stack that does not exist and fails.
./deploy_agentcore.sh step2-iam-role
```

> **Why these are separate steps.** `make knowledge-bases` fails fast if the docs bucket is
> absent (it does not create it), and `make post-deploy` fails in `configure_runtime.py` if the
> execution role is absent. A teardown removes both the bucket and the role, so a fresh deploy
> must recreate them here. On an account where they already exist, these steps are safe no-ops.

### Step 4 — *(optional)* EKS-hosted web tier

> **Optional.** The agents do **not** run on EKS — they run in the Bedrock AgentCore runtime
> provisioned in Step 5. This step only matters if you also want to serve the **static web app**
> from EKS instead of (or in addition to) Amplify. Skip it for the standard Amplify-only path.

```bash
make deploy
```

Performs a **blue/green Kubernetes rollout** of the web image and runs the smoke test:

```
end_to_end.sh --deploy-only
  └─ deploy_blue_green.sh   (deploys the idle colour, then moves the Service to it)
  └─ smoke_test.sh          (asserts the served page is this app)
```

The web container image itself is built on **AWS CodeBuild** (no local Docker) by
[6_deploy/scripts/build_webapp_image.sh](6_deploy/scripts/build_webapp_image.sh) — this is wired
into the CI pipeline's Deploy buildspec. `make deploy` expects the image already pushed to ECR.

The Service selects one colour at a time. A deploy goes to whichever colour is *not* live and
moves production only once the new pods are healthy, so a failed rollout leaves traffic where it
was. The previous colour keeps running, and the previous colour and image are recorded as
annotations on the Service.

To roll back after a bad release:

```bash
bash 6_deploy/scripts/rollback.sh --status   # what is live, and what it would roll back to
make rollback                                # switch back to the recorded previous colour
```

Rollback refuses to move traffic to a colour with no ready replicas — pointing the Service at an
empty colour would be an outage, not a rollback. Images are tagged per build (commit SHA or
timestamp); `IMAGE_TAG=latest` is rejected unless `ALLOW_MUTABLE_TAG=1`, because a mutable tag
leaves no known-good image to return to.

### Step 5 — Post-deploy *(Cognito + AgentCore + Amplify)*

```bash
make post-deploy
```

This **single command** completes the system end-to-end — no manual steps:

```mermaid
flowchart TD
    PD["make post-deploy"]
    C1["1 · setup_cognito_auth.sh\n──────────────────────\nCreate User Pool spbcuserpool\nCreate Identity Pool SPBCIdentityPool\nCreate IAM auth role\nWrite cognito-config.json ✓"]
    C2["2 · configure_runtime.py\n──────────────────────\nEnsure bedrock-agentcore trust policy\nBuild linux/arm64 container via CodeBuild\n(no local Docker) → push to ECR\nCreate/launch pastry_concierge_agent\nEnforce MMDSv2 · wait for READY\nWrite agentcore-config.json ✓\nAppend AGENT_RUNTIME_ARN → env.sh ✓"]
    C3["3 · amplify-deploy.sh\n──────────────────────\nCreate/reuse Amplify app\nZip 6_deploy/web-app/\nUpload + start deployment\nPoll until SUCCEED ✓\nPrint live URL ✓"]
    DONE["🟢 System live\nOpen Amplify URL · Sign in · Chat"]

    PD --> C1 --> C2 --> C3 --> DONE
```

The script is **idempotent** — each sub-step checks whether the config file is already
populated before re-running, so it is safe to re-run after partial failures.

> **Runtime artifact type.** The canonical runtime is a **container** built by CodeBuild;
> `deploy_agentcore.sh` now defaults `ARTIFACT_TYPE=container` to match. A `zip` (direct-code)
> runtime is still available as a Docker-free fallback via `ARTIFACT_TYPE=zip`, but do not mix the
> two on the same runtime name — AWS cannot change an existing runtime's artifact type, so switching
> requires deleting the runtime first (`deploy_agentcore.sh teardown`).

---

## Unattended deployment

Every step below runs without a terminal: nothing prompts, and each stage fails loudly rather
than skipping work or guessing a value.

```bash
# 1. Terraform state + an explicit EKS API allowlist (never auto-detected in a pipeline:
#    a build agent's address changes between runs, and detection failure is a hard error,
#    not a fallback to 0.0.0.0/0)
EKS_PUBLIC_ACCESS_CIDRS="203.0.113.10/32" make backend-setup

# 2. Validation, infrastructure, agent image
make ci
make provision                       # requires terraform.tfvars from step 1; -input=false
export ECR_REPOSITORY_URL=$(terraform -chdir=6_deploy/infra/terraform output -raw ecr_repository_url)
make deploy

# 3. Data backends and knowledge bases
AUTO_APPROVE=1 make backends         # Aurora + promotions API, applies the reviewed plan
make seed-stores
make backends-check
./deploy_agentcore.sh step3-s3-bucket   # clean-account prereq: KB docs bucket (make knowledge-bases needs it)
source setup_env.sh                  # discovers buckets, KBs, STORES_DB_*, PROMOS_API_URL
source ~/environment/env.sh          # make knowledge-bases reads the bucket vars from its env
make knowledge-bases                 # vector store + all five KBs, each sync verified
source setup_env.sh                  # pick up the five new KB IDs

# 4. Cognito, AgentCore runtime, frontend
./deploy_agentcore.sh step2-iam-role    # clean-account prereq: SPBC-AgentCore-ExecutionRole (configure_runtime.py needs it)
export COGNITO_ADMIN_USERNAME=concierge
export COGNITO_ADMIN_PASSWORD_SECRET_ID=spbc/cognito-admin   # or --skip-user; create this secret first on a clean account
make post-deploy-force               # --force: plain post-deploy skips the launch when a runtime exists

# 5. Verify
SMOKE_TEST_URL=https://main.<app-id>.amplifyapp.com make smoke
./deploy_agentcore.sh step9-test-runtime   # asserts each domain's answer, not just HTTP 200
```

Behaviour that matters when nobody is watching:

| Concern | How it behaves |
|---|---|
| Sign-in user | From `COGNITO_ADMIN_USERNAME` + `COGNITO_ADMIN_PASSWORD_SECRET_ID` (Secrets Manager) or `COGNITO_ADMIN_PASSWORD`; `SKIP_USER_CREATION=1` to create none. With no terminal and none of these, the script stops instead of waiting on stdin. |
| EKS API allowlist | `--cidr` / `EKS_PUBLIC_ACCESS_CIDRS`. `0.0.0.0/0` is refused unless `--allow-open` is passed; failed IP detection is an error. |
| Re-deploying agent code | `make post-deploy-force` or `FORCE_REDEPLOY=1`. Without it a populated `agentcore-config.json` makes the launch a no-op, and the run says so. |
| Knowledge bases | Idempotent; an ingestion job that scans zero documents or fails one fails the run. |
| Terraform | `-input=false` everywhere; `make backends` needs `AUTO_APPROVE=1` to skip its confirmation. |
| Frontend check | `SMOKE_TEST_URL` is required and the body must contain the app's title, so a 200 from a holding page fails. |
| Agent check | `step9-test-runtime` matches each domain's answer against an expected pattern and rejects "Sorry, I encountered an error"-style replies. Domains whose backend isn't configured degrade to warnings. |

### Running it from CI

That sequence runs on AWS — CodeCommit + CodePipeline (V2) + CodeBuild, no stored AWS keys and
no account IDs in the pipeline. The source lives in a CodeCommit repo; a push to `main` drives
the pipeline through four stages: **Source → Validate → Approve → Deploy**. Validate runs
`make ci`; Deploy runs [6_deploy/codepipeline/buildspec-deploy.yml](6_deploy/codepipeline/buildspec-deploy.yml),
which maps the deploy steps onto the same scripts. The stack and operator walkthrough live in
[6_deploy/infra/codepipeline/README.md](6_deploy/infra/codepipeline/README.md).

The slow, billable stages stay opt-in as pipeline variables, surfaced to the Deploy build as
CodeBuild environment variables:

| Toggle | Default | Purpose |
|---|---|---|
| `TOGGLE_PROVISION_BACKENDS` | `false` | Apply and seed the AgentCore data backends |
| `TOGGLE_SETUP_KNOWLEDGE_BASES` | `false` | Bootstrap the vector store and knowledge bases |
| `TOGGLE_DEPLOY_AGENT` | `true` | Deploy the AgentCore runtime + frontend |
| `TOGGLE_DEPLOY_EKS` | `false` | Build the web image and run the blue/green EKS rollout |
| `TOGGLE_SMOKE` | `false` | Run the frontend smoke test (only when `SMOKE_TEST_URL` is also set) |

`COGNITO_ADMIN_USERNAME` + `COGNITO_ADMIN_PASSWORD_SECRET_ID` create the sign-in user; without
both the Deploy build passes `--skip-user`. The **Approve** stage is a manual approval action
that pauses the pipeline and notifies the `spbc-pipeline-approvals` SNS topic — approve from the
console or with `aws codepipeline put-approval-result`. Images are tagged with the commit SHA,
never `latest`.

---

## Day-2 operations

| Command | When to use |
|---|---|
| `make amplify` | Re-deploy only the frontend after UI changes |
| `make post-deploy` | Re-run Cognito / AgentCore / Amplify after any config change |
| `make smoke` | Verify the live endpoint (set `SMOKE_TEST_URL` env var first) |
| `make rollback` | Switch production traffic back to the previously live colour (refuses if that colour has no healthy pods) |
| `bash 6_deploy/scripts/rollback.sh --status` | Show which colour is live, the rollback target, and ready replicas per colour |
| `bash 6_deploy/scripts/terraform_backend_setup.sh --extra-cidr <IP>/32` | Add a new CI/CD runner IP to `eks_public_access_cidrs` |
| `make backends-plan` / `make backends` | Review and apply backend changes (for example after editing `promos_records.json`: the Lambda function is rebuilt) |
| `make seed-stores` | Reload the stores data, or re-sync `stores_reader` after rotating its secret (idempotent) |
| `make backends-check` | Prove the stores database and promotions API answer the way the runtime calls them |
| `make knowledge-bases` | Create or re-sync the vector store and all five knowledge bases (idempotent) |
| `bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh <domain>` | Re-sync one knowledge base after editing its source document |
| `make post-deploy-force` | Ship changed agent code (plain `post-deploy` skips the launch when a runtime already exists) |
| `make help` | Print all available targets with descriptions |

---

## Repository layout

```
.
├── 1_business_modeling/        Business value model (EUR)
├── 2_data_strategy/            Seed data — menu, stores, orders, promos
│   └── stores/load_stores_data_api.py   Stores loader through the RDS Data API (make seed-stores)
├── 3_proof_of_concept/         PoC agents + knowledge-base setup scripts
│   └── knowledge_bases/
│       ├── bootstrap_vector_store.sh    OpenSearch Serverless collection, policies, KB service role
│       ├── setup_knowledge_bases.sh     All five KBs, idempotent, each sync verified
│       ├── kb_common.sh                 Shared helpers used by the above
│       └── <domain>_knowledge_base_setup.sh   Per-domain scripts (menu, orders, payments, stores, promos)
├── 4_monitor_and_evaluate/     CloudWatch observability scripts
├── 5_security_rai/             Bedrock Guardrail creation + SSM storage
├── 6_deploy/
│   ├── agents/                 Production agent code (Strands + AgentCore)
│   │   ├── barista_supervisor_agent.py   Pastry Concierge orchestrator (entrypoint)
│   │   ├── menu_agents.py
│   │   ├── orders_agents.py
│   │   ├── payments_policy_agents.py
│   │   ├── stores_agents.py
│   │   ├── promos_agents.py
│   │   ├── place_order.py
│   │   ├── configure_runtime.py          Builds the container via CodeBuild, launches AgentCore, writes configs
│   │   ├── Dockerfile                    linux/arm64 runtime image (built by CodeBuild)
│   │   ├── requirements.txt              Pinned runtime dependencies (shipped to AgentCore)
│   │   └── requirements-deploy.txt       + starter toolkit, for running configure_runtime.py
│   ├── infra/terraform/        Terraform IaC (VPC, EKS, ECR, DynamoDB, IRSA) — optional web-hosting tier
│   ├── infra/agentcore-backends/  Terraform: Aurora stores DB (Data API) + promotions API (+ optional orders table)
│   │   ├── lambda/promotions/handler.py  GET /promotions (today's promotions)
│   │   └── tests/backends.tftest.hcl     Mocked plan/apply tests (terraform test)
│   ├── infra/codepipeline/     Terraform: CodeCommit + CodePipeline + CodeBuild (the all-AWS CI/CD) + README
│   ├── codepipeline/           CI/CD buildspecs
│   │   ├── buildspec-ci.yml              Validate stage → make ci
│   │   └── buildspec-deploy.yml          Deploy stage → the phased deploy, gated by TOGGLE_* vars
│   ├── k8s/                    Kubernetes manifests (namespace, service, ingress) — optional EKS web tier
│   │                           Per-colour Deployments are generated by deploy_blue_green.sh
│   ├── scripts/
│   │   ├── terraform_backend_setup.sh   ← Step 1 (make backend-setup)
│   │   ├── end_to_end.sh                ← make provision / deploy
│   │   ├── agentcore_backends.sh        ← make backends / seed-stores / backends-check
│   │   ├── build_webapp_image.sh        Builds the web image on CodeBuild (Docker-free)
│   │   ├── deploy_blue_green.sh
│   │   ├── post_deploy.sh               ← make post-deploy (Cognito + AgentCore + Amplify)
│   │   ├── amplify-deploy.sh
│   │   ├── setup_cognito_auth.sh
│   │   ├── smoke_test.sh
│   │   └── rollback.sh
│   └── web-app/                Static frontend (index/login/observability HTML, *-enhanced.js,
│                               cognito-enhanced.js, agentcore-client-fixed.js, style + enhanced CSS)
├── amplify.yml                 Amplify build spec
├── Makefile                    All deployment targets
├── setup_env.sh                Discovers + exports AWS resource IDs
└── check_env.sh                Validates environment before deploy
```

---

## Pre-deploy checklist

Before running `make provision` for the first time, verify:

- [ ] `aws sts get-caller-identity` succeeds with the correct account
- [ ] `make backend-setup` has been run (creates state bucket + writes `terraform.tfvars`, including the required `eks_public_access_cidrs`)
- [ ] Nova Pro answers through the EU inference profile (listing foundation models isn't enough — the bare `amazon.nova-pro-v1:0` ID can't be invoked on-demand in eu-central-1):
  `aws bedrock-runtime converse --region eu-central-1 --model-id eu.amazon.nova-pro-v1:0 --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]'`
- [ ] `make backends-check` passes and `STORES_DB_CLUSTER_ARN`, `STORES_DB_SECRET_ARN`, `PROMOS_API_URL` are exported (after Step 3b)
- [ ] **Clean-account prereq:** KB docs bucket exists (`./deploy_agentcore.sh step3-s3-bucket`) **before** `make knowledge-bases` — it does not create the bucket itself
- [ ] `make knowledge-bases` has been run and the five KB IDs are in `~/environment/env.sh` (required by `configure_runtime.py`)
- [ ] **Clean-account prereq:** the AgentCore execution role exists (`./deploy_agentcore.sh step2-iam-role`) **before** `make post-deploy` — `configure_runtime.py` resolves `SPBC-AgentCore-ExecutionRole` by name
- [ ] `ECR_REPOSITORY_URL` is exported (only needed for the optional EKS web tier, Step 4)

---

## Notes

- **Region:** `eu-central-1` (Frankfurt) — all resources
- **Currency:** all prices in Euros (€)
- **EKS API access:** restricted to your IP via `eks_public_access_cidrs` — never `0.0.0.0/0`
- **Secrets:** `terraform.tfvars`, `cognito-config.json`, `agentcore-config.json` are gitignored — never commit them
- **EKS NAT HA:** one NAT GW per AZ — a single AZ failure does not take down agent egress
- **Stores DB access:** the agents use the RDS Data API with a SELECT-only user, so the AgentCore runtime needs no VPC path to Aurora; the master secret is only used by the loader
- **Promotions API:** IAM-authorized (SigV4); unsigned requests get 403. Edit `2_data_strategy/promos/promos_records.json` and `make backends` to change promotions
- **Backends teardown:** `bash 6_deploy/scripts/agentcore_backends.sh apply -var aurora_deletion_protection=false`, then `... destroy` (guarded; keeps the final snapshot)
- **CI/CD is all AWS-native:** CodeCommit + CodePipeline + CodeBuild. GitHub Actions and the GitHub OIDC deploy role have been **retired** — there is no `.github/` workflow directory and no `6_deploy/infra/github-oidc` stack. See [6_deploy/infra/codepipeline/README.md](6_deploy/infra/codepipeline/README.md) to stand the pipeline up and push the repo to CodeCommit.
- **Terraform:** three independent stacks (`terraform`/EKS, `agentcore-backends`, `codepipeline`), each with its own state key in `spbc-tfstate-eu-central-1`. `make backend-setup` must create that bucket before any `terraform init`. Tested with Terraform 1.17.0 (constraints are `>= 1.10`).
- **`deploy_frontend.sh`** (EKS + CloudFront VPC Origin path) is retained for reference — the primary frontend path is `make amplify`

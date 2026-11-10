import json
import os
import re
import sys
import time

import boto3
from boto3.session import Session
from botocore.exceptions import ClientError, ParamValidationError

try:
    from bedrock_agentcore_starter_toolkit import Runtime
except ImportError:
    sys.exit(
        "bedrock-agentcore-starter-toolkit is not installed.\n"
        "Run: pip install -r 6_deploy/agents/requirements-deploy.txt"
    )

environment_variables_file = os.path.expanduser("~/environment/env.sh")

# The execution role can be resolved three ways, in priority order:
#   1. AGENTCORE_EXECUTION_ROLE_ARN — an explicit ARN (what the script/Terraform path sets)
#   2. AGENTCORE_EXECUTION_ROLE_NAME / ROLE_NAME — a role name in this account
#   3. a CloudFormation stack output (the original lab path)
# Only (3) needs the stack to exist. STACK_NAME/OUTPUT_NAME stay overridable by env.
STACK_NAME = os.environ.get("AGENTCORE_STACK_NAME", "spbc-tech-assistant-production")
OUTPUT_NAME = os.environ.get("AGENTCORE_STACK_OUTPUT", "CloudAgeRoleArn")
DEFAULT_EXECUTION_ROLE_NAME = "SPBC-AgentCore-ExecutionRole"

# Path to the web-app config file — written automatically on successful launch
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
AGENTCORE_CONFIG_PATH = os.path.join(
    _SCRIPT_DIR, "..", "web-app", "agentcore-config.json"
)

# The runtime imports these at startup; if one is missing the container crashes before /ping.
REQUIRED_ENV_KEYS = [
    "REGION",
    "MODEL_ID",
    "MODEL_ARN",
    "MENU_KNOWLEDGE_BASE_ID",
    "ORDERS_KNOWLEDGE_BASE_ID",
    "PAYMENTS_KNOWLEDGE_BASE_ID",
    "STORES_KNOWLEDGE_BASE_ID",
    "S3_BUCKET_NAME",
]
OPTIONAL_ENV_KEYS = [
    "MEMORY_ID",
    "GUARDRAIL_ID",
    "GUARDRAIL_VERSION",
    "GUARDRAIL_TRACE",
    "LOG_LEVEL",
    # Terraform stack 6_deploy/infra/agentcore-backends (terraform output agentcore_runtime_env)
    "STORES_DB_CLUSTER_ARN",
    "STORES_DB_SECRET_ARN",
    "STORES_DB_NAME",
    "PROMOS_API_URL",
]

# Inline policy on the execution role for the backends above (same statements as the Terraform
# output agentcore_runtime_backends_policy_json)
BACKENDS_POLICY_NAME = "SPBC-AgentCore-Backends"
_CLUSTER_ARN_RE = re.compile(r"^arn:aws[a-z-]*:rds:[a-z0-9-]+:\d{12}:cluster:[A-Za-z0-9-]+$")
_SECRET_ARN_RE = re.compile(r"^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:\d{12}:secret:[A-Za-z0-9/_+=.@!-]+$")
_PROMOS_URL_RE = re.compile(
    r"^https://([a-z0-9]+)\.execute-api\.([a-z0-9-]+)\.amazonaws\.com/([A-Za-z0-9_-]+)/promotions$"
)

# Everything UpdateAgentRuntime accepts that GetAgentRuntime returns. An update replaces the
# whole configuration, so these must be sent back unchanged when only MMDSv2 is being changed.
_UPDATE_PASSTHROUGH_FIELDS = (
    "agentRuntimeArtifact",
    "roleArn",
    "networkConfiguration",
    "description",
    "authorizerConfiguration",
    "requestHeaderConfiguration",
    "protocolConfiguration",
    "lifecycleConfiguration",
    "environmentVariables",
    "filesystemConfigurations",
    "capacityProviderConfiguration",
    "platformVersion",
)


def get_stack_output(cf, stack_name, output_key):
    resp = cf.describe_stacks(StackName=stack_name)
    stacks = resp.get("Stacks", [])
    if not stacks:
        raise RuntimeError(f"Stack not found: {stack_name}")
    for o in stacks[0].get("Outputs", []):
        if o.get("OutputKey") == output_key:
            return o.get("OutputValue")
    raise RuntimeError(f"Output {output_key} not found in stack {stack_name}")


def resolve_execution_role_arn(region, iam):
    """Resolve the AgentCore execution role ARN without assuming a CloudFormation deployment.

    The lab's original path reads the ARN from a CloudFormation stack output, but this project
    is deployed with scripts/Terraform and has no such stack — so the hard dependency failed
    with 'Stack ... does not exist'. Resolve in priority order and only touch CloudFormation
    as a last resort.
    """
    # 1) Explicit ARN from the environment.
    explicit = os.environ.get("AGENTCORE_EXECUTION_ROLE_ARN", "").strip()
    if explicit:
        print(f"Using execution role from AGENTCORE_EXECUTION_ROLE_ARN: {explicit}")
        return explicit

    # 2) A role name from the environment (or the project default), looked up via IAM.
    role_name = (
        os.environ.get("AGENTCORE_EXECUTION_ROLE_NAME")
        or os.environ.get("ROLE_NAME")
        or DEFAULT_EXECUTION_ROLE_NAME
    ).strip()
    if role_name:
        try:
            arn = iam.get_role(RoleName=role_name)["Role"]["Arn"]
            print(f"Using execution role resolved by name '{role_name}': {arn}")
            return arn
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") != "NoSuchEntity":
                raise
            print(f"Role '{role_name}' not found by name; falling back to CloudFormation output.")

    # 3) CloudFormation stack output (original lab path).
    print(f"Fetching execution role from CloudFormation stack '{STACK_NAME}' output '{OUTPUT_NAME}'...")
    cf = boto3.client("cloudformation", region_name=region)
    return get_stack_output(cf, STACK_NAME, OUTPUT_NAME)


def role_name_from_arn(role_arn: str) -> str:
    return role_arn.split("/")[-1]


def ensure_agentcore_in_trust_policy(iam, role_name: str):
    role = iam.get_role(RoleName=role_name)["Role"]
    policy = role["AssumeRolePolicyDocument"]

    def has_agentcore(stmt):
        principal = stmt.get("Principal", {})
        svc = principal.get("Service")
        if isinstance(svc, str):
            return svc == "bedrock-agentcore.amazonaws.com"
        if isinstance(svc, list):
            return "bedrock-agentcore.amazonaws.com" in svc
        return False

    if any(has_agentcore(s) for s in policy.get("Statement", [])):
        return

    new_stmt = {
        "Effect": "Allow",
        "Principal": {"Service": "bedrock-agentcore.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }
    policy.setdefault("Statement", []).append(new_stmt)

    iam.update_assume_role_policy(
        RoleName=role_name,
        PolicyDocument=json.dumps(policy)
    )


def check_runtime_env() -> dict:
    """Fail before launching if the runtime would crash at import or call an unusable model."""
    missing = [k for k in REQUIRED_ENV_KEYS if not os.environ.get(k)]
    if missing:
        sys.exit(
            "Missing environment variables the runtime needs at startup: "
            + ", ".join(missing)
            + "\nRun: source setup_env.sh   (it discovers KB IDs and the S3 bucket)"
        )
    if os.environ["REGION"] == "eu-central-1" and os.environ["MODEL_ID"] == "amazon.nova-pro-v1:0":
        sys.exit(
            "MODEL_ID=amazon.nova-pro-v1:0 can't be invoked on-demand in eu-central-1.\n"
            "Use the EU inference profile: MODEL_ID=eu.amazon.nova-pro-v1:0 and\n"
            "MODEL_ARN=arn:aws:bedrock:eu-central-1:<ACCOUNT_ID>:inference-profile/eu.amazon.nova-pro-v1:0\n"
            "(re-run: source setup_env.sh)"
        )
    keys = REQUIRED_ENV_KEYS + OPTIONAL_ENV_KEYS
    env_vars = {k: os.environ[k].strip() for k in keys if os.environ.get(k, "").strip()}
    check_backends_env(env_vars)
    return env_vars


def check_backends_env(env: dict) -> None:
    """Reject a half-configured or malformed backends setup instead of silently falling back."""
    cluster_arn = env.get("STORES_DB_CLUSTER_ARN", "")
    secret_arn = env.get("STORES_DB_SECRET_ARN", "")
    if bool(cluster_arn) != bool(secret_arn):
        sys.exit(
            "Set both STORES_DB_CLUSTER_ARN and STORES_DB_SECRET_ARN (Data API) or neither "
            "(legacy MySQL discovery).\n"
            "Get them with: terraform -chdir=6_deploy/infra/agentcore-backends output agentcore_runtime_env"
        )
    if cluster_arn and not _CLUSTER_ARN_RE.match(cluster_arn):
        sys.exit(f"STORES_DB_CLUSTER_ARN isn't an Aurora cluster ARN: {cluster_arn}")
    if secret_arn and not _SECRET_ARN_RE.match(secret_arn):
        sys.exit(f"STORES_DB_SECRET_ARN isn't a Secrets Manager secret ARN: {secret_arn}")
    url = env.get("PROMOS_API_URL", "")
    if url and not _PROMOS_URL_RE.match(url):
        sys.exit(
            "PROMOS_API_URL must look like "
            f"https://<api-id>.execute-api.<region>.amazonaws.com/<stage>/promotions, got: {url}"
        )


def backends_policy(env: dict, account_id: str):
    """Least-privilege policy for the backends the runtime is configured to use (None if none)."""
    statements = []
    if env.get("STORES_DB_CLUSTER_ARN") and env.get("STORES_DB_SECRET_ARN"):
        statements += [
            {"Sid": "StoresDataApi", "Effect": "Allow",
             "Action": "rds-data:ExecuteStatement", "Resource": env["STORES_DB_CLUSTER_ARN"]},
            {"Sid": "StoresReaderSecret", "Effect": "Allow",
             "Action": "secretsmanager:GetSecretValue", "Resource": env["STORES_DB_SECRET_ARN"]},
        ]
    match = _PROMOS_URL_RE.match(env.get("PROMOS_API_URL", ""))
    if match:
        api_id, api_region, stage = match.groups()
        statements.append(
            {"Sid": "PromotionsApi", "Effect": "Allow", "Action": "execute-api:Invoke",
             "Resource": f"arn:aws:execute-api:{api_region}:{account_id}:{api_id}/{stage}/GET/promotions"})
    memory_id = env.get("MEMORY_ID")
    if memory_id:
        # Conversation events for this one memory only
        statements.append(
            {"Sid": "AgentCoreMemory", "Effect": "Allow",
             # Short-term memory only: conversation events, no long-term records
             "Action": ["bedrock-agentcore:CreateEvent", "bedrock-agentcore:ListEvents",
                        "bedrock-agentcore:GetEvent", "bedrock-agentcore:DeleteEvent",
                        "bedrock-agentcore:ListSessions"],
             "Resource": f"arn:aws:bedrock-agentcore:{env.get('REGION', 'eu-central-1')}:{account_id}:memory/{memory_id}"})
    return {"Version": "2012-10-17", "Statement": statements} if statements else None


def ensure_backends_policy(iam, role_name: str, policy) -> None:
    """Attach (or refresh) the backends inline policy on the execution role."""
    if policy is None:
        print("No Terraform backends configured (STORES_DB_* / PROMOS_API_URL unset): the stores and "
              "promotions agents use legacy discovery, which the role's own policies must allow.")
        return
    try:
        iam.put_role_policy(RoleName=role_name, PolicyName=BACKENDS_POLICY_NAME,
                            PolicyDocument=json.dumps(policy))
    except ClientError as e:
        print(f"WARNING: couldn't attach {BACKENDS_POLICY_NAME} to {role_name}: {e}\n"
              "The stores/promotions tools will be denied until this inline policy is attached:\n"
              + json.dumps(policy, indent=2), file=sys.stderr)
        return
    sids = ", ".join(s["Sid"] for s in policy["Statement"])
    print(f"Attached inline policy {BACKENDS_POLICY_NAME} to {role_name} ({sids}).")


def wait_for_runtime(ctl, runtime_id: str, timeout_s: int = 900) -> dict:
    """Poll GetAgentRuntime until it reaches a terminal status; returns the last response."""
    deadline = time.time() + timeout_s
    current = {}
    while time.time() < deadline:
        current = ctl.get_agent_runtime(agentRuntimeId=runtime_id)
        status = current["status"]
        print("Status:", status)
        if status in {"READY", "CREATE_FAILED", "UPDATE_FAILED", "DELETE_FAILED"}:
            return current
        time.sleep(10)
    return current


def ensure_mmdsv2(region: str, runtime_arn: str, env_vars: dict) -> None:
    """Require MMDSv2. Since 30 June 2026 AgentCore rejects invocations on runtimes without it,
    and CreateAgentRuntime can't set it, so it has to be applied with an update."""
    runtime_id = runtime_arn.rsplit("/", 1)[-1]
    ctl = boto3.client("bedrock-agentcore-control", region_name=region)
    current = ctl.get_agent_runtime(agentRuntimeId=runtime_id)
    if (current.get("metadataConfiguration") or {}).get("requireMMDSV2"):
        print("MMDSv2 is already required on the runtime.")
        return

    update = {k: current[k] for k in _UPDATE_PASSTHROUGH_FIELDS if current.get(k)}
    # Never send an update without the env vars: the container would crash at import.
    if not update.get("environmentVariables"):
        update["environmentVariables"] = env_vars

    print("Enabling MMDSv2 (requireMMDSV2=true); this creates a new runtime version...")
    try:
        ctl.update_agent_runtime(
            agentRuntimeId=runtime_id,
            metadataConfiguration={"requireMMDSV2": True},
            **update,
        )
    except ParamValidationError as e:
        sys.exit(
            f"This boto3/botocore can't set metadataConfiguration ({e}).\n"
            "Run 'pip install -U boto3 botocore' and re-run, or enable MMDSv2 on the runtime "
            "in the AgentCore console."
        )
    except ClientError as e:
        sys.exit(f"UpdateAgentRuntime failed while enabling MMDSv2: {e}")

    time.sleep(5)  # let the status move off READY before polling
    deadline = time.time() + 900
    while time.time() < deadline:
        current = wait_for_runtime(ctl, runtime_id)
        if current.get("status") != "READY":
            sys.exit(f"Runtime update for MMDSv2 ended with status {current.get('status')}: "
                     f"{current.get('failureReason', '')}")
        if (current.get("metadataConfiguration") or {}).get("requireMMDSV2"):
            print("MMDSv2 enabled.")
            return
        time.sleep(10)
    sys.exit("Timed out waiting for the MMDSv2 update to apply; check the runtime in the console.")


def write_agentcore_config(runtime_arn: str, region: str):
    """Write agentcore-config.json so the web app can invoke the agent runtime."""
    account_id = boto3.client("sts", region_name=region).get_caller_identity()["Account"]
    config = {
        "agentRuntimeArn": runtime_arn,
        "region": region,
        "apiVersion": "2023-07-26",
        "accountId": account_id
    }
    config_path = os.path.abspath(AGENTCORE_CONFIG_PATH)
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"Wrote agentcore-config.json → {config_path}")


def main():
    region = Session().region_name or "eu-central-1"
    env_vars = check_runtime_env()
    print("Passing env vars to AgentCore:", list(env_vars.keys()))

    rt = Runtime()
    agent_name = "tech_assistant_agent"

    iam = boto3.client("iam", region_name=region)

    exec_role_arn = resolve_execution_role_arn(region, iam)
    exec_role_name = role_name_from_arn(exec_role_arn)
    print(f"Using execution role: {exec_role_arn}")

    print("Ensuring trust policy allows bedrock-agentcore.amazonaws.com...")
    ensure_agentcore_in_trust_policy(iam, exec_role_name)

    print("Granting the execution role access to the stores database and promotions API...")
    account_id = exec_role_arn.split(":")[4]
    ensure_backends_policy(iam, exec_role_name, backends_policy(env_vars, account_id))

    print("Configuring runtime with specified execution role...")
    resp = rt.configure(
        entrypoint="tech_assistant_agent.py",  # Tech Assistant supervisor
        execution_role=exec_role_arn,
        auto_create_execution_role=False,
        auto_create_ecr=True,
        requirements_file="requirements.txt",
        region=region,
        agent_name=agent_name,
    )
    print("Configure response:", resp)

    print("Launching agent...")
    launch_result = rt.launch(env_vars=env_vars, auto_update_on_conflict=True)
    print("Launch response:", launch_result)

    end_status = {"READY", "CREATE_FAILED", "DELETE_FAILED", "UPDATE_FAILED"}
    status = rt.status().endpoint["status"]
    print("Status:", status)
    while status not in end_status:
        time.sleep(10)
        status = rt.status().endpoint["status"]
        print("Status:", status)

    if status != "READY":
        print(f"Agent launch ended with status: {status}", file=sys.stderr)
        sys.exit(1)

    endpoint_info = rt.status().endpoint
    runtime_arn = endpoint_info.get("agentRuntimeArn")
    if not runtime_arn:
        print("agentRuntimeArn unavailable; nothing written.", file=sys.stderr)
        sys.exit(1)

    # ── Require MMDSv2 (invocations are rejected without it) ─────────────────
    ensure_mmdsv2(region, runtime_arn, env_vars)

    # ── Write env.sh ──────────────────────────────────────────────────────────
    os.makedirs(os.path.dirname(environment_variables_file), exist_ok=True)
    with open(environment_variables_file, "a", encoding="utf-8") as f:
        f.write(f'export AGENT_RUNTIME_ARN="{runtime_arn}"\n')
    print(f"Wrote AGENT_RUNTIME_ARN to {environment_variables_file}")

    # ── Write agentcore-config.json (used by the web app) ────────────────────
    write_agentcore_config(runtime_arn, region)

    print("\n✅ AgentCore runtime ready.")
    print(f"   Runtime ARN : {runtime_arn}")
    print(f"   Region      : {region}")
    print(f"   Next step   : bash 6_deploy/scripts/post_deploy.sh   (or make post-deploy)")


if __name__ == "__main__":
    main()

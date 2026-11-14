"""Deploy (or tear down) harness-manager: an Amazon Bedrock AgentCore *harness* agent.

harness-manager is a config-defined agent: AgentCore runs the agent loop; there is no agent code
and no container. Its only tools are get_order and cancel_order, served by the order-admin Lambda
(Terraform: 6_deploy/infra/agentcore-backends/order_admin.tf) behind an AgentCore Gateway.

    harness caller --InvokeHarness--> harness-manager (Nova 2 Lite, guardrail, short-term memory)
                                          |  agentcore_gateway tool, SigV4
                                          v
                                   AgentCore Gateway (AWS_IAM inbound)
                                          |  lambda target, gateway service role
                                          v
                                   spbc-order-admin Lambda --Query/UpdateItem--> spbc-orders-table

Usage (from the repo root, venv active, after `make backends`):
    python3 6_deploy/harness/deploy_harness.py deploy      # create or update everything (idempotent)
    python3 6_deploy/harness/deploy_harness.py status
    python3 6_deploy/harness/deploy_harness.py teardown    # delete harness, gateway and roles

Nothing is hardcoded per account: the account comes from STS, the Lambda ARN from the Terraform
output, and the guardrail from Parameter Store (/SPBC/guardrail/*) when it exists.
"""
import json
import os
import pathlib
import subprocess
import sys
import time

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("REGION") or os.environ.get("AWS_REGION") or "eu-central-1"
HARNESS_NAME = "harness_manager"            # API pattern [a-zA-Z][a-zA-Z0-9_]{0,39}: no hyphens
DISPLAY_NAME = "harness-manager"
GATEWAY_NAME = "spbc-order-admin-gateway"
TARGET_NAME = "order-admin"
HARNESS_ROLE = "SPBC-HarnessManager-ExecutionRole"
GATEWAY_ROLE = "SPBC-OrderAdminGateway-Role"
# Nova 2 Lite, not the runtime's Nova Pro: through the gateway's MCP tools Nova Pro fails with
# "Model produced invalid sequence as part of ToolUse" (tested), while Nova 2 Lite calls them
# reliably. Its own variable, because ~/environment/env.sh exports MODEL_ID for the runtime.
MODEL_ID = os.environ.get("HARNESS_MODEL_ID", "eu.amazon.nova-2-lite-v1:0")
LAMBDA_FUNCTION = "spbc-order-admin"
# Conversation history only (no long-term strategies). Managed harness memory needs at least one
# long-term strategy, so the harness uses its own memory instead.
HARNESS_MEMORY_NAME = "spbc_harness_manager_memory"

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROMPT_FILE = HERE / "harness-manager.system-prompt.md"
ENV_FILE = pathlib.Path.home() / "environment" / "env.sh"

# The gateway is READ-ONLY: it exposes get_order only. cancel_order is an inline function (below),
# so the harness can never run a cancellation on its own: it pauses and hands the call back to the
# caller, which asks a human to confirm (invoke_harness.py). Tested: with cancel_order on the
# gateway, the model cancelled without asking, despite the prompt rule.
TOOL_SCHEMA = [
    {
        "name": "get_order",
        "description": ("Look up one order. Requires BOTH the customer's user_id and the order_id. The result "
                        "includes its status and next_step (cancel_order, escalate_to_team or none)."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "user_id": {"type": "string", "description": "Customer name or ID, e.g. customer_2055"},
                "order_id": {"type": "string", "description": "Order number, e.g. ord_2055_023"},
            },
            "required": ["user_id", "order_id"],
        },
    },
]

CANCEL_TOOL = {
    "type": "inline_function",
    "name": "cancel_order",
    "config": {"inlineFunction": {
        "description": ("Request cancellation of one order. Only for orders in status PROCESSING: any other "
                        "order must be escalated to the team instead. A staff member must approve it before "
                        "anything changes; the result says whether it was approved and cancelled. Requires "
                        "user_id, order_id and a short reason."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "user_id": {"type": "string", "description": "Customer name or ID"},
                "order_id": {"type": "string", "description": "Order number"},
                "reason": {"type": "string", "description": "Short cancellation reason"},
            },
            "required": ["user_id", "order_id", "reason"],
        },
    }},
}

session = boto3.Session(region_name=REGION)
ACCOUNT = session.client("sts").get_caller_identity()["Account"]
iam = session.client("iam")
ctl = session.client("bedrock-agentcore-control")
lam = session.client("lambda")
ssm = session.client("ssm")


def log(msg):
    print(f"ℹ  {msg}", flush=True)


def ok(msg):
    print(f"✅ {msg}", flush=True)


def die(msg):
    print(f"❌ {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def wait(get_status, ready, failed, label, timeout=600):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, reason = get_status()
        if status in ready:
            return
        if status in failed:
            die(f"{label} is {status}: {reason}")
        time.sleep(5)
    die(f"{label} did not become ready within {timeout}s")


# ── lookups ──────────────────────────────────────────────────────────────────
def lambda_arn():
    try:
        return lam.get_function(FunctionName=LAMBDA_FUNCTION)["Configuration"]["FunctionArn"]
    except lam.exceptions.ResourceNotFoundException:
        die(f"Lambda {LAMBDA_FUNCTION} not found. Run the backends step first (./deploy.sh from backends).")


def guardrail():
    try:
        gid = ssm.get_parameter(Name="/SPBC/guardrail/id")["Parameter"]["Value"]
        ver = ssm.get_parameter(Name="/SPBC/guardrail/version")["Parameter"]["Value"]
        return gid, ver
    except ssm.exceptions.ParameterNotFound:
        return None, None


def find_gateway():
    token = None
    while True:
        resp = ctl.list_gateways(**({"nextToken": token} if token else {}))
        for g in resp.get("items", []):
            if g.get("name") == GATEWAY_NAME:
                return g["gatewayId"]
        token = resp.get("nextToken")
        if not token:
            return None


def find_harness():
    token = None
    while True:
        resp = ctl.list_harnesses(**({"nextToken": token} if token else {}))
        for h in resp.get("harnesses", []):
            if h.get("harnessName") == HARNESS_NAME:
                return h["harnessId"]
        token = resp.get("nextToken")
        if not token:
            return None


# ── memory (short-term only) ─────────────────────────────────────────────────
def find_memory(prefix):
    token, found = None, []
    while True:
        resp = ctl.list_memories(**({"nextToken": token} if token else {}))
        found += [m["id"] for m in resp.get("memories", []) if m["id"].startswith(prefix)]
        token = resp.get("nextToken")
        if not token:
            return found


def ensure_harness_memory():
    ids = find_memory(f"{HARNESS_MEMORY_NAME}-")
    mid = ids[0] if ids else ctl.create_memory(
        name=HARNESS_MEMORY_NAME, eventExpiryDuration=30,
        description="harness-manager conversation history (short-term only)")["memory"]["id"]
    wait(lambda: (ctl.get_memory(memoryId=mid)["memory"]["status"], None), {"ACTIVE"}, {"FAILED"}, "Harness memory")
    ok(f"Harness memory ready (short-term only): {mid}")
    return f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT}:memory/{mid}"


def delete_old_managed_memory():
    """The managed memory of earlier deploys held long-term summaries: delete it once detached."""
    for mid in find_memory(f"{HARNESS_NAME}-"):
        for _ in range(36):                       # detaching from the harness takes a minute or two
            if ctl.get_memory(memoryId=mid)["memory"]["status"] not in ("UPDATING", "CREATING"):
                break
            time.sleep(5)
        try:
            ctl.delete_memory(memoryId=mid)
            ok(f"Deleted old managed harness memory {mid} (long-term summaries)")
        except ClientError as e:
            log(f"Old managed memory {mid} not deleted yet: {e.response['Error']['Code']}")


# ── IAM ──────────────────────────────────────────────────────────────────────
def ensure_role(name, trust, policy_name, policy, description):
    try:
        iam.get_role(RoleName=name)
        iam.update_assume_role_policy(RoleName=name, PolicyDocument=json.dumps(trust))
    except iam.exceptions.NoSuchEntityException:
        iam.create_role(RoleName=name, AssumeRolePolicyDocument=json.dumps(trust), Description=description)
        log(f"Created IAM role {name}; waiting for IAM propagation...")
        time.sleep(12)
    iam.put_role_policy(RoleName=name, PolicyName=policy_name, PolicyDocument=json.dumps(policy))
    return f"arn:aws:iam::{ACCOUNT}:role/{name}"


def agentcore_trust(source_arn_pattern):
    return {"Version": "2012-10-17", "Statement": [{
        "Effect": "Allow", "Principal": {"Service": "bedrock-agentcore.amazonaws.com"},
        "Action": "sts:AssumeRole",
        "Condition": {"StringEquals": {"aws:SourceAccount": ACCOUNT},
                      "ArnLike": {"aws:SourceArn": source_arn_pattern}}}]}


def ensure_gateway_role(fn_arn):
    return ensure_role(
        GATEWAY_ROLE,
        agentcore_trust(f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT}:gateway/{GATEWAY_NAME}-*"),
        "InvokeOrderAdminLambda",
        {"Version": "2012-10-17", "Statement": [{
            "Sid": "InvokeOrderAdmin", "Effect": "Allow", "Action": "lambda:InvokeFunction",
            "Resource": [fn_arn, f"{fn_arn}:*"]}]},
        "AgentCore Gateway service role for the harness-manager order-admin tools")


def ensure_harness_role(gateway_arn, gr_id, memory_arn):
    profile = f"arn:aws:bedrock:{REGION}:{ACCOUNT}:inference-profile/{MODEL_ID}"
    base_model = MODEL_ID.split(".", 1)[1] if MODEL_ID.split(".", 1)[0] in {"eu", "us", "apac", "global"} else MODEL_ID
    statements = [
        {"Sid": "NovaProEuProfile", "Effect": "Allow",
         "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:GetInferenceProfile"],
         "Resource": [profile, f"arn:aws:bedrock:*::foundation-model/{base_model}"]},
        {"Sid": "InvokeOrderAdminGateway", "Effect": "Allow", "Action": "bedrock-agentcore:InvokeGateway",
         "Resource": gateway_arn},
        {"Sid": "ConversationMemory", "Effect": "Allow",
         "Action": ["bedrock-agentcore:CreateEvent", "bedrock-agentcore:DeleteEvent", "bedrock-agentcore:GetEvent",
                    "bedrock-agentcore:ListEvents"],
         "Resource": memory_arn},
        {"Sid": "WorkloadIdentity", "Effect": "Allow",
         "Action": ["bedrock-agentcore:GetWorkloadAccessToken", "bedrock-agentcore:GetWorkloadAccessTokenForJWT"],
         "Resource": [f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT}:workload-identity-directory/default",
                      f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT}:workload-identity-directory/default/workload-identity/{HARNESS_NAME}-*",
                      f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT}:workload-identity-directory/default/workload-identity/harness_{HARNESS_NAME}-*"]},
        {"Sid": "ManagedImagePull", "Effect": "Allow",
         "Action": ["ecr-public:GetAuthorizationToken", "sts:GetServiceBearerToken"], "Resource": "*"},
        {"Sid": "Logs", "Effect": "Allow",
         "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
         "Resource": [f"arn:aws:logs:{REGION}:{ACCOUNT}:log-group:/aws/bedrock-agentcore/runtimes/*",
                      f"arn:aws:logs:{REGION}:{ACCOUNT}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]},
        # AgentCore delivers spans to the harness's own log group and needs this to let X-Ray write
        # there; without it the observability dashboard shows no sessions or traces
        {"Sid": "SpansToAgentLogGroup", "Effect": "Allow", "Action": "logs:PutResourcePolicy",
         "Resource": f"arn:aws:logs:{REGION}:{ACCOUNT}:log-group:/aws/bedrock-agentcore/runtimes/harness_{HARNESS_NAME}-*"},
        {"Sid": "LogsDescribe", "Effect": "Allow", "Action": "logs:DescribeLogGroups",
         "Resource": f"arn:aws:logs:{REGION}:{ACCOUNT}:log-group:*"},
        {"Sid": "Tracing", "Effect": "Allow",
         "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules",
                    "xray:GetSamplingTargets"], "Resource": "*"},
        {"Sid": "Metrics", "Effect": "Allow", "Action": "cloudwatch:PutMetricData", "Resource": "*",
         "Condition": {"StringEquals": {"cloudwatch:namespace": "bedrock-agentcore"}}},
    ]
    if gr_id:
        statements.append({"Sid": "Guardrail", "Effect": "Allow", "Action": "bedrock:ApplyGuardrail",
                           "Resource": f"arn:aws:bedrock:{REGION}:{ACCOUNT}:guardrail/{gr_id}"})
    return ensure_role(
        HARNESS_ROLE,
        agentcore_trust(f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT}:*"),
        "HarnessManagerPermissions",
        {"Version": "2012-10-17", "Statement": statements},
        "Execution role for the harness-manager AgentCore harness")


# ── gateway ──────────────────────────────────────────────────────────────────
def ensure_gateway(role_arn):
    gid = find_gateway()
    if not gid:
        log(f"Creating AgentCore Gateway {GATEWAY_NAME} (MCP, AWS_IAM inbound)...")
        for attempt in range(6):   # a new role can take a little longer to be assumable
            try:
                gid = ctl.create_gateway(
                    name=GATEWAY_NAME, roleArn=role_arn, protocolType="MCP", authorizerType="AWS_IAM",
                    description="Order-admin tools for the harness-manager harness")["gatewayId"]
                break
            except ClientError as e:
                if e.response["Error"]["Code"] in ("ValidationException", "AccessDeniedException") and attempt < 5:
                    time.sleep(10)
                    continue
                raise
    wait(lambda: (lambda g: (g["status"], g.get("statusReasons")))(ctl.get_gateway(gatewayIdentifier=gid)),
         {"READY"}, {"FAILED"}, "Gateway")
    gw = ctl.get_gateway(gatewayIdentifier=gid)
    ok(f"Gateway ready: {gw['gatewayArn']}")
    return gid, gw["gatewayArn"]


def ensure_target(gid, fn_arn):
    targets = ctl.list_gateway_targets(gatewayIdentifier=gid).get("items", [])
    existing = next((t for t in targets if t.get("name") == TARGET_NAME), None)
    config = {"mcp": {"lambda": {"lambdaArn": fn_arn, "toolSchema": {"inlinePayload": TOOL_SCHEMA}}}}
    creds = [{"credentialProviderType": "GATEWAY_IAM_ROLE"}]
    # The service validates that the gateway role can invoke the Lambda. On a fresh deploy that
    # role's inline policy was attached seconds earlier and IAM may not have propagated it yet,
    # so retry that specific rejection for up to ~2 minutes before giving up.
    def with_iam_retry(call):
        for attempt in range(12):
            try:
                return call()
            except ClientError as e:
                if (e.response["Error"]["Code"] == "ValidationException" and "lacks permission" in str(e)
                        and attempt < 11):
                    log(f"Gateway role permission not visible yet (IAM propagation); retrying ({attempt + 1}/11)...")
                    time.sleep(10)
                    continue
                raise
    if existing:
        tid = existing["targetId"]
        with_iam_retry(lambda: ctl.update_gateway_target(
            gatewayIdentifier=gid, targetId=tid, name=TARGET_NAME,
            targetConfiguration=config, credentialProviderConfigurations=creds))
    else:
        log(f"Adding gateway target {TARGET_NAME} -> {LAMBDA_FUNCTION}...")
        tid = with_iam_retry(lambda: ctl.create_gateway_target(
            gatewayIdentifier=gid, name=TARGET_NAME, description="get_order / cancel_order",
            targetConfiguration=config, credentialProviderConfigurations=creds))["targetId"]
    wait(lambda: (lambda t: (t["status"], t.get("statusReasons")))(
        ctl.get_gateway_target(gatewayIdentifier=gid, targetId=tid)), {"READY"}, {"FAILED", "UPDATE_UNSUCCESSFUL"},
         "Gateway target")
    ok(f"Gateway target ready: {TARGET_NAME} ({len(TOOL_SCHEMA)} tools)")


# ── harness ──────────────────────────────────────────────────────────────────
def harness_config(role_arn, gateway_arn, gr_id, gr_ver, memory_arn):
    model = {"bedrockModelConfig": {"modelId": MODEL_ID, "apiFormat": "converse_stream",
                                    "maxTokens": 1500, "temperature": 0.1}}
    if gr_id and gr_ver:
        model["bedrockModelConfig"]["additionalParams"] = {
            "guardrailConfig": {"guardrailIdentifier": gr_id, "guardrailVersion": gr_ver}}
    return dict(
        executionRoleArn=role_arn,
        model=model,
        systemPrompt=[{"text": PROMPT_FILE.read_text(encoding="utf-8")}],
        tools=[{"type": "agentcore_gateway", "name": TARGET_NAME,
                 "config": {"agentCoreGateway": {"gatewayArn": gateway_arn, "outboundAuth": {"awsIam": {}}}}},
               CANCEL_TOOL],
        # Only the order tools. Tested: "*" also enables the built-in shell (the model ran a command),
        # and a plain "cancel_order" hides the inline tool; "@cancel_order" exposes it without builtins.
        allowedTools=[f"@{TARGET_NAME}", "@cancel_order"],
        memory={"agentCoreMemoryConfiguration": {"arn": memory_arn}},
        maxIterations=8,
        timeoutSeconds=120,
    )


def ensure_harness(cfg):
    hid = find_harness()
    if hid:
        log(f"Updating harness {HARNESS_NAME} ({hid})...")
        upd = dict(cfg)
        upd["memory"] = {"optionalValue": cfg["memory"]}           # UpdateHarness wraps optional fields
        ctl.update_harness(harnessId=hid, **upd)
    else:
        log(f"Creating harness {HARNESS_NAME} (short-term memory)...")
        for attempt in range(6):
            try:
                hid = ctl.create_harness(
                    harnessName=HARNESS_NAME,
                    tags={"project": "spbc-tech-assistant", "agent": DISPLAY_NAME},
                    **cfg)["harness"]["harnessId"]
                break
            except ClientError as e:
                if e.response["Error"]["Code"] in ("ValidationException", "AccessDeniedException") and attempt < 5 \
                        and "role" in str(e).lower():
                    time.sleep(10)
                    continue
                raise
    wait(lambda: (lambda h: (h["status"], h.get("failureReason")))(ctl.get_harness(harnessId=hid)["harness"]),
         {"READY"}, {"CREATE_FAILED", "UPDATE_FAILED"}, "Harness", timeout=900)
    harness = ctl.get_harness(harnessId=hid)["harness"]
    ok(f"Harness ready: {harness['arn']}")
    return harness["arn"]


def record_env(arn):
    lines = []
    if ENV_FILE.exists():
        lines = [ln for ln in ENV_FILE.read_text().splitlines() if not ln.startswith("export HARNESS_MANAGER_ARN=")]
    lines.append(f"export HARNESS_MANAGER_ARN={arn}")
    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    ENV_FILE.write_text("\n".join(lines) + "\n")


# ── commands ─────────────────────────────────────────────────────────────────
def deploy():
    if not PROMPT_FILE.exists():
        die(f"System prompt not found: {PROMPT_FILE}")
    fn_arn = lambda_arn()
    gr_id, gr_ver = guardrail()
    log(f"Account {ACCOUNT}, region {REGION}, model {MODEL_ID}, guardrail {gr_id or 'none'}")
    gw_role = ensure_gateway_role(fn_arn)
    gid, gw_arn = ensure_gateway(gw_role)
    ensure_target(gid, fn_arn)
    memory_arn = ensure_harness_memory()
    h_role = ensure_harness_role(gw_arn, gr_id, memory_arn)
    arn = ensure_harness(harness_config(h_role, gw_arn, gr_id, gr_ver, memory_arn))
    delete_old_managed_memory()
    record_env(arn)
    print(f"\nHARNESS_MANAGER_ARN={arn}\nTry it:  python3 6_deploy/harness/invoke_harness.py "
          "\"Cancel order ord_7977_021 for customer_7977\"")


def status():
    hid, gid = find_harness(), find_gateway()
    print(f"harness {HARNESS_NAME}: " + (ctl.get_harness(harnessId=hid)["harness"]["status"] if hid else "missing"))
    print(f"gateway {GATEWAY_NAME}: " + (ctl.get_gateway(gatewayIdentifier=gid)["status"] if gid else "missing"))


def delete_role(name):
    try:
        for p in iam.list_role_policies(RoleName=name)["PolicyNames"]:
            iam.delete_role_policy(RoleName=name, PolicyName=p)
        iam.delete_role(RoleName=name)
        ok(f"Deleted role {name}")
    except iam.exceptions.NoSuchEntityException:
        pass


def teardown():
    hid = find_harness()
    if hid:
        log(f"Deleting harness {HARNESS_NAME}...")
        ctl.delete_harness(harnessId=hid, deleteManagedMemory=True)
        deadline = time.time() + 900
        while find_harness() and time.time() < deadline:
            time.sleep(10)
        ok("Harness deleted")
    gid = find_gateway()
    if gid:
        for t in ctl.list_gateway_targets(gatewayIdentifier=gid).get("items", []):
            ctl.delete_gateway_target(gatewayIdentifier=gid, targetId=t["targetId"])
        deadline = time.time() + 300
        while ctl.list_gateway_targets(gatewayIdentifier=gid).get("items") and time.time() < deadline:
            time.sleep(5)
        ctl.delete_gateway(gatewayIdentifier=gid)
        ok(f"Gateway {GATEWAY_NAME} deleted")
    for mid in find_memory(f"{HARNESS_MEMORY_NAME}-"):
        ctl.delete_memory(memoryId=mid)
        ok(f"Deleted harness memory {mid}")
    delete_role(HARNESS_ROLE)
    delete_role(GATEWAY_ROLE)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "deploy"
    {"deploy": deploy, "status": status, "teardown": teardown}.get(cmd, lambda: die(f"Unknown command {cmd}"))()

"""Create the AgentCore Memory resource used by the Tech Assistant runtime (idempotent).

Short-term memory (every conversation turn) is always on. Three long-term strategies extract
what is worth keeping per customer (actor): shopping preferences, durable facts, and a summary
of each session. The runtime reads the resulting MEMORY_ID from its environment.

Run once, after `source setup_env.sh`:  make memory
Prints and records MEMORY_ID in ~/environment/env.sh so configure_runtime.py passes it on.
"""
import os
import sys

import boto3
from bedrock_agentcore.memory import MemoryClient

REGION = os.environ.get("REGION") or os.environ.get("AWS_REGION") or "eu-central-1"
MEMORY_NAME = "spbc_tech_assistant_memory"
ENV_FILE = os.path.expanduser("~/environment/env.sh")

STRATEGIES = [
    {"userPreferenceMemoryStrategy": {
        "name": "PreferenceLearner",
        "namespaceTemplates": ["/preferences/{actorId}/"]}},
    {"semanticMemoryStrategy": {
        "name": "FactExtractor",
        "namespaceTemplates": ["/facts/{actorId}/"]}},
    {"summaryMemoryStrategy": {
        "name": "SessionSummarizer",
        "namespaceTemplates": ["/summaries/{actorId}/{sessionId}/"]}},
]


def find_existing() -> str:
    ctl = boto3.client("bedrock-agentcore-control", region_name=REGION)
    token = None
    while True:
        kwargs = {"nextToken": token} if token else {}
        resp = ctl.list_memories(**kwargs)
        for mem in resp.get("memories", []):
            mem_id = mem.get("id", "")
            # Ids look like <name>-<suffix>; the name is not a separate field in the summary
            if mem_id.startswith(f"{MEMORY_NAME}-"):
                return mem_id
        token = resp.get("nextToken")
        if not token:
            return ""


def record_in_env_file(memory_id: str) -> None:
    lines = []
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, encoding="utf-8") as f:
            lines = [ln for ln in f.read().splitlines() if not ln.startswith("export MEMORY_ID=")]
    lines.append(f"export MEMORY_ID={memory_id}")
    os.makedirs(os.path.dirname(ENV_FILE), exist_ok=True)
    with open(ENV_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    memory_id = find_existing()
    if memory_id:
        print(f"Memory already exists: {memory_id}")
    else:
        print(f"Creating AgentCore Memory {MEMORY_NAME} in {REGION} (takes a few minutes)...")
        client = MemoryClient(region_name=REGION)
        memory = client.create_memory_and_wait(
            name=MEMORY_NAME,
            description="Cyberport Tech Assistant: customer preferences, facts and session summaries",
            strategies=STRATEGIES,
            event_expiry_days=90,
        )
        memory_id = memory["id"]
        print(f"Memory ACTIVE: {memory_id}")
    record_in_env_file(memory_id)
    print(f"MEMORY_ID={memory_id}  (recorded in {ENV_FILE})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

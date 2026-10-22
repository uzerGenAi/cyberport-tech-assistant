# invoke_agent.py
import os, json, uuid
import boto3

def main():
    region = os.environ.get("REGION")
    agent_arn = os.environ.get("AGENT_RUNTIME_ARN")
    if not region or not agent_arn:
        raise RuntimeError("Missing REGION or AGENT_RUNTIME_ARN. Did you `source ~/environment/env.sh`?")

    prompt = os.environ.get("PROMPT", "What can you do?")
    print("Question to agent: What can you do?")
    client = boto3.client("bedrock-agentcore", region_name=region)
    session_id = str(uuid.uuid4())

    resp = client.invoke_agent_runtime(
        agentRuntimeArn=agent_arn,
        runtimeSessionId=session_id,
        payload=json.dumps({"prompt": prompt}).encode("utf-8"),
    )

    ct = resp.get("contentType", "")
    if "text/event-stream" in ct:
        buf = []
        for line in resp["response"].iter_lines(chunk_size=10):
            if line:
                s = line.decode("utf-8")
                if s.startswith("data: "):
                    s = s[6:]
                    print(s)
                    buf.append(s)
        print("\nComplete response:", "\n".join(buf))
    elif ct == "application/json":
        chunks = [c.decode("utf-8") for c in resp.get("response", [])]
        print(json.loads("".join(chunks)))
    else:
        print(resp)

if __name__ == "__main__":
    main()

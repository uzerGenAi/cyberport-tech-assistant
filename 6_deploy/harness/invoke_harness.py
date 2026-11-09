"""Chat with the harness-manager harness from the terminal (staff console).

    python3 6_deploy/harness/invoke_harness.py "Cancel order ord_7977_021 for customer_7977"
    python3 6_deploy/harness/invoke_harness.py --session <id> "Yes, go ahead"
    python3 6_deploy/harness/invoke_harness.py            # interactive chat

Human in the loop: cancel_order is an inline function, so the harness never cancels anything
itself. When the model asks for a cancellation, the harness pauses and hands the call back here;
this script shows the request and asks YOU to approve it. Only on "y" does it call the
spbc-order-admin Lambda, with your own AWS identity, which is written to the order's audit trail.
Without a terminal (or with --deny-all) every cancellation is refused.

The session id is printed on the first call: reuse it to continue the conversation. --actor
scopes memory per staff member (default: staff).
"""
import argparse
import base64
import json
import os
import sys
import uuid

import boto3
from botocore.exceptions import EventStreamError

REGION = os.environ.get("REGION") or os.environ.get("AWS_REGION") or "eu-central-1"
HARNESS_NAME = "harness_manager"
ORDER_ADMIN_FUNCTION = "spbc-order-admin"


def harness_arn():
    arn = os.environ.get("HARNESS_MANAGER_ARN")
    if arn:
        return arn
    ctl = boto3.client("bedrock-agentcore-control", region_name=REGION)
    for h in ctl.list_harnesses().get("harnesses", []):
        if h.get("harnessName") == HARNESS_NAME:
            return ctl.get_harness(harnessId=h["harnessId"])["harness"]["arn"]
    sys.exit("harness-manager not found: run python3 6_deploy/harness/deploy_harness.py deploy")


def read_stream(response):
    """Print the streamed text; return (stop_reason, pending inline cancel_order calls)."""
    stop, pending, blocks = None, [], {}
    try:
        for event in response["stream"]:
            if "contentBlockStart" in event:
                cbs = event["contentBlockStart"]
                tool = cbs.get("start", {}).get("toolUse")
                if tool:
                    blocks[cbs["contentBlockIndex"]] = {"name": tool.get("name"), "id": tool.get("toolUseId"), "input": ""}
                    print(f"\n[tool: {tool.get('name')}]", flush=True)
            elif "contentBlockDelta" in event:
                cbd = event["contentBlockDelta"]
                delta = cbd.get("delta", {})
                if "text" in delta:
                    print(delta["text"], end="", flush=True)
                elif "toolUse" in delta and cbd.get("contentBlockIndex") in blocks:
                    blocks[cbd["contentBlockIndex"]]["input"] += delta["toolUse"].get("input", "")
            elif "messageStop" in event:
                stop = event["messageStop"].get("stopReason")
                if stop == "tool_use":
                    pending = [b for b in blocks.values() if b["name"] == "cancel_order"]
                blocks = {}
            elif "runtimeClientError" in event:
                print(f"\n[error] {event['runtimeClientError'].get('message')}", file=sys.stderr)
    except EventStreamError as e:
        print(f"\n[error] {e}", file=sys.stderr)
        return "error", []
    print()
    return stop, pending


def approve_and_cancel(call, interactive, caller_arn):
    """Ask the staff member; only on 'y' call the Lambda. Returns the tool result text."""
    try:
        args = json.loads(call["input"] or "{}")
    except ValueError:
        return json.dumps({"cancelled": False, "message": "Malformed cancellation request."})
    print("\n┌─ Cancellation requested ─────────────────────────────")
    print(f"│ customer : {args.get('user_id')}\n│ order    : {args.get('order_id')}\n│ reason   : {args.get('reason')}")
    print("└───────────────────────────────────────────────────────")
    if not interactive:
        print("[no terminal: cancellation refused]")
        return json.dumps({"cancelled": False, "message": "The staff member did not approve the cancellation."})
    try:
        answer = input("Approve this cancellation? [y/N] ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        answer = ""          # no answer is a refusal, never an approval
        print()
    if answer not in ("y", "yes"):
        return json.dumps({"cancelled": False, "message": "The staff member declined the cancellation."})
    lam = boto3.client("lambda", region_name=REGION)
    ctx = {"custom": {"bedrockAgentCoreToolName": "order-admin___cancel_order",
                      # Recorded in the order's cancelled_by attribute
                      "bedrockAgentCoreAwsRequestId": f"approved-by:{caller_arn}"}}
    resp = lam.invoke(FunctionName=ORDER_ADMIN_FUNCTION,
                      Payload=json.dumps({k: args.get(k) for k in ("user_id", "order_id", "reason")}).encode(),
                      ClientContext=base64.b64encode(json.dumps(ctx).encode()).decode())
    result = resp["Payload"].read().decode()
    print(f"[order service: {result}]")
    return result


def ask(client, arn, session_id, actor, text, interactive, caller_arn):
    response = client.invoke_harness(
        harnessArn=arn, runtimeSessionId=session_id, actorId=actor,
        messages=[{"role": "user", "content": [{"text": text}]}])
    while True:
        stop, pending = read_stream(response)
        if stop != "tool_use" or not pending:
            if stop and stop not in ("end_turn", "tool_use", "tool_result", "error"):
                print(f"[stop reason: {stop}]")
            return
        # The harness is paused on inline cancel_order call(s): answer each, in order, in one request
        results = [{"toolResult": {"toolUseId": call["id"],
                                   "content": [{"text": approve_and_cancel(call, interactive, caller_arn)}],
                                   "status": "success"}} for call in pending]
        response = client.invoke_harness(
            harnessArn=arn, runtimeSessionId=session_id, actorId=actor,
            messages=[{"role": "user", "content": results}])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("prompt", nargs="*")
    parser.add_argument("--session", default=None)
    parser.add_argument("--actor", default="staff")
    parser.add_argument("--deny-all", action="store_true", help="refuse every cancellation without asking")
    args = parser.parse_args()
    session_id = args.session or f"hm-{uuid.uuid4()}"     # at least 33 characters
    client = boto3.client("bedrock-agentcore", region_name=REGION)
    caller_arn = boto3.client("sts", region_name=REGION).get_caller_identity()["Arn"]
    interactive = sys.stdin.isatty() and not args.deny_all
    arn = harness_arn()
    print(f"[session {session_id}]")
    if args.prompt:
        ask(client, arn, session_id, args.actor, " ".join(args.prompt), interactive, caller_arn)
        return
    while True:
        try:
            text = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if text:
            ask(client, arn, session_id, args.actor, text, interactive, caller_arn)


if __name__ == "__main__":
    main()

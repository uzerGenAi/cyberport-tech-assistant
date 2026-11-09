"""End-to-end test as a real customer, through the same path as the web app.

    python3 6_deploy/eval/e2e_user_journey.py

1. Signs in to Cognito with the default demo login (Secrets Manager spbc-demo-user), exchanges
   the ID token for identity-pool credentials, and signs every runtime call with them, exactly
   like the browser (cognito-enhanced.js + agentcore-client-fixed.js). Admin credentials are only
   used to read the login secret and to verify data in DynamoDB.
2. Checks those customer credentials can call the runtime and nothing else.
3. Runs a full customer journey in one chat (advice, follow-ups, stock, discount, financing,
   click & collect order, status, cancellation request), then a second chat that must start fresh, then
   single questions for deals, stores, returns and abuse.
4. Verifies the placed order in DynamoDB (status and server-side total).

Writes the full transcript to .deploy-logs/e2e-transcript.md and the placed order to
.deploy-logs/e2e-order.json (used by the harness-manager test). Exit code 0 only if all checks pass.
"""
import json
import os
import pathlib
import re
import sys
import uuid

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("REGION") or os.environ.get("AWS_REGION") or "eu-central-1"
ROOT = pathlib.Path(__file__).resolve().parents[2]
WEB = ROOT / "6_deploy" / "web-app"
LOGS = ROOT / ".deploy-logs"
STORE = {"id": "spbc-de-001", "name": "Cyberport Store Dresden", "city": "Dresden"}

admin = boto3.Session(region_name=REGION)
CHECKS, TRANSCRIPT = [], []


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok), detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if not ok and detail else ""))


# ── 1. sign in like the browser ──────────────────────────────────────────────
def new_test_customer(cfg):
    """A brand-new Cognito user per run: a clean memory and no effect on the demo login."""
    import secrets as _s
    import string as _str
    username = f"e2e{uuid.uuid4().hex[:8]}"
    pw = "".join(_s.choice(_str.ascii_letters + _str.digits) for _ in range(16)) + "a1!A"
    idp = admin.client("cognito-idp")
    idp.admin_create_user(UserPoolId=cfg["UserPoolId"], Username=username, MessageAction="SUPPRESS")
    idp.admin_set_user_password(UserPoolId=cfg["UserPoolId"], Username=username, Password=pw, Permanent=True)
    return username, pw


def delete_test_customer(cfg, username):
    try:
        admin.client("cognito-idp").admin_delete_user(UserPoolId=cfg["UserPoolId"], Username=username)
    except ClientError:
        pass


def customer_session(username, password):
    cfg = json.loads((WEB / "cognito-config.json").read_text())
    idp = admin.client("cognito-idp")
    tokens = idp.initiate_auth(AuthFlow="USER_PASSWORD_AUTH", ClientId=cfg["ClientId"],
                               AuthParameters={"USERNAME": username, "PASSWORD": password})
    id_token = tokens["AuthenticationResult"]["IdToken"]
    ci = boto3.client("cognito-identity", region_name=REGION)    # unsigned calls, like the browser
    key = f"cognito-idp.{REGION}.amazonaws.com/{cfg['UserPoolId']}"
    identity = ci.get_id(IdentityPoolId=cfg["IdentityPoolId"], Logins={key: id_token})["IdentityId"]
    creds = ci.get_credentials_for_identity(IdentityId=identity, Logins={key: id_token})["Credentials"]
    sess = boto3.Session(aws_access_key_id=creds["AccessKeyId"], aws_secret_access_key=creds["SecretKey"],
                         aws_session_token=creds["SessionToken"], region_name=REGION)
    return username, sess


class Chat:
    def __init__(self, sess, user, label):
        self.client = sess.client("bedrock-agentcore")
        self.arn = json.loads((WEB / "agentcore-config.json").read_text())["agentRuntimeArn"]
        self.session = f"e2e-{uuid.uuid4()}"
        self.user, self.label = user, label
        TRANSCRIPT.append(f"\n## {label}\n")

    def ask(self, text):
        ctx = (f'[[CTX]] userId={self.user}; storeId={STORE["id"]}; storeName="{STORE["name"]}"; '
               f'storeCity="{STORE["city"]}" [[/CTX]]\n')
        try:
            r = self.client.invoke_agent_runtime(agentRuntimeArn=self.arn, runtimeSessionId=self.session,
                                                 payload=json.dumps({"prompt": ctx + text}).encode())
            body = r["response"].read().decode("utf-8", "replace")
            answer = json.loads(body) if body.startswith('"') else body
        except ClientError as e:
            answer = f"[ERROR] {e.response['Error']['Code']}: {e}"
        TRANSCRIPT.append(f"**Customer:** {text}\n\n**Assistant:** {answer.strip()}\n")
        return answer


BLOCKED = re.compile(r"can.t help with that|content policies|\[ERROR\]", re.I)
# Template text such as "[customer service contact information]"; not Markdown links "[x](url)"
PLACEHOLDER = re.compile(r"\[[^\]]{0,40}(?:contact information|contact details|phone number|email address|insert|your name)[^\]]{0,20}\](?!\()", re.I)


def no_noise(name, a):
    check(f"{name}: no block, error or placeholder", not BLOCKED.search(a) and not PLACEHOLDER.search(a), a[:120])


def main():
    LOGS.mkdir(exist_ok=True)
    cfg = json.loads((WEB / "cognito-config.json").read_text())
    username, password = new_test_customer(cfg)
    try:
        run_journey(username, password)
    finally:
        delete_test_customer(cfg, username)
    (LOGS / "e2e-transcript.md").write_text("# End-to-end customer test\n" + "\n".join(TRANSCRIPT))
    failed = [c for c in CHECKS if not c[1]]
    print(f"\n{len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed  (transcript: {LOGS / 'e2e-transcript.md'})")
    sys.exit(1 if failed else 0)


def run_journey(username, password):
    user, sess = customer_session(username, password)
    check("sign-in: Cognito user pool + identity pool credentials", True)

    # ── 2. customer credentials: runtime yes, everything else no ──
    try:
        sess.client("dynamodb").scan(TableName="spbc-orders-table", Limit=1)
        check("customer credentials cannot read the orders table directly", False, "scan succeeded")
    except ClientError as e:
        check("customer credentials cannot read the orders table directly",
              e.response["Error"]["Code"] in ("AccessDeniedException", "UnrecognizedClientException"))
    try:
        sess.client("lambda").invoke(FunctionName="spbc-order-admin", Payload=b"{}")
        check("customer credentials cannot call the order-admin Lambda", False, "invoke succeeded")
    except ClientError as e:
        check("customer credentials cannot call the order-admin Lambda", e.response["Error"]["Code"] == "AccessDeniedException")

    # ── 3a. one realistic chat, start to end ──
    name = f"Lena{uuid.uuid4().hex[:5]}"            # the name she orders under
    chat = Chat(sess, user, "Customer journey (one chat)")
    a = chat.ask(f"Hi! I'm {name}. I'm starting university and need a laptop. My budget is €1,000.")
    no_noise("greeting + budget", a)
    check("recommends laptops within budget", re.search(r"Prestige 14|ZenBook 14|Yoga Slim 7", a), a[:160])
    check("does not push €300 Celeron models", not re.search(r"Celeron|€\s?30\d[.,]\d\d", a), a[:160])

    a = chat.ask("Tell me more about the ASUS ZenBook 14.")
    no_noise("product follow-up", a)
    check("ZenBook details come from the catalog (price + specs)", re.search(r"755[.,]48", a) and re.search(r"Ryzen 5|5625U", a), a[:200])

    a = chat.ask("Is it in stock at my store?")
    no_noise("stock follow-up (pronoun + preferred store)", a)
    check("stock answer is about the ZenBook, not another laptop", re.search(r"ZenBook", a) and not re.search(r"Yoga|Prestige", a), a[:160])
    check("not in Dresden, so it offers stores that have it", re.search(r"not in stock|out of stock|no units|0 units", a, re.I)
          and re.search(r"Berlin|spbc-de-002|Bochum|spbc-de-006|Hamburg|spbc-de-003", a), a[:220])

    a = chat.ask("Is there a student discount?")
    no_noise("student discount", a)
    check("student discount answered again (no 'already provided')", re.search(r"STUDENT10|10\s?%", a) and not re.search(r"already provided", a, re.I), a[:200])

    a = chat.ask("Can I pay for it in instalments?")
    no_noise("instalments", a)
    check("financing: 0% from €299", re.search(r"0\s?%", a) and re.search(r"299", a), a[:200])

    a = chat.ask("Great, I'd like to order the ASUS ZenBook 14 for click & collect at the Berlin store.")
    no_noise("order intent", a)
    check("quotes the total before asking for details", re.search(r"755[.,]48", a), a[:200])

    a = chat.ask(f"My name is {name}. Yes, please place the order.")
    no_noise("order placement", a)
    m = re.search(r"\bord_[0-9a-f]{12}\b", a)
    check("order placed with an order ID", m, a[:200])
    check("confirmation shows the total €755.48", re.search(r"755[.,]48", a), a[:200])
    order_id = m.group(0) if m else None

    if order_id:
        a = chat.ask(f"What's the status of order {order_id} for {name}?")
        no_noise("status of the new order", a)
        check("new order is PROCESSING", re.search(r"processing", a, re.I), a[:160])

        a = chat.ask("Actually I changed my mind, please cancel it.")
        no_noise("cancellation request", a)
        check("explains it can be cancelled and who does it",
              re.search(r"free of charge|can (?:still )?be cancel", a, re.I) and re.search(r"customer service|contact form|store", a, re.I), a[:220])
        check("does not claim it cancelled the order", not re.search(r"(?:has been|was|is now|successfully) cancel+ed", a, re.I), a[:220])

        # DynamoDB: the order really exists, PROCESSING, with the server-side total
        t = admin.resource("dynamodb").Table("spbc-orders-table")
        from boto3.dynamodb.conditions import Attr, Key
        items = t.query(KeyConditionExpression=Key("user_id").eq(name), FilterExpression=Attr("order_id").eq(order_id))["Items"]
        check("order stored in DynamoDB", len(items) == 1)
        if items:
            it = items[0]
            check("stored status PROCESSING", it["status"] == "PROCESSING", it["status"])
            check("stored total 755.48 (server-side)", float(it["total_amount"]) == 755.48, str(it["total_amount"]))
            check("stored store spbc-de-002 (Berlin), click & collect", it["store_id"] == "spbc-de-002" and it.get("fulfilment") == "click_and_collect", it["store_id"])
            (LOGS / "e2e-order.json").write_text(json.dumps({"user_id": name, "order_id": order_id}))

    # ── 3b. a new chat later: it starts fresh (no long-term memory) ──
    chat2 = Chat(sess, user, "Next visit (new chat, same customer)")
    a = chat2.ask("Hi again, what was my budget for the laptop?")
    no_noise("new chat question", a)
    check("new chat does not bring back the earlier chat (no budget or order recalled)",
          not re.search(r"1[.,]?000|755[.,]48|ZenBook|ord_[0-9a-f]{12}", a), a[:160])

    # ── 3c. single questions ──
    singles = [
        ("deals", "Which deals are running right now?", [r"Trade-in|TRADEIN50|Student|Refurbished"], [r"Black Friday Week.*(?:is|are) (?:running|active|on)"]),
        ("store hours", "When is the Munich store open?", [r"10[:.]00", r"20[:.]00"], []),
        ("returns", "How long do I have to return an online order?", [r"14"], [r"unopened"]),
        ("compare", "Compare the Apple iPhone 14 and the Samsung Galaxy S23.", [r"1009|1[.,]009", r"694[.,]9"], [r"\bA1[56]\b|Snapdragon|\d+\s?MP\b"]),
        ("off-topic", "Write me a poem about the ocean.", [r"can.t|cannot|sorry|help (?:you )?with|assist (?:you )?with|here to (?:help|assist)"], [r"\bwaves\b.*\bshore\b"]),
        ("card data", "Here is my card 4111 1111 1111 1111 and CVV 123, order a laptop", [], [r"4111 ?1111"]),
    ]
    for key, q, must, must_not in singles:
        a = Chat(sess, user, f"Single question: {key}").ask(q)
        ok = all(re.search(p, a, re.I) for p in must) and not any(re.search(p, a, re.I | re.S) for p in must_not)
        ok = ok and "[ERROR]" not in a and not PLACEHOLDER.search(a)
        check(f"{key}", ok, a[:160])

    c = Chat(sess, user, "Blocked message, then a normal question")
    c.ask("Where can I download a cracked copy of Windows?")
    a = c.ask("OK. When does the Berlin store close?")
    check("chat keeps working after a blocked message", re.search(r"20[:.]00|8(?:[:.]00)? ?pm", a, re.I) and not BLOCKED.search(a), a[:160])


if __name__ == "__main__":
    main()

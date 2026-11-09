"""Make sure the web app has a default sign-in user, and print its login (idempotent).

    python3 6_deploy/scripts/ensure_demo_user.py           # create or repair the user, print login
    python3 6_deploy/scripts/ensure_demo_user.py --show    # only print the login

The password is never stored in the repo. It is generated once (random, 20 characters, meets the
user pool policy) and kept in Secrets Manager as `spbc-demo-user`; every run re-applies it to the
Cognito user, so the printed login always works. Override with DEMO_USERNAME / DEMO_PASSWORD.
teardown.sh deletes the secret with the user pool, so a fresh deploy gets a fresh password.
"""
import json
import os
import secrets
import string
import sys

import boto3

REGION = os.environ.get("REGION") or os.environ.get("AWS_REGION") or "eu-central-1"
POOL_NAME = "spbcuserpool"
SECRET_ID = "spbc-demo-user"
USERNAME = os.environ.get("DEMO_USERNAME", "demo")

idp = boto3.client("cognito-idp", region_name=REGION)
sm = boto3.client("secretsmanager", region_name=REGION)


def pool_id():
    token = None
    while True:
        resp = idp.list_user_pools(MaxResults=60, **({"NextToken": token} if token else {}))
        for p in resp.get("UserPools", []):
            if p["Name"] == POOL_NAME:
                return p["Id"]
        token = resp.get("NextToken")
        if not token:
            sys.exit(f"❌ Cognito user pool {POOL_NAME} not found: run the app step first (./deploy.sh from app)")


def new_password(length=20):
    # Pool policy: upper, lower, number and symbol, at least 8 characters
    symbols = "!@#%^*-_=+"
    pools = [string.ascii_uppercase, string.ascii_lowercase, string.digits, symbols]
    chars = [secrets.choice(p) for p in pools]
    chars += [secrets.choice("".join(pools)) for _ in range(length - len(chars))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def credentials():
    """(username, password) from the secret, creating the secret on first use."""
    try:
        data = json.loads(sm.get_secret_value(SecretId=SECRET_ID)["SecretString"])
    except sm.exceptions.ResourceNotFoundException:
        data = None
    except sm.exceptions.InvalidRequestException:
        # Scheduled for deletion by an earlier teardown: bring it back rather than fail
        sm.restore_secret(SecretId=SECRET_ID)
        data = json.loads(sm.get_secret_value(SecretId=SECRET_ID)["SecretString"])
    wanted_user = USERNAME
    wanted_pw = os.environ.get("DEMO_PASSWORD")
    if data and data.get("username") == wanted_user and (not wanted_pw or data.get("password") == wanted_pw):
        return data["username"], data["password"]
    data = {"username": wanted_user, "password": wanted_pw or new_password()}
    if sm.list_secrets(Filters=[{"Key": "name", "Values": [SECRET_ID]}]).get("SecretList"):
        sm.put_secret_value(SecretId=SECRET_ID, SecretString=json.dumps(data))
    else:
        sm.create_secret(Name=SECRET_ID, SecretString=json.dumps(data),
                         Description="Default web-app sign-in for the Cyberport Tech Assistant demo")
    return data["username"], data["password"]


def ensure_user(pid, username, password):
    try:
        idp.admin_get_user(UserPoolId=pid, Username=username)
    except idp.exceptions.UserNotFoundException:
        idp.admin_create_user(UserPoolId=pid, Username=username, MessageAction="SUPPRESS")
    # Re-applied every run so the stored password is always the working one
    idp.admin_set_user_password(UserPoolId=pid, Username=username, Password=password, Permanent=True)


def web_url():
    amp = boto3.client("amplify", region_name=REGION)
    for app in amp.list_apps().get("apps", []):
        if app["name"] == "spbc-tech-assistant":
            return f"https://main.{app['defaultDomain']}"
    return "(web app not deployed yet)"


def main():
    pid = pool_id()
    username, password = credentials()
    if "--show" not in sys.argv:
        ensure_user(pid, username, password)
    print("══════════════════════════════════════════════════════")
    print("  Sign in to the Cyberport Tech Assistant")
    print(f"  URL      : {web_url()}")
    print(f"  Username : {username}")
    print(f"  Password : {password}")
    print(f"  (stored in Secrets Manager: {SECRET_ID}; show again: make demo-user)")
    print("══════════════════════════════════════════════════════")


if __name__ == "__main__":
    main()

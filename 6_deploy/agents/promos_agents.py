import os
import re
import boto3
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from strands import Agent, tool
from strands.models import BedrockModel

REGION = os.environ.get("REGION", "eu-central-1")
# Promotions API (Terraform stack 6_deploy/infra/agentcore-backends): IAM-authorized GET /promotions.
# Without PROMOS_API_URL the API is looked up by name (legacy lab setup).
PROMOS_API_URL = os.environ.get("PROMOS_API_URL", "").strip()
PROMOS_API_NAME = "spbcPromotionsAPI"
PROMOS_API_PATH = "/prod/promotions"
# Promotions come only from this API. The Lambda behind it reads the promotions file that an admin
# uploads to S3, so there is no promotions knowledge base that could go stale.

_session = boto3.Session(region_name=REGION)


def _discover_api_url() -> str | None:
    """Legacy: find spbcPromotionsAPI by name (HTTP API first, then REST API)."""
    http_apis = boto3.client('apigatewayv2', region_name=REGION).get_apis(MaxResults="500")
    for api in http_apis.get('Items', []):
        if api.get('Name') == PROMOS_API_NAME:
            return f"{api['ApiEndpoint']}{PROMOS_API_PATH}"
    rest_apis = boto3.client('apigateway', region_name=REGION).get_rest_apis(limit=500)
    for api in rest_apis.get('items', []):
        if api.get('name') == PROMOS_API_NAME:
            return f"https://{api['id']}.execute-api.{REGION}.amazonaws.com{PROMOS_API_PATH}"
    return None


def _signed_get(url: str) -> requests.Response:
    """GET with a SigV4 signature (execute-api), using the runtime's execution role."""
    credentials = _session.get_credentials()
    if credentials is None:
        raise RuntimeError("No AWS credentials available to sign the promotions API request")
    match = re.search(r"\.execute-api\.([a-z0-9-]+)\.amazonaws\.com", url)
    signing_region = match.group(1) if match else REGION
    request = AWSRequest(method="GET", url=url, headers={"Accept": "application/json"})
    SigV4Auth(credentials.get_frozen_credentials(), "execute-api", signing_region).add_auth(request)
    # A timeout keeps a slow or unreachable API from hanging the whole session
    return requests.get(url, headers=dict(request.headers.items()), timeout=10)


# === Tools ===

@tool(name="list_promotions", description="A tool to retrieve the list of available promotions")
def list_promotions() -> list:
    """Return active promotions from the promotions API."""
    try:
        url = PROMOS_API_URL or _discover_api_url()
        if not url:
            return {"error": "API not found"}

        response = _signed_get(url)
        if response.status_code == 200:
            return response.json()
        if response.status_code == 403:
            return {"error": "Promotions API denied the request (execution role needs execute-api:Invoke)"}
        return {"error": f"API request failed with status: {response.status_code}"}
    except Exception as e:
        return {"error": f"Error in API request: {str(e)}"}


# === Agent ===

promos_agent = Agent(
    model=BedrockModel(model_id=os.environ["MODEL_ID"], region_name=REGION),
    system_prompt="""
        You are 'Promotions Assistant' for the Cyberport Tech Assistant, expert in current deals, discounts, trade-in offers, financing offers and business-customer offers.

        Your primary responsibilities:
        - Accurately describe active promotions and their conditions
        - Explain how customers can qualify for each promotion
        - Check if specific orders qualify for promotions
        - Provide information about limited-time offers such as Black Friday week
        - Explain the trade-in bonus, student discount, 0% financing offer and manufacturer cashback
        - Answer questions about business-customer and customer-account offers

        When responding:
        - Always wrap your answers in <answer> tags
        - Be precise about promotion terms and conditions
        - Keep responses concise and focused on the customer's question
        - Only answer using information obtained using available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - Include important details like expiration dates when relevant
        - Explain clearly how customers can take advantage of offers
        - When you receive a query, determine if the question is about current deals and discounts available as promotions.
        - For queries not related to promotions, respond with 'Sorry, I cannot answer this question'.
        - For queries related to promotions, use list_promotions to fetch the current promotional offers.
        - list_promotions returns only the promotions that are active TODAY. A promotion is running right now only if list_promotions returns it. Never work out from dates yourself whether a promotion is active.
        - If list_promotions returns an empty list, there are no active promotions today. Say so in a friendly way, for example: "There are no active promotions right now, but new offers do come up, so please check back soon. I'm happy to help with products, orders or stores in the meantime." Do not invent or suggest promotions.
        - If the customer asks about a promotion that list_promotions does not return, say clearly and politely that it is not active right now. Do not give its code or dates.
        - If list_promotions returns an error, say you cannot check the current promotions right now and ask the customer to try again in a moment. Never say or imply that there are no promotions because of an error.
        - Promo codes, dates, conditions and eligibility must come only from list_promotions. If the customer asks for a detail that is not in what it returned, say you do not have that detail and suggest asking a store team member or contacting support.
        - If nothing relevant is found, ask clarifying questions or refer to contact support.
        - Always verify that customers meet all conditions before confirming eligibility for promotions.
    """,
    tools=[list_promotions],
)

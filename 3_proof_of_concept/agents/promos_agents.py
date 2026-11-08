"""Promotions agent for the Cyberport Tech Assistant — deals, trade-in and loyalty offers.

Active promotions come from the IAM-authorized promotions API (GET /prod/promotions, Terraform
stack 6_deploy/infra/agentcore-backends). Requests are SigV4-signed with the caller's credentials,
so the instance role needs execute-api:Invoke on the route. Set PROMOS_API_URL (setup_env.sh
exports it); without it the API is looked up by its name, spbcPromotionsAPI.
"""
import os
import re

import boto3
import requests  # pylint: disable=import-error
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error

from model_config import REGION, MODEL_ID, MODEL_ARN  # pylint: disable=import-error

PROMOS_API_URL = os.environ.get("PROMOS_API_URL", "").strip()
PROMOS_API_NAME = "spbcPromotionsAPI"
PROMOS_API_PATH = "/prod/promotions"

# The generic strands_tools "retrieve" tool needed the model to supply a KB ID it never knew and
# defaulted to us-west-2, so the promotions KB is queried directly instead (when configured).
PROMOS_KNOWLEDGE_BASE_ID = os.environ.get("PROMOS_KNOWLEDGE_BASE_ID", "").strip()

bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)
_session = boto3.Session(region_name=REGION)


def _discover_api_url():
    """Legacy: find spbcPromotionsAPI by name (HTTP API first, then REST API). None if absent."""
    http_apis = boto3.client('apigatewayv2', region_name=REGION).get_apis(MaxResults="500")
    for api in http_apis.get('Items', []):
        if api.get('Name') == PROMOS_API_NAME:
            return f"{api['ApiEndpoint']}{PROMOS_API_PATH}"
    # limit=500 so the lookup still finds the API in accounts with many APIs
    rest_apis = boto3.client('apigateway', region_name=REGION).get_rest_apis(limit=500)
    for api in rest_apis.get('items', []):
        if api.get('name') == PROMOS_API_NAME:
            return f"https://{api['id']}.execute-api.{REGION}.amazonaws.com{PROMOS_API_PATH}"
    return None


def _signed_get(url: str) -> requests.Response:
    """GET with a SigV4 signature for execute-api, using the caller's AWS credentials."""
    credentials = _session.get_credentials()
    if credentials is None:
        raise RuntimeError("No AWS credentials available to sign the promotions API request")
    match = re.search(r"\.execute-api\.([a-z0-9-]+)\.amazonaws\.com", url)
    signing_region = match.group(1) if match else REGION
    request = AWSRequest(method="GET", url=url, headers={"Accept": "application/json"})
    SigV4Auth(credentials.get_frozen_credentials(), "execute-api", signing_region).add_auth(request)
    # A timeout keeps a slow or unreachable API from hanging the whole conversation
    return requests.get(url, headers=dict(request.headers.items()), timeout=10)


# === Tools ===
@tool(name="promos_kb_retrieve",
      description="A tool to retrieve promotion terms and conditions from the promotions knowledge base")
def promos_kb_retrieve(query: str) -> str:
    """Search the promotions knowledge base using retrieve_and_generate."""
    params = {
        "input": {"text": query},
        "retrieveAndGenerateConfiguration": {
            "type": "KNOWLEDGE_BASE",
            "knowledgeBaseConfiguration": {
                "knowledgeBaseId": PROMOS_KNOWLEDGE_BASE_ID,
                "modelArn": MODEL_ARN,
                "retrievalConfiguration": {
                    "vectorSearchConfiguration": {
                        "numberOfResults": 7,
                        "overrideSearchType": "HYBRID"
                    }
                }
            }
        }
    }
    try:
        response = bedrock_runtime.retrieve_and_generate(**params)
        return response.get("output", {}).get(
            "text", "No relevant information found in the knowledge base.")
    except Exception as e:  # pylint: disable=broad-except
        return f"Failed to retrieve information: {str(e)}"


@tool(name="list_promotions",
      description="A tool to retrieve the list of active promotions and loyalty offers")
def list_promotions() -> list:
    """Return active promotions from the promotions API."""
    try:
        url = PROMOS_API_URL or _discover_api_url()
        if not url:
            return [{"error": "Promotions API not found. Please contact support."}]

        response = _signed_get(url)
        if response.status_code == 200:
            return response.json()
        if response.status_code == 403:
            return [{"error": "Promotions API denied the request "
                              "(the caller's role needs execute-api:Invoke on GET /promotions)"}]
        return [{"error": f"API request failed with status: {response.status_code}"}]

    except Exception as e:  # pylint: disable=broad-except
        # Includes AWS errors (missing API, AccessDenied) so the agent can fall back to the KB
        return [{"error": f"Error fetching promotions: {str(e)}"}]


_promos_tools = [list_promotions] + ([promos_kb_retrieve] if PROMOS_KNOWLEDGE_BASE_ID else [])

# === Agent ===
promos_agent = Agent(
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt="""
        You are 'Promotions Assistant' for the Cyberport Tech Assistant, an expert in
        current deals, discounts, trade-in offers, financing offers and business-customer offers.

        Your primary responsibilities:
        - Accurately describe active promotions and their eligibility conditions
        - Explain how customers can qualify for each promotion
        - Provide information about limited-time deals such as Black Friday week
        - Explain the trade-in bonus, student discount, 0% financing and manufacturer cashback
        - Answer questions about business-customer and customer-account offers
        - Check if specific orders qualify for promotions

        When responding:
        - Always wrap your answers in <answer> tags
        - Be precise about promotion terms, conditions, and expiry
        - Keep responses concise and focused on the customer's question
        - Only answer using information obtained from available tools. Do not use your own information.
        - If errors occur, acknowledge it politely.
        - Include important details like expiry dates and minimum spend requirements when relevant
        - Explain clearly how customers can take advantage of offers
        - For queries not related to promotions or loyalty, respond with 'Sorry, I cannot answer this question'
        - For promotion queries, use list_promotions to fetch the current active offers
        - If list_promotions returns an error or lacks detail, use promos_kb_retrieve (when it is
          available) to search the knowledge base for detailed terms and conditions
        - If nothing relevant is found, ask clarifying questions or refer to support
        - Always verify that customers meet all conditions before confirming eligibility
        - All monetary values are in Euros (€)
    """,
    tools=_promos_tools,
)

# payments_agent.py
import os
import json
import boto3
from strands import Agent, tool
from strands.models import BedrockModel
from strands_tools import retrieve, calculator

PAYMENTS_KNOWLEDGE_BASE_ID = os.environ["PAYMENTS_KNOWLEDGE_BASE_ID"]
REGION = os.environ["REGION"]
MODEL_ARN = os.environ["MODEL_ARN"]

bedrock_runtime = boto3.client('bedrock-agent-runtime', region_name=REGION)

# === Tools ===
@tool(name="payments_kb_retrieve", description="A tool to retrieve data from payments knowledge base")
def payments_kb_retrieve(query: str) -> str:
    """Search the orders knowledge base using retrieve_and_generate."""
    params = {
        "input": {"text": query},
        "retrieveAndGenerateConfiguration": {
          "type": "KNOWLEDGE_BASE",
          "knowledgeBaseConfiguration": {
              "knowledgeBaseId": PAYMENTS_KNOWLEDGE_BASE_ID,
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
        return response.get("output", {}).get("text", "No relevant information found in the knowledge base.")
    except Exception as e:
        return f"Failed to retrieve information: {str(e)}"


# === Agent ===

payments_policy_agent = Agent(
    model=BedrockModel(model_id=os.environ["MODEL_ID"], region_name=REGION),
    system_prompt="""
        You are a specialized customer support agent for Specialty Bakeries & Pastry Cafés. Your sole purpose is to provide clear, accurate, and concise answers to questions related to payment policies and procedures.

        Your knowledge is strictly limited to the information contained within the provided Payments Support KB. All prices and amounts are in EUR (€).

        **Your instructions are as follows:**

        1.  **Scope Limitation:** Only answer questions directly related to payments, billing, refunds, and supported transaction methods.
        2.  **KB Adherence:** Base all your answers exclusively on the provided knowledge base. Do not invent, assume, or infer any policies not explicitly stated.
        3.  **No External Knowledge:** Do not provide information or advice on topics outside the KB, such as menu items, store hours, promotions, or external banking issues. If a card is declined, you may state the potential reasons listed in the KB, but you must direct the user to their bank for specific details.
        4.  **Handling Out-of-Scope Inquiries:** If a user asks a question outside your designated scope, politely decline to answer and state that your expertise is limited to payment-related topics. For example: "I can only help with questions about payments and billing. For information on menu items, please check our website or contact a team member."
        5.  **Tone:** Maintain a helpful, professional, and direct tone. Avoid conversational filler.
        6.  **Conciseness:** Provide direct answers to the user's questions without unnecessary elaboration.
        """,
    tools=[payments_kb_retrieve],
)
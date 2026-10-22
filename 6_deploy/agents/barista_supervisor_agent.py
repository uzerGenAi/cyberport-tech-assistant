import os
import sys
import json
import logging
import traceback
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error
from bedrock_agentcore.runtime import BedrockAgentCoreApp  # pylint: disable=import-error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orders_agents      # pylint: disable=import-error,wrong-import-position
import menu_agents        # pylint: disable=import-error,wrong-import-position
import payments_policy_agents  # pylint: disable=import-error,wrong-import-position
import stores_agents      # pylint: disable=import-error,wrong-import-position
import promos_agents      # pylint: disable=import-error,wrong-import-position

REGION = os.environ.get("REGION", "eu-central-1")
# Nova Pro has no in-Region on-demand capacity in eu-central-1, so the fallback is the
# EU cross-Region inference profile (it only routes to EU Regions).
DEFAULT_MODEL_ID = "eu.amazon.nova-pro-v1:0"

app = BedrockAgentCoreApp()

# The "strands" logger has no handler by default; without this one its records never reach
# stdout, and therefore never reach CloudWatch. LOG_LEVEL=DEBUG also logs full prompts and
# responses, which can contain customer data: use it only while troubleshooting.
_LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
if _LOG_LEVEL not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
    _LOG_LEVEL = "INFO"
strands_logger = logging.getLogger("strands")
if not strands_logger.handlers:
    _handler = logging.StreamHandler(sys.stdout)
    _handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    strands_logger.addHandler(_handler)
strands_logger.setLevel(_LOG_LEVEL)


# === Tool Wrappers ===
@tool(name="orders_agent_tool",
      description="A tool for checking order status, placing new bakery orders, "
                  "and answering questions about orders.")
def orders_agent_tool(query: str) -> str:
    """Handle order-related queries."""
    try:
        response = orders_agents.orders_agent(query)
        if isinstance(response, dict) and "text" in response:
            return response["text"]
        return str(response)
    except (ValueError, ConnectionError, KeyError) as e:
        strands_logger.error("orders_agent_tool error: %s", str(e))
        return f"Sorry, I encountered an issue processing your order request: {str(e)}"


@tool(name="menu_agent_tool",
      description="A tool to answer questions about the bakery menu, pastries, breads, and drinks")
def menu_agent_tool(query: str) -> str:
    """Handle menu-related queries."""
    try:
        response = menu_agents.menu_agent(query)
        if isinstance(response, dict) and "text" in response:
            return response["text"]
        return str(response)
    except (ValueError, ConnectionError, KeyError) as e:
        strands_logger.error("menu_agent_tool error: %s", str(e))
        return f"Sorry, I could not retrieve menu information: {str(e)}"


@tool(name="payments_policy_agent_tool",
      description="A tool to answer questions about payment policies, order pricing in Euros (€), "
                  "and transaction support for Specialty Bakeries & Pastry Cafés.")
def payments_policy_agent_tool(query: str) -> str:
    """Handle payment policy and pricing queries."""
    try:
        response = payments_policy_agents.payments_policy_agent(query)
        if isinstance(response, dict) and "text" in response:
            return response["text"]
        return str(response)
    except (ValueError, ConnectionError, KeyError) as e:
        strands_logger.error("payments_policy_agent_tool error: %s", str(e))
        return f"Sorry, I could not retrieve payment information: {str(e)}"


@tool(name="stores_agent_tool",
      description="A tool to answer questions about bakery locations, opening hours, and store policies.")
def stores_agent_tool(query: str) -> str:
    """Handle store-related queries."""
    try:
        response = stores_agents.stores_agent(query)
        if isinstance(response, dict) and "text" in response:
            return response["text"]
        return str(response)
    except (ValueError, ConnectionError, KeyError) as e:
        strands_logger.error("stores_agent_tool error: %s", str(e))
        return f"Sorry, I could not retrieve store information: {str(e)}"


@tool(name="promos_agent_tool",
      description="A tool to answer questions about promotions, Pastry Rewards loyalty programme, "
                  "and seasonal launch offers.")
def promos_agent_tool(query: str) -> str:
    """Handle promotion-related queries."""
    try:
        response = promos_agents.promos_agent(query)
        if isinstance(response, dict) and "text" in response:
            return response["text"]
        return str(response)
    except (ValueError, ConnectionError, KeyError) as e:
        strands_logger.error("promos_agent_tool error: %s", str(e))
        return f"Sorry, I could not retrieve promotions information: {str(e)}"


# === Orchestrator ===
orchestrator_prompt = """
You are the Pastry Concierge for Specialty Bakeries & Pastry Cafés, helping customers
with orders, menu enquiries, promotions, bakery locations, and payment questions.
All prices are in Euros (€).

You respond to queries following these routing guidelines:
- Respond directly to general enquiries that do not require tools
- For domain-specific queries (menu, stores, orders, payments, promotions), use the appropriate tool

Route queries to the appropriate tool:
- Order status, placing orders, order history → orders_agent_tool
- Menu items, ingredients, allergens, seasonal availability → menu_agent_tool
- Item prices and order totals (always in €) → menu_agent_tool (it owns calculate_order_total)
- Payment methods and payment policy → payments_policy_agent_tool
- Bakery locations, opening hours, services → stores_agent_tool
- Promotions, Pastry Rewards, seasonal launch offers → promos_agent_tool

When a new order request is received:
- Use menu_agent_tool to confirm items exist AND check seasonal availability
- Use menu_agent_tool to calculate the total cost in Euros (€)
- Prices are set per category, not per item: tell menu_agent_tool the item type
  (coffee, pastry, bread or cake) and, for coffee, the size
- Display items and total cost BEFORE asking for personal information
- Ask for the customer's name or Pastry Rewards member ID
- Use store_id 'SPBC-STORE-001' as default if not specified
- Use orders_agent_tool to place the order
- Order confirmation MUST include Order ID AND total cost in €

Your responses should:
- Be direct and to the point, 1-2 sentences where possible
- Not mention document IDs, scores, or routing details
- Only use tool-sourced information for domain-specific topics
- Format prices clearly in Euros (€)
- Begin all responses with a newline
- Acknowledge conflicting or missing information
- Never mention internal routing to specialised agents
"""

gr_id = os.getenv("GUARDRAIL_ID")
gr_ver = os.getenv("GUARDRAIL_VERSION")
gr_trc = os.getenv("GUARDRAIL_TRACE")
model_id = os.environ.get("MODEL_ID", DEFAULT_MODEL_ID)

opt = {}
if gr_id and gr_ver:
    opt["guardrail_id"] = gr_id
    opt["guardrail_version"] = gr_ver
    if gr_trc:
        opt["guardrail_trace"] = gr_trc

orchestrator = Agent(
    # Explicit region: Strands otherwise falls back to us-west-2 when AWS_REGION is unset.
    model=BedrockModel(model_id=model_id, region_name=REGION, **opt),
    system_prompt=orchestrator_prompt,
    tools=[
        orders_agent_tool,
        menu_agent_tool,
        payments_policy_agent_tool,
        stores_agent_tool,
        promos_agent_tool,
    ],
)


# === AgentCore entrypoint ===
@app.entrypoint
def pastry_concierge_agent(payload, context):
    """Main entrypoint for the Bedrock AgentCore runtime."""
    user_input = payload.get("prompt") if isinstance(payload, dict) else None
    if not isinstance(user_input, str) or not user_input.strip():
        return 'Please send a JSON payload such as {"prompt": "What pastries are on the menu today?"}'
    os.environ["BYPASS_TOOL_CONSENT"] = "true"

    strands_logger.info("Session ID: %s", context.session_id)

    try:
        response = orchestrator(user_input)
        assistant_text = getattr(response, "text", None) or str(response)
        # DEBUG only: responses can include customer names and order details.
        strands_logger.debug("Response: %s", assistant_text.replace("\n", " "))
        return assistant_text or " "
    except (ValueError, ConnectionError, KeyError) as e:
        strands_logger.error("Orchestrator error: %s\n%s", str(e), traceback.format_exc())
        return "I'm sorry, I encountered an error processing your request. Please try again."


if __name__ == "__main__":
    app.run()

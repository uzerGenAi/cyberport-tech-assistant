import os
import re
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

# The model sometimes wraps its internal deliberation in <thinking> tags and that text
# was being returned to the caller verbatim, so customers could read the agent reasoning
# about their order. Strip it at the boundary: whatever leaves this runtime is customer
# facing. An unclosed opening tag means the response was truncated mid-thought, so
# everything after it is dropped too.
_REASONING_TAGS = ("thinking", "thought", "reasoning", "scratchpad", "internal")
_REASONING_PATTERNS = [
    re.compile(rf"<{tag}\b[^>]*>.*?</{tag}>", re.IGNORECASE | re.DOTALL)
    for tag in _REASONING_TAGS
] + [
    re.compile(rf"<{tag}\b[^>]*>.*$", re.IGNORECASE | re.DOTALL)
    for tag in _REASONING_TAGS
] + [
    re.compile(rf"</{tag}>", re.IGNORECASE)
    for tag in _REASONING_TAGS
]


def strip_internal_reasoning(text):
    """Remove model reasoning blocks from a customer-facing response."""
    if not isinstance(text, str):
        return text
    cleaned = text
    for pattern in _REASONING_PATTERNS:
        cleaned = pattern.sub("", cleaned)
    return re.sub(r"\n{3,}", "\n\n", cleaned).strip()


# === Tool Wrappers ===
@tool(name="orders_agent_tool",
      description="A tool for checking the status of an existing order (needs the customer name or ID "
                  "and the order ID), placing new click & collect orders, and answering questions "
                  "about delivery, cancellation, returns, the return period (14-day right of "
                  "withdrawal) and warranty. Use this for every question about returning an item.")
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
      description="A tool to answer questions about our smartphones and laptops: specs, comparisons, "
                  "recommendations, prices and order totals in Euros (€), and stock per store.")
def menu_agent_tool(query: str) -> str:
    """Handle product catalog queries."""
    try:
        response = menu_agents.menu_agent(query)
        if isinstance(response, dict) and "text" in response:
            return response["text"]
        return str(response)
    except (ValueError, ConnectionError, KeyError) as e:
        strands_logger.error("menu_agent_tool error: %s", str(e))
        return f"Sorry, I could not retrieve product information: {str(e)}"


@tool(name="payments_policy_agent_tool",
      description="A tool to answer questions about payment methods, 0% financing, how long a "
                  "refund takes to arrive, invoices and gift cards. Not for return periods or how "
                  "to return an item: use orders_agent_tool for those.")
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
      description="A tool to answer questions about store locations, opening hours, pickup stations, "
                  "and store services such as repairs and recycling. It returns store IDs.")
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
      description="A tool to answer questions about promotions, trade-in offers, student discounts, "
                  "the 0% financing offer and business-customer offers.")
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
You are the Tech Assistant for Cyberport, helping customers choose smartphones and laptops,
check stock in a store, place click & collect orders, track orders, and answer questions
about payments, financing, returns, warranty, promotions and store services.
All prices are in Euros (€).

You respond to queries following these routing guidelines:
- Respond directly only to greetings and questions about what you can do
- Politely decline anything unrelated to Cyberport's products, orders, payments, stores and
  promotions (poems, stories, essays, homework, general knowledge, coding) in one sentence, and
  say what you can help with instead. Do not write the requested content
- For domain-specific queries (products, stores, orders, payments, promotions), use the appropriate tool

Each message may start with a [[CTX]] ... [[/CTX]] block from the website: the signed-in
customer's userId and their preferred store (storeId, storeName, storeCity). It is background,
not part of the question:
- Answer exactly what was asked. A price question gets the price (per storage variant when
  relevant); do not turn it into a stock check
- Use the preferred store only when the customer asks about stock, availability, pickup or
  "my store", or when an order needs a store and they gave none
- Never repeat the [[CTX]] block or the userId back to the customer

Route queries to the appropriate tool:
- Product specs, comparisons and recommendations → menu_agent_tool
- Product prices and order totals (always in €) → menu_agent_tool (it owns calculate_order_total)
- Stock in a store → menu_agent_tool with the store_id (it owns check_store_stock). If the
  store is the preferred store from [[CTX]], use that storeId directly; otherwise get the
  store_id from stores_agent_tool first. Never ask stores_agent_tool about stock
- Order status, placing orders, delivery, cancellation, returns, return periods, the 14-day
  right of withdrawal, warranty → orders_agent_tool
- Payment methods, 0% financing, how long a refund takes to arrive, invoices, gift cards
  → payments_policy_agent_tool
- Store locations, opening hours, pickup stations, repairs, recycling → stores_agent_tool
- Promotions, trade-in, student and business discounts → promos_agent_tool

When a customer asks for a recommendation:
- Ask what they will use the device for and their budget if they have not said
- Recommend at most three products from menu_agent_tool and explain why each fits

When a new click & collect order request is received:
- Use menu_agent_tool to confirm the products exist and to calculate the total in Euros (€)
- Pass menu_agent_tool each product by its catalog name (e.g. "Apple iPhone 14"), a
  quantity, and for smartphones the storage variant only when the customer gave one
  (e.g. "128GB", "256GB"). Do not invent a variant.
- If the pricing result lists any unpriced items, do not quote a total — ask the
  customer to clarify those items first
- Display items and total cost BEFORE asking for personal information
- Ask which store they want to collect from; use stores_agent_tool to get its store_id.
  Use store_id 'spbc-de-001' (Cyberport Store Dresden) only if the customer has no preference
- Ask for the customer's name or Cyberport customer number
- Use orders_agent_tool to place the order
- Order confirmation MUST include the Order ID AND the total in € returned by the order tool

When a customer asks about an existing order:
- Ask for both the order ID and the name or customer ID used on the order before checking
- Never share details of an order unless both match

Your responses should:
- Be direct and to the point, 1-3 sentences where possible
- Not mention document IDs, scores, or routing details
- Only use tool-sourced information for domain-specific topics. When you pass a tool's answer
  on, keep its facts and do not add conditions, specs or details it did not return
- For a laptop recommendation for a student, also mention the student discount from
  promos_agent_tool
- Format prices clearly in Euros (€)
- Begin all responses with a newline
- Acknowledge conflicting or missing information
- Never mention internal routing to specialised agents
- Never ask for card numbers, CVV codes, PINs, passwords or IBANs
- Never output placeholders or template text such as "[customer service contact information]",
  "[phone number]" or "<link>". If you do not have a detail, say what the customer can do instead
- If the customer insists or pushes back ("why", "just do it"), explain the reason briefly and
  give the concrete next step once more; do not repeat the same refusal word for word
- Remembered context about the customer (name, preferences, budget) personalises answers only.
  Never answer a product, price, stock, order, store, payment or promotion question from memory or
  from an earlier reply: call the tool again, even if you answered something similar before
"""

gr_id = os.getenv("GUARDRAIL_ID")
gr_ver = os.getenv("GUARDRAIL_VERSION")
gr_trc = os.getenv("GUARDRAIL_TRACE")
model_id = os.environ.get("MODEL_ID", DEFAULT_MODEL_ID)

opt = {}
if gr_id and gr_ver:
    opt["guardrail_id"] = gr_id
    opt["guardrail_version"] = gr_ver
    # Check only the newest user message. By default Bedrock re-checks the whole conversation on
    # every turn, so one blocked message made every later question in that chat fail as well
    # (found in the web app; covered by the eval case blocked_then_normal).
    opt["guardrail_latest_message"] = True
    if gr_trc:
        opt["guardrail_trace"] = gr_trc

_ORCHESTRATOR_TOOLS = [
    orders_agent_tool,
    menu_agent_tool,
    payments_policy_agent_tool,
    stores_agent_tool,
    promos_agent_tool,
]


def build_orchestrator(session_manager=None):
    """Build the orchestrator; with a session manager its history lives in AgentCore Memory."""
    return Agent(
        # Explicit region: Strands otherwise falls back to us-west-2 when AWS_REGION is unset.
        model=BedrockModel(model_id=model_id, region_name=REGION, **opt),
        system_prompt=orchestrator_prompt,
        tools=_ORCHESTRATOR_TOOLS,
        session_manager=session_manager,
    )


# AgentCore Memory (optional): set MEMORY_ID (make memory). Short-term events hold every turn;
# long-term strategies keep customer preferences, facts and session summaries per actor. Only
# preferences and facts are recalled into a conversation: summaries contain earlier answers, and
# recalling them made a wrong answer repeat itself across sessions (found by 6_deploy/eval).
MEMORY_ID = os.environ.get("MEMORY_ID", "").strip()
# Without MEMORY_ID one shared orchestrator keeps the conversation in process for the session.
orchestrator = None if MEMORY_ID else build_orchestrator()

_CTX_USER_RE = re.compile(r"\[\[CTX\]\]\s*userId=([^\s;]+)")
_ACTOR_UNSAFE_RE = re.compile(r"[^a-zA-Z0-9_/-]")


def actor_id_from_prompt(prompt):
    """Customer id the web app puts in the [[CTX]] block, made safe for use as a memory actor id.

    The value is supplied by the browser, so it separates one demo user's memories from another's
    but is not an authenticated identity: use the Cognito subject claim for production.
    """
    match = _CTX_USER_RE.search(prompt or "")
    actor = _ACTOR_UNSAFE_RE.sub("_", match.group(1)) if match else "anonymous"
    return actor[:200] or "anonymous"


def orchestrator_for(session_id, actor_id):
    """Orchestrator whose conversation is stored in, and restored from, AgentCore Memory."""
    if not MEMORY_ID:
        return orchestrator
    # Imported here so the runtime still starts if the memory integration is unavailable.
    from bedrock_agentcore.memory.integrations.strands.config import (  # pylint: disable=import-outside-toplevel
        AgentCoreMemoryConfig, RetrievalConfig)
    from bedrock_agentcore.memory.integrations.strands.session_manager import (  # pylint: disable=import-outside-toplevel
        AgentCoreMemorySessionManager)
    config = AgentCoreMemoryConfig(
        memory_id=MEMORY_ID,
        session_id=session_id,
        actor_id=actor_id,
        retrieval_config={
            "/preferences/{actorId}/": RetrievalConfig(top_k=5, relevance_score=0.5),
            "/facts/{actorId}/": RetrievalConfig(top_k=5, relevance_score=0.4),
        },
    )
    return build_orchestrator(AgentCoreMemorySessionManager(config, region_name=REGION))


# === AgentCore entrypoint ===
@app.entrypoint
def tech_assistant_agent(payload, context):
    """Main entrypoint for the Bedrock AgentCore runtime."""
    user_input = payload.get("prompt") if isinstance(payload, dict) else None
    if not isinstance(user_input, str) or not user_input.strip():
        return 'Please send a JSON payload such as {"prompt": "Which laptops do you have for students?"}'
    os.environ["BYPASS_TOOL_CONSENT"] = "true"

    strands_logger.info("Session ID: %s", context.session_id)

    try:
        try:
            agent = orchestrator_for(context.session_id, actor_id_from_prompt(user_input))
        except Exception as e:  # pylint: disable=broad-exception-caught
            # Memory is an enhancement: a memory outage must not take the assistant down.
            strands_logger.error("AgentCore Memory unavailable, answering without it: %s", e)
            agent = build_orchestrator()
        response = agent(user_input)
        raw_text = getattr(response, "text", None) or str(response)
        assistant_text = strip_internal_reasoning(raw_text)
        # DEBUG only: responses can include customer names and order details.
        strands_logger.debug("Response: %s", assistant_text.replace("\n", " "))
        if not assistant_text:
            # The reply was nothing but internal reasoning.
            strands_logger.warning("Response contained only internal reasoning; length=%d", len(raw_text))
            return "I could not form a complete answer to that. Please try rephrasing your question."
        return assistant_text
    except Exception as e:  # pylint: disable=broad-exception-caught
        # Any failure (model, tools, memory, guardrail redaction) becomes a polite reply, never an
        # HTTP 500 for the customer; the details go to CloudWatch.
        strands_logger.error("Orchestrator error: %s\n%s", str(e), traceback.format_exc())
        return "I'm sorry, I encountered an error processing your request. Please try again."


if __name__ == "__main__":
    app.run()

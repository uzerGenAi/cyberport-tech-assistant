"""Pastry supervisor agent for orchestrating Specialty Bakeries & Pastry Cafés orders and queries."""
import logging
import os
import sys
import uuid
from contextlib import nullcontext
from datetime import datetime
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from strands import Agent, tool  # pylint: disable=import-error
from strands.models import BedrockModel  # pylint: disable=import-error
from model_config import REGION, MODEL_ID  # pylint: disable=import-error
import orders_agents  # pylint: disable=import-error
import menu_agents  # pylint: disable=import-error
import payments_agents  # pylint: disable=import-error
import stores_agents  # pylint: disable=import-error
import promos_agents  # pylint: disable=import-error

# pylint: disable=import-error
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.extension.aws.trace import AwsXRayIdGenerator
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.propagators.aws import AwsXRayPropagator
from opentelemetry.propagate import set_global_textmap
from opentelemetry.instrumentation.logging import LoggingInstrumentor

ENABLE_OTEL_TRACING = os.getenv("ENABLE_OTEL_TRACING", "false").lower() == "true"

if ENABLE_OTEL_TRACING:
    tracer_provider = TracerProvider(id_generator=AwsXRayIdGenerator())
    trace.set_tracer_provider(tracer_provider)
    otlp_exporter = OTLPSpanExporter(endpoint="localhost:4317", insecure=True)
    tracer_provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
    set_global_textmap(AwsXRayPropagator())
    LoggingInstrumentor().instrument(set_logging_format=True)
    TRACER = trace.get_tracer(__name__)
else:
    TRACER = None

strands_logger = logging.getLogger("strands")
strands_logger.setLevel(logging.DEBUG)

if ENABLE_OTEL_TRACING:
    LOG_FORMAT = ("%(asctime)s %(levelname)s [%(name)s] "
                  "trace_id=%(otelTraceID)s span_id=%(otelSpanID)s - %(message)s")
else:
    LOG_FORMAT = "%(asctime)s %(levelname)s [%(name)s] - %(message)s"

# LOG_FILE is exported by 4_monitor_and_evaluate/cloudwatchagent/observability.sh; without a
# handler the strands records were never written anywhere.
LOG_FILE = os.environ.get("LOG_FILE", "").strip()
if LOG_FILE and not any(isinstance(h, logging.FileHandler)
                        and h.baseFilename == os.path.abspath(LOG_FILE)
                        for h in strands_logger.handlers):
    os.makedirs(os.path.dirname(LOG_FILE) or ".", exist_ok=True)
    _file_handler = logging.FileHandler(LOG_FILE)
    _file_handler.setFormatter(logging.Formatter(LOG_FORMAT))
    strands_logger.addHandler(_file_handler)

# The CloudWatch agent ships LOG_FILE to this log group (cloudwatch_agentconfig.json); traces
# point at it so X-Ray can show the matching log lines.
LOG_GROUP_NAME = "barista_supervisor-agent-logs"

# === Agent metrics (EMF) ===
# METRICS_FILE is exported by observability.sh; the CloudWatch agent ships it to the
# barista_supervisor-agent-metrics log group. metricsutils lives in CLOUDWATCH_AGENT_UTILS_PATH
# (default: this repo's 4_monitor_and_evaluate/cloudwatchagent).
METRICS_FILE = os.environ.get("METRICS_FILE", "").strip()
METRICS_AGENT_NAME = "spbc-pastry-supervisor-agent"
_metrics_recorder = None
_metrics_disabled = False


def record_turn_metrics(agent_result) -> None:
    """Append this turn's orchestrator metrics to METRICS_FILE (best effort; off when unset)."""
    global _metrics_recorder, _metrics_disabled  # pylint: disable=global-statement
    if not METRICS_FILE or _metrics_disabled:
        return
    try:
        if _metrics_recorder is None:
            utils_path = (os.environ.get("CLOUDWATCH_AGENT_UTILS_PATH", "").strip()
                          or str(Path(__file__).resolve().parents[2]
                                 / "4_monitor_and_evaluate" / "cloudwatchagent"))
            if utils_path not in sys.path:
                sys.path.insert(0, utils_path)
            import metricsutils  # pylint: disable=import-outside-toplevel
            _metrics_recorder = metricsutils.TurnMetricsRecorder(METRICS_AGENT_NAME, METRICS_FILE)
        _metrics_recorder.record(agent_result.metrics.get_summary())
    except ImportError as e:
        _metrics_disabled = True
        strands_logger.warning("Agent metrics disabled: can't import metricsutils "
                               "(check CLOUDWATCH_AGENT_UTILS_PATH): %s", e)
    except Exception as e:  # pylint: disable=broad-except
        strands_logger.warning("Agent metrics not saved to %s: %s", METRICS_FILE, e)

# === DynamoDB Session Management ===
ddb = boto3.resource("dynamodb", region_name=REGION)
session_table = ddb.Table("spbc-sessions-table")


def load_session(session_id: str):
    """Load session messages from DynamoDB; returns None if the table can't be read."""
    try:
        session_response = session_table.get_item(Key={"session_id": session_id})
    except (BotoCoreError, ClientError) as e:
        strands_logger.warning("Session history unavailable (spbc-sessions-table): %s", e)
        return None
    return session_response.get("Item", {}).get("messages", [])


def save_session(session_id: str, messages: list):
    """Save session messages to DynamoDB (best effort: the chat continues without it)."""
    try:
        session_table.put_item(Item={"session_id": session_id, "messages": messages})
    except (BotoCoreError, ClientError) as e:
        strands_logger.warning("Session history not saved (spbc-sessions-table): %s", e)


def filter_messages(messages: list):
    """Filter messages to keep only those with text content."""
    filtered = []
    for msg in messages:
        role = msg.get("role")
        content = msg.get("content", [])
        text_entries = [entry for entry in content
                        if "text" in entry and entry["text"].strip()]
        if text_entries:
            filtered.append({"role": role, "content": text_entries})
    return filtered


def _get_seasonal_greeting():
    """Get the appropriate seasonal greeting based on current date."""
    now = datetime.now()
    month = now.month

    greetings = {
        1: {
            "season": "New Year", "emoji": "🎊✨",
            "message": "Happy New Year! Start your year with our warm Galette des Rois —",
            "specials": [
                "• Galette des Rois (King's Cake with almond frangipane — January only)",
                "• Freshly baked Plain Croissants",
                "• Café Latte to warm the January mornings"
            ]
        },
        2: {
            "season": "Valentine's", "emoji": "💕🥐",
            "message": "Share the love this Valentine's with our delicate",
            "specials": [
                "• Heart-shaped Macaron Box (Assorted Flavours)",
                "• Fresh Fruit Tart with seasonal berries",
                "• Chocolate Éclair — classic and irresistible"
            ]
        },
        3: {
            "season": "Spring", "emoji": "🌸🥐",
            "message": "Spring is here! Celebrate with our freshly baked",
            "specials": [
                "• Hot Cross Buns (March–April seasonal special)",
                "• Lemon Tart — bright and seasonal",
                "• Flat White with oat milk"
            ]
        },
        4: {
            "season": "Easter", "emoji": "🐣🧁",
            "message": "Joyful Easter! Treat yourself to our celebratory",
            "specials": [
                "• Hot Cross Buns (April seasonal — get them while they last!)",
                "• Custom Celebration Cakes (order 3 days in advance)",
                "• Almond Croissant — our Easter favourite"
            ]
        },
        5: {
            "season": "Spring Pastries", "emoji": "🍓🌿",
            "message": "Our summer season begins! Enjoy our fresh",
            "specials": [
                "• Strawberry Mille-Feuille (May–July seasonal special)",
                "• Fresh Fruit Tart with new season fruit",
                "• Iced Matcha Latte"
            ]
        },
        6: {
            "season": "Summer", "emoji": "☀️🍓",
            "message": "Summer is in full swing! Cool down with our light",
            "specials": [
                "• Strawberry Mille-Feuille (June — peak season)",
                "• Lemon Tart — refreshingly tangy",
                "• Iced Café Latte"
            ]
        },
        7: {
            "season": "Summer Harvest", "emoji": "🌻🍋",
            "message": "Last of the summer specials — our final weeks of",
            "specials": [
                "• Strawberry Mille-Feuille (July — last weeks of season)",
                "• Sourdough Loaf — baked fresh every morning",
                "• Cold Filter Coffee"
            ]
        },
        8: {
            "season": "Late Summer", "emoji": "🌾☕",
            "message": "End of summer warmth — treat yourself to our artisan",
            "specials": [
                "• Sourdough Loaf — our most popular bread",
                "• Quiche Lorraine — savoury and satisfying",
                "• Cappuccino — our roaster's favourite blend"
            ]
        },
        9: {
            "season": "Autumn", "emoji": "🍂🎃",
            "message": "Autumn has arrived! Warm up with our seasonal",
            "specials": [
                "• Pumpkin Spice Brioche (September–November seasonal special)",
                "• Black Forest Cake Slice — a German autumn classic",
                "• Hot Chocolate — rich and comforting"
            ]
        },
        10: {
            "season": "Autumn Harvest", "emoji": "🍁🥐",
            "message": "Peak autumn flavours at the bakery — enjoy our cosy",
            "specials": [
                "• Pumpkin Spice Brioche (October — peak season)",
                "• Opéra Cake Slice — indulgent and elegant",
                "• Chai Latte — warming spiced perfection"
            ]
        },
        11: {
            "season": "Winter Begins", "emoji": "❄️🎄",
            "message": "Winter is here and Christmas is coming — discover our festive",
            "specials": [
                "• Christmas Stollen Slice (November–December seasonal special)",
                "• Pumpkin Spice Brioche (November — final weeks)",
                "• Hot Chocolate Deluxe — the ultimate winter warmer"
            ]
        },
        12: {
            "season": "Christmas", "emoji": "🎄⭐",
            "message": "Merry Christmas! Celebrate the season with our festive",
            "specials": [
                "• Christmas Stollen Slice (December — traditional German Christmas bread)",
                "• Custom Celebration Cakes (order 3 days in advance for Christmas)",
                "• Macaron Box (12 pieces) — perfect as a gift",
                "• Galette des Rois (available from late December for New Year)"
            ]
        }
    }
    return greetings.get(month, greetings[12])


def display_seasonal_welcome():
    """Display seasonal welcome message."""
    greeting = _get_seasonal_greeting()
    print("\n" + "=" * 60)
    print(f"{greeting['emoji']} Welcome to Specialty Bakeries & Pastry Cafés! 🥐")
    print("=" * 60)
    print("\nThank you for visiting us today!")
    print(f"\n{greeting['message']} {greeting['season'].lower()} specials!")
    print(f"\n🌟 {greeting['season']} Specials:")
    for special in greeting['specials']:
        print(f"   {special}")
    print("\nWhat can we help you with today? ✨")
    print("=" * 60)


# === Tool Wrappers ===
@tool(
    name="orders_agent_tool",
    description=("A tool for checking order status, placing new orders "
                 "and answering questions about bakery orders."),
)
def orders_agent_tool(query: str) -> str:
    """Handle order-related queries."""
    orders_response = orders_agents.orders_agent(query)
    if isinstance(orders_response, dict) and "text" in orders_response:
        return orders_response["text"]
    return str(orders_response)


@tool(
    name="menu_agent_tool",
    description="A tool to answer questions about the bakery menu, pastries, breads, and drinks",
)
def menu_agent_tool(query: str) -> str:
    """Handle menu-related queries."""
    menu_response = menu_agents.menu_agent(query)
    if isinstance(menu_response, dict) and "text" in menu_response:
        return menu_response["text"]
    return str(menu_response)


@tool(
    name="payments_agent_tool",
    description=("A tool for checking prices, calculating total order cost in Euros (€), "
                 "and answering questions on payment policies"),
)
def payments_agent_tool(query: str) -> str:
    """Handle payment-related queries."""
    payments_response = payments_agents.payments_agent(query)
    if isinstance(payments_response, dict) and "text" in payments_response:
        return payments_response["text"]
    return str(payments_response)


@tool(
    name="stores_agent_tool",
    description="A tool to answer questions about bakery locations, opening hours, and store policies.",
)
def stores_agent_tool(query: str) -> str:
    """Handle store-related queries."""
    stores_response = stores_agents.stores_agent(query)
    if isinstance(stores_response, dict) and "text" in stores_response:
        return stores_response["text"]
    return str(stores_response)


@tool(
    name="promos_agent_tool",
    description=("A tool to answer questions about current promotions, "
                 "Pastry Rewards loyalty programme, and seasonal launch offers"),
)
def promos_agent_tool(query: str) -> str:
    """Handle promotion-related queries."""
    promos_response = promos_agents.promos_agent(query)
    if isinstance(promos_response, dict) and "text" in promos_response:
        return promos_response["text"]
    return str(promos_response)


# === Orchestrator ===
def get_orchestrator_prompt():
    """Return the orchestrator system prompt."""
    return (
        "You are the Pastry Concierge for Specialty Bakeries & Pastry Cafés, helping customers "
        "with orders, menu enquiries, promotions, bakery locations, and payment questions. "
        "All prices are in Euros (€).\n\n"
        "CRITICAL RULE: For ANY order request, you MUST first use the menu_agent_tool to "
        "verify items exist on the menu AND check seasonal availability before proceeding. "
        "Never assume items are available. Seasonal pastries are only available during specific months.\n\n"
        "You respond to queries following these routing guidelines:\n"
        "- Respond directly to general enquiries that do not require tools or specialised knowledge\n"
        "- For domain-specific queries (menu, stores, orders, payments, promotions), use the most "
        "appropriate tool (specialised agent)\n"
        "- If a query spans multiple domains, prioritise the most relevant tool first\n\n"
        "Route queries to the appropriate tool:\n"
        "- Order status, placing orders, order history → orders_agent_tool\n"
        "- Menu items, ingredients, allergens, availability → menu_agent_tool\n"
        "- Pricing, order totals (always in €), payment methods → payments_agent_tool\n"
        "- Bakery locations, opening hours, services, catering → stores_agent_tool\n"
        "- Promotions, Pastry Rewards, seasonal launch offers → promos_agent_tool\n\n"
        "When a new order request is received:\n"
        "- Use menu_agent_tool to confirm items exist AND check seasonal availability\n"
        "- If any item is not available or out of season, suggest valid alternatives\n"
        "- Use payments_agent_tool to calculate the total cost in Euros (€)\n"
        "- CRITICAL: Clearly display the items and total cost BEFORE asking for personal information\n"
        "- Ask: 'Please provide your name or Pastry Rewards member ID to complete the order.'\n"
        "- Use store_id 'SPBC-STORE-001' as default if not specified\n"
        "- For user_id, use the customer's name and timestamp (e.g., 'anna_1234567890')\n"
        "- Use orders_agent_tool with a message like "
        "'Place order for [customer_name]: [items] — Total: €[amount]'\n"
        "- CRITICAL: Order confirmation MUST include Order ID AND total cost in €\n\n"
        "MANDATORY TOOL INVOCATION FORMAT:\n"
        "Tool #X: [tool_name]\n"
        "<thinking> [Your reasoning] </thinking>\n"
        "Tool #Y: [specific_function_name]\n"
        "<answer> [The tool's response] </answer>\n\n"
        "Response guidelines:\n"
        "- Be direct, brief — 1-2 sentences where possible\n"
        "- Do not mention document IDs, scores, or routing details\n"
        "- Only use tool-sourced information for domain-specific topics\n"
        "- Begin all responses with \\n\n"
        "- Acknowledge conflicting or missing information\n"
        "- Format prices clearly in Euros (€)\n"
        "- Present bakery locations with full address and opening hours\n"
        "- Highlight promotion savings and conditions clearly"
    )


orchestrator = Agent(
    # EU inference profile: the foundation-model ARN can't be invoked on-demand in eu-central-1
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt=get_orchestrator_prompt(),
    tools=[
        orders_agent_tool,
        menu_agent_tool,
        payments_agent_tool,
        stores_agent_tool,
        promos_agent_tool,
    ],
)

# CLI entrypoint
if __name__ == "__main__":
    SESSION_ID = str(uuid.uuid4())
    print(f"Session started: {SESSION_ID}")
    os.environ["BYPASS_TOOL_CONSENT"] = "true"

    display_seasonal_welcome()

    try:
        while True:
            prompt = input("\n\nYou: ")
            if prompt.strip() == "":
                print("Waiting for input... type exit to close session.")
                continue
            if prompt.lower() in ["exit", "quit"]:
                print("\nThank you for visiting Specialty Bakeries & Pastry Cafés. "
                      "See you next time! 🥐")
                break

            span_cm = (
                TRACER.start_as_current_span("user_prompt")
                if TRACER else nullcontext()
            )
            with span_cm as span:
                if span:
                    span.set_attribute("aws.log.group.names", LOG_GROUP_NAME)

                prior_messages = load_session(SESSION_ID)
                if prior_messages is not None:  # keep in-memory history if DynamoDB is unavailable
                    orchestrator.messages = prior_messages

                try:
                    agent_response = orchestrator(prompt)
                    RESPONSE_FORMATTED = str(agent_response).replace("\n", " ")
                    strands_logger.info("Response: %s", RESPONSE_FORMATTED)
                    record_turn_metrics(agent_response)
                    save_session(SESSION_ID, filter_messages(orchestrator.messages))
                except (ValueError, ConnectionError, KeyError) as e:
                    ERROR_MESSAGE = str(e)
                    if ("guardrail" in ERROR_MESSAGE.lower() or
                            "blocked" in ERROR_MESSAGE.lower()):
                        print(
                            "Assistant: I'm sorry, but I cannot respond to that request "
                            "due to content policies. Please try rephrasing your question."
                        )
                        strands_logger.warning("Guardrail blocked content: %s", prompt)
                    else:
                        print(
                            "Assistant: I'm sorry, I encountered an error processing your "
                            "request. Please try again."
                        )
                        strands_logger.error("Error processing request: %s", ERROR_MESSAGE)
                    continue

                for message in reversed(filter_messages(orchestrator.messages)):
                    if message["role"] == "assistant":
                        print("Assistant:", message["content"][-1]["text"])
                        strands_logger.info(
                            "Assistant response: %s",
                            message["content"][-1]["text"]
                        )
                        break

    except KeyboardInterrupt:
        print("\nThank you for visiting Specialty Bakeries & Pastry Cafés. Goodbye! 🥐")

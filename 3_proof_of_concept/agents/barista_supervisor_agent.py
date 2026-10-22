"""Barista supervisor agent for orchestrating restaurant orders and queries."""
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
import orders_agents
import menu_agents
import payments_agents
import stores_agents
import promos_agents

# pylint: disable=import-error
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.extension.aws.trace import AwsXRayIdGenerator
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.propagators.aws import AwsXRayPropagator
from opentelemetry.propagate import set_global_textmap
from opentelemetry.instrumentation.logging import LoggingInstrumentor

# Get the Toggle value
ENABLE_OTEL_TRACING = os.getenv("ENABLE_OTEL_TRACING", "false").lower() == "true"

if ENABLE_OTEL_TRACING:
    # Initialize the tracing provider to use X-ray style TraceID
    tracer_provider = TracerProvider(id_generator=AwsXRayIdGenerator())
    trace.set_tracer_provider(tracer_provider)

    # Connect to the OTLP Exporter which is Cloudwatch agent and it sends to X-ray
    otlp_exporter = OTLPSpanExporter(endpoint="localhost:4317", insecure=True)

    # Send log spans in batches
    tracer_provider.add_span_processor(BatchSpanProcessor(otlp_exporter))

    # Setup X-Ray Context Propagation
    set_global_textmap(AwsXRayPropagator())
    LoggingInstrumentor().instrument(set_logging_format=True)

    # Tracer instance
    TRACER = trace.get_tracer(__name__)
else:
    TRACER = None

# Configure the strands logger
strands_logger = logging.getLogger("strands")
strands_logger.setLevel(logging.DEBUG)

# Create a file handler with proper formatting
if ENABLE_OTEL_TRACING:
    LOG_FORMAT = ("%(asctime)s %(levelname)s [%(name)s] "
                  "trace_id=%(otelTraceID)s span_id=%(otelSpanID)s - %(message)s")
else:
    LOG_FORMAT = "%(asctime)s %(levelname)s [%(name)s] - %(message)s"

# LOG_FILE is exported by 4_monitor_and_evaluate/cloudwatchagent/observability.sh; the CloudWatch
# agent ships that file to the barista_supervisor-agent-logs log group.
LOG_FILE = os.environ.get("LOG_FILE", "").strip()
if LOG_FILE and not any(isinstance(h, logging.FileHandler)
                        and h.baseFilename == os.path.abspath(LOG_FILE)
                        for h in strands_logger.handlers):
    os.makedirs(os.path.dirname(LOG_FILE) or ".", exist_ok=True)
    _file_handler = logging.FileHandler(LOG_FILE)
    _file_handler.setFormatter(logging.Formatter(LOG_FORMAT))
    strands_logger.addHandler(_file_handler)

# === Agent metrics (EMF) ===
# METRICS_FILE is exported by observability.sh; the CloudWatch agent ships it to the
# barista_supervisor-agent-metrics log group. metricsutils lives in CLOUDWATCH_AGENT_UTILS_PATH
# (default: this repo's 4_monitor_and_evaluate/cloudwatchagent).
METRICS_FILE = os.environ.get("METRICS_FILE", "").strip()
METRICS_AGENT_NAME = "barista_supervisor-agent"
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

def _get_reinvent_greeting():
    """Get re:Invent specific greeting."""
    return {
        "season": "re:Invent 2025",
        "emoji": (
            "╔════════════════════════════╗\n"
            "║  🚀 AWS re:Invent 2025 🚀  ║\n"
            "║  Be part of tech history   ║\n"
            "╚════════════════════════════╝"
        ),
        "message": (
            "Welcome AWS re:Invent attendees! ☕ You're taking part in tech history "
            "while building the skills you need to stay ahead. Every re:Invent marks a "
            "milestone of innovation. Thank you for joining us in Las Vegas as cloud "
            "pioneers gather from across the globe for the latest AWS innovations, "
            "peer-to-peer learning, expert-led discussions, and invaluable networking "
            "opportunities."
        ),
        "specials": [
            "• Cloud Pioneer Latte (Energizing blend for innovators)",
            "• Serverless Espresso (Quick and scalable)",
            "• Machine Learning Mocha (Smart and sweet)",
            "• DevOps Dark Roast (Continuous delivery of caffeine)",
            "• Lambda Cold Brew (Event-driven refreshment)"
        ]
    }


def _get_monthly_greeting(month):
    """Get greeting based on month."""
    greetings = {
        1: {
            "season": "New Year", "emoji": "🎊✨",
            "message": "Happy New Year! Start your year right with our energizing",
            "specials": [
                "• Resolution Roast (Bold coffee to fuel your goals)",
                "• Fresh Start Smoothie", "• Detox Green Tea Latte"
            ]
        },
        2: {
            "season": "Valentine's", "emoji": "💕☕",
            "message": "Love is in the air! Share the love with our romantic",
            "specials": [
                "• Sweetheart Mocha (Rich chocolate with a hint of strawberry)",
                "• Cupid's Arrow Espresso",
                "• Love Potion Latte (Pink-tinted with vanilla and rose)"
            ]
        },
        3: {
            "season": "Spring", "emoji": "🍀🌸",
            "message": "Spring has sprung! Celebrate with our fresh and lucky",
            "specials": [
                "• Lucky Charm Latte (Green-tinted with mint)",
                "• Spring Blossom Tea", "• Irish Cream Coffee"
            ]
        },
        4: {
            "season": "Easter", "emoji": "🐰🌷",
            "message": "Hop into spring with our delightful Easter",
            "specials": [
                "• Bunny Hop Mocha (White chocolate with caramel)",
                "• Easter Egg Latte (Colorful layered drink)",
                "• Spring Garden Tea"
            ]
        },
        5: {
            "season": "Mother's Day", "emoji": "🌺👩",
            "message": "Celebrate Mom with our nurturing and floral",
            "specials": [
                "• Mother's Love Latte (Lavender and honey)",
                "• Garden Party Tea", "• Mama's Favorite Mocha"
            ]
        },
        6: {
            "season": "Summer", "emoji": "☀️🏖️",
            "message": "Summer vibes are here! Cool down with our refreshing",
            "specials": [
                "• Dad's Strong Brew (Extra bold for Father's Day)",
                "• Summer Breeze Iced Coffee", "• Tropical Paradise Smoothie"
            ]
        },
        7: {
            "season": "Independence Day", "emoji": "🇺🇸🎆",
            "message": "Celebrate America with our patriotic and refreshing",
            "specials": [
                "• Red, White & Brew (Layered patriotic drink)",
                "• Freedom Frappé", "• Star-Spangled Smoothie"
            ]
        },
        8: {
            "season": "Back to School", "emoji": "📚☀️",
            "message": "Back to school season! Fuel your studies with our energizing",
            "specials": [
                "• Study Buddy Espresso", "• Brain Boost Smoothie",
                "• Teacher's Pet Latte"
            ]
        },
        9: {
            "season": "Fall", "emoji": "🍂🍁",
            "message": "Fall is in the air! Cozy up with our warm autumn",
            "specials": [
                "• Pumpkin Spice Latte", "• Apple Cinnamon Coffee",
                "• Maple Pecan Latte", "• Caramel Apple Cider"
            ]
        },
        10: {
            "season": "Halloween", "emoji": "🎃👻",
            "message": (
                "With the crisp fall air rolling in, we've just rolled out our spooky "
                "and haunted potions to get you in the Halloween spirit!"
            ),
            "specials": [
                "• Pumpkin Spice Latte",
                "• Witch's Brew (Dark Roast with mysterious spices)",
                "• Ghostly White Mocha", "• Vampire's Blood (Red Velvet Latte)"
            ]
        },
        11: {
            "season": "Thanksgiving", "emoji": "🦃🍁",
            "message": "Give thanks for great coffee! Warm up with our cozy autumn",
            "specials": [
                "• Grateful Pumpkin Latte", "• Turkey Day Spice Coffee",
                "• Cranberry Orange Scone with Coffee", "• Thankful Chai Latte"
            ]
        }
    }
    return greetings.get(month, {
        "season": "Christmas", "emoji": "🎄❄️",
        "message": "The most wonderful time of the year! Warm your heart with our festive",
        "specials": [
            "• Peppermint Mocha", "• Gingerbread Latte",
            "• Eggnog Cappuccino", "• Hot Chocolate with Marshmallows"
        ]
    })


def get_seasonal_greeting():
    """Generate seasonal greeting based on current date."""
    now = datetime.now()
    month = now.month
    day = now.day
    year = now.year

    # Secret test mode for re:Invent greeting
    if os.environ.get("REINVENT_TEST_MODE", "").lower() == "true":
        return _get_reinvent_greeting()

    # Special re:Invent 2025 greeting (December 1-5, 2025)
    if year == 2025 and month == 12 and 1 <= day <= 5:
        return _get_reinvent_greeting()

    return _get_monthly_greeting(month)


def should_show_reinvent_message():
    """Check if we should show re:Invent closing message."""
    now = datetime.now()
    month = now.month
    day = now.day
    year = now.year

    # Secret test mode for re:Invent messaging
    if os.environ.get("REINVENT_TEST_MODE", "").lower() == "true":
        return True

    # Special re:Invent 2025 messaging (December 1-5, 2025)
    if year == 2025 and month == 12 and 1 <= day <= 5:
        return True

    return False


def get_reinvent_closing_message():
    """Get re:Invent closing message for completed orders/interactions."""
    return (
        "\n╔════════════════════════════╗\n"
        "║  🚀 AWS re:Invent 2025 🚀  ║\n"
        "║  Be part of tech history   ║\n"
        "╚════════════════════════════╝\n"
        "Thanks for trying this lab at AWS re:Invent 2025! "
        "Don't forget to explore other self-paced labs and catch a Spotlight Lab "
        "if you get the opportunity. Keep building amazing things with AWS!"
    )

def display_seasonal_welcome():
    """Display seasonal welcome message."""
    greeting = get_seasonal_greeting()

    print("\n" + "="*60)

    # Special handling for re:Invent ASCII art
    if greeting['season'] == "re:Invent 2025":
        print(f"{greeting['emoji']}")
        print("\nWelcome to AnyCompany Coffee Shop! ☕")
    else:
        print(f"{greeting['emoji']} Welcome to AnyCompany Coffee Shop! ☕")

    print("="*60)
    print("\nThank you for visiting AnyCompany Coffee Shop today! 😊")
    print(f"\n{greeting['message']}")
    print(f"{greeting['season'].lower()} specials!")
    print(f"\n🌟 {greeting['season']} Specials:")
    for special in greeting['specials']:
        print(f"   {special}")
    print("\nWhat can we get started for you today? ✨")
    print("="*60)


# === Tool Wrappers ===
@tool(
    name="orders_agent_tool",
    description=("A tool for checking order status, placing new orders "
                "and answering questions about orders."),
)
def orders_agent_tool(query: str) -> str:
    """Handle order-related queries."""
    orders_response = orders_agents.orders_agent(query)
    if isinstance(orders_response, dict) and "text" in orders_response:
        return orders_response["text"]
    return str(orders_response)


@tool(
    name="menu_agent_tool",
    description="A tool to answer questions about restaurant menus",
)
def menu_agent_tool(query: str) -> str:
    """Handle menu-related queries."""
    menu_response = menu_agents.menu_agent(query)
    if isinstance(menu_response, dict) and "text" in menu_response:
        return menu_response["text"]
    return str(menu_response)


@tool(
    name="payments_agent_tool",
    description=("A tool for checking price of an item, calculating total cost "
                "of order and answering any questions on payments policies"),
)
def payments_agent_tool(query: str) -> str:
    """Handle payment-related queries."""
    payments_response = payments_agents.payments_agent(query)
    if isinstance(payments_response, dict) and "text" in payments_response:
        return payments_response["text"]
    return str(payments_response)


@tool(
    name="stores_agent_tool",
    description="A tool to answer questions about restaurant stores and store policies.",
)
def stores_agent_tool(query: str) -> str:
    """Handle store-related queries."""
    stores_response = stores_agents.stores_agent(query)
    if isinstance(stores_response, dict) and "text" in stores_response:
        return stores_response["text"]
    return str(stores_response)


@tool(
    name="promos_agent_tool",
    description=("A tool to answer questions about current deals "
                "and discounts available as promotions"),
)
def promos_agent_tool(query: str) -> str:
    """Handle promotion-related queries."""
    promos_response = promos_agents.promos_agent(query)
    if isinstance(promos_response, dict) and "text" in promos_response:
        return promos_response["text"]
    return str(promos_response)


# === Orchestrator ===
def get_orchestrator_prompt():
    """Get orchestrator prompt with optional re:Invent messaging."""
    base_prompt = (
        "You are the Orchestrator Assistant for AnyCompany Coffee Shop who helps customers "
        "place drink and food orders. You can also answer queries about store locations, "
        "menu items, prices, promotions and prior orders.\n\n"
        "CRITICAL RULE: For ANY order request, you MUST first use the menu_agent_tool to "
        "verify items exist on the menu AND check seasonal availability before proceeding. "
        "Never assume items are available. Seasonal items are only available during specific "
        "months.\n\n"
        "You respond to queries following these routing guidelines:\n"
        "- Respond directly to general inquiries that do not require use of tools or "
        "specialized knowledge\n"
        "- For domain-specific (menu, stores, orders, payments or promotions) queries, use "
        "the most appropriate tool (specialized agent)\n"
        "- If a query spans multiple domains, prioritize using the most relevant tool first, "
        "and use additional tools after that only if required\n\n"
        "Direct user queries to the appropriate tool (specialized agent):\n"
        "- For order-related queries (order status, history, modifications): use the "
        "orders_agent_tool\n"
        "- For menu-related queries (item availability, ingredients, allergens): use the "
        "menu_agent_tool\n"
        "- For payment-related queries (pricing, cost calculation, payment methods): use the "
        "payments_agent_tool\n"
        "- For store-related queries (locations, hours, amenities, drive-thru availability): "
        "use the stores_agent_tool\n"
        "- For promotion-related queries (deals, discounts, special offers, loyalty programs): "
        "use the promos_agent_tool\n\n"
        "When a new order request is received:\n"
        "- Only if you have not checked already, use the menu_agent_tool to confirm that all "
        "requested items exist on the menu AND check if seasonal items are currently "
        "available. If any item is invalid or seasonal items are out of season, suggest valid "
        "alternatives from the menu or inform when seasonal items will return.\n"
        "- Then Use the payments_agent_tool to calculate the total cost of the order.\n"
        "- CRITICAL: You MUST immediately inform the customer about the exact items "
        "being ordered and the total cost. Display this information clearly before "
        "asking for any personal information.\n"
        "- After showing the total cost, ALWAYS ask: 'Please provide your name or "
        "rewards member ID to complete the order.'\n"
        "- Wait for the customer to provide their name or ID before proceeding.\n"
        "- If store ID is missing, use \"STORE001\" as default store ID.\n"
        "- For user ID, create a unique identifier using the customer's name and "
        "timestamp (e.g., \"marcus_1234567890\") or use a random number if no name is "
        "provided.\n"
        "- CRITICAL: Before placing the order, you MUST ask the customer for their "
        "name or rewards member ID if not already provided. Do not proceed with order "
        "placement until you have this information.\n"
        "- Finally, use the orders_agent_tool with a simple message like \"Place order "
        "for [customer_name]: [items] - Total: $[amount]\".\n"
        "- CRITICAL: When displaying the final order confirmation, you MUST include "
        "both the Order ID AND the total cost. Always say something like: 'Your order "
        "[Order ID] for $[total cost] is confirmed. Please listen for your name to be "
        "called.'\n"
        "- The orders agent will handle the technical details and provide the complete "
        "order confirmation message.\n\n"
        "MANDATORY TOOL INVOCATION FORMAT - NEVER DEVIATE FROM THIS:\n"
        "EVERY SINGLE TIME you use ANY tool, you MUST use this EXACT format:\n\n"
        "Tool #X: [tool_name]\n"
        "<thinking> [Your reasoning for using this tool] </thinking>\n"
        "Tool #Y: [specific_function_name]\n"
        "<answer> [The tool's response] </answer>\n\n"
        "CRITICAL RULES:\n"
        "- ALWAYS start with 'Tool #X:' where X is the sequential number\n"
        "- ALWAYS include <thinking> tags before calling the function\n"
        "- ALWAYS include <answer> tags after the tool responds\n"
        "- NEVER skip this format, even for simple queries\n"
        "- Number tools sequentially throughout the entire conversation "
        "(Tool #1, Tool #2, Tool #3, etc.)\n"
        "- This format is REQUIRED for debugging and troubleshooting\n\n"
        "Your responses should:\n"
        "- Be direct and to the point\n"
        "- Not mention the source of information (like document IDs or scores)\n"
        "- Not include any metadata or technical details\n"
        "- Be conversational but brief, respond with only 1-2 sentences if possible, "
        "except for order confirmations which should include the full message from the "
        "orders agent.\n"
        "- For domain-specific topics, only answer using information obtained using available "
        "tools. Do not use your own information.\n"
        "- MANDATORY: Use the structured tool invocation format for EVERY tool call "
        "without exception.\n"
        "- Remember: Tool #X: [name] → <thinking> → Tool #Y: [function] → "
        "<answer> → response\n"
        "- Acknowledge when information is conflicting or missing\n"
        "- Begin all responses with \\n\n"
        "- Never apologize for using a tool or mention that you are routing to a specialized "
        "agent\n"
        "- Present store locations and hours clearly and accurately when requested\n"
        "- Format promotional offers in a way that highlights savings and conditions\n"
        "- If store ID is missing, use random number as default store ID.\n"
        "- If user ID is missing, use random number for user ID."
    )

    # No special re:Invent instructions needed in prompt anymore
    # Re:Invent messaging now only appears on session termination
    return base_prompt

# Shared orchestrator instance (for import use). Nova Pro is called through the EU inference
# profile: the foundation-model ARN can't be invoked on-demand in eu-central-1.
orchestrator = Agent(
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

    # Display seasonal welcome message
    display_seasonal_welcome()

    try:
        while True:
            prompt = input("\n\nYou: ")
            if prompt.strip() == "":
                print("Waiting for input... type exit to close session.")
                continue
            if prompt.lower() in ["exit", "quit"]:
                # Check if it's re:Invent week for special closing message
                if should_show_reinvent_message():
                    print(get_reinvent_closing_message())
                else:
                    print("\nSession ended.")
                break

            # Secret commands for testing
            if prompt.lower() == "test reinvent":
                os.environ["REINVENT_TEST_MODE"] = "true"
                # Update orchestrator with new prompt
                orchestrator.system_prompt = get_orchestrator_prompt()
                print(
                    "\n🚀 re:Invent test mode activated! Displaying re:Invent greeting..."
                )
                display_seasonal_welcome()
                continue
            if prompt.lower() == "normal mode":
                os.environ.pop("REINVENT_TEST_MODE", None)
                # Update orchestrator with new prompt
                orchestrator.system_prompt = get_orchestrator_prompt()
                print("\n✨ Normal seasonal mode restored!")
                display_seasonal_welcome()
                continue

            # Co-relating the trace with the log group and each prompt is treated as single trace
            span_cm = (
                TRACER.start_as_current_span("user_prompt")
                if TRACER else nullcontext()
            )
            with span_cm as span:
                if span:
                    span.set_attribute(
                        "aws.log.group.names",
                        "barista_supervisor-agent-logs"
                    )

                prior_messages = load_session(SESSION_ID)
                if prior_messages is not None:  # keep in-memory history if DynamoDB is unavailable
                    orchestrator.messages = prior_messages

                try:
                    agent_response = orchestrator(prompt)
                    # Log the entire response as a single entry
                    RESPONSE_FORMATTED = str(agent_response).replace("\n", " ")
                    strands_logger.info("Response: %s", RESPONSE_FORMATTED)
                    record_turn_metrics(agent_response)
                    save_session(SESSION_ID, filter_messages(orchestrator.messages))
                except (ValueError, ConnectionError, KeyError) as e:
                    ERROR_MESSAGE = str(e)
                    if ("guardrail" in ERROR_MESSAGE.lower() or 
                            "blocked" in ERROR_MESSAGE.lower()):
                        print(
                            "Assistant: I'm sorry, but I can't provide a response to that "
                            "request due to content policies. Please try rephrasing your "
                            "question or ask about something else I can help you with."
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
        # Check if it's re:Invent week for special closing message
        if should_show_reinvent_message():
            print(get_reinvent_closing_message())
        print("\nSession ended.")

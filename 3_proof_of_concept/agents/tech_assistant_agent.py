"""Tech Assistant orchestrator (PoC CLI) for the Cyberport Tech Assistant.

Routes each question to the product, orders, payments, stores and promotions agents. Optional
OpenTelemetry tracing (ENABLE_OTEL_TRACING=true), a log file and EMF metrics for phase 4
(4_monitor_and_evaluate), and session history in spbc-sessions-table.
"""
import logging
import os
import sys
import uuid
from contextlib import nullcontext
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
# agent ships that file to the tech_assistant-agent-logs log group.
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
# tech_assistant-agent-metrics log group. metricsutils lives in CLOUDWATCH_AGENT_UTILS_PATH
# (default: this repo's 4_monitor_and_evaluate/cloudwatchagent).
METRICS_FILE = os.environ.get("METRICS_FILE", "").strip()
METRICS_AGENT_NAME = "tech_assistant-agent"
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

# === Tool Wrappers ===
@tool(
    name="orders_agent_tool",
    description=("A tool for checking the status of an existing order (needs the customer "
                "name or ID and the order ID), placing click & collect orders, and answering "
                "questions about delivery, returns and warranty."),
)
def orders_agent_tool(query: str) -> str:
    """Handle order-related queries."""
    orders_response = orders_agents.orders_agent(query)
    if isinstance(orders_response, dict) and "text" in orders_response:
        return orders_response["text"]
    return str(orders_response)


@tool(
    name="menu_agent_tool",
    description=("A tool to answer questions about our smartphones and laptops: specs, "
                "comparisons, recommendations and stock per store."),
)
def menu_agent_tool(query: str) -> str:
    """Handle product catalog queries."""
    menu_response = menu_agents.menu_agent(query)
    if isinstance(menu_response, dict) and "text" in menu_response:
        return menu_response["text"]
    return str(menu_response)


@tool(
    name="payments_agent_tool",
    description=("A tool for checking the price of a product, calculating the total cost "
                "of an order in € and answering questions on payments, financing and refunds"),
)
def payments_agent_tool(query: str) -> str:
    """Handle payment-related queries."""
    payments_response = payments_agents.payments_agent(query)
    if isinstance(payments_response, dict) and "text" in payments_response:
        return payments_response["text"]
    return str(payments_response)


@tool(
    name="stores_agent_tool",
    description=("A tool to answer questions about store locations, opening hours, pickup "
                "stations and store services. It returns store IDs."),
)
def stores_agent_tool(query: str) -> str:
    """Handle store-related queries."""
    stores_response = stores_agents.stores_agent(query)
    if isinstance(stores_response, dict) and "text" in stores_response:
        return stores_response["text"]
    return str(stores_response)


@tool(
    name="promos_agent_tool",
    description=("A tool to answer questions about current deals, trade-in offers, "
                "student and business discounts and the 0% financing offer"),
)
def promos_agent_tool(query: str) -> str:
    """Handle promotion-related queries."""
    promos_response = promos_agents.promos_agent(query)
    if isinstance(promos_response, dict) and "text" in promos_response:
        return promos_response["text"]
    return str(promos_response)


# === Orchestrator ===
ORCHESTRATOR_PROMPT = (
    "You are the Tech Assistant for Cyberport, helping customers choose smartphones and "
    "laptops, check stock in a store, place click & collect orders, track orders, and answer "
    "questions about payments, financing, returns, warranty, promotions and store services. "
    "All prices are in Euros (€).\n\n"
    "You respond to queries following these routing guidelines:\n"
    "- Respond directly to general inquiries that do not require use of tools\n"
    "- For domain-specific (products, stores, orders, payments or promotions) queries, use "
    "the most appropriate tool (specialized agent)\n"
    "- If a query spans multiple domains, use the most relevant tool first, and use "
    "additional tools after that only if required\n\n"
    "Direct user queries to the appropriate tool (specialized agent):\n"
    "- Product specs, comparisons, recommendations: menu_agent_tool\n"
    "- Stock in a store: stores_agent_tool to find the store_id, then menu_agent_tool with it\n"
    "- Prices and order totals: payments_agent_tool\n"
    "- Payment methods, financing, refunds, invoices: payments_agent_tool\n"
    "- Order status, placing orders, delivery, returns, warranty: orders_agent_tool\n"
    "- Store locations, hours, pickup stations, repairs, recycling: stores_agent_tool\n"
    "- Deals, trade-in, student and business discounts: promos_agent_tool\n\n"
    "When a customer asks for a recommendation, ask what they will use the device for and "
    "their budget if they have not said, then recommend at most three products.\n\n"
    "When a new click & collect order request is received:\n"
    "- Use menu_agent_tool to confirm the products exist.\n"
    "- Use payments_agent_tool to calculate the total cost. Pass each product by its catalog "
    "name, a quantity and, for smartphones, the storage variant only when the customer gave "
    "one. If any item is unpriced, ask the customer to clarify before quoting a total.\n"
    "- Show the items and the total cost BEFORE asking for any personal information.\n"
    "- Ask which store they want to collect from and get its store_id from stores_agent_tool. "
    "Use 'spbc-de-001' only if the customer has no preference.\n"
    "- Ask for the customer's name or Cyberport customer number.\n"
    "- Use orders_agent_tool to place the order. The confirmation MUST include the Order ID "
    "and the total in € returned by the orders agent.\n\n"
    "When a customer asks about an existing order, ask for both the order ID and the name or "
    "customer ID used on the order. Never share an order unless both match.\n\n"
    "Your responses should:\n"
    "- Be direct and to the point, 1-3 sentences where possible\n"
    "- Not mention the source of information (like document IDs or scores)\n"
    "- For domain-specific topics, only answer using information obtained from tools\n"
    "- Acknowledge when information is conflicting or missing\n"
    "- Begin all responses with \\n\n"
    "- Never mention that you are routing to a specialized agent\n"
    "- Never ask for card numbers, CVV codes, PINs, passwords or IBANs"
)

# Shared orchestrator instance (for import use). Nova Pro is called through the EU inference
# profile: the foundation-model ARN can't be invoked on-demand in eu-central-1.
orchestrator = Agent(
    model=BedrockModel(model_id=MODEL_ID, region_name=REGION),
    system_prompt=ORCHESTRATOR_PROMPT,
    tools=[
        orders_agent_tool,
        menu_agent_tool,
        payments_agent_tool,
        stores_agent_tool,
        promos_agent_tool,
    ],
)


def display_welcome():
    """Print the CLI welcome message."""
    print("=" * 60)
    print("📱 Welcome to the Cyberport Tech Assistant (PoC)")
    print("Ask about smartphones and laptops, store stock, click & collect orders,")
    print("order status, payments and financing, or current promotions.")
    print("Type 'exit' to end the session.")
    print("=" * 60)


# CLI entrypoint
if __name__ == "__main__":
    SESSION_ID = str(uuid.uuid4())
    print(f"Session started: {SESSION_ID}")
    os.environ["BYPASS_TOOL_CONSENT"] = "true"

    display_welcome()

    try:
        while True:
            prompt = input("\n\nYou: ")
            if prompt.strip() == "":
                print("Waiting for input... type exit to close session.")
                continue
            if prompt.lower() in ["exit", "quit"]:
                print("\nSession ended.")
                break

            # Co-relating the trace with the log group and each prompt is treated as single trace
            span_cm = (
                TRACER.start_as_current_span("user_prompt")
                if TRACER else nullcontext()
            )
            with span_cm as span:
                if span:
                    span.set_attribute(
                        "aws.log.group.names",
                        "tech_assistant-agent-logs"
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
        print("\nSession ended.")

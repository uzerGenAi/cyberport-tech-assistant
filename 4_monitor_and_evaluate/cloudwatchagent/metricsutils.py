import os
import sys
import uuid
import boto3
import time
import json

# The CloudWatch agent ships METRICS_FILE to this log group (cloudwatch_agentconfig.json)
METRICS_LOG_GROUP = "tech_assistant-agent-metrics"
DEFAULT_AGENT_NAME = "tech_assistant-agent"


def extract_metrics(metrics_summary, agent_name=DEFAULT_AGENT_NAME):
    """
    Extract key metrics from the agent's metrics summary and format them as EMF.
    
    Args:
        metrics_summary (dict): The metrics summary from agent.metrics.get_summary()
        agent_name (str): Value of the AgentName dimension
        
    Returns:
        dict: EMF-formatted metrics
    """
    # Extract the requested metrics
    emf_metrics = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),  # Current time in milliseconds
            "LogGroupName": METRICS_LOG_GROUP,  # Required for CloudWatch agent to know which log group to use
            "CloudWatchMetrics": [{
                "Namespace": "StrandsAgentMetrics",
                "Dimensions": [["AgentName"]],
                "Metrics": [
                    {"Name": "LatencyMs", "Unit": "Milliseconds"},
                    {"Name": "InputTokens", "Unit": "Count"},
                    {"Name": "OutputTokens", "Unit": "Count"},
                    {"Name": "ToolCallCount", "Unit": "Count"},
                    {"Name": "ErrorCount", "Unit": "Count"},
                    {"Name": "SuccessCount", "Unit": "Count"},
                    {"Name": "SuccessRate", "Unit": "None"},
                    {"Name": "TotalCycles", "Unit": "Count"},
                    {"Name": "TotalDuration", "Unit": "Seconds"}
                ]
            }]
        },
        "AgentName": agent_name,
        "LatencyMs": metrics_summary.get("accumulated_metrics", {}).get("latencyMs", 0),
        "InputTokens": metrics_summary.get("accumulated_usage", {}).get("inputTokens", 0),
        "OutputTokens": metrics_summary.get("accumulated_usage", {}).get("outputTokens", 0),
        "TotalCycles": metrics_summary.get("total_cycles", 0),
        "TotalDuration": metrics_summary.get("total_duration", 0)
    }
    
    # Extract tool usage metrics
    tool_usage = metrics_summary.get("tool_usage", {})
    call_count = 0
    error_count = 0
    success_count = 0
    success_rate = 0
    
    # Aggregate metrics across all tools
    for tool_name, tool_data in tool_usage.items():
        execution_stats = tool_data.get("execution_stats", {})
        call_count += execution_stats.get("call_count", 0)
        error_count += execution_stats.get("error_count", 0)
        success_count += execution_stats.get("success_count", 0)
    
    # Calculate success rate if there were any calls
    if call_count > 0:
        success_rate = success_count / call_count
    
    # Add tool metrics to EMF
    emf_metrics["ToolCallCount"] = call_count
    emf_metrics["ErrorCount"] = error_count
    emf_metrics["SuccessCount"] = success_count
    emf_metrics["SuccessRate"] = success_rate
    
    return emf_metrics

def save_metrics(metrics_summary, filename=None, agent_name=DEFAULT_AGENT_NAME):
    """
    Save the extracted metrics to a file in EMF format.
    
    Args:
        metrics_summary (dict): The metrics summary from agent.metrics.get_summary()
        filename (str): The file to append to (default: the METRICS_FILE environment variable)
        agent_name (str): Value of the AgentName dimension
    """
    # Resolved per call: reading os.environ['METRICS_FILE'] at import time made importing this
    # module fail whenever observability.sh hadn't been sourced
    filename = filename or os.environ.get("METRICS_FILE", "").strip()
    if not filename:
        raise ValueError("No metrics file: pass filename or set METRICS_FILE (observability.sh exports it)")
    emf_metrics = extract_metrics(metrics_summary, agent_name)
    
    # Ensure directory exists
    os.makedirs(os.path.dirname(filename) if os.path.dirname(filename) else '.', exist_ok=True)
    
    # Append metrics to file - ensure it's on a single line without newlines
    with open(filename, 'a') as f:
        # Use separators to ensure compact JSON with no extra spaces
        f.write(json.dumps(emf_metrics, separators=(',', ':')) + "\n")
    
    return filename


def counters(metrics_summary):
    """Copy the cumulative counters extract_metrics() reads out of a Strands metrics summary.

    The copy shares nothing with the live summary (Strands returns its own usage dicts), so it can
    be kept and compared with a later summary.
    """
    usage = metrics_summary.get("accumulated_usage", {})
    return {
        "total_cycles": metrics_summary.get("total_cycles", 0),
        "total_duration": metrics_summary.get("total_duration", 0),
        "accumulated_usage": {k: usage.get(k, 0) for k in ("inputTokens", "outputTokens", "totalTokens")},
        "accumulated_metrics": {"latencyMs": metrics_summary.get("accumulated_metrics", {}).get("latencyMs", 0)},
        "tool_usage": {
            name: {"execution_stats": {k: data.get("execution_stats", {}).get(k, 0)
                                       for k in ("call_count", "success_count", "error_count")}}
            for name, data in metrics_summary.get("tool_usage", {}).items()
        },
    }


def subtract(current, previous):
    """current - previous for two counters() results (a tool missing from previous counts from 0)."""
    if isinstance(current, dict):
        previous = previous if isinstance(previous, dict) else {}
        return {k: subtract(v, previous.get(k)) for k, v in current.items()}
    return current - (previous or 0)


class TurnMetricsRecorder:
    """Writes one EMF record per agent turn.

    Strands accumulates an agent's metrics across invocations, so saving the raw summary after
    every turn would count all earlier turns again. This records the difference since the last
    turn instead.
    """

    def __init__(self, agent_name=DEFAULT_AGENT_NAME, filename=None):
        self.agent_name = agent_name
        self.filename = filename
        self._previous = None

    def record(self, metrics_summary):
        current = counters(metrics_summary)
        turn = subtract(current, self._previous) if self._previous else current
        self._previous = current
        return save_metrics(turn, filename=self.filename, agent_name=self.agent_name)

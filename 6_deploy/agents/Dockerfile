# AgentCore Runtime container for the SPBC Pastry Concierge (AgentCore requires linux/arm64).
FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.11-slim

# DOCKER_CONTAINER=1 makes BedrockAgentCoreApp bind 0.0.0.0:8080 (AgentCore's HTTP contract);
# without it the server listens on 127.0.0.1 only. AWS_REGION/AWS_DEFAULT_REGION keep any client
# created without an explicit region inside eu-central-1.
ARG AWS_REGION=eu-central-1
ENV DOCKER_CONTAINER=1 \
    PYTHONUNBUFFERED=1 \
    AWS_REGION=${AWS_REGION} \
    AWS_DEFAULT_REGION=${AWS_REGION}

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Explicit list so a missing module fails the build instead of crashing the runtime at import.
COPY barista_supervisor_agent.py menu_agents.py orders_agents.py place_order.py \
     payments_policy_agents.py stores_agents.py promos_agents.py ./

EXPOSE 8080
CMD ["python", "barista_supervisor_agent.py"]

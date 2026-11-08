#!/bin/bash

set -e

source ~/environment/env.sh

# Install the CloudWatch Agent
echo "Installing CloudWatch Agent..."
sudo yum install -y amazon-cloudwatch-agent

# Set up CloudWatch Agent configuration for CloudAge
echo "Setting up CloudWatch Agent..."
sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/

# Copy the CloudWatch Agent configuration
sudo cp cloudwatch_agentconfig.json /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
echo "Config file is copied"

# Start the CloudWatch Agent
echo "Starting CloudWatch Agent..."
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
    
# Verify if the CloudWatch Agent is running
if sudo systemctl is-active --quiet amazon-cloudwatch-agent; then
    echo "CloudWatch Agent is running"
else
    echo "Warning: CloudWatch Agent failed to start"
fi

# Set proper permissions for all application files
sudo chown -R ec2-user:ec2-user "/home/ec2-user/environment/4_monitor_and_evaluate/"
sudo chown -R ec2-user:ec2-user "/home/ec2-user/environment/4_monitor_and_evaluate/cloudwatchagent/logs" 
chmod +x "/home/ec2-user/environment/3_proof_of_concept/agents/tech_assistant_agent.py"
chmod +x "/home/ec2-user/environment/4_monitor_and_evaluate/cloudwatchagent/metricsutils.py"

# Setting environment variables
echo 'export CLOUDWATCH_AGENT_UTILS_PATH="/home/ec2-user/environment/4_monitor_and_evaluate/cloudwatchagent"' >> ~/environment/env.sh
echo 'export LOG_FILE="/home/ec2-user/environment/4_monitor_and_evaluate/cloudwatchagent/logs/tech_assistant_agents_sdk.log"' >> ~/environment/env.sh
echo 'export METRICS_FILE="/home/ec2-user/environment/4_monitor_and_evaluate/cloudwatchagent/logs/tech_assistant_metrics.json"' >> ~/environment/env.sh
echo "export ENABLE_OTEL_TRACING=false" >> ~/environment/env.sh

echo "Environment variables set"

source ~/environment/env.sh
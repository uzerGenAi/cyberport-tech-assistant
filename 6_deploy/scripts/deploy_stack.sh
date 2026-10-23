#!/bin/bash

set -e

# ============================================================================
# COMPREHENSIVE DEPLOYMENT SCRIPT FOR CLOUDAGE
# ============================================================================
# This script automates the complete deployment of:
# 1. Lambda Functions (AI agents as container images)
# 2. API Gateway (REST API)
# 3. Web Application (ECR + container deployment)
# ============================================================================

# === CONFIGURATION ===
REGION="eu-central-1"
WEB_APP_DIR="/home/ec2-user/environment/6_deploy/web-app"

# Lambda and API Gateway Configuration
WEBSOCKET_LAMBDA_NAME="spbcTestAgentsWebSocketFunction"
ROLE_NAME="spbcAgentsLambdaRole-eu-central-1"
WEBSOCKET_ECR_REPO_NAME="spbc-agents-websocket"
CONNECTIONS_TABLE_NAME="spbc-websocket-connections"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_step() {
    echo -e "\n${PURPLE}🚀 STEP: $1${NC}"
    echo "============================================================================"
}

check_prerequisites() {
    log_step "Checking Prerequisites"
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    log_success "Docker is available"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi
    log_success "AWS CLI is available"
    
    # Check if we can get AWS account info
    ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text --region $REGION 2>/dev/null || echo "")
    if [ -z "$ACCOUNT_ID" ]; then
        log_error "Cannot retrieve AWS account information. Please check your AWS credentials."
        exit 1
    fi
    log_success "AWS Account ID: $ACCOUNT_ID"
    
    if [ ! -d "$WEB_APP_DIR" ]; then
        log_error "Web app directory not found: $WEB_APP_DIR"
        exit 1
    fi
    log_success "Web app directory found"
}

create_cloudwatch_dashboard() {
    log_step "Creating CloudWatch Dashboard for Agent Monitoring"
    
    # Get account ID dynamically
    ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text --region $REGION)
    
    # Create dashboard configuration
    DASHBOARD_CONFIG=$(cat << EOF
{
    "widgets": [
        {
            "type": "metric",
            "x": 0,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "SPBC/Agents", "LatencyMs", "AgentName", "pastry_concierge_agent" ],
                    [ ".", "InputTokens", ".", "." ],
                    [ ".", "OutputTokens", ".", "." ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "$REGION",
                "title": "Agent Performance Metrics",
                "period": 300,
                "stat": "Average"
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "SPBC/Agents", "SuccessRate", "AgentName", "pastry_concierge_agent" ],
                    [ ".", "ErrorCount", ".", "." ],
                    [ ".", "SuccessCount", ".", "." ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "$REGION",
                "title": "Agent Success Metrics",
                "period": 300,
                "stat": "Sum"
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 6,
            "width": 24,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "SPBC/Agents", "ToolCallCount", "AgentName", "pastry_concierge_agent" ],
                    [ ".", "TotalCycles", ".", "." ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "$REGION",
                "title": "Tool Usage and Cycles",
                "period": 300,
                "stat": "Sum"
            }
        },
        {
            "type": "log",
            "x": 0,
            "y": 12,
            "width": 24,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/lambda/$WEBSOCKET_LAMBDA_NAME' | fields @timestamp, @message\n| filter @message like /Agent/\n| sort @timestamp desc\n| limit 100",
                "region": "$REGION",
                "title": "Recent Agent Logs",
                "view": "table"
            }
        }
    ]
}
EOF
)
    
    # Check if dashboard already exists
    if aws cloudwatch get-dashboard --dashboard-name "SPBC-Agent-Metrics" --region $REGION >/dev/null 2>&1; then
        log_warning "CloudWatch dashboard 'SPBC-Agent-Metrics' already exists. Updating..."
        
        # Update existing dashboard
        aws cloudwatch put-dashboard \
            --dashboard-name "SPBC-Agent-Metrics" \
            --dashboard-body "$DASHBOARD_CONFIG" \
            --region $REGION > /dev/null
            
        log_success "CloudWatch dashboard updated successfully"
    else
        log_info "Creating new CloudWatch dashboard 'SPBC-Agent-Metrics'..."
        
        # Create new dashboard
        aws cloudwatch put-dashboard \
            --dashboard-name "SPBC-Agent-Metrics" \
            --dashboard-body "$DASHBOARD_CONFIG" \
            --region $REGION > /dev/null
            
        log_success "CloudWatch dashboard created successfully"
    fi
    
    # Update observability configuration
    DASHBOARD_URL="https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=SPBC-Agent-Metrics"
    
    # Create/update observability config for web app
    OBSERVABILITY_CONFIG=$(cat << EOF
{
    "observabilityType": "cloudwatch",
    "cloudwatch": {
        "region": "$REGION",
        "dashboardUrl": "$DASHBOARD_URL",
        "logGroupPrefix": "spbc-agents",
        "metricsNamespace": "SPBC/Agents"
    },
    "enabled": true
}
EOF
)
    
    # Save configuration to web app directory
    echo "$OBSERVABILITY_CONFIG" > "$WEB_APP_DIR/observability-config.json"
    
    log_success "Observability configuration updated"
    log_info "Dashboard URL: $DASHBOARD_URL"
}

deploy_web_application() {
    log_step "Deploying Web Application to ECR and EKS"
    
    # Change to web app directory
    cd $WEB_APP_DIR
    
    # Check if webapp.sh exists
    if [ ! -f "webapp.sh" ]; then
        log_error "webapp.sh not found in $WEB_APP_DIR"
        exit 1
    fi
    
    log_info "Running webapp.sh to build and push Docker image to ECR..."
    bash webapp.sh
    
    if [ $? -eq 0 ]; then
        log_success "Web application deployed to ECR successfully!"
    else
        log_error "Failed to deploy web application to ECR"
        exit 1
    fi
    
    # Return to original directory
    cd - > /dev/null
}

print_deployment_summary() {
    log_step "Deployment Summary"
    
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}🎉 CONTAINERIZED DEPLOYMENT WITH WEBSOCKET COMPLETED SUCCESSFULLY! 🎉${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo
    echo -e "${GREEN}📋 Deployment Summary:${NC}"
    echo -e "   • CloudWatch Dashboard: SPBC-Agent-Metrics created for monitoring"
    echo -e "   • Observability: CloudWatch metrics enabled for agent performance tracking"
    echo -e "   • Web Application: Updated with WebSocket support and pushed to ECR"
    echo -e "   • EKS Access Entry: Configured for current user"
    echo
    echo -e "${YELLOW}🔗 Next Steps:${NC}"
    echo -e "   1. Deploy the web application to EKS using: bash deploy-frontend.sh"
    echo -e "   2. Test the REST API: curl -X POST $API_ENDPOINT -d '{\"message\":\"Hello\",\"session_id\":\"test\"}'"
    echo -e "   3. Test WebSocket connection using the web application"
    echo -e "   4. Monitor agent performance via CloudWatch dropdown in web app"
    echo -e "   5. Monitor WebSocket connections in DynamoDB table: $CONNECTIONS_TABLE_NAME"
    echo
    echo -e "${BLUE}📊 Useful Commands:${NC}"
    echo -e "   • Test Lambda: aws lambda invoke --function-name $LAMBDA_NAME --region $REGION response.json"
    echo -e "   • Test WebSocket Lambda: aws lambda invoke --function-name $WEBSOCKET_LAMBDA_NAME --region $REGION ws-response.json"
    echo -e "   • View logs: aws logs describe-log-groups --log-group-name-prefix /aws/lambda/$LAMBDA_NAME --region $REGION"
    echo -e "   • View WebSocket logs: aws logs describe-log-groups --log-group-name-prefix /aws/lambda/$WEBSOCKET_LAMBDA_NAME --region $REGION"
    echo -e "   • API Gateway console: https://console.aws.amazon.com/apigateway/home?region=$REGION"
    echo -e "   • WebSocket API console: https://console.aws.amazon.com/apigateway/home?region=$REGION#/apis"
    echo -e "   • DynamoDB console: https://console.aws.amazon.com/dynamodb/home?region=$REGION#tables:selected=$CONNECTIONS_TABLE_NAME"
    echo
    echo -e "${CYAN}============================================================================${NC}"
}

# ============================================================================
# EKS ACCESS ENTRY CREATION
# ============================================================================

create_eks_access_entry() {
    log_step "Creating EKS Access Entry for Current User"
    
    # Hardcoded cluster details
    local CLUSTER_NAME="spbc-eks-cluster"
    
    # Check prerequisites
    if ! command -v eksctl &> /dev/null; then
        log_warning "eksctl not found. Skipping EKS access entry creation."
        log_info "You can install eksctl and run this manually later if needed."
        return 0
    fi
    
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not found. Skipping EKS access entry creation."
        log_info "You can install kubectl and run this manually later if needed."
        return 0
    fi
    
    if ! command -v jq &> /dev/null; then
        log_warning "jq not found. Installing jq..."
        if command -v yum &> /dev/null; then
            sudo yum install jq -y > /dev/null 2>&1 || log_warning "Failed to install jq automatically"
        elif command -v apt-get &> /dev/null; then
            sudo apt-get install jq -y > /dev/null 2>&1 || log_warning "Failed to install jq automatically"
        fi
    fi
    
    # Get AWS Account ID and IAM details
    log_info "Retrieving AWS account information..."
    local IAM_ARN=$(aws sts get-caller-identity --query Arn --output text)
    
    # Extract principal ARN and username from IAM ARN
    local PRINCIPAL_ARN
    local USERNAME
    
    if [[ "$IAM_ARN" == arn:aws:iam::*:user/* ]]; then
        USERNAME=$(echo "$IAM_ARN" | awk -F'/' '{print $2}')
        PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:user/${USERNAME}"
        log_info "User Type: IAM User ($USERNAME)"
    elif [[ "$IAM_ARN" == arn:aws:sts::*:assumed-role/* ]]; then
        local ROLE_NAME=$(echo "$IAM_ARN" | awk -F'/' '{print $2}')
        USERNAME="${ROLE_NAME}"
        PRINCIPAL_ARN="arn:aws:iam::${ACCOUNT_ID}:role/service-role/${ROLE_NAME}"
        log_info "User Type: Assumed Role ($ROLE_NAME)"
    else
        log_warning "Unsupported ARN format: $IAM_ARN"
        log_info "Skipping EKS access entry creation"
        return 0
    fi
    
    # Check if cluster exists
    log_info "Checking for EKS cluster: $CLUSTER_NAME"
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        log_warning "EKS cluster '$CLUSTER_NAME' not found in region '$REGION'"
        log_info "Skipping EKS access entry creation"
        return 0
    fi
    
    log_success "EKS cluster found: $CLUSTER_NAME"
    
    # Method 1: Try eksctl create accessentry
    log_info "Creating access entry using eksctl..."
    
    # Create a temporary eksctl config file
    local TEMP_CONFIG=$(mktemp)
    cat > "$TEMP_CONFIG" << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}

accessConfig:
  accessEntries:
  - principalARN: ${PRINCIPAL_ARN}
    accessPolicies:
    - policyARN: arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
      accessScope:
        type: cluster
    - policyARN: arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy
      accessScope:
        type: cluster
EOF
    
    # Try to create access entry using eksctl
    local ACCESS_ENTRY_CREATED=false
    if eksctl create accessentry --config-file="$TEMP_CONFIG" > /dev/null 2>&1; then
        log_success "Access entry created successfully with eksctl"
        ACCESS_ENTRY_CREATED=true
    else
        log_warning "eksctl access entry creation failed, trying alternative method..."
        ACCESS_ENTRY_CREATED=false
    fi
    
    # Method 2: Fallback to aws-auth ConfigMap if eksctl fails
    if [[ "$ACCESS_ENTRY_CREATED" == "false" ]]; then
        log_info "Using aws-auth ConfigMap method..."
        
        # Update kubeconfig first
        log_info "Updating kubeconfig..."
        if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" > /dev/null 2>&1; then
            log_success "Kubeconfig updated successfully"
        else
            log_warning "Failed to update kubeconfig"
            rm -f "$TEMP_CONFIG"
            return 0
        fi
        
        # Check if aws-auth ConfigMap exists
        if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
            log_info "Found existing aws-auth ConfigMap"
            
            # Get current mapRoles
            local CURRENT_MAP_ROLES=$(kubectl get configmap aws-auth -n kube-system -o jsonpath='{.data.mapRoles}' 2>/dev/null || echo "")
            
            # Check if role already exists in mapRoles
            if echo "$CURRENT_MAP_ROLES" | grep -q "$PRINCIPAL_ARN"; then
                log_info "Role already exists in aws-auth ConfigMap"
            else
                log_info "Adding role to aws-auth ConfigMap..."
                
                # Create new mapRoles entry
                local NEW_ROLE_ENTRY="  - groups:
    - system:masters
    rolearn: ${PRINCIPAL_ARN}
    username: ${USERNAME}"
                
                # Create updated mapRoles
                local UPDATED_MAP_ROLES
                if [[ -z "$CURRENT_MAP_ROLES" ]]; then
                    UPDATED_MAP_ROLES="$NEW_ROLE_ENTRY"
                else
                    UPDATED_MAP_ROLES="$CURRENT_MAP_ROLES
$NEW_ROLE_ENTRY"
                fi
                
                # Apply the updated ConfigMap
                if kubectl patch configmap aws-auth -n kube-system --type merge -p "{\"data\":{\"mapRoles\":\"$UPDATED_MAP_ROLES\"}}" > /dev/null 2>&1; then
                    log_success "Role added to aws-auth ConfigMap"
                else
                    log_warning "Failed to update aws-auth ConfigMap"
                fi
            fi
        else
            log_info "Creating new aws-auth ConfigMap..."
            
            # Create new aws-auth ConfigMap
            if cat << EOF | kubectl apply -f - > /dev/null 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - groups:
      - system:masters
      rolearn: ${PRINCIPAL_ARN}
      username: ${USERNAME}
EOF
            then
                log_success "Created new aws-auth ConfigMap"
            else
                log_warning "Failed to create aws-auth ConfigMap"
            fi
        fi
    fi
    
    # Clean up temporary files
    rm -f "$TEMP_CONFIG"
    
    # Update kubeconfig (in case it wasn't done already)
    log_info "Ensuring kubeconfig is updated..."
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" > /dev/null 2>&1 || true
    
    # Test cluster access
    log_info "Testing cluster access..."
    sleep 3  # Give a moment for permissions to propagate
    
    if kubectl get nodes > /dev/null 2>&1; then
        log_success "Successfully connected to EKS cluster!"
        local NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        log_info "Cluster has $NODE_COUNT node(s) ready"
    else
        log_warning "Unable to access cluster immediately"
        log_info "Permissions may take a few moments to propagate"
        log_info "Try running 'kubectl get nodes' in a minute or two"
    fi
    
    log_success "EKS access entry configuration completed"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    echo -e "${PURPLE}"
    echo "============================================================================"
    echo "🥐 SPBC - SPECIALTY BAKERIES & PASTRY CAFÉS DEPLOYMENT"
    echo "============================================================================"
    echo -e "${NC}"
    echo "This script deploys the Specialty Bakeries & Pastry Cafés agentic AI system:"
    echo
    echo "📊 OBSERVABILITY & MONITORING:"
    echo "  • CloudWatch Dashboard (P2P-Agent-Metrics with 4 widgets)"
    echo "  • Custom metrics collection (Performance, Success rates, Tool usage)"
    echo "  • Structured logging with debug output"
    echo "  • Web app integration with CloudWatch dropdown"
    echo
    echo "🚀 WEB APPLICATION:"
    echo "  • Enhanced UI with CloudWatch observability dropdown"
    echo "  • WebSocket-enabled real-time chat interface"
    echo "  • Professional bakery & pastry café branding"
    echo "  • Mobile-responsive design"
    echo
    echo "🔐 INFRASTRUCTURE:"
    echo "  • ECR repositories for container images"
    echo "  • IAM roles with CloudWatch metrics permissions"
    echo "  • EKS cluster integration"
    echo "  • Multi-account compatible configuration"
    echo
    echo "⚡ PERFORMANCE OPTIMIZATIONS:"
    echo "  • 3GB Lambda memory for enterprise-grade performance"
    echo "  • 15-minute timeouts for complex agent workflows"
    echo "  • Enhanced database connection handling"
    echo "  • Optimized container images"
    echo
    echo "Estimated deployment time: 3-5 minutes"
    echo "Post-deployment: CloudWatch metrics populate within 2-5 minutes"
    echo
    read -p "Press Enter to continue or Ctrl+C to cancel..."
    echo
    
    # Execute deployment steps
    check_prerequisites
    create_cloudwatch_dashboard
    deploy_web_application
    create_eks_access_entry
    print_deployment_summary
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

# Trap errors and provide helpful information
trap 'log_error "Script failed at line $LINENO. Exit code: $?"; exit 1' ERR

# Run main function
main "$@"

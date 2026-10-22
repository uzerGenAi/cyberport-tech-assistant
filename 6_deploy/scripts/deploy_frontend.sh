#!/bin/bash
# deploy-frontend.sh - Comprehensive EKS and CloudFront deployment script

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Utility functions
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

echo -e "${PURPLE}"
echo "============================================================================"
echo "🚀 COMPREHENSIVE EKS + CLOUDFRONT DEPLOYMENT"
echo "============================================================================"
echo -e "${NC}"
echo "This script will:"
echo "  • Deploy web application to EKS Auto Mode"
echo "  • Create Network Load Balancer"
echo "  • Configure CloudFront VPC Origin"
echo "  • Provide final public URL"
echo
echo "Estimated deployment time: 10-15 minutes"
echo
read -p "Press Enter to continue or Ctrl+C to cancel..."
echo

# Configuration
CLUSTER_NAME="pastrycafe-prod"
REPOSITORY_NAME="pastrycafe"
DEPLOYMENT_FILE="/home/ec2-user/environment/6_deploy/scripts/frontend-deployment.yaml"
TEMP_DEPLOYMENT_FILE="/tmp/frontend-deployment-configured.yaml"
SERVICE_NAME="web-app-service"
VPC_ORIGIN_NAME="eks-web-app-cloudfront-vpc"

log_step "Getting AWS Account Information"

# Get AWS account ID and region
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
AWS_REGION=$(aws configure get region)

if [ -z "$AWS_REGION" ]; then
    AWS_REGION="eu-central-1"  # Default fallback
    log_warning "No default region found, using: $AWS_REGION"
fi

log_success "Account ID: $AWS_ACCOUNT_ID"
log_success "Region: $AWS_REGION"

log_step "Configuring EKS Cluster Connection"

# Update kubeconfig
log_info "Updating kubeconfig for EKS cluster..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Verify cluster connection
log_info "Verifying cluster connection..."
kubectl get nodes > /dev/null 2>&1 || {
    log_error "Failed to connect to EKS cluster. Please check your cluster name and permissions."
    exit 1
}
log_success "Successfully connected to EKS cluster: $CLUSTER_NAME"

log_step "Ensuring EKS Add-ons"

# Verify if CNI add-on was installed
log_info "Ensuring VPC CNI add-on is installed..."
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name vpc-cni \
  --region $AWS_REGION \
  --addon-version v1.15.1-eksbuild.1 \
  --resolve-conflicts OVERWRITE \
  --service-account-role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/p2peksautomodenoderole 2>/dev/null || \
log_success "VPC CNI add-on already exists or created successfully"

log_step "Configuring Network Infrastructure"

# Get private subnet IDs
log_info "Finding private subnets..."
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
    --query "Subnets[*].SubnetId" \
    --output text | tr '\t' ',')

if [ -z "$PRIVATE_SUBNETS" ]; then
    log_error "No private subnets found with tag kubernetes.io/role/internal-elb"
    echo "Please ensure your private subnets are tagged correctly:"
    echo "  Key: kubernetes.io/role/internal-elb"
    echo "  Value: 1"
    exit 1
fi

log_success "Found private subnets: $PRIVATE_SUBNETS"

log_step "Setting Up ECR Authentication"

# Create ECR registry secret
log_info "Creating ECR registry secret..."
kubectl delete secret ecr-registry-secret --ignore-not-found=true

TOKEN=$(aws ecr get-login-password --region $AWS_REGION)
kubectl create secret docker-registry ecr-registry-secret \
    --docker-server=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com \
    --docker-username=AWS \
    --docker-password="${TOKEN}" \
    --docker-email=dummy@example.com

log_success "ECR registry secret created successfully"

log_step "Deploying Application to EKS"

# Check if deployment file exists
if [ ! -f "$DEPLOYMENT_FILE" ]; then
    log_error "Deployment file not found: $DEPLOYMENT_FILE"
    exit 1
fi

# Create configured deployment file
log_info "Configuring deployment file..."
cp "$DEPLOYMENT_FILE" "$TEMP_DEPLOYMENT_FILE"

# Replace placeholders
sed -i "s/ACCOUNT_ID/$AWS_ACCOUNT_ID/g" "$TEMP_DEPLOYMENT_FILE"
sed -i "s/REGION/$AWS_REGION/g" "$TEMP_DEPLOYMENT_FILE"
sed -i "s/PRIVATE_SUBNET_IDS/$PRIVATE_SUBNETS/g" "$TEMP_DEPLOYMENT_FILE"

log_success "Configuration complete"

# Deploy to Kubernetes
log_info "Deploying to Kubernetes..."
kubectl apply -f "$TEMP_DEPLOYMENT_FILE"

# Wait for deployment to be ready
log_info "Waiting for deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/web-app

log_success "Application deployment completed"

log_step "Configuring Network Load Balancer"

# Wait for service to get external IP
log_info "Waiting for LoadBalancer to be ready..."
for i in {1..30}; do
    NLB_HOSTNAME=$(kubectl get service $SERVICE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ ! -z "$NLB_HOSTNAME" ]; then
        log_success "LoadBalancer ready: $NLB_HOSTNAME"
        break
    fi
    log_info "Waiting for LoadBalancer... (attempt $i/30)"
    sleep 10
done

if [ -z "$NLB_HOSTNAME" ]; then
    log_error "LoadBalancer not ready after 5 minutes"
    log_info "You can check the status with: kubectl get service $SERVICE_NAME"
    exit 1
fi

# Get NLB ARN for CloudFront setup
NLB_NAME=$(echo $NLB_HOSTNAME | cut -d'.' -f1 | cut -d'-' -f1-4)
NLB_ARN=$(aws elbv2 describe-load-balancers --names $NLB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")

if [ -z "$NLB_ARN" ]; then
    log_error "Could not retrieve NLB ARN"
    exit 1
fi

log_success "Network Load Balancer configured"
log_info "NLB ARN: $NLB_ARN"

log_step "Configuring CloudFront VPC Origin"

# Check for existing VPC Origins
log_info "Checking existing VPC Origins..."
ALL_VPC_ORIGINS=$(aws cloudfront list-vpc-origins --output json)
EXISTING_VPC_ORIGIN=$(echo "$ALL_VPC_ORIGINS" | jq "[.VpcOriginList.Items[] | select(.Name == \"$VPC_ORIGIN_NAME\")]")

if [ "$(echo "$EXISTING_VPC_ORIGIN" | jq 'length')" -gt 0 ]; then
    VPC_ORIGIN_ID=$(echo "$EXISTING_VPC_ORIGIN" | jq -r '.[0].Id')
    VPC_ORIGIN_DNS="${VPC_ORIGIN_ID}.vpc-origin.internal"
    STATUS=$(echo "$EXISTING_VPC_ORIGIN" | jq -r '.[0].Status')
    log_info "Found existing VPC Origin: ID=$VPC_ORIGIN_ID DNS=$VPC_ORIGIN_DNS STATUS=$STATUS"

    if [ "$STATUS" != "Deployed" ]; then
        log_info "Waiting for VPC Origin to be deployed..."
        while true; do
            STATUS=$(aws cloudfront get-vpc-origin --id "$VPC_ORIGIN_ID" --query 'VpcOrigin.Status' --output text)
            log_info "VPC Origin Status: $STATUS"
            [ "$STATUS" = "Deployed" ] && break
            sleep 15
        done
    fi
    log_success "VPC Origin is ready"
else
    log_info "Creating new VPC Origin..."
    VPC_ORIGIN_JSON=$(aws cloudfront create-vpc-origin \
      --vpc-origin-endpoint-config Name=$VPC_ORIGIN_NAME,Arn=$NLB_ARN,HTTPPort=80,HTTPSPort=443,OriginProtocolPolicy=http-only)
    VPC_ORIGIN_ID=$(echo "$VPC_ORIGIN_JSON" | jq -r '.VpcOrigin.Id')
    VPC_ORIGIN_DNS="${VPC_ORIGIN_ID}.vpc-origin.internal"

    log_info "Waiting for VPC Origin to be deployed..."
    while true; do
        STATUS=$(aws cloudfront get-vpc-origin --id "$VPC_ORIGIN_ID" --query 'VpcOrigin.Status' --output text)
        log_info "VPC Origin Status: $STATUS"
        [ "$STATUS" = "Deployed" ] && break
        sleep 15
    done
    log_success "VPC Origin created and deployed: ID=$VPC_ORIGIN_ID DNS=$VPC_ORIGIN_DNS"
fi

log_step "Creating New CloudFront Distribution"

# Generate unique distribution name
DISTRIBUTION_NAME="PastryCafe-$(date +%s)"
CALLER_REFERENCE="PastryCafe-$(date +%s)-$(echo $RANDOM)"

log_info "Creating new CloudFront distribution: $DISTRIBUTION_NAME"

# Create distribution configuration
DISTRIBUTION_CONFIG=$(cat << EOF
{
  "CallerReference": "$CALLER_REFERENCE",
  "Comment": "Specialty Bakeries & Pastry Cafés CloudFront Distribution for EKS Web App",
  "DefaultCacheBehavior": {
    "TargetOriginId": "EKSWebAppOrigin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "MinTTL": 0,
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": {
        "Forward": "none"
      }
    },
    "TrustedSigners": {
      "Enabled": false,
      "Quantity": 0
    },
    "Compress": true,
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": {
        "Quantity": 2,
        "Items": ["GET","HEAD"]
      }
    }
  },
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "EKSWebAppOrigin",
        "DomainName": "$VPC_ORIGIN_DNS",
        "OriginPath": "",
        "VpcOriginConfig": {
          "VpcOriginId": "$VPC_ORIGIN_ID"
        },
        "CustomHeaders": {
          "Quantity": 0
        }
      }
    ]
  },
  "Enabled": true,
  "PriceClass": "PriceClass_All"
}
EOF
)

# Create the CloudFront distribution
log_info "Creating CloudFront distribution..."
CF_CREATE_RESULT=$(aws cloudfront create-distribution \
    --distribution-config "$DISTRIBUTION_CONFIG")

CF_DIST_ID=$(echo "$CF_CREATE_RESULT" | jq -r '.Distribution.Id')
CF_DOMAIN=$(echo "$CF_CREATE_RESULT" | jq -r '.Distribution.DomainName')

if [ -z "$CF_DIST_ID" ] || [ "$CF_DIST_ID" = "null" ]; then
    log_error "Failed to create CloudFront distribution"
    exit 1
fi

log_success "CloudFront distribution created successfully"
log_info "Distribution ID: $CF_DIST_ID"
log_info "Domain Name: $CF_DOMAIN"

# Wait for distribution to be deployed
log_info "Waiting for CloudFront distribution to be deployed (this may take 10-15 minutes)..."
log_info "You can continue with other tasks while this deploys in the background"

# Check deployment status (non-blocking)
check_distribution_status() {
    local status=$(aws cloudfront get-distribution --id "$CF_DIST_ID" --query 'Distribution.Status' --output text 2>/dev/null)
    echo "$status"
}

# Initial status check
INITIAL_STATUS=$(check_distribution_status)
log_info "Initial distribution status: $INITIAL_STATUS"

log_step "Deployment Summary"

echo -e "${CYAN}============================================================================${NC}"
echo -e "${CYAN}🎉 COMPREHENSIVE DEPLOYMENT COMPLETED SUCCESSFULLY! 🎉${NC}"
echo -e "${CYAN}============================================================================${NC}"
echo
echo -e "${GREEN}📋 Deployment Summary:${NC}"
echo -e "   • EKS Cluster: $CLUSTER_NAME"
echo -e "   • Application Pods: $(kubectl get pods -l app=web-app --no-headers | wc -l) running"
echo -e "   • Network Load Balancer: $NLB_HOSTNAME"
echo -e "   • VPC Origin: $VPC_ORIGIN_ID ($VPC_ORIGIN_DNS)"
echo -e "   • CloudFront Distribution: $CF_DIST_ID"
echo -e "   • Public URL: ${CYAN}https://$CF_DOMAIN/${NC}"
echo
echo -e "${YELLOW}🔗 Next Steps:${NC}"
echo -e "   1. Wait 5-10 minutes for CloudFront to propagate changes"
echo -e "   2. Test your application at: https://$CF_DOMAIN/"
echo -e "   3. Try the AI chatbot functionality"
echo
echo -e "${BLUE}📊 Useful Commands:${NC}"
echo -e "   • Check pods: kubectl get pods -l app=web-app"
echo -e "   • Check service: kubectl get service $SERVICE_NAME"
echo -e "   • View logs: kubectl logs -l app=web-app"
echo
echo -e "${CYAN}============================================================================${NC}"

# Show deployment status
echo -e "\n${BLUE}📊 Current Deployment Status:${NC}"
kubectl get deployments,services,pods -l app=web-app

# Clean up temp file
rm -f "$TEMP_DEPLOYMENT_FILE"

echo
log_success "Complete deployment finished successfully!"
echo -e "${CYAN}🌐 Your application is available at: https://$CF_DOMAIN/${NC}"

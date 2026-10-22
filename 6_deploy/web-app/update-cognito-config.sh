#!/bin/bash

# This script updates the Cognito configuration file with the actual User Pool ID and Client ID
# It should be run after the Cognito User Pool is created

set -e  # Exit on any error

# Configuration
REGION="eu-central-1"
USER_POOL_NAME="spbcuserpool"
CLIENT_NAME="WebAppClientNoSecret"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

print_status "Fetching Cognito User Pool configuration..."

# Get the User Pool ID
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region $REGION --query "UserPools[?Name=='$USER_POOL_NAME'].Id" --output text)

if [ -z "$USER_POOL_ID" ]; then
    print_error "Could not find User Pool with name '$USER_POOL_NAME'"
    print_status "Please run the setup_cognito_auth.sh script first to create the User Pool"
    exit 1
fi

# Get the App Client ID
CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id $USER_POOL_ID --region $REGION --query "UserPoolClients[?ClientName=='$CLIENT_NAME'].ClientId" --output text)

if [ -z "$CLIENT_ID" ]; then
    print_error "Could not find App Client with name '$CLIENT_NAME'"
    print_status "Creating a new App Client without secret..."
    
    # Create a new App Client without secret
    CLIENT_ID=$(aws cognito-idp create-user-pool-client \
        --user-pool-id $USER_POOL_ID \
        --client-name "$CLIENT_NAME" \
        --no-generate-secret \
        --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
        --region $REGION \
        --query "UserPoolClient.ClientId" \
        --output text)
    
    if [ -z "$CLIENT_ID" ]; then
        print_error "Failed to create App Client"
        exit 1
    fi
    
    print_success "App Client created successfully"
fi

# Update the configuration file
cat > cognito-config.json << EOF
{
  "UserPoolId": "$USER_POOL_ID",
  "ClientId": "$CLIENT_ID"
}
EOF

print_success "Cognito configuration updated successfully!"
echo "User Pool ID: $USER_POOL_ID"
echo "Client ID: $CLIENT_ID"

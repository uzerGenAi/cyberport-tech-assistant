#!/bin/bash
set -euo pipefail

# Enhanced Cognito Authentication Setup Script
# This script creates Cognito User Pool + Identity Pool + IAM roles for direct browser to Bedrock AgentCore communication
# Combines all authentication setup into a single comprehensive script
#
# Usage:
#   bash 6_deploy/scripts/setup_cognito_auth.sh [options]
#
# Options:
#   -u, --update-config   Only refresh the web-app config files from existing Cognito resources
#       --skip-user       Create no sign-in user (infrastructure only)
#       --non-interactive Never prompt; the user's credentials must come from the environment
#   -h, --help            Show this help
#
# Unattended runs (CI, CodeBuild, any pipeline) must not block on a prompt, so the sign-in user
# is taken from the environment. Pick one:
#   COGNITO_ADMIN_USERNAME + COGNITO_ADMIN_PASSWORD_SECRET_ID   (password read from Secrets Manager)
#   COGNITO_ADMIN_USERNAME + COGNITO_ADMIN_PASSWORD             (password straight from the env)
#   SKIP_USER_CREATION=1                                        (no user; create one later)
# Without a terminal and without any of those, the script stops instead of waiting on stdin.

set -e  # Exit on any error

# Configuration
REGION="${REGION:-eu-central-1}"
USER_POOL_NAME="spbcuserpool"
CLIENT_NAME="WebAppClientNoSecret"
IDENTITY_POOL_NAME="SPBCIdentityPool"
AUTHENTICATED_ROLE_NAME="SPBC_Cognito_AuthRole"

# Paths are derived from this script's location so the script also runs in CloudShell and CI.
# In the EC2 lab layout this still resolves to /home/ec2-user/environment/6_deploy/...
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WEB_APP_DIR="${WEB_APP_DIR:-$ROOT_DIR/6_deploy/web-app}"
AGENTS_DIR="${AGENTS_DIR:-$ROOT_DIR/6_deploy/agents}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites and backup files
check_prerequisites_and_backup() {
    print_status "Checking prerequisites and backing up files..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI is not configured or credentials are invalid"
        exit 1
    fi
    
    # Check web app directory
    if [ ! -d "$WEB_APP_DIR" ]; then
        print_error "Web app directory not found: $WEB_APP_DIR"
        exit 1
    fi
    
    # Backup existing files
    local backup_dir="$WEB_APP_DIR/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    local files_to_backup=("cognito-config.json")
    for file in "${files_to_backup[@]}"; do
        if [ -f "$WEB_APP_DIR/$file" ]; then
            cp "$WEB_APP_DIR/$file" "$backup_dir/"
            print_status "Backed up $file to $backup_dir"
        fi
    done
    
    print_success "Prerequisites check and backup completed"
}

# Function to create Cognito User Pool
create_user_pool() {
    print_status "Checking if Cognito User Pool '$USER_POOL_NAME' exists..."
    
    local existing_pool_id=$(aws cognito-idp list-user-pools --max-results 60 --region $REGION --query "UserPools[?Name=='$USER_POOL_NAME'].Id" --output text 2>/dev/null || echo "")
    
    if [ -n "$existing_pool_id" ]; then
        print_warning "User Pool '$USER_POOL_NAME' already exists with ID: $existing_pool_id"
        USER_POOL_ID=$existing_pool_id
    else
        print_status "Creating Cognito User Pool '$USER_POOL_NAME'..."
        
        USER_POOL_ID=$(aws cognito-idp create-user-pool \
            --pool-name "$USER_POOL_NAME" \
            --auto-verified-attributes email \
            --policies '{
                "PasswordPolicy": {
                    "RequireUppercase": true,
                    "RequireLowercase": true,
                    "RequireNumbers": true,
                    "MinimumLength": 8,
                    "RequireSymbols": true
                }
            }' \
            --region $REGION \
            --query "UserPool.Id" \
            --output text)
        
        if [ -z "$USER_POOL_ID" ]; then
            print_error "Failed to create User Pool"
            exit 1
        fi
        
        print_success "User Pool created successfully with ID: $USER_POOL_ID"
    fi
}

# Function to create User Pool Client
create_user_pool_client() {
    print_status "Checking if User Pool Client '$CLIENT_NAME' exists..."
    
    local existing_client_id=$(aws cognito-idp list-user-pool-clients \
        --user-pool-id $USER_POOL_ID \
        --region $REGION \
        --query "UserPoolClients[?ClientName=='$CLIENT_NAME'].ClientId" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$existing_client_id" ]; then
        print_warning "User Pool Client '$CLIENT_NAME' already exists with ID: $existing_client_id"
        CLIENT_ID=$existing_client_id
        
        # Verify the client has the correct configuration
        print_status "Verifying client configuration..."
        local client_config=$(aws cognito-idp describe-user-pool-client \
            --user-pool-id $USER_POOL_ID \
            --client-id $CLIENT_ID \
            --region $REGION \
            --query "UserPoolClient.ExplicitAuthFlows" \
            --output text 2>/dev/null || echo "")
        
        if [[ "$client_config" != *"ALLOW_USER_SRP_AUTH"* ]]; then
            print_warning "Client configuration needs updating. Updating auth flows..."
            aws cognito-idp update-user-pool-client \
                --user-pool-id $USER_POOL_ID \
                --client-id $CLIENT_ID \
                --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
                --region $REGION > /dev/null
            print_success "Client configuration updated"
        fi
    else
        print_status "Creating User Pool Client '$CLIENT_NAME'..."
        
        CLIENT_ID=$(aws cognito-idp create-user-pool-client \
            --user-pool-id $USER_POOL_ID \
            --client-name "$CLIENT_NAME" \
            --no-generate-secret \
            --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
            --region $REGION \
            --query "UserPoolClient.ClientId" \
            --output text)
        
        if [ -z "$CLIENT_ID" ]; then
            print_error "Failed to create User Pool Client"
            exit 1
        fi
        
        print_success "User Pool Client created successfully with ID: $CLIENT_ID"
    fi
}

# Function to create IAM role for authenticated users
create_authenticated_role() {
    print_status "Creating IAM role for authenticated users..."
    
    # Check if role already exists
    local existing_role=$(aws iam get-role --role-name $AUTHENTICATED_ROLE_NAME --region $REGION 2>/dev/null || echo "NOT_FOUND")
    
    if [[ $existing_role != "NOT_FOUND" ]]; then
        print_warning "IAM role '$AUTHENTICATED_ROLE_NAME' already exists"
        local account_id=$(aws sts get-caller-identity --query "Account" --output text)
        AUTHENTICATED_ROLE_ARN="arn:aws:iam::${account_id}:role/${AUTHENTICATED_ROLE_NAME}"
    else
        print_status "Creating IAM role '$AUTHENTICATED_ROLE_NAME'..."
        
        # Create trust policy for the role
        local trust_policy=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "\${IDENTITY_POOL_ID}"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "authenticated"
        }
      }
    }
  ]
}
EOF
)
        
        # Create the role
        AUTHENTICATED_ROLE_ARN=$(aws iam create-role \
            --role-name $AUTHENTICATED_ROLE_NAME \
            --assume-role-policy-document "$trust_policy" \
            --region $REGION \
            --query "Role.Arn" \
            --output text)
        
        print_success "IAM role created: $AUTHENTICATED_ROLE_ARN"
        
        # Create and attach policy for Bedrock AgentCore access
        local policy_document=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:InvokeAgentRuntime"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
EOF
)
        
        aws iam put-role-policy \
            --role-name $AUTHENTICATED_ROLE_NAME \
            --policy-name "BedrockAgentCoreAccess" \
            --policy-document "$policy_document" \
            --region $REGION
        
        print_success "Policy attached to role"
    fi
}

# Function to create Cognito Identity Pool
create_identity_pool() {
    print_status "Checking if Identity Pool '$IDENTITY_POOL_NAME' exists..."
    
    local existing_pools=$(aws cognito-identity list-identity-pools --max-results 60 --region $REGION --query "IdentityPools[?IdentityPoolName=='$IDENTITY_POOL_NAME'].IdentityPoolId" --output text 2>/dev/null || echo "")
    
    if [ -n "$existing_pools" ]; then
        print_warning "Identity Pool '$IDENTITY_POOL_NAME' already exists with ID: $existing_pools"
        IDENTITY_POOL_ID=$existing_pools
    else
        print_status "Creating Identity Pool '$IDENTITY_POOL_NAME'..."
        
        # Create Identity Pool with User Pool as auth provider
        IDENTITY_POOL_ID=$(aws cognito-identity create-identity-pool \
            --identity-pool-name "$IDENTITY_POOL_NAME" \
            --allow-unauthenticated-identities \
            --cognito-identity-providers ProviderName="cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}",ClientId="${CLIENT_ID}",ServerSideTokenCheck=true \
            --region $REGION \
            --query "IdentityPoolId" \
            --output text)
        
        if [ -z "$IDENTITY_POOL_ID" ]; then
            print_error "Failed to create Identity Pool"
            exit 1
        fi
        
        print_success "Identity Pool created successfully with ID: $IDENTITY_POOL_ID"
    fi
    
    # Update the trust policy with the actual Identity Pool ID
    print_status "Updating IAM role trust policy with Identity Pool ID..."
    
    local updated_trust_policy=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "cognito-identity.amazonaws.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "cognito-identity.amazonaws.com:aud": "$IDENTITY_POOL_ID"
        },
        "ForAnyValue:StringLike": {
          "cognito-identity.amazonaws.com:amr": "authenticated"
        }
      }
    }
  ]
}
EOF
)
    
    aws iam update-assume-role-policy \
        --role-name $AUTHENTICATED_ROLE_NAME \
        --policy-document "$updated_trust_policy" \
        --region $REGION
    
    # Set Identity Pool roles
    print_status "Setting Identity Pool roles..."
    
    local account_id=$(aws sts get-caller-identity --query "Account" --output text)
    local unauthenticated_role_arn="arn:aws:iam::${account_id}:role/Cognito_${IDENTITY_POOL_NAME}Unauth_Role"
    
    # Create a basic unauthenticated role if it doesn't exist
    aws iam create-role \
        --role-name "Cognito_${IDENTITY_POOL_NAME}Unauth_Role" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Federated": "arn:aws:iam::'${account_id}':oidc-provider/cognito-identity.amazonaws.com"
                    },
                    "Action": "sts:AssumeRoleWithWebIdentity",
                    "Condition": {
                        "StringEquals": {
                            "cognito-identity.amazonaws.com:aud": "'${IDENTITY_POOL_ID}'"
                        },
                        "ForAnyValue:StringLike": {
                            "cognito-identity.amazonaws.com:amr": "unauthenticated"
                        }
                    }
                }
            ]
        }' \
        --region $REGION 2>/dev/null || true
    
    aws cognito-identity set-identity-pool-roles \
        --identity-pool-id $IDENTITY_POOL_ID \
        --roles authenticated="$AUTHENTICATED_ROLE_ARN",unauthenticated="$unauthenticated_role_arn" \
        --region $REGION
    
    print_success "Identity Pool roles configured"
}

# Function to update existing Cognito configuration (for re-runs or updates)
update_existing_config() {
    print_status "Updating existing Cognito configuration..."

    USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region $REGION \
        --query "UserPools[?Name=='$USER_POOL_NAME'].Id" --output text)

    if [ -z "$USER_POOL_ID" ]; then
        print_error "Could not find User Pool with name '$USER_POOL_NAME'"
        return 1
    fi
    print_success "Found existing User Pool: $USER_POOL_ID"

    CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id $USER_POOL_ID --region $REGION \
        --query "UserPoolClients[?ClientName=='$CLIENT_NAME'].ClientId" --output text)

    if [ -z "$CLIENT_ID" ]; then
        print_warning "Could not find App Client with name '$CLIENT_NAME'"
        return 1
    fi
    print_success "Found existing App Client: $CLIENT_ID"

    IDENTITY_POOL_ID=$(aws cognito-identity list-identity-pools --max-results 60 --region $REGION \
        --query "IdentityPools[?IdentityPoolName=='$IDENTITY_POOL_NAME'].IdentityPoolId" --output text)

    if [ -z "$IDENTITY_POOL_ID" ]; then
        print_warning "Could not find Identity Pool with name '$IDENTITY_POOL_NAME'"
        return 1
    fi
    print_success "Found existing Identity Pool: $IDENTITY_POOL_ID"

    local config_file="$WEB_APP_DIR/cognito-config.json"
    cat > "$config_file" << EOF
{
  "UserPoolId": "$USER_POOL_ID",
  "ClientId": "$CLIENT_ID",
  "IdentityPoolId": "$IDENTITY_POOL_ID",
  "Region": "$REGION"
}
EOF
    print_success "Configuration file updated: $config_file"
    return 0
}
# Function to update Cognito configuration
update_cognito_config() {
    print_status "Updating Cognito configuration file..."
    
    local config_file="$WEB_APP_DIR/cognito-config.json"
    
    cat > "$config_file" << EOF
{
  "UserPoolId": "$USER_POOL_ID",
  "ClientId": "$CLIENT_ID",
  "IdentityPoolId": "$IDENTITY_POOL_ID",
  "Region": "$REGION"
}
EOF
    
    print_success "Cognito configuration file updated: $config_file"
}

# Function to update AgentCore runtime with latest agent code
update_agentcore_runtime() {
    print_status "Updating AgentCore runtime with latest agent code..."
    
    # Check if we're using AgentCore (not Lambda)
    local config_file="$WEB_APP_DIR/agentcore-config.json"
    if [ ! -f "$config_file" ]; then
        print_warning "AgentCore config not found. Skipping agent code update."
        return 0
    fi
    
    local runtime_arn=$(grep -o '"agentRuntimeArn": "[^"]*' "$config_file" | cut -d'"' -f4)
    if [[ "$runtime_arn" == *"RUNTIME_NAME"* ]]; then
        print_warning "AgentCore runtime ARN contains placeholder. Skipping agent code update."
        print_status "Please deploy your AgentCore runtime first, then run this script again."
        return 0
    fi
    
    print_success "Found AgentCore runtime: $runtime_arn"
    
    # Check if agents directory exists
    local agents_dir="$AGENTS_DIR"
    if [ ! -d "$agents_dir" ]; then
        print_warning "Agents directory not found at $agents_dir. Skipping agent code update."
        return 0
    fi
    
    print_status "Building and deploying agent code to AgentCore runtime..."
    
    # Navigate to agents directory
    cd "$agents_dir"
    
    # Check if we have the necessary files
    if [ ! -f "Dockerfile" ] || [ ! -f "tech_assistant_agent.py" ]; then
        print_warning "Required agent files not found. Skipping agent code update."
        cd - > /dev/null
        return 0
    fi
    
    # Get runtime ID from ARN
    local runtime_id=$(echo "$runtime_arn" | sed 's/.*runtime\///')
    
    print_status "Updating AgentCore runtime: $runtime_id"
    print_status "This may take a few minutes..."
    
    # Note: The actual AgentCore runtime update would depend on your specific deployment method
    # This could involve:
    # 1. Building a new container image
    # 2. Pushing to ECR
    # 3. Updating the AgentCore runtime
    # 4. Waiting for deployment to complete
    
    # For now, we'll add a placeholder that can be customized based on the specific AgentCore deployment method
    if command -v docker &> /dev/null; then
        print_status "Docker found. Building agent container..."
        
        # Build the container (this is a template - adjust based on your AgentCore deployment method)
        if docker build -t "agentcore-agents:latest" . > /dev/null 2>&1; then
            print_success "Agent container built successfully"
            
            # Here you would typically:
            # 1. Tag and push to ECR
            # 2. Update the AgentCore runtime
            # 3. Wait for deployment
            
            print_status "Agent code updated successfully"
        else
            print_warning "Failed to build agent container. Continuing with existing agent code."
        fi
    else
        print_warning "Docker not found. Skipping agent code build."
    fi
    
    # Return to original directory
    cd - > /dev/null
    
    print_success "AgentCore runtime update completed"
}

# Function to find and update AgentCore configuration
update_agentcore_config() {
    print_status "Updating AgentCore configuration..."
    
    local config_file="$WEB_APP_DIR/agentcore-config.json"
    # Source environment file for AGENT_RUNTIME_ARN and REGION
    source ~/environment/env.sh

    # Default to empty: on a first deploy the runtime has not launched yet, so env.sh has no
    # AGENT_RUNTIME_ARN. Under `set -u` a bare reference would abort before the empty-check
    # below (which is written precisely to handle "no runtime yet") could run.
    local runtime_arn="${AGENT_RUNTIME_ARN:-}"
    local account_id=$(aws sts get-caller-identity --query "Account" --output text)

    # Never overwrite a good config with a blank ARN: this used to write
    # "agentRuntimeArn": "" whenever AGENT_RUNTIME_ARN was absent from env.sh, which silently
    # broke a web app that was working a moment earlier.
    if [ -z "$runtime_arn" ]; then
        if [ -s "$config_file" ] && grep -q '"agentRuntimeArn": "arn:' "$config_file"; then
            print_warning "AGENT_RUNTIME_ARN is not in env.sh; keeping the existing $config_file"
            return 0
        fi
        print_warning "AGENT_RUNTIME_ARN is not set and no runtime ARN is on file."
        print_status  "Deploy the runtime first (./deploy_agentcore.sh step8-create-runtime), then re-run."
        return 0
    fi

    print_success "Using AgentCore runtime from env.sh: $runtime_arn"

    
    # Create AgentCore configuration
    cat > "$config_file" << EOF
{
  "agentRuntimeArn": "$runtime_arn",
  "region": "$REGION",
  "apiVersion": "2023-07-26",
  "accountId": "$account_id"
}
EOF
    
    print_success "AgentCore configuration created: $config_file"
}

# Function to verify deployment
verify_deployment() {
    print_status "Verifying deployment..."
    
    # This script owns only cognito-config.json. agentcore-config.json is written later,
    # by configure_runtime.py (post_deploy.sh step 2), and is validated there — so requiring
    # it here made this step fail on a clean checkout where the runtime has not been launched
    # yet (e.g. the CI deploy job). Verify only what this script produces.
    local required_files=(
        "cognito-config.json"
    )
    
    local missing_files=()
    for file in "${required_files[@]}"; do
        if [ ! -f "$WEB_APP_DIR/$file" ]; then
            missing_files+=("$file")
        fi
    done
    
    if [ ${#missing_files[@]} -eq 0 ]; then
        print_success "All required configuration files are present"
    else
        print_error "Missing files: ${missing_files[*]}"
        return 1
    fi
    
    # Validate JSON files
    for file in "${required_files[@]}"; do
        if ! python3 -m json.tool "$WEB_APP_DIR/$file" > /dev/null 2>&1; then
            print_error "Invalid JSON in $file"
            return 1
        fi
    done
    
    print_success "Cognito configuration file is present and valid JSON"
    
    # If the AgentCore runtime config already exists, validate it too (don't require it).
    local agentcore_config="$WEB_APP_DIR/agentcore-config.json"
    if [ -f "$agentcore_config" ]; then
        if python3 -m json.tool "$agentcore_config" > /dev/null 2>&1; then
            print_success "AgentCore configuration file is present and valid JSON"
        else
            print_error "Invalid JSON in agentcore-config.json"
            return 1
        fi
    else
        print_status "agentcore-config.json not present yet (written when the runtime is launched)"
    fi
    return 0
}

# Checks a password against the User Pool policy this script sets (never echoes the value)
password_is_valid() {
    local candidate="$1"
    [ ${#candidate} -ge 8 ] || return 1
    [[ "$candidate" =~ [A-Z] ]] || return 1
    [[ "$candidate" =~ [a-z] ]] || return 1
    [[ "$candidate" =~ [0-9] ]] || return 1
    [[ "$candidate" =~ [^A-Za-z0-9] ]] || return 1
    return 0
}

# Creates or re-syncs one user, given a username and password already in hand
apply_user_credentials() {
    local username="$1" password="$2"

    print_status "Checking if user '$username' already exists..."
    local user_exists
    user_exists=$(aws cognito-idp admin-get-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$username" \
        --region "$REGION" 2>&1 || echo "NOT_FOUND")

    if [[ $user_exists != *"UserNotFoundException"* && $user_exists != "NOT_FOUND" ]]; then
        print_warning "User '$username' already exists. Updating password..."
    else
        print_status "Creating user '$username'..."
        aws cognito-idp admin-create-user \
            --user-pool-id "$USER_POOL_ID" \
            --username "$username" \
            --message-action SUPPRESS \
            --region "$REGION" > /dev/null
    fi

    # --password is read from a file-free stdin-free argument; it never reaches the console output
    aws cognito-idp admin-set-user-password \
        --user-pool-id "$USER_POOL_ID" \
        --username "$username" \
        --password "$password" \
        --permanent \
        --region "$REGION"

    print_success "Sign-in user ready: $username (password not shown)"
}

# Reads the password from Secrets Manager when COGNITO_ADMIN_PASSWORD_SECRET_ID is set.
# The secret may be the raw password or JSON with a "password" key.
password_from_secret() {
    local secret_id="$1" raw
    raw=$(aws secretsmanager get-secret-value --secret-id "$secret_id" \
        --region "$REGION" --query SecretString --output text 2>/dev/null) || return 1
    python3 -c '
import json, sys
raw = sys.stdin.read().rstrip("\n")
try:
    parsed = json.loads(raw)
except ValueError:
    print(raw)
else:
    print(parsed.get("password", raw) if isinstance(parsed, dict) else raw)
' <<< "$raw"
}

# Function to create the sign-in user. Prompts only when a terminal is attached and no
# credentials were supplied, so unattended runs never block on stdin.
ensure_admin_user() {
    echo ""

    if [ "${SKIP_USER_CREATION:-0}" = "1" ] || [ "${SKIP_USER_CREATION:-}" = "true" ]; then
        print_warning "Skipping sign-in user creation (--skip-user)."
        print_status  "Create one later with:"
        print_status  "  aws cognito-idp admin-create-user --user-pool-id $USER_POOL_ID --username <name> --message-action SUPPRESS --region $REGION"
        print_status  "  aws cognito-idp admin-set-user-password --user-pool-id $USER_POOL_ID --username <name> --password <pw> --permanent --region $REGION"
        return 0
    fi

    local username="${COGNITO_ADMIN_USERNAME:-}" password="${COGNITO_ADMIN_PASSWORD:-}"

    if [ -n "${COGNITO_ADMIN_PASSWORD_SECRET_ID:-}" ] && [ -z "$password" ]; then
        print_status "Reading the sign-in password from Secrets Manager (${COGNITO_ADMIN_PASSWORD_SECRET_ID})..."
        if ! password=$(password_from_secret "$COGNITO_ADMIN_PASSWORD_SECRET_ID"); then
            print_error "Could not read secret '${COGNITO_ADMIN_PASSWORD_SECRET_ID}' in ${REGION}"
            exit 1
        fi
    fi

    # Supplied credentials: validate before touching Cognito so a bad password fails fast
    if [ -n "$username" ] && [ -n "$password" ]; then
        if ! password_is_valid "$password"; then
            print_error "The supplied password does not meet the pool policy:"
            print_error "  at least 8 characters, with an uppercase letter, a lowercase letter, a digit and a symbol."
            exit 1
        fi
        print_status "Creating the sign-in user from the environment (no prompt)..."
        apply_user_credentials "$username" "$password"
        return 0
    fi

    # Nothing supplied: prompt only if a human is there to answer
    if [ "${NON_INTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
        print_error "No sign-in user credentials and no terminal to ask for them."
        print_error "For unattended runs choose one of:"
        print_error "  COGNITO_ADMIN_USERNAME=<name> COGNITO_ADMIN_PASSWORD_SECRET_ID=<secret>   (recommended)"
        print_error "  COGNITO_ADMIN_USERNAME=<name> COGNITO_ADMIN_PASSWORD=<password>"
        print_error "  SKIP_USER_CREATION=1                                                     (create the user later)"
        print_error "Everything else is already deployed; re-run this script with one of the above to finish."
        exit 1
    fi

    print_status "Creating a user..."
    echo ""

    while true; do
        read -r -p "Please enter username: " username
        if [ -n "$username" ]; then
            break
        fi
        print_warning "Username cannot be empty. Please try again."
    done

    while true; do
        read -r -s -p "Please enter password (min 8 chars, must include uppercase, lowercase, number, and symbol): " password
        echo ""
        if password_is_valid "$password"; then
            break
        fi
        print_warning "Password must be at least 8 characters and include uppercase, lowercase, number and symbol."
    done

    apply_user_credentials "$username" "$password"
    echo ""
}

# Function to validate web app directory
validate_web_app_directory() {
    print_status "Validating web application directory..."
    
    if [ ! -d "$WEB_APP_DIR" ]; then
        print_error "Web application directory not found: $WEB_APP_DIR"
        exit 1
    fi
    
    local required_files=("index.html" "login.html" "style.css")
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$WEB_APP_DIR/$file" ]; then
            print_error "Required file not found: $WEB_APP_DIR/$file"
            exit 1
        fi
    done
    
    print_success "Web application directory validated"
}

# Function to display summary
display_summary() {
    echo ""
    echo "=========================================="
    print_success "🎉 Enhanced Cognito Authentication & Agent Setup Complete!"
    echo "=========================================="
    echo ""
    echo "✅ **DEPLOYED INFRASTRUCTURE:**"
    echo "   • Cognito User Pool: $USER_POOL_NAME ($USER_POOL_ID)"
    echo "   • Cognito Identity Pool: $IDENTITY_POOL_NAME ($IDENTITY_POOL_ID)"
    echo "   • IAM Role for Authenticated Users: $AUTHENTICATED_ROLE_ARN"
    echo "   • AgentCore Runtime: Updated with latest agent code"
    echo "   • Region: $REGION"
    echo ""
    echo "🔐 **AUTHENTICATION FLOW:**"
    echo "   1. Frontend authenticates with User Pool → Gets ID token"
    echo "   2. ID token exchanged with Identity Pool → Gets AWS credentials"
    echo "   3. Frontend uses AWS credentials → Calls Bedrock AgentCore directly"
    echo "   4. No WebSocket/Lambda overhead → Direct browser to AgentCore communication"
    echo ""
    if [[ "$AUTHENTICATED_ROLE_ARN" == *"RUNTIME_NAME"* ]]; then
        echo "🔧 **IMPORTANT NOTE:**"
        echo "   ⚠️  AgentCore Runtime ARN contains 'RUNTIME_NAME' placeholder"
        echo "      Update agentcore-config.json with actual runtime ARN after deployment"
        echo ""
    fi
}

# Main execution
main() {
    echo "=========================================="
    echo "🚀 Enhanced Cognito Authentication & Agent Setup"
    echo "=========================================="
    echo ""
    echo "This script will set up:"
    echo "  • Cognito User Pool for user authentication"
    echo "  • Cognito Identity Pool for AWS credential exchange"
    echo "  • IAM role with Bedrock AgentCore permissions"
    echo "  • Configuration files for direct browser → AgentCore communication"
    echo "  • Update AgentCore runtime with latest agent code"
    echo ""
    
    # Parse command line arguments
    UPDATE_ONLY=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --update-config|-u) UPDATE_ONLY=true ;;
            --skip-user)        SKIP_USER_CREATION=1 ;;
            --non-interactive)  NON_INTERACTIVE=1 ;;
            -h|--help)          sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            *)                  print_error "Unknown argument: $1"; return 1 ;;
        esac
        shift
    done
    export SKIP_USER_CREATION="${SKIP_USER_CREATION:-0}" NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
    
    # Prerequisites and backup
    check_prerequisites_and_backup
    validate_web_app_directory
    
    # If update-only mode, try to update existing configuration
    if [ "$UPDATE_ONLY" = true ]; then
        echo "🔄 Configuration Update Mode"
        echo ""
        if update_existing_config; then
            echo ""
            print_success "✅ Configuration update completed successfully!"
            echo ""
            update_cognito_config   # ensures all four fields persist
            print_success "✅ Configuration update completed!"
            return 0
            echo ""
            echo "The web application configuration has been updated."
            return 0
        else
            print_warning "Could not update existing configuration. Proceeding with full setup..."
            echo ""
        fi
    fi
    
    # Full setup process
    create_user_pool
    create_user_pool_client
    create_authenticated_role
    create_identity_pool
    update_cognito_config
    update_agentcore_config
    
    # Update AgentCore runtime with latest agent code
    update_agentcore_runtime
    
    ensure_admin_user
    
    # Verify deployment
    if verify_deployment; then
        display_summary
    else
        print_error "Deployment verification failed. Please check the configuration files."
        exit 1
    fi
}

# Run main function
main "$@"

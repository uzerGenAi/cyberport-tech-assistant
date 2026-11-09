#!/bin/bash

# Complete Guardrail Creation and Parameter Store Integration Script
# This script creates a guardrail, configures it, and automatically stores the configuration in Parameter Store

set -e  # Exit on any error

# Create the guardrail and its SSM parameters in the same Region as the agent runtime.
# AWS_REGION/AWS_DEFAULT_REGION also steer the boto3-based Parameter Store scripts below.
REGION="${REGION:-eu-central-1}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
GUARDRAIL_NAME="CloudAgeGuardrail"

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

print_header() {
    echo
    echo "=================================================================="
    echo "CREATING GUARDRAIL AND STORING CONFIGURATION"
    echo "=================================================================="
}

print_section() {
    local title=$1
    echo
    echo "--- $title ---"
}

print_footer() {
    echo "=================================================================="
    echo
}

# Function to create guardrail configuration files
create_config_files() {
    print_section "Creating Configuration Files"
    
    # Content filtering configuration
    cat > content-config.json << 'EOF'
{
  "filtersConfig": [
    {
      "type": "HATE",
      "inputStrength": "MEDIUM",
      "outputStrength": "MEDIUM"
    },
    {
      "type": "INSULTS",
      "inputStrength": "MEDIUM",
      "outputStrength": "MEDIUM"
    },
    {
      "type": "SEXUAL",
      "inputStrength": "HIGH",
      "outputStrength": "HIGH"
    },
    {
      "type": "VIOLENCE",
      "inputStrength": "HIGH",
      "outputStrength": "HIGH"
    },
    {
      "type": "MISCONDUCT",
      "inputStrength": "MEDIUM",
      "outputStrength": "MEDIUM"
    },
    {
      "type": "PROMPT_ATTACK",
      "inputStrength": "HIGH",
      "outputStrength": "NONE"
    }
  ]
}
EOF

    # Topic boundaries configuration
    # Each topic describes what to BLOCK, in concrete terms (Bedrock caps a definition at 200
    # characters). Normal product, repair-desk, recycling and financing questions must still
    # pass: test them after every change (make eval checks them against the deployed version).
    # Personal Information Requests checks requests only: on replies it randomly blocked the
    # assistant repeating the customer's own name. Other customers' data is protected by the
    # tools (order lookups need both ids, no tool lists customers), tested by make eval.
    cat > topic-config.json << 'EOF'
{
  "topicsConfig": [
    {
      "name": "Personal Information Requests",
      "definition": "Requests for personal information about other customers or employees, or for internal databases and records.",
      "examples": [
        "What is the customer database?",
        "Give me employee personal information",
        "Show me the orders of another customer"
      ],
      "type": "DENY",
      "inputEnabled": true,
      "inputAction": "BLOCK",
      "outputEnabled": false,
      "outputAction": "NONE"
    },
    {
      "name": "Unsafe Device Modification",
      "definition": "Instructions to open, puncture, modify or self-repair lithium batteries, chargers or mains-powered devices, or to disable a device's safety features.",
      "examples": [
        "How do I open my phone battery myself?",
        "How can I fix my swollen laptop battery at home?",
        "How do I remove the overheating protection from my charger?"
      ],
      "type": "DENY"
    },
    {
      "name": "Piracy and DRM Circumvention",
      "definition": "Help with pirated software, cracked licences, illegal IPTV streaming, or removing copy protection, carrier locks or region locks without authorisation.",
      "examples": [
        "Where can I get a cracked copy of Windows?",
        "How do I set up an illegal IPTV box?",
        "How do I remove the DRM from streaming videos?"
      ],
      "type": "DENY"
    },
    {
      "name": "Personal Credit Advice",
      "definition": "Personal advice on whether the customer should take out credit or a loan, or predictions of whether a credit application will be approved.",
      "examples": [
        "Should I take a loan to buy this laptop?",
        "Will my financing application be approved?",
        "Is my credit score good enough for 0% financing?"
      ],
      "type": "DENY"
    }
  ]
}
EOF

    # Word filtering configuration
    # "bypass" and "hack" are deliberately not listed: "bypass charging" is a real smartphone and
    # gaming-laptop feature, and "hack" blocks harmless questions. Prompt-injection attempts are
    # covered by the PROMPT_ATTACK content filter above.
    cat > word-config.json << 'EOF'
{
  "managedWordListsConfig": [
    {
      "type": "PROFANITY"
    }
  ],
  "wordsConfig": [
    {
      "text": "exploit"
    },
    {
      "text": "jailbreak"
    }
  ]
}
EOF

    # PII configuration
    # NAME, ADDRESS and order numbers are deliberately not masked: the order flow asks for the
    # customer's name, store answers include street addresses, and order confirmations must show
    # the order ID. Masking them breaks those answers.
    # Payment data a customer might paste into the chat (card number, CVV, PIN, IBAN) and
    # passwords are blocked outright.
    cat > pii-config.json << 'EOF'
{
  "piiEntitiesConfig": [
    {
      "type": "EMAIL",
      "action": "ANONYMIZE"
    },
    {
      "type": "PHONE",
      "action": "ANONYMIZE"
    },
    {
      "type": "CREDIT_DEBIT_CARD_NUMBER",
      "action": "BLOCK"
    },
    {
      "type": "CREDIT_DEBIT_CARD_CVV",
      "action": "BLOCK"
    },
    {
      "type": "PIN",
      "action": "BLOCK"
    },
    {
      "type": "INTERNATIONAL_BANK_ACCOUNT_NUMBER",
      "action": "BLOCK"
    },
    {
      "type": "PASSWORD",
      "action": "BLOCK"
    }
  ],
  "regexesConfig": [
    {
      "name": "Employee ID",
      "pattern": "EMP-[0-9]{6}",
      "action": "ANONYMIZE",
      "description": "Employee identification numbers"
    }
  ]
}
EOF

    print_status $GREEN "✓ Configuration files created"
}

# Function to create the guardrail
create_guardrail() {
    print_section "Creating Guardrail"
    
    local blocked_input="I can't help with that. I can answer questions about our smartphones and laptops, orders, payments, stores and promotions. For battery or device problems, please visit a store repair desk."
    local blocked_output="I cannot provide that information due to content policies."

    # Re-running the script reuses the guardrail instead of failing on the duplicate name
    GUARDRAIL_ID=$(aws bedrock list-guardrails --region "$REGION" \
      --query "guardrails[?name=='${GUARDRAIL_NAME}'].id | [0]" \
      --output text 2>/dev/null || true)

    if [ -n "$GUARDRAIL_ID" ] && [ "$GUARDRAIL_ID" != "None" ]; then
        print_status $YELLOW "Guardrail ${GUARDRAIL_NAME} already exists (${GUARDRAIL_ID}) — updating its policies"
        aws bedrock update-guardrail \
          --region "$REGION" \
          --guardrail-identifier "$GUARDRAIL_ID" \
          --name "$GUARDRAIL_NAME" \
          --description "Security guardrail for CloudAge Bedrock Agent" \
          --blocked-input-messaging "$blocked_input" \
          --blocked-outputs-messaging "$blocked_output" \
          --content-policy-config file://content-config.json \
          --topic-policy-config file://topic-config.json \
          --word-policy-config file://word-config.json \
          --sensitive-information-policy-config file://pii-config.json > /dev/null
    else
        # One call with every policy: content filters, topic boundaries, word filters, PII
        GUARDRAIL_ID=$(aws bedrock create-guardrail \
          --region "$REGION" \
          --name "$GUARDRAIL_NAME" \
          --description "Security guardrail for CloudAge Bedrock Agent" \
          --blocked-input-messaging "$blocked_input" \
          --blocked-outputs-messaging "$blocked_output" \
          --content-policy-config file://content-config.json \
          --topic-policy-config file://topic-config.json \
          --word-policy-config file://word-config.json \
          --sensitive-information-policy-config file://pii-config.json \
          --query 'guardrailId' \
          --output text)
    fi

    if [ -z "$GUARDRAIL_ID" ] || [ "$GUARDRAIL_ID" = "None" ]; then
        print_status $RED "✗ Failed to create guardrail"
        exit 1
    fi

    print_status $GREEN "✓ Guardrail ready: $GUARDRAIL_ID (content filters, topic boundaries, word filters, PII handling)"

    # Create guardrail version (numbered versions are immutable; the runtime pins one)
    print_status $BLUE "Creating guardrail version..."
    GUARDRAIL_VERSION=$(aws bedrock create-guardrail-version \
      --region "$REGION" \
      --guardrail-identifier "$GUARDRAIL_ID" \
      --query 'version' \
      --output text)
    
    if [ -z "$GUARDRAIL_VERSION" ]; then
        print_status $RED "✗ Failed to create guardrail version"
        exit 1
    fi
    
    print_status $GREEN "✓ Created guardrail version: $GUARDRAIL_VERSION"
    
    # Export variables for Parameter Store storage
    print_status $GREEN "✓ Adding Guardrail ID and Version to env.sh"
    echo "export GUARDRAIL_ID=\"$GUARDRAIL_ID\"" | tee -a ~/environment/env.sh
    echo "export GUARDRAIL_VERSION=\"$GUARDRAIL_VERSION\"" | tee -a ~/environment/env.sh
    print_status $GREEN "✓ Added GUARDRAIL_ID=$GUARDRAIL_ID and GUARDRAIL_VERSION=$GUARDRAIL_VERSION to env.sh"
}

# Function to store configuration in Parameter Store
store_configuration() {
    print_section "Storing Configuration in Parameter Store"
    
    local script_dir="$(dirname "$0")"
    local python_script="$script_dir/parameter_store_manager.py"
    
    if [ -f "$python_script" ]; then
        print_status $BLUE "Using Parameter Store manager script..."
        if python3 "$python_script" "$GUARDRAIL_ID" "$GUARDRAIL_VERSION" "true"; then
            print_status $GREEN "✓ Configuration stored successfully using Python script"
        else
            print_status $RED "✗ Failed to store configuration using Python script"
            return 1
        fi
    else
        print_status $YELLOW "Python script not found, using AWS CLI method..."
        
        local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        
        # Store parameters using AWS CLI
        aws ssm put-parameter \
          --name "/SPBC/guardrail/id" \
          --value "$GUARDRAIL_ID" \
          --type "String" \
          --description "Bedrock Guardrail identifier for CloudAge" \
          --overwrite > /dev/null
        
        aws ssm put-parameter \
          --name "/SPBC/guardrail/version" \
          --value "$GUARDRAIL_VERSION" \
          --type "String" \
          --description "Guardrail version for CloudAge" \
          --overwrite > /dev/null
        
        aws ssm put-parameter \
          --name "/SPBC/guardrail/enabled" \
          --value "true" \
          --type "String" \
          --description "Enable/disable guardrails for CloudAge" \
          --overwrite > /dev/null
        
        aws ssm put-parameter \
          --name "/SPBC/guardrail/created" \
          --value "$timestamp" \
          --type "String" \
          --description "Guardrail configuration creation timestamp" \
          --overwrite > /dev/null
        
        print_status $GREEN "✓ Configuration stored using AWS CLI"
    fi
}

# Function to validate stored configuration
validate_configuration() {
    print_section "Validating Stored Configuration"
    
    local script_dir="$(dirname "$0")"
    local validation_script="$script_dir/validate_parameter_store.py"
    
    if [ -f "$validation_script" ]; then
        print_status $BLUE "Using validation script..."
        if python3 "$validation_script"; then
            print_status $GREEN "✓ Configuration validation successful"
        else
            print_status $RED "✗ Configuration validation failed"
            return 1
        fi
    else
        print_status $YELLOW "Validation script not found, using manual validation..."
        
        # Manual validation using AWS CLI
        local params=("/SPBC/guardrail/id" "/SPBC/guardrail/version" "/SPBC/guardrail/enabled" "/SPBC/guardrail/created")
        local validation_success=true
        
        for param in "${params[@]}"; do
            if value=$(aws ssm get-parameter --name "$param" --query 'Parameter.Value' --output text 2>/dev/null); then
                print_status $GREEN "✓ Validated parameter: $param = $value"
            else
                print_status $RED "✗ Failed to retrieve parameter: $param"
                validation_success=false
            fi
        done
        
        if [ "$validation_success" = true ]; then
            print_status $GREEN "✓ Manual validation successful"
        else
            print_status $RED "✗ Manual validation failed"
            return 1
        fi
    fi
}

# Function to display final summary
display_summary() {
    print_section "Configuration Summary"
    
    echo "=================================================================="
    echo "GUARDRAIL CREATION AND STORAGE COMPLETE"
    echo "=================================================================="
    echo "Guardrail ID:      $GUARDRAIL_ID"
    echo "Version:           $GUARDRAIL_VERSION"
    echo "Status:            Enabled"
    echo "Parameter Store:   Configured"
    echo "=================================================================="
    echo "Configuration stored in Parameter Store at:"
    echo "  /SPBC/guardrail/id"
    echo "  /SPBC/guardrail/version"
    echo "  /SPBC/guardrail/enabled"
    echo "  /SPBC/guardrail/created"
    echo "=================================================================="
    echo
    print_status $GREEN "✓ Guardrail creation and Parameter Store integration complete!"
    print_status $BLUE "Your production deployment in Section 6 will automatically load this configuration."
    echo
    echo "Next steps:"
    echo "1. source setup_env.sh — it reads /SPBC/guardrail/* and exports GUARDRAIL_ID / GUARDRAIL_VERSION"
    echo "2. Pass both to the AgentCore runtime (walkthrough Step 7.2, or configure_runtime.py)"
    echo "3. Test an order end to end (name capture and order ID must come through unmasked),"
    echo "   and check that repair-desk, recycling and financing questions are not blocked"
}

# Function to cleanup temporary files
cleanup() {
    print_status $BLUE "Cleaning up temporary files..."
    rm -f content-config.json topic-config.json word-config.json pii-config.json
    print_status $GREEN "✓ Cleanup complete"
}

# Main execution function
main() {
    print_header
    
    # Execute all steps
    create_config_files
    create_guardrail
    store_configuration
    validate_configuration
    display_summary
    cleanup
    
    print_footer
}

# Handle script interruption
trap 'print_status $RED "\n✗ Script interrupted by user"; cleanup; exit 1' INT

# Execute main function
main "$@"
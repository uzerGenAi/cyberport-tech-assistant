#!/usr/bin/env python3
"""
Parameter Store Validation Script
Validates that guardrail configuration is properly stored in Parameter Store.
"""

import boto3
import sys
import logging
from datetime import datetime
from botocore.exceptions import ClientError

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def validate_parameter_store_config():
    """
    Validate guardrail configuration in Parameter Store.
    
    Returns:
        bool: True if validation successful, False otherwise
    """
    try:
        # Initialize SSM client
        ssm_client = boto3.client('ssm')
        parameter_prefix = '/SPBC/guardrail'
        
        print("="*60)
        print("PARAMETER STORE VALIDATION")
        print("="*60)
        
        # Required parameters
        required_params = ['id', 'version', 'enabled', 'created']
        param_names = [f"{parameter_prefix}/{param}" for param in required_params]
        
        # Retrieve all parameters
        try:
            response = ssm_client.get_parameters(
                Names=param_names,
                WithDecryption=False
            )
            
            retrieved_params = {param['Name']: param['Value'] for param in response['Parameters']}
            invalid_params = response.get('InvalidParameters', [])
            
            if invalid_params:
                print(f"✗ Missing parameters: {invalid_params}")
                return False
            
            # Display retrieved parameters
            parameter_values = {}
            for param in required_params:
                full_name = f"{parameter_prefix}/{param}"
                if full_name in retrieved_params:
                    parameter_values[param] = retrieved_params[full_name]
                    print(f"✓ {param.upper()}: {retrieved_params[full_name]}")
                else:
                    print(f"✗ Missing parameter: {param}")
                    return False
            
            print("="*60)
            
            # Validate parameter values
            validation_errors = []
            
            # Validate guardrail ID
            if not parameter_values['id'].strip():
                validation_errors.append("Guardrail ID cannot be empty")
            
            # Validate version
            if not parameter_values['version'].strip():
                validation_errors.append("Guardrail version cannot be empty")
            
            # Validate enabled flag
            if parameter_values['enabled'].lower() not in ['true', 'false']:
                validation_errors.append("Enabled flag must be 'true' or 'false'")
            
            # Validate timestamp format
            try:
                datetime.fromisoformat(parameter_values['created'].replace('Z', '+00:00'))
            except ValueError:
                validation_errors.append("Invalid timestamp format")
            
            if validation_errors:
                print("VALIDATION ERRORS:")
                for error in validation_errors:
                    print(f"✗ {error}")
                return False
            
            print("✓ All parameters validated successfully!")
            print("✓ Configuration is ready for production deployment")
            return True
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            if error_code == 'AccessDenied':
                print("✗ Access denied reading parameters")
                print("  Check IAM permissions for ssm:GetParameters")
            else:
                print(f"✗ Failed to retrieve parameters: {e}")
            return False
            
    except Exception as e:
        print(f"✗ Unexpected error: {e}")
        return False

def main():
    """Main function for standalone execution."""
    print("Validating guardrail configuration in Parameter Store...")
    
    success = validate_parameter_store_config()
    
    if success:
        print("\n✓ Parameter Store validation completed successfully!")
        sys.exit(0)
    else:
        print("\n✗ Parameter Store validation failed!")
        print("Please run the guardrail creation and storage process again.")
        sys.exit(1)

if __name__ == "__main__":
    main()
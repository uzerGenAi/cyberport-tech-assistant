#!/usr/bin/env python3
"""
Parameter Store Manager for Guardrail Configuration
Implements storage and validation functions for guardrail configuration in AWS Systems Manager Parameter Store.
"""

import boto3
import json
import logging
from datetime import datetime
from typing import Dict, Optional, Tuple
from botocore.exceptions import ClientError

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class ParameterStoreManager:
    """
    Manages guardrail configuration storage and retrieval from AWS Systems Manager Parameter Store.
    
    Uses parameter naming convention: /SPBC/guardrail/{property}
    """
    
    def __init__(self, region: str = None):
        """
        Initialize Parameter Store Manager.
        
        Args:
            region: AWS region name. If None, uses default region from AWS configuration.
        """
        try:
            self.ssm_client = boto3.client('ssm', region_name=region)
            self.parameter_prefix = '/SPBC/guardrail'
            logger.info(f"Parameter Store Manager initialized for region: {region or 'default'}")
        except Exception as e:
            logger.error(f"Failed to initialize Parameter Store Manager: {e}")
            raise
    
    def store_guardrail_config(self, guardrail_id: str, version: str = "DRAFT", enabled: bool = True) -> bool:
        """
        Store guardrail configuration in Parameter Store.
        
        Args:
            guardrail_id: Bedrock guardrail identifier
            version: Guardrail version (default: "DRAFT")
            enabled: Whether guardrails are enabled (default: True)
            
        Returns:
            bool: True if storage successful, False otherwise
        """
        try:
            # Create timestamp for creation tracking
            creation_timestamp = datetime.utcnow().isoformat() + 'Z'
            
            # Define parameters to store
            parameters = {
                f"{self.parameter_prefix}/id": {
                    "value": guardrail_id,
                    "description": "Bedrock Guardrail identifier for CloudAge"
                },
                f"{self.parameter_prefix}/version": {
                    "value": str(version),
                    "description": "Guardrail version for CloudAge"
                },
                f"{self.parameter_prefix}/enabled": {
                    "value": str(enabled).lower(),
                    "description": "Enable/disable guardrails for CloudAge"
                },
                f"{self.parameter_prefix}/created": {
                    "value": creation_timestamp,
                    "description": "Guardrail configuration creation timestamp"
                }
            }
            
            logger.info("Storing guardrail configuration in Parameter Store...")
            
            # Store each parameter
            for param_name, param_data in parameters.items():
                try:
                    self.ssm_client.put_parameter(
                        Name=param_name,
                        Value=param_data["value"],
                        Type='String',
                        Description=param_data["description"],
                        Overwrite=True
                    )
                    logger.info(f"✓ Stored parameter: {param_name} = {param_data['value']}")
                    
                except ClientError as e:
                    error_code = e.response['Error']['Code']
                    if error_code == 'AccessDenied':
                        logger.error(f"✗ Access denied storing parameter {param_name}. Check IAM permissions for ssm:PutParameter")
                    else:
                        logger.error(f"✗ Failed to store parameter {param_name}: {e}")
                    return False
                    
            logger.info("✓ Guardrail configuration successfully stored in Parameter Store")
            return True
            
        except Exception as e:
            logger.error(f"✗ Unexpected error storing guardrail configuration: {e}")
            return False
    
    def validate_storage(self) -> Tuple[bool, Dict[str, str]]:
        """
        Validate that all required guardrail parameters are stored correctly.
        
        Returns:
            Tuple[bool, Dict[str, str]]: (success_status, parameter_values)
        """
        try:
            logger.info("Validating guardrail configuration in Parameter Store...")
            
            # Required parameters
            required_params = ['id', 'version', 'enabled', 'created']
            parameter_values = {}
            
            # Retrieve all parameters at once for efficiency
            param_names = [f"{self.parameter_prefix}/{param}" for param in required_params]
            
            try:
                response = self.ssm_client.get_parameters(
                    Names=param_names,
                    WithDecryption=False
                )
                
                # Check if all parameters were retrieved
                retrieved_params = {param['Name']: param['Value'] for param in response['Parameters']}
                invalid_params = response.get('InvalidParameters', [])
                
                if invalid_params:
                    logger.error(f"✗ Missing parameters: {invalid_params}")
                    return False, {}
                
                # Extract parameter values with friendly names
                for param in required_params:
                    full_name = f"{self.parameter_prefix}/{param}"
                    if full_name in retrieved_params:
                        parameter_values[param] = retrieved_params[full_name]
                        logger.info(f"✓ Found parameter {param}: {retrieved_params[full_name]}")
                    else:
                        logger.error(f"✗ Missing required parameter: {param}")
                        return False, {}
                
                # Validate parameter values
                validation_errors = []
                
                # Validate guardrail ID (should not be empty)
                if not parameter_values['id'].strip():
                    validation_errors.append("Guardrail ID cannot be empty")
                
                # Validate version (should not be empty)
                if not parameter_values['version'].strip():
                    validation_errors.append("Guardrail version cannot be empty")
                
                # Validate enabled flag (should be 'true' or 'false')
                if parameter_values['enabled'].lower() not in ['true', 'false']:
                    validation_errors.append("Enabled flag must be 'true' or 'false'")
                
                # Validate timestamp format (basic check)
                try:
                    datetime.fromisoformat(parameter_values['created'].replace('Z', '+00:00'))
                except ValueError:
                    validation_errors.append("Invalid timestamp format")
                
                if validation_errors:
                    logger.error(f"✗ Parameter validation errors: {validation_errors}")
                    return False, parameter_values
                
                logger.info("✓ All guardrail parameters validated successfully")
                return True, parameter_values
                
            except ClientError as e:
                error_code = e.response['Error']['Code']
                if error_code == 'AccessDenied':
                    logger.error("✗ Access denied reading parameters. Check IAM permissions for ssm:GetParameters")
                else:
                    logger.error(f"✗ Failed to retrieve parameters: {e}")
                return False, {}
                
        except Exception as e:
            logger.error(f"✗ Unexpected error validating parameters: {e}")
            return False, {}
    
    def display_configuration_summary(self, parameter_values: Dict[str, str]) -> None:
        """
        Display a formatted summary of the stored guardrail configuration.
        
        Args:
            parameter_values: Dictionary of parameter names and values
        """
        print("\n" + "="*60)
        print("GUARDRAIL CONFIGURATION SUMMARY")
        print("="*60)
        print(f"Guardrail ID:      {parameter_values.get('id', 'Not found')}")
        print(f"Version:           {parameter_values.get('version', 'Not found')}")
        print(f"Enabled:           {parameter_values.get('enabled', 'Not found')}")
        print(f"Created:           {parameter_values.get('created', 'Not found')}")
        print("="*60)
        print("Configuration stored in Parameter Store at:")
        for param in ['id', 'version', 'enabled', 'created']:
            print(f"  {self.parameter_prefix}/{param}")
        print("="*60)


def main():
    """
    Main function for standalone execution.
    Demonstrates usage of the ParameterStoreManager class.
    """
    import sys
    
    if len(sys.argv) < 3:
        print("Usage: python parameter_store_manager.py <guardrail_id> <version> [enabled]")
        print("Example: python parameter_store_manager.py abc123def456 1 true")
        sys.exit(1)
    
    guardrail_id = sys.argv[1]
    version = sys.argv[2]
    enabled = sys.argv[3].lower() == 'true' if len(sys.argv) > 3 else True
    
    try:
        # Initialize manager
        manager = ParameterStoreManager()
        
        # Store configuration
        print(f"Storing guardrail configuration...")
        print(f"  ID: {guardrail_id}")
        print(f"  Version: {version}")
        print(f"  Enabled: {enabled}")
        
        success = manager.store_guardrail_config(guardrail_id, version, enabled)
        
        if success:
            print("\n✓ Configuration stored successfully!")
            
            # Validate storage
            print("\nValidating stored configuration...")
            is_valid, params = manager.validate_storage()
            
            if is_valid:
                print("✓ Validation successful!")
                manager.display_configuration_summary(params)
            else:
                print("✗ Validation failed!")
                sys.exit(1)
        else:
            print("✗ Failed to store configuration!")
            sys.exit(1)
            
    except Exception as e:
        logger.error(f"Script execution failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
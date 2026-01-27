"""
Custom Capacity Block Scale-Up Lambda for FlashInfer CI

This Lambda handles scaling up runners for Capacity Block instances (p5, p6).
It operates independently from the upstream terraform-aws-github-runner module,
allowing us to use upstream unmodified while supporting CB-based GPU instances.

Flow:
1. Receive workflow_job event from SQS (routed by EventBridge based on labels)
2. Check for active Capacity Block matching the required instance type
3. If CB found, launch instance into it using RunInstances API
4. Tag instance for scale-down Lambda to find and manage
"""

import json
import logging
import os
import time
from typing import Optional, Dict, Any, List

import boto3
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
AWS_REGION = os.environ.get('AWS_REGION', 'us-west-2')
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'flashinfer')
LAUNCH_TEMPLATE_NAME = os.environ.get('LAUNCH_TEMPLATE_NAME')
SUBNET_IDS = os.environ.get('SUBNET_IDS', '').split(',')
INSTANCE_TYPE = os.environ.get('INSTANCE_TYPE')  # e.g., p6-b200.48xlarge
RUNNER_NAME_PREFIX = os.environ.get('RUNNER_NAME_PREFIX', 'flashinfer-cb-')
SSM_CONFIG_PATH = os.environ.get('SSM_CONFIG_PATH')

# AWS clients
ec2_client = boto3.client('ec2', region_name=AWS_REGION)


class ScaleError(Exception):
    """Error that should trigger SQS retry."""
    pass


def find_active_capacity_block(instance_type: str) -> Optional[Dict[str, Any]]:
    """
    Find an active Capacity Block reservation for the given instance type.
    
    Returns:
        Dict with 'id' and 'az' if found, None otherwise
    """
    try:
        response = ec2_client.describe_capacity_reservations(
            Filters=[
                {'Name': 'state', 'Values': ['active']},
                {'Name': 'instance-type', 'Values': [instance_type]},
            ]
        )
        
        # Find a capacity block with available capacity
        for cr in response.get('CapacityReservations', []):
            if (cr.get('ReservationType') == 'capacity-block' and 
                cr.get('AvailableInstanceCount', 0) > 0):
                cb_id = cr['CapacityReservationId']
                az = cr['AvailabilityZone']
                available = cr['AvailableInstanceCount']
                logger.info(f"Found active CB: {cb_id} in {az} with {available} available")
                return {'id': cb_id, 'az': az, 'available': available}
        
        logger.warning(f"No active Capacity Block found for {instance_type}")
        return None
        
    except ClientError as e:
        logger.error(f"Error describing capacity reservations: {e}")
        raise


def find_subnet_in_az(az: str) -> Optional[str]:
    """Find a subnet in the given availability zone from our configured subnets."""
    try:
        response = ec2_client.describe_subnets(
            SubnetIds=SUBNET_IDS,
            Filters=[{'Name': 'availability-zone', 'Values': [az]}]
        )
        
        subnets = response.get('Subnets', [])
        if subnets:
            subnet_id = subnets[0]['SubnetId']
            logger.info(f"Found subnet {subnet_id} in {az}")
            return subnet_id
        
        logger.warning(f"No subnet found in {az} from configured subnets: {SUBNET_IDS}")
        return None
        
    except ClientError as e:
        logger.error(f"Error describing subnets: {e}")
        raise


def launch_instance_into_cb(
    cb_info: Dict[str, Any],
    subnet_id: str,
    job_info: Dict[str, Any]
) -> str:
    """
    Launch an EC2 instance into the Capacity Block.
    
    Returns:
        Instance ID of the launched instance
    """
    tags = [
        {'Key': 'Name', 'Value': f'{ENVIRONMENT}-cb-action-runner'},
        {'Key': 'ghr:Application', 'Value': 'github-action-runner'},
        {'Key': 'ghr:created_by', 'Value': 'cb-scale-up-lambda'},
        {'Key': 'ghr:environment', 'Value': ENVIRONMENT},
        {'Key': 'ghr:runner_name_prefix', 'Value': RUNNER_NAME_PREFIX},
        {'Key': 'ghr:ssm_config_path', 'Value': SSM_CONFIG_PATH},
        {'Key': 'Environment', 'Value': ENVIRONMENT},
        {'Key': 'Project', 'Value': 'FlashInfer'},
        {'Key': 'ManagedBy', 'Value': 'Terraform'},
    ]
    
    # Add job-specific tags if available
    if job_info.get('repository'):
        tags.append({'Key': 'ghr:repository', 'Value': job_info['repository']})
    if job_info.get('workflow_job_id'):
        tags.append({'Key': 'ghr:workflow_job_id', 'Value': str(job_info['workflow_job_id'])})
    
    try:
        response = ec2_client.run_instances(
            LaunchTemplate={
                'LaunchTemplateName': LAUNCH_TEMPLATE_NAME,
                'Version': '$Default'
            },
            InstanceType=INSTANCE_TYPE,
            SubnetId=subnet_id,
            MinCount=1,
            MaxCount=1,
            InstanceMarketOptions={
                'MarketType': 'capacity-block'
            },
            CapacityReservationSpecification={
                'CapacityReservationTarget': {
                    'CapacityReservationId': cb_info['id']
                }
            },
            TagSpecifications=[
                {
                    'ResourceType': 'instance',
                    'Tags': tags
                },
                {
                    'ResourceType': 'volume',
                    'Tags': tags
                }
            ]
        )
        
        instance_id = response['Instances'][0]['InstanceId']
        logger.info(f"Successfully launched instance {instance_id} into CB {cb_info['id']}")
        return instance_id
        
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', '')
        logger.error(f"Error launching instance: {e}")
        
        # These errors should trigger retry
        retry_errors = [
            'InsufficientInstanceCapacity',
            'RequestLimitExceeded',
            'ServiceUnavailable'
        ]
        if error_code in retry_errors:
            raise ScaleError(f"Retryable error: {error_code}")
        raise


def parse_sqs_message(record: Dict[str, Any]) -> Dict[str, Any]:
    """Parse SQS message to extract job information."""
    try:
        body = json.loads(record['body'])
        return {
            'workflow_job_id': body.get('id'),
            'repository': f"{body.get('repositoryOwner')}/{body.get('repositoryName')}",
            'event_type': body.get('eventType'),
            'installation_id': body.get('installationId'),
        }
    except (json.JSONDecodeError, KeyError) as e:
        logger.error(f"Error parsing SQS message: {e}")
        return {}


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler for CB scale-up.
    
    Receives SQS events and launches instances into active Capacity Blocks.
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Validate required environment variables
    if not LAUNCH_TEMPLATE_NAME:
        raise ValueError("LAUNCH_TEMPLATE_NAME environment variable is required")
    if not INSTANCE_TYPE:
        raise ValueError("INSTANCE_TYPE environment variable is required")
    if not SUBNET_IDS or SUBNET_IDS == ['']:
        raise ValueError("SUBNET_IDS environment variable is required")
    
    results = {
        'successful': [],
        'failed': []
    }
    
    records = event.get('Records', [])
    logger.info(f"Processing {len(records)} SQS record(s)")
    
    for record in records:
        message_id = record.get('messageId', 'unknown')
        
        try:
            job_info = parse_sqs_message(record)
            logger.info(f"Processing job: {job_info}")
            
            # Step 1: Find active Capacity Block
            cb_info = find_active_capacity_block(INSTANCE_TYPE)
            if not cb_info:
                # No CB available - raise ScaleError to trigger SQS retry
                raise ScaleError(f"No active Capacity Block for {INSTANCE_TYPE}")
            
            # Step 2: Find subnet in CB's availability zone
            subnet_id = find_subnet_in_az(cb_info['az'])
            if not subnet_id:
                raise ScaleError(f"No subnet in {cb_info['az']}")
            
            # Step 3: Launch instance into CB
            instance_id = launch_instance_into_cb(cb_info, subnet_id, job_info)
            
            results['successful'].append({
                'message_id': message_id,
                'instance_id': instance_id,
                'capacity_block_id': cb_info['id']
            })
            
        except ScaleError as e:
            # ScaleError should trigger SQS retry via partial batch failure
            logger.warning(f"Scale error for message {message_id}: {e}")
            results['failed'].append({
                'message_id': message_id,
                'error': str(e),
                'retry': True
            })
            
        except Exception as e:
            # Other errors - log but don't retry
            logger.error(f"Error processing message {message_id}: {e}")
            results['failed'].append({
                'message_id': message_id,
                'error': str(e),
                'retry': False
            })
    
    # Return partial batch failure response for SQS
    # This tells SQS which messages to retry
    batch_item_failures = [
        {'itemIdentifier': f['message_id']} 
        for f in results['failed'] 
        if f.get('retry', False)
    ]
    
    response = {
        'statusCode': 200,
        'body': json.dumps(results),
        'batchItemFailures': batch_item_failures
    }
    
    logger.info(f"Response: {json.dumps(response)}")
    return response

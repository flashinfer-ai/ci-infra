"""P4D Scale-Up Lambda - launches p4d.24xlarge spot instances with on-demand fallback."""

import json
import logging
import os
import random
from typing import Optional, Dict, Any, List

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get('REGION', os.environ.get('AWS_REGION', 'us-west-2'))
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'flashinfer')
LAUNCH_TEMPLATE_NAME = os.environ.get('LAUNCH_TEMPLATE_NAME')
SUBNET_IDS = os.environ.get('SUBNET_IDS', '').split(',')
INSTANCE_TYPE = os.environ.get('INSTANCE_TYPE', 'p4d.24xlarge')
RUNNER_NAME_PREFIX = os.environ.get('RUNNER_NAME_PREFIX', 'flashinfer-p4d-')
SSM_CONFIG_PATH = os.environ.get('SSM_CONFIG_PATH')

ec2_client = boto3.client('ec2', region_name=REGION)

SPOT_FAILOVER_ERRORS = [
    'InsufficientInstanceCapacity',
    'SpotMaxPriceTooLow',
    'MaxSpotInstanceCountExceeded',
]

RETRY_ERRORS = [
    'RequestLimitExceeded',
    'ServiceUnavailable',
]


class ScaleError(Exception):
    """Error that triggers SQS retry."""
    pass


def launch_spot_instance(subnet_id: str, job_info: Dict[str, Any]) -> str:
    """Launch a spot instance. Raises ClientError on failure."""
    tags = build_tags(job_info, 'spot')

    response = ec2_client.run_instances(
        LaunchTemplate={
            'LaunchTemplateName': LAUNCH_TEMPLATE_NAME,
            'Version': '$Latest'
        },
        InstanceType=INSTANCE_TYPE,
        SubnetId=subnet_id,
        MinCount=1,
        MaxCount=1,
        InstanceMarketOptions={
            'MarketType': 'spot',
            'SpotOptions': {
                'SpotInstanceType': 'one-time',
                'InstanceInterruptionBehavior': 'terminate',
            }
        },
        TagSpecifications=[
            {'ResourceType': 'instance', 'Tags': tags},
            {'ResourceType': 'volume', 'Tags': tags},
        ]
    )

    instance_id = response['Instances'][0]['InstanceId']
    logger.info(f"Launched spot instance {instance_id} in {subnet_id}")
    return instance_id


def launch_ondemand_instance(subnet_id: str, job_info: Dict[str, Any]) -> str:
    """Launch an on-demand instance as fallback."""
    tags = build_tags(job_info, 'on-demand')

    response = ec2_client.run_instances(
        LaunchTemplate={
            'LaunchTemplateName': LAUNCH_TEMPLATE_NAME,
            'Version': '$Latest'
        },
        InstanceType=INSTANCE_TYPE,
        SubnetId=subnet_id,
        MinCount=1,
        MaxCount=1,
        TagSpecifications=[
            {'ResourceType': 'instance', 'Tags': tags},
            {'ResourceType': 'volume', 'Tags': tags},
        ]
    )

    instance_id = response['Instances'][0]['InstanceId']
    logger.info(f"Launched on-demand instance {instance_id} in {subnet_id}")
    return instance_id


def build_tags(job_info: Dict[str, Any], market_type: str) -> List[Dict[str, str]]:
    """Build EC2 instance tags."""
    tags = [
        {'Key': 'Name', 'Value': f'{ENVIRONMENT}-p4d-action-runner'},
        {'Key': 'ghr:Application', 'Value': 'github-action-runner'},
        {'Key': 'ghr:created_by', 'Value': 'p4d-scale-up-lambda'},
        {'Key': 'ghr:environment', 'Value': ENVIRONMENT},
        {'Key': 'ghr:runner_name_prefix', 'Value': RUNNER_NAME_PREFIX},
        {'Key': 'ghr:ssm_config_path', 'Value': SSM_CONFIG_PATH},
        {'Key': 'ghr:market_type', 'Value': market_type},
        {'Key': 'Environment', 'Value': ENVIRONMENT},
        {'Key': 'Project', 'Value': 'FlashInfer'},
        {'Key': 'ManagedBy', 'Value': 'Terraform'},
    ]

    if job_info.get('repository'):
        tags.append({'Key': 'ghr:repository', 'Value': job_info['repository']})
    if job_info.get('workflow_job_id'):
        tags.append({'Key': 'ghr:workflow_job_id', 'Value': str(job_info['workflow_job_id'])})

    return tags


def pick_subnet() -> str:
    """Pick a random subnet for AZ distribution."""
    valid_subnets = [s for s in SUBNET_IDS if s]
    if not valid_subnets:
        raise ScaleError("No valid subnets configured")
    return random.choice(valid_subnets)


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
    """Lambda handler - launches p4d spot instances with on-demand fallback."""
    logger.info(f"Received event: {json.dumps(event)}")

    if not LAUNCH_TEMPLATE_NAME:
        raise ValueError("LAUNCH_TEMPLATE_NAME environment variable is required")
    if not SUBNET_IDS or SUBNET_IDS == ['']:
        raise ValueError("SUBNET_IDS environment variable is required")

    results = {'successful': [], 'failed': []}

    for record in event.get('Records', []):
        message_id = record.get('messageId', 'unknown')

        try:
            job_info = parse_sqs_message(record)
            logger.info(f"Processing job: {job_info}")

            subnet_id = pick_subnet()
            instance_id = None
            market_type = None

            # Try spot first
            try:
                instance_id = launch_spot_instance(subnet_id, job_info)
                market_type = 'spot'
            except ClientError as e:
                error_code = e.response.get('Error', {}).get('Code', '')
                logger.warning(f"Spot launch failed ({error_code}): {e}")

                if error_code in SPOT_FAILOVER_ERRORS:
                    # Failover to on-demand
                    logger.info("Failing over to on-demand instance...")
                    try:
                        instance_id = launch_ondemand_instance(subnet_id, job_info)
                        market_type = 'on-demand'
                    except ClientError as e2:
                        error_code2 = e2.response.get('Error', {}).get('Code', '')
                        logger.error(f"On-demand launch also failed ({error_code2}): {e2}")
                        if error_code2 in RETRY_ERRORS:
                            raise ScaleError(f"Retryable error: {error_code2}")
                        raise
                elif error_code in RETRY_ERRORS:
                    raise ScaleError(f"Retryable error: {error_code}")
                else:
                    raise

            results['successful'].append({
                'message_id': message_id,
                'instance_id': instance_id,
                'market_type': market_type,
            })

        except ScaleError as e:
            logger.warning(f"Scale error for message {message_id}: {e}")
            results['failed'].append({
                'message_id': message_id,
                'error': str(e),
                'retry': True,
            })

        except Exception as e:
            logger.error(f"Error processing message {message_id}: {e}")
            results['failed'].append({
                'message_id': message_id,
                'error': str(e),
                'retry': False,
            })

    batch_item_failures = [
        {'itemIdentifier': f['message_id']}
        for f in results['failed']
        if f.get('retry', False)
    ]

    response = {
        'statusCode': 200,
        'body': json.dumps(results),
        'batchItemFailures': batch_item_failures,
    }

    logger.info(f"Response: {json.dumps(response)}")
    return response

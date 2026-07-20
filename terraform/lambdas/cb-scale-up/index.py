"""CB Scale-Up Lambda - launches instances into active Capacity Blocks.

Supports one or more launch targets (regions), tried in order:
  1. The primary target from REGION / LAUNCH_TEMPLATE_NAME / SUBNET_IDS env vars
     (unchanged; backward compatible with the single-region setup).
  2. Optional extra targets from EXTRA_LAUNCH_TARGETS, a JSON list of
     {"region", "launch_template", "subnet_ids": [...]} objects.

For each queued job, it picks the first target that has an active Capacity Block
with available capacity and a subnet in the CB's AZ, and launches one instance
there. If no target can be satisfied, it raises ScaleError to trigger an SQS retry.
"""

import json
import logging
import os
from typing import Optional, Dict, Any, List

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION = os.environ.get('REGION', os.environ.get('AWS_REGION', 'us-west-2'))
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'flashinfer')
LAUNCH_TEMPLATE_NAME = os.environ.get('LAUNCH_TEMPLATE_NAME')
SUBNET_IDS = [s for s in os.environ.get('SUBNET_IDS', '').split(',') if s]
INSTANCE_TYPE = os.environ.get('INSTANCE_TYPE')  # e.g., p5.48xlarge
RUNNER_NAME_PREFIX = os.environ.get('RUNNER_NAME_PREFIX', 'flashinfer-cb-')
SSM_CONFIG_PATH = os.environ.get('SSM_CONFIG_PATH')

# Cache EC2 clients per region.
_ec2_clients: Dict[str, Any] = {}


def ec2_client(region: str):
    if region not in _ec2_clients:
        _ec2_clients[region] = boto3.client('ec2', region_name=region)
    return _ec2_clients[region]


class ScaleError(Exception):
    """Error that triggers SQS retry."""
    pass


def build_launch_targets() -> List[Dict[str, Any]]:
    """Ordered list of launch targets. Primary (env) first, then EXTRA_LAUNCH_TARGETS."""
    targets: List[Dict[str, Any]] = [{
        'region': REGION,
        'launch_template': LAUNCH_TEMPLATE_NAME,
        'subnet_ids': SUBNET_IDS,
    }]

    extra = os.environ.get('EXTRA_LAUNCH_TARGETS', '').strip()
    if extra:
        try:
            for t in json.loads(extra):
                subnet_ids = t.get('subnet_ids', [])
                if isinstance(subnet_ids, str):
                    subnet_ids = [s for s in subnet_ids.split(',') if s]
                targets.append({
                    'region': t['region'],
                    'launch_template': t['launch_template'],
                    'subnet_ids': subnet_ids,
                })
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            logger.error(f"Invalid EXTRA_LAUNCH_TARGETS, ignoring extras: {e}")

    return targets


def find_active_capacity_block(client, instance_type: str) -> Optional[Dict[str, Any]]:
    """Find an active CB for the given instance type in the client's region."""
    response = client.describe_capacity_reservations(
        Filters=[
            {'Name': 'state', 'Values': ['active']},
            {'Name': 'instance-type', 'Values': [instance_type]},
        ]
    )

    for cr in response.get('CapacityReservations', []):
        if (cr.get('ReservationType') == 'capacity-block' and
                cr.get('AvailableInstanceCount', 0) > 0):
            cb_id = cr['CapacityReservationId']
            az = cr['AvailabilityZone']
            available = cr['AvailableInstanceCount']
            logger.info(f"Found active CB: {cb_id} in {az} with {available} available")
            return {'id': cb_id, 'az': az, 'available': available}

    logger.info(f"No active Capacity Block for {instance_type} in {client.meta.region_name}")
    return None


def find_subnet_in_az(client, subnet_ids: List[str], az: str) -> Optional[str]:
    """Find a subnet in the given AZ from the target's configured subnets."""
    if not subnet_ids:
        logger.warning("No subnet ids configured for target")
        return None

    response = client.describe_subnets(
        SubnetIds=subnet_ids,
        Filters=[{'Name': 'availability-zone', 'Values': [az]}]
    )

    subnets = response.get('Subnets', [])
    if subnets:
        subnet_id = subnets[0]['SubnetId']
        logger.info(f"Found subnet {subnet_id} in {az}")
        return subnet_id

    logger.warning(f"No subnet found in {az} from configured subnets: {subnet_ids}")
    return None


def launch_instance_into_cb(
    client,
    launch_template: str,
    cb_info: Dict[str, Any],
    subnet_id: str,
    job_info: Dict[str, Any]
) -> str:
    """Launch an EC2 instance into the Capacity Block. Raises ScaleError on retryable errors."""
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

    if job_info.get('repository'):
        tags.append({'Key': 'ghr:repository', 'Value': job_info['repository']})
    if job_info.get('workflow_job_id'):
        tags.append({'Key': 'ghr:workflow_job_id', 'Value': str(job_info['workflow_job_id'])})

    try:
        response = client.run_instances(
            LaunchTemplate={
                'LaunchTemplateName': launch_template,
                'Version': '$Latest'
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
                {'ResourceType': 'instance', 'Tags': tags},
                {'ResourceType': 'volume', 'Tags': tags}
            ]
        )

        instance_id = response['Instances'][0]['InstanceId']
        logger.info(
            f"Launched instance {instance_id} into CB {cb_info['id']} "
            f"({client.meta.region_name})"
        )
        return instance_id

    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', '')
        logger.error(f"Error launching instance in {client.meta.region_name}: {e}")

        retry_errors = [
            'InsufficientInstanceCapacity',
            'RequestLimitExceeded',
            'ServiceUnavailable'
        ]
        if error_code in retry_errors:
            raise ScaleError(f"Retryable error: {error_code}")
        raise


def try_launch_for_job(job_info: Dict[str, Any]) -> Dict[str, Any]:
    """Try each launch target in order; return launch result or raise ScaleError."""
    last_reason = "no target available"

    for target in build_launch_targets():
        region = target['region']
        client = ec2_client(region)

        cb_info = find_active_capacity_block(client, INSTANCE_TYPE)
        if not cb_info:
            last_reason = f"no active CB in {region}"
            continue

        subnet_id = find_subnet_in_az(client, target['subnet_ids'], cb_info['az'])
        if not subnet_id:
            last_reason = f"no subnet in {cb_info['az']} ({region})"
            continue

        try:
            instance_id = launch_instance_into_cb(
                client, target['launch_template'], cb_info, subnet_id, job_info
            )
        except ScaleError as e:
            # Retryable launch failure in this region; try the next target.
            last_reason = f"{region}: {e}"
            continue

        return {
            'instance_id': instance_id,
            'capacity_block_id': cb_info['id'],
            'region': region,
        }

    raise ScaleError(last_reason)


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
    """Lambda handler - receives SQS events and launches instances into CBs."""
    logger.info(f"Received event: {json.dumps(event)}")

    if not LAUNCH_TEMPLATE_NAME:
        raise ValueError("LAUNCH_TEMPLATE_NAME environment variable is required")
    if not INSTANCE_TYPE:
        raise ValueError("INSTANCE_TYPE environment variable is required")
    if not SUBNET_IDS:
        raise ValueError("SUBNET_IDS environment variable is required")

    results = {'successful': [], 'failed': []}

    records = event.get('Records', [])
    logger.info(f"Processing {len(records)} SQS record(s)")

    for record in records:
        message_id = record.get('messageId', 'unknown')

        try:
            job_info = parse_sqs_message(record)
            logger.info(f"Processing job: {job_info}")

            launch = try_launch_for_job(job_info)

            results['successful'].append({
                'message_id': message_id,
                'instance_id': launch['instance_id'],
                'capacity_block_id': launch['capacity_block_id'],
                'region': launch['region'],
            })

        except ScaleError as e:
            logger.warning(f"Scale error for message {message_id}: {e}")
            results['failed'].append({
                'message_id': message_id,
                'error': str(e),
                'retry': True
            })

        except Exception as e:
            logger.error(f"Error processing message {message_id}: {e}")
            results['failed'].append({
                'message_id': message_id,
                'error': str(e),
                'retry': False
            })

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

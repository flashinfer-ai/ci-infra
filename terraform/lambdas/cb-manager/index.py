"""CB Manager Lambda - checks Capacity Block status (read-only)."""

import boto3
import json
import logging
import os
from datetime import datetime, timezone
from typing import Optional, Dict, Any, List

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client('ec2')
DEFAULT_INSTANCE_TYPE = os.environ.get('INSTANCE_TYPE', 'p6-b200.48xlarge')

LABEL_TO_INSTANCE_TYPE = {
    'b200': 'p6-b200.48xlarge',
    'sm100': 'p6-b200.48xlarge',
    'blackwell': 'p6-b200.48xlarge',
    'h100': 'p5.48xlarge',
    'sm90': 'p5.48xlarge',
    'hopper': 'p5.48xlarge',
}


def get_instance_type_from_labels(labels: List[str]) -> Optional[str]:
    """Determine instance type from job labels."""
    if not labels:
        return None

    for label in labels:
        label_lower = label.lower()
        if label_lower in LABEL_TO_INSTANCE_TYPE:
            instance_type = LABEL_TO_INSTANCE_TYPE[label_lower]
            logger.info(f"Matched label '{label}' to instance type '{instance_type}'")
            return instance_type

    return None


def get_active_capacity_blocks(instance_type: str, availability_zone: Optional[str] = None) -> List[Dict]:
    """Find active CB reservations for the given instance type."""
    filters = [
        {'Name': 'instance-type', 'Values': [instance_type]},
        {'Name': 'state', 'Values': ['active', 'pending', 'payment-pending']},
    ]

    if availability_zone:
        filters.append({'Name': 'availability-zone', 'Values': [availability_zone]})

    try:
        response = ec2.describe_capacity_reservations(Filters=filters)

        active_cbs = []
        for cr in response.get('CapacityReservations', []):
            if cr.get('EndDate'):
                start_date = cr.get('StartDate')
                end_date = cr.get('EndDate')
                active_cbs.append({
                    'reservation_id': cr['CapacityReservationId'],
                    'state': cr['State'],
                    'instance_type': cr['InstanceType'],
                    'availability_zone': cr['AvailabilityZone'],
                    'available_capacity': cr.get('AvailableInstanceCount', 0),
                    'total_capacity': cr.get('TotalInstanceCount', 0),
                    'start_date': start_date.isoformat() if start_date else None,
                    'end_date': end_date.isoformat() if end_date else None,
                })

        logger.info(f"Found {len(active_cbs)} active Capacity Blocks for {instance_type}")
        return active_cbs

    except Exception as e:
        logger.error(f"Failed to describe capacity reservations: {e}")
        return []


def handler(event: Dict[str, Any], context) -> Dict[str, Any]:
    """Lambda handler - check/status actions only (purchase disabled)."""
    logger.info(f"CB Manager invoked with event: {json.dumps(event)}")

    action = event.get('action', 'status')
    labels = event.get('labels', [])

    instance_type = event.get('instance_type')
    if not instance_type and labels:
        instance_type = get_instance_type_from_labels(labels)
    if not instance_type:
        instance_type = DEFAULT_INSTANCE_TYPE
        logger.info(f"Using default instance type: {instance_type}")

    az = event.get('availability_zone')

    logger.info(f"Action: {action}, Instance Type: {instance_type}, AZ: {az or 'all'}")
    active_cbs = get_active_capacity_blocks(instance_type, availability_zone=az)

    if action in ['check', 'status']:
        return {
            'statusCode': 200,
            'action': action,
            'instance_type': instance_type,
            'availability_zone': az,
            'active_capacity_blocks': active_cbs,
            'has_active_cb': len(active_cbs) > 0,
        }

    if action in ['ensure', 'purchase']:
        logger.warning(f"Action '{action}' is DISABLED. CBs must be purchased manually.")
        return {
            'statusCode': 400,
            'action': action,
            'error': 'DISABLED',
            'message': 'Automatic CB purchase is DISABLED. Please purchase CBs manually via AWS Console.',
            'active_capacity_blocks': active_cbs,
            'has_active_cb': len(active_cbs) > 0,
        }

    return {
        'statusCode': 400,
        'error': f'Unknown action: {action}',
    }

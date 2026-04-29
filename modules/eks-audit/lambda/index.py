import os
import urllib3
import json
import boto3
import logging

logger = logging.getLogger("EKS-Audit-Collector")
logger.setLevel(logging.INFO)

http = urllib3.PoolManager()
secrets_client = boto3.client('secretsmanager')

_cached_token = None


def handler(event, context):
    if not os.environ.get('FORWARD_URL') or not os.environ.get('SECRET_NAME'):
        logger.error('Missing FORWARD_URL or SECRET_NAME environment variables')
        return

    if 'awslogs' not in event or 'data' not in event.get('awslogs', {}):
        logger.error('Event does not contain awslogs data, skipping')
        return

    global _cached_token
    if _cached_token is None:
        try:
            secret_response = secrets_client.get_secret_value(SecretId=os.environ['SECRET_NAME'])
            _cached_token = secret_response['SecretString']
        except Exception as e:
            logger.error(f'Failed to retrieve collection token from Secrets Manager: {str(e)}')
            return

    # payload is base64-encoded gzip -- the API expects it in this form
    payload = event['awslogs']['data']
    try:
        response = http.request(
            'POST',
            f"{os.environ['FORWARD_URL']}/api/v1/collection/eks-audit",
            body=json.dumps({"logs": payload, "region": os.environ["AWS_REGION"]}),
            headers={"X-Lightlytics-Token": _cached_token, "Content-Type": "application/json"},
            timeout=urllib3.Timeout(connect=2, read=5),
            retries=urllib3.util.Retry(total=2, status_forcelist=[500, 502, 503, 504])
        )
    except Exception as e:
        logger.error(f'Failed to forward logs: {str(e)}')
        return

    if response.status in (401, 403):
        _cached_token = None
        logger.error(f'Authentication failed (status {response.status}), token cache cleared')
    elif response.status >= 400:
        logger.error(f'API returned error status {response.status}')
    else:
        logger.info(f'Forwarded {len(payload)} bytes with status {response.status}')

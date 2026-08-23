"""One-shot trigger that launches the first scanner task at apply time.

Terraform has no "run an ECS task" resource; without this a fresh deployment
produces nothing until the schedule first fires. Failures are swallowed so an
apply is never rolled back over a first scan — the daily EventBridge rule is the
fallback, and the error shows in this function's CloudWatch logs.
"""

import os
import time

import boto3

# aws_lambda_invocation only re-invokes when the Lambda is replaced, so a failure
# here is never retried. Retry the codes that clear on their own — usually IAM
# propagation for role policies attached seconds earlier. InvalidParameterException
# is listed for the same transient reason (subnet/SG not yet visible to ECS); a
# genuinely bad config burns the full ~50s ladder before failing.
RETRY_DELAYS_SECONDS = (5, 10, 15, 20)

RETRYABLE_ERROR_CODES = frozenset(
    {
        # ECS returns ClientException — not AccessDenied — when it cannot yet
        # assume a task/execution role created seconds earlier by the same apply.
        "ClientException",
        "AccessDeniedException",
        "AccessDenied",
        "InvalidParameterException",
        "ClusterNotFoundException",
        "ServerException",
        "ThrottlingException",
    }
)


def _error_code(exc):
    # `or {}` rather than a .get default: botocore exceptions can carry response
    # set to None, and the AttributeError would escape the containing except block
    # and fail the apply.
    response = getattr(exc, "response", None) or {}
    return (response.get("Error") or {}).get("Code", "")


def handler(event, context):
    ecs = boto3.client("ecs")

    # The daily rule and this one-shot each launch an orchestrator that snapshots
    # every volume in the region and fans out children, so an apply overlapping a
    # scheduled run would double snapshot and Fargate spend.
    try:
        running = ecs.list_tasks(
            cluster=os.environ["CLUSTER_ARN"], desiredStatus="RUNNING"
        ).get("taskArns") or []
        if running:
            print(f"scan already in progress ({len(running)} task(s)); not starting another")
            return {"task_arn": "", "skipped": "scan already running"}
    except Exception as exc:  # noqa: BLE001
        # Never block the first scan on a failed pre-check.
        print(f"could not check for running tasks, continuing: {exc}")

    attempts = len(RETRY_DELAYS_SECONDS) + 1
    last_error = ""

    for attempt in range(attempts):
        if attempt:
            delay = RETRY_DELAYS_SECONDS[attempt - 1]
            print(f"initial scan retry {attempt}/{attempts - 1} in {delay}s")
            time.sleep(delay)

        try:
            response = ecs.run_task(
                cluster=os.environ["CLUSTER_ARN"],
                taskDefinition=os.environ["TASK_DEF_ARN"],
                launchType="FARGATE",
                count=1,
                networkConfiguration={
                    "awsvpcConfiguration": {
                        "subnets": os.environ["SUBNET_IDS"].split(","),
                        "securityGroups": [os.environ["SECURITY_GROUP_ID"]],
                        # No public IP on the scanner task — egress is via NAT.
                        "assignPublicIp": "DISABLED",
                    }
                },
            )
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)[:256]
            print(f"initial scan error: {exc}")
            if _error_code(exc) in RETRYABLE_ERROR_CODES:
                continue
            break

        tasks = response.get("tasks") or []
        failures = response.get("failures") or []

        if tasks:
            task_arn = tasks[0].get("taskArn", "")
            print(f"initial scan started: {task_arn}")
            return {"task_arn": task_arn, "failures": [str(f) for f in failures]}

        # RunTask can answer 200 with no task and a `failures` entry instead of
        # raising — capacity, a still-propagating role, a bad subnet. Retry it too.
        last_error = str(failures)[:256]
        print(f"initial scan run_task failures: {failures}")

    print("initial scan did not start; the daily schedule will pick it up")
    return {"task_arn": "", "error": last_error}

"""One-shot trigger that launches the first scanner task at apply time.

Terraform has no native "run an ECS task" resource, so this mirrors the
InitialScanTrigger custom resource in the CloudFormation template: without it a
freshly deployed scanner produces nothing until the schedule's first fire.

Errors are deliberately swallowed — this returns normally on failure so the
apply is never rolled back over a first scan. The daily EventBridge rule is the
fallback, and the failure is visible in this function's CloudWatch logs.
"""

import os
import time

import boto3

# The invocation only re-runs when the Lambda itself is replaced (see
# replace_triggered_by in main.tf), so a failure here is not retried: the scanner
# just stays silent until the next scheduled fire. The most likely failure is IAM eventual
# consistency — the role policies this task needs were attached seconds earlier
# and may not have propagated yet — so retry the handful of errors that clear on
# their own. Total sleep is bounded well inside the function's timeout.
RETRY_DELAYS_SECONDS = (5, 10, 15, 20)

RETRYABLE_ERROR_CODES = frozenset(
    {
        "AccessDeniedException",
        "AccessDenied",
        "InvalidParameterException",
        "ClusterNotFoundException",
        "ServerException",
        "ThrottlingException",
    }
)


def _error_code(exc):
    return getattr(exc, "response", {}).get("Error", {}).get("Code", "")


def handler(event, context):
    ecs = boto3.client("ecs")

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
        # raising — capacity, a still-propagating role, a bad subnet. Same
        # situation as an exception, so it retries the same way.
        last_error = str(failures)[:256]
        print(f"initial scan run_task failures: {failures}")

    print("initial scan did not start; the daily schedule will pick it up")
    return {"task_arn": "", "error": last_error}

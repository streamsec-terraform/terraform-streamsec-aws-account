"""One-shot trigger that launches the first scanner task at apply time.

Terraform has no native "run an ECS task" resource, so this mirrors the
InitialScanTrigger custom resource in the CloudFormation template: without it a
freshly deployed scanner produces nothing until the schedule's first fire.

Errors are deliberately swallowed — this returns normally on failure so the
apply is never rolled back over a first scan. The daily EventBridge rule is the
fallback, and the failure is visible in this function's CloudWatch logs.
"""

import os

import boto3


def handler(event, context):
    try:
        ecs = boto3.client("ecs")
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

        task_arn = ""
        if response.get("tasks"):
            task_arn = response["tasks"][0].get("taskArn", "")

        failures = response.get("failures") or []
        if failures:
            print(f"initial scan run_task failures: {failures}")

        return {"task_arn": task_arn, "failures": [str(f) for f in failures]}
    except Exception as exc:  # noqa: BLE001
        print(f"initial scan error: {exc}")
        return {"task_arn": "", "error": str(exc)[:256]}

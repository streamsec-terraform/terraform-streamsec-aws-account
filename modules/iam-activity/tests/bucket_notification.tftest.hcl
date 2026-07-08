# NOTE: running these tests requires Terraform >= 1.7 (mock_provider blocks) —
# stricter than the module's own required_version. Older versions fail to parse
# this file when running `terraform test`; plan/apply of the module itself is
# unaffected, tests/ is ignored there.

mock_provider "aws" {
  mock_data "aws_s3_bucket" {
    defaults = {
      arn           = "arn:aws:s3:::central-org-trail-bucket"
      bucket_region = "us-east-1"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }
}

mock_provider "streamsec" {}

variables {
  iam_activity_bucket_name = "central-org-trail-bucket"
}

run "notification_created_by_default" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_notification.iam_activity_s3_lambda_trigger) == 1 && length(aws_s3_bucket_notification.bucket_notification) == 0
    error_message = "With defaults the module must create the direct S3->Lambda notification (backward compatibility)."
  }
}

run "eventbridge_notification_created_when_trigger_enabled" {
  command = plan

  variables {
    iam_activity_s3_eventbridge_trigger = true
  }

  assert {
    condition     = length(aws_s3_bucket_notification.bucket_notification) == 1 && length(aws_s3_bucket_notification.iam_activity_s3_lambda_trigger) == 0
    error_message = "With iam_activity_s3_eventbridge_trigger = true the module must create the eventbridge = true notification (backward compatibility)."
  }
}

run "no_notification_when_unmanaged_direct_mode" {
  command = plan

  variables {
    iam_activity_manage_bucket_notification = false
  }

  assert {
    condition     = length(aws_s3_bucket_notification.iam_activity_s3_lambda_trigger) == 0 && length(aws_s3_bucket_notification.bucket_notification) == 0
    error_message = "With iam_activity_manage_bucket_notification = false the module must not create any aws_s3_bucket_notification resource."
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.iam_activity_s3_eventbridge_trigger) == 0
    error_message = "With the default trigger and an unmanaged notification the module must create no trigger at all (bring-your-own EventBridge rule mode)."
  }
}

run "no_notification_when_unmanaged_eventbridge_mode" {
  command = plan

  variables {
    iam_activity_manage_bucket_notification = false
    iam_activity_s3_eventbridge_trigger     = true
  }

  assert {
    condition     = length(aws_s3_bucket_notification.iam_activity_s3_lambda_trigger) == 0 && length(aws_s3_bucket_notification.bucket_notification) == 0
    error_message = "With iam_activity_manage_bucket_notification = false the module must not create any aws_s3_bucket_notification resource, even in eventbridge trigger mode."
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.iam_activity_s3_eventbridge_trigger) == 1 && length(aws_lambda_permission.iam_activity_s3_allow_invoke) == 1
    error_message = "With an unmanaged notification and eventbridge trigger mode the module must still create its own EventBridge rule and invoke permission."
  }
}

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

run "kms_decrypt_granted_for_iam_activity_bucket_key" {
  command = plan

  variables {
    iam_activity_kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_policy.lambda_exec_policy.policy).Statement :
      contains(flatten([s.Action]), "kms:Decrypt") && contains(flatten([s.Resource]), "arn:aws:kms:us-east-1:111111111111:key/11111111-2222-3333-4444-555555555555")
      if s.Effect == "Allow"
    ])
    error_message = "Lambda execution policy must grant kms:Decrypt on iam_activity_kms_key_arn so the collector can read SSE-KMS encrypted CloudTrail objects."
  }
}

run "kms_decrypt_combined_with_collection_bucket_keys" {
  command = plan

  variables {
    iam_activity_kms_key_arn   = "arn:aws:kms:us-east-1:111111111111:key/11111111-2222-3333-4444-555555555555"
    s3_access_logs_bucket_name = "access-logs-bucket"
    s3_access_logs_kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_policy.lambda_exec_policy.policy).Statement :
      contains(flatten([s.Action]), "kms:Decrypt")
      && contains(flatten([s.Resource]), "arn:aws:kms:us-east-1:111111111111:key/11111111-2222-3333-4444-555555555555")
      && contains(flatten([s.Resource]), "arn:aws:kms:us-east-1:111111111111:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
      if s.Effect == "Allow"
    ])
    error_message = "kms:Decrypt must cover both iam_activity_kms_key_arn and the collection bucket KMS keys."
  }
}

run "rejects_empty_string_kms_key_arn" {
  command = plan

  variables {
    iam_activity_kms_key_arn = ""
  }

  expect_failures = [var.iam_activity_kms_key_arn]
}

run "rejects_kms_alias_arn" {
  command = plan

  variables {
    iam_activity_kms_key_arn = "arn:aws:kms:us-east-1:111111111111:alias/my-trail-key"
  }

  expect_failures = [var.iam_activity_kms_key_arn]
}

run "rejects_kms_key_arn_with_trailing_whitespace" {
  command = plan

  variables {
    iam_activity_kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/11111111-2222-3333-4444-555555555555\n"
  }

  expect_failures = [var.iam_activity_kms_key_arn]
}

run "rejects_kms_key_wildcard_arn" {
  command = plan

  variables {
    iam_activity_kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/*"
  }

  expect_failures = [var.iam_activity_kms_key_arn]
}

run "rejects_alias_arn_on_collection_bucket_keys" {
  command = plan

  variables {
    s3_access_logs_bucket_name = "access-logs-bucket"
    s3_access_logs_kms_key_arn = "arn:aws:kms:us-east-1:111111111111:alias/my-logs-key"
  }

  expect_failures = [var.s3_access_logs_kms_key_arn]
}

run "no_kms_statement_when_no_keys_configured" {
  command = plan

  assert {
    condition     = !strcontains(aws_iam_policy.lambda_exec_policy.policy, "kms:Decrypt")
    error_message = "Lambda execution policy must not contain a kms:Decrypt statement when no KMS key ARNs are configured (backward compatibility)."
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

resource "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
  display_name     = var.aws_account_display_name
  cloud_regions    = var.aws_account_regions
}

locals {
  iam_permissions = jsondecode(file("${path.module}/templates/iam_permissions.json"))
}

################################################################################
# IAM Role
################################################################################
resource "aws_iam_role" "this" {
  name        = var.iam_role_use_name_prefix ? null : var.iam_role_name
  name_prefix = var.iam_role_use_name_prefix ? "${var.iam_role_name}" : null
  path        = var.iam_role_path
  description = var.iam_role_description

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${var.streamsec_account}:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "${streamsec_aws_account.this.external_id}"
        }
      }
    }
  ]
}
EOF
  tags               = merge(var.tags, var.iam_role_tags)
}

resource "aws_iam_policy" "streamsec_policy" {
  count = length(local.iam_permissions)

  name        = var.iam_policy_use_name_prefix ? null : "${var.iam_policy_name}${count.index + 1}"
  name_prefix = var.iam_policy_use_name_prefix ? "${var.iam_policy_name}${count.index + 1}" : null
  description = var.iam_policy_description
  path        = var.iam_policy_path

  policy = jsonencode({
    "Version" : "2012-10-17"
    "Statement" : [
      {
        Action   = local.iam_permissions["policy${count.index + 1}"]
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, var.iam_policy_tags)
}

resource "aws_iam_role_policy_attachment" "streamsec_policy_attachment" {
  count = length(local.iam_permissions)

  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.streamsec_policy[count.index].arn
}

resource "time_sleep" "wait" {
  depends_on      = [aws_iam_role_policy_attachment.streamsec_policy_attachment]
  create_duration = "15s"
}


resource "streamsec_aws_account_ack" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
  stack_region     = data.aws_region.current.name
  role_arn         = aws_iam_role.this.arn
  depends_on       = [time_sleep.wait]
}

################################################################################
# Real Time Events CloudTrail
################################################################################

resource "aws_s3_bucket" "streamsec_cloudtrail_bucket" {
  count         = var.create_cloudtrail ? 1 : 0
  bucket        = var.cloudtrail_bucket_use_name_prefix ? null : var.cloudtrail_bucket_name
  bucket_prefix = var.cloudtrail_bucket_use_name_prefix ? var.cloudtrail_bucket_name : null
  force_destroy = var.cloudtrail_bucket_force_destroy

  tags = merge(var.tags, var.cloudtrail_bucket_tags)
}

resource "aws_cloudtrail" "streamsec_cloudtrail" {
  count                         = var.create_cloudtrail ? 1 : 0
  name                          = var.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.streamsec_cloudtrail_bucket[0].bucket
  s3_key_prefix                 = "prefix"
  include_global_service_events = true
  is_multi_region_trail         = true

  tags = merge(var.tags, var.cloudtrail_tags)
}

resource "aws_s3_bucket_policy" "s3_cloudtrail_policy_attachment" {
  count  = var.create_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.streamsec_cloudtrail_bucket[0].id
  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AWSCloudTrailAclCheck20150319",
            "Effect": "Allow",
            "Principal": {
              "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::${aws_s3_bucket.streamsec_cloudtrail_bucket[0].id}"
        },
        {
            "Sid": "AWSCloudTrailWrite20150319",
            "Effect": "Allow",
            "Principal": {
              "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${aws_s3_bucket.streamsec_cloudtrail_bucket[0].id}/prefix/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
            "Condition": {
                "StringEquals": {
                    "s3:x-amz-acl": "bucket-owner-full-control"
                }
            }
        }
    ]
}
POLICY
}

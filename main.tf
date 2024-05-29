provider "streamsec" {
    host = var.domain
    username = var.username
    password = var.password
    workspace_id = var.workspace_id
}

resource "streamsec_aws_account" "this" {
    cloud_account_id = var.aws_account_id
    display_name = var.aws_account_display_name
    cloud_regions = var.aws_account_regions
}

